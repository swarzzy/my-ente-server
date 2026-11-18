#!/usr/bin/env bash
# ente-ops.sh - running an Ente server set up by ente-setup.sh: health checks and backup verification.
# Usage: ente-ops.sh <command> (see OPS_COMMANDS below)
#   check       read-only health report; exit 1 on any FAIL (daily by ente-check.timer when Telegram alerts are on)
#   verify      deep test that the S3 backup restores (monthly by ente-verify.timer)
# Config and secrets: those of ente-setup.sh. Needs ente-setup.sh next to it (its helpers).
OPS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ente-setup.sh
. "$OPS_DIR/ente-setup.sh" # its helpers and config; its own main does not run when sourced

# new_uploads NAME: prints a temp file of rclone exclude rules naming the photo objects uploaded since the last good backup to
# NAME (s3) started. They are not in that backup yet, and that is not an error. The caller passes it as --exclude-from
# and removes it. It also excludes the config copy ($PHOTO_CFG_DIR/). One listing, no request per object. (An age filter instead would also hide freshly copied backup objects.)
new_uploads() {
  local s f; f=$(mktemp)
  echo "/$PHOTO_CFG_DIR/**" >"$f" # the config copy, not a photo
  if s=$(cat "$BACKUP_STATE/last-ok-$1" 2>/dev/null); then
    rclone lsf -R --files-only --use-server-modtime --max-age "$(($(date +%s) - $(date -d "$s" +%s) + 60))s" "ente-s3:$PHOTO_BUCKET" \
      --exclude "/$PHOTO_CFG_DIR/**" 2>/dev/null |
      sed 's/[][*?{}\\]/\\&/g; s|^|/|' >>"$f" || true
  fi
  echo "$f"
}
# rc_err OUTPUT: the error lines of an rclone run, without timestamps, on one line.
rc_err() { grep -E 'ERROR|Failed to' <<<"$1" | sed -E 's|^[0-9/]+ [0-9:]+ ||' | head -3 | tr '\n' ' ' || true; }

# ---------------------------------------------------------------- check
# check: read-only health report, daily by ente-check.timer (every FAIL is a Telegram alert). Each FAIL is something that can
# break on its own and that nothing else reports; a failed backup run alerts by itself (OnFailure), so here backups count
# only by the age of their last success. Sections are functions; they count FAILs in FAILS.
REBOOT_FLAG=/var/run/reboot-required
CERT_MIN_DAYS=20 # Caddy renews at 30 days left: fewer means renewal is failing
IMAGE_MAX_DAYS=60
DISK_WARN=80 DISK_FAIL=90
BOT_UNIT_FILE=/etc/systemd/system/ente-tg-bot.service # the telegram bot add-on is installed when this exists

# hours_since STAMP: whole hours since the date in STAMP
hours_since() { echo $((($(date +%s) - $(date -d "$1" +%s)) / 3600)); }

# container_state ID: healthy/unhealthy/starting for a container with a health check, else running/exited/...; "gone" if it
# disappeared meanwhile (a FAIL line, not an aborted check)
container_state() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo gone; }

check_services() {
  local s cid st i img days
  echo "== services"
  for s in museum web postgres; do
    cid=$(dc ps -q "$s" 2>/dev/null || true)
    if [[ -z $cid ]]; then bad "$s not running"; continue; fi
    st=$(container_state "$cid")
    for ((i = 0; i < 20; i++)); do # just restarted (lockdown, update, reboot): give it a minute instead of a false alarm
      [[ $st == starting || $st == restarting ]] || break
      sleep 3
      st=$(container_state "$cid")
    done
    if [[ $st != healthy && $st != running ]]; then bad "$s $st"; continue; fi
    img=$(docker image inspect -f '{{.Created}}' "$(docker inspect -f '{{.Image}}' "$cid")" 2>/dev/null || true)
    if [[ $s == postgres || -z $img ]]; then ok "$s $st"; continue; fi
    ok "$s $st (image built ${img:0:10})"
    days=$(($(hours_since "$img") / 24))
    ((days <= IMAGE_MAX_DAYS)) || warn "$s image is $days days old: read Ente's release notes, then run ente-setup.sh update"
  done
  if internal_locked; then ok "sign-ups closed"
  elif [[ -n $(internal_admin) ]]; then bad "sign-ups are OPEN although lockdown was done (re-run lockdown)"
  else warn "sign-ups are open: run lockdown once the family has signed up"; fi
}

# cert_days HOST: days left on the certificate Caddy serves for HOST (nothing if it serves none)
cert_days() {
  local end
  end=$(openssl s_client -connect 127.0.0.1:443 -servername "$1" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null) || return 0
  echo $((($(date -d "${end#notAfter=}" +%s) - $(date +%s)) / 86400))
}
check_web() {
  local h u d min=
  echo "== web"
  if ! systemctl is-active --quiet caddy; then bad "caddy is not running (journalctl -u caddy)"; return 0; fi
  for u in "api.$DOMAIN/ping" "web.$DOMAIN/" "albums.$DOMAIN/"; do
    if curl -fsS -m 10 -o /dev/null "https://$u" 2>/dev/null; then ok "https://$u"; else bad "https://$u does not answer"; fi
  done
  for h in api web albums; do
    d=$(cert_days "$h.$DOMAIN")
    if [[ -z $d ]]; then bad "no certificate served for $h.$DOMAIN"
    elif ((d < CERT_MIN_DAYS)); then bad "certificate of $h.$DOMAIN expires in $d days: renewal is failing (journalctl -u caddy)"
    elif [[ -z $min ]] || ((d < min)); then min=$d; fi
  done
  [[ -z $min ]] || ok "certificates valid for $min+ days"
}

# public_listeners: TCP sockets reachable from outside (not on loopback) other than SSH, 80 and 443, as ADDRESS:PORT PROCESS
public_listeners() {
  local addr peer proc
  while read -r _ _ _ addr peer proc; do
    case "${addr%:*}" in 127.* | \[::1\] | \[::ffff:127.*) continue ;; esac
    case "${addr##*:}" in "$SSH_PORT" | 80 | 443) continue ;; esac
    proc=$(sed -nE 's/^users:\(\("([^"]+)".*/\1/p' <<<"$proc")
    echo "$addr${proc:+ ($proc)}"
  done < <(ss -Htlnp)
}
check_security() {
  local s out miss=
  echo "== security"
  out=$(public_listeners)
  if [[ -z $out ]]; then ok "from outside only SSH ($SSH_PORT), 80 and 443 are open (TCP)"
  else bad "listening beyond localhost: $(tr '\n' ' ' <<<"$out")(Docker bypasses ufw)"; fi
  out=$(sshd -T 2>/dev/null || true)
  for s in "passwordauthentication no" "permitrootlogin no" "maxauthtries 3" "allowusers ${ADMIN_USER:-?}"; do
    grep -qx "$s" <<<"$out" || miss+="${miss:+, }$s"
  done
  if [[ -z $miss ]]; then ok "sshd: keys only, no root, 3 tries, only $ADMIN_USER"; else bad "sshd expected: $miss"; fi
  if [[ -n $(ss -Htln "sport = :$SSH_PORT") ]]; then ok "sshd listening on $SSH_PORT"; else bad "sshd not listening on $SSH_PORT"; fi
  out=$(ufw status 2>/dev/null || true)
  if ! grep -q '^Status: active' <<<"$out"; then bad "ufw inactive"
  elif ! grep -qE "^$SSH_PORT/tcp +ALLOW" <<<"$out"; then bad "ufw does not allow $SSH_PORT/tcp (SSH)"
  else ok "ufw active, SSH allowed"; fi
}

check_bucket() {
  local out
  echo "== photo bucket"
  if [[ $PHOTO_ENDPOINT/$PHOTO_BUCKET != "$S3_ENDPOINT/$S3_BUCKET" ]]; then
    warn "ente-setup.env names $S3_ENDPOINT/$S3_BUCKET but museum uses $PHOTO_ENDPOINT/$PHOTO_BUCKET: re-run install to switch"
  fi
  if out=$(rclone lsf "ente-s3:$PHOTO_BUCKET" --max-depth 1 2>&1 >/dev/null); then ok "bucket $PHOTO_BUCKET reachable"; else bad "bucket $PHOTO_BUCKET: $out"; fi
  out=$(curl -sS -m 10 -o /dev/null -D - -X OPTIONS -H "Origin: https://web.$DOMAIN" -H "Access-Control-Request-Method: PUT" \
    "https://$PHOTO_ENDPOINT/$PHOTO_BUCKET/ente-check" 2>&1 || true)
  if grep -qi '^access-control-allow-origin:' <<<"$out"; then ok "CORS preflight from https://web.$DOMAIN allowed"; else bad "CORS preflight from https://web.$DOMAIN not allowed (web uploads will fail)"; fi
}

# check_addons: each installed add-on's own check (name, script, the file that marks it installed); its FAIL lines count here
check_addons() {
  local addon name script marker out rc
  for addon in "s3 proxy|ente-s3-proxy.sh|$CADDY_SITES/s3-proxy.caddy" "telegram bot|ente-tg-bot.sh|$BOT_UNIT_FILE"; do
    IFS='|' read -r name script marker <<<"$addon"
    [[ -e $marker ]] || continue
    echo "== $name"
    if [[ ! -f $SCRIPT_DIR/$script ]]; then bad "the $name is installed but $script is not next to $0"; continue; fi
    out=$(bash "$SCRIPT_DIR/$script" check 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out"
    FAILS=$((FAILS + $(grep -c '^  FAIL' <<<"$out" || true)))
    if ((rc != 0)) && ! grep -q '^  FAIL' <<<"$out"; then bad "the $name check did not run (exit $rc): $(tail -1 <<<"$out" | cut -c1-160)"; fi
  done
}

# stamp_check NAME WHAT RUNNING: FAIL unless the backup left the stamp NAME (time of its last success) less than 36 h ago
stamp_check() {
  local s; s=$(cat "$BACKUP_STATE/$1" 2>/dev/null || true)
  if [[ -z $s && -n $3 ]]; then warn "$2: none yet, the first backup is running"
  elif [[ -z $s ]]; then bad "$2: none yet (journalctl -u ente-backup.service)"
  elif (($(hours_since "$s") >= 36)); then bad "$2 is older than 36 h: $s (journalctl -u ente-backup.service)"
  else ok "$2 $s"; fi
}
check_backup() {
  local s running=
  echo "== backup"
  for s in .restore-incomplete .restore-finishing; do
    [[ ! -e $ENTE_DIR/$s ]] || bad "a restore did not finish ($ENTE_DIR/$s): run ente-setup.sh restore again"
  done
  if [[ $(systemctl show ente-backup.service -p ActiveState --value 2>/dev/null) == activating ]]; then running=1; ok "a backup is running now"; fi
  stamp_check last-ok-s3 "last good backup" "$running"
  stamp_check last-ok-photo-config "config copy in the photo bucket" "$running"
  s=$(cat "$BACKUP_STATE"/verify-ok 2>/dev/null || true)
  if ! systemctl is-enabled --quiet ente-verify.timer 2>/dev/null; then bad "ente-verify.timer not enabled (run backup-setup)"
  elif [[ -z $s ]]; then warn "monthly verify has not passed yet (run: $0 verify)"
  elif (($(hours_since "$s") > 45 * 24)); then bad "last good verify is older than 45 days ($s)"
  else ok "monthly verify: last passed $s"; fi
  [[ -n $TG_CHAT_ID || -n $HC_URL ]] || warn "no failure alerts (set TG_CHAT_ID or HC_URL)"
}

check_system() {
  local pct used size n
  echo "== system"
  read -r pct used size < <(df -h --output=pcent,used,size / | tail -1)
  pct=${pct%\%}
  if ((pct >= DISK_FAIL)); then bad "disk / is $pct% full ($used of $size)"
  elif ((pct >= DISK_WARN)); then warn "disk / is $pct% full ($used of $size)"
  else ok "disk / $pct% used ($used of $size)"; fi
  n=$(journalctl -k -q --since '24 hours ago' 2>/dev/null | grep -ciE 'out of memory|oom-kill' || true)
  if [[ $n == 0 ]]; then ok "no OOM kills in 24 h"; else bad "$n OOM kernel messages in 24 h (journalctl -k | grep -i oom)"; fi
  if [[ ! -e $REBOOT_FLAG ]]; then ok "no reboot pending"
  elif (($(hours_since "@$(stat -c %Y "$REBOOT_FLAG")") >= 24)); then warn "reboot pending for over a day: the automatic reboot (02:00) did not happen"
  else ok "reboot pending: automatic at 02:00"; fi
}

cmd_check() {
  load_env
  check_services
  check_web
  check_security
  check_bucket
  check_addons
  check_backup
  check_system
  echo
  if ((FAILS)); then echo "$FAILS check(s) FAILED"; return 1; fi
  echo "all checks passed"
}

# ---------------------------------------------------------------- verify
# verify: deep test of the backup, monthly by ente-verify.timer (a FAIL alerts like the daily check). It proves the backup can
# be restored, which `check` does not: photo objects by checksum, the encrypted config in both buckets decrypted and compared
# byte for byte, and a test restore of the newest dump into a scratch database. It also reports how big the backup bucket has
# grown (nothing is ever deleted there). It changes neither the backup nor the live database.
verify_cleanup() {
  dc exec -T postgres rm -f /tmp/ente-verify.dump </dev/null >/dev/null 2>&1 || true
  dc exec -T postgres psql -U pguser -d postgres -qc 'DROP DATABASE IF EXISTS ente_verify' </dev/null >/dev/null 2>&1 || true
}
# vq ARGS: psql in the postgres container, unaligned output with space-separated columns.
vq() { dc exec -T postgres psql -U pguser -At -F ' ' "$@" </dev/null; }
info() { printf '  INFO  %s\n' "$*"; }
# backup_growth: one line on the backup bucket's size: photos (and those no longer in the photo bucket, which a clean-up would
# remove) and dumps. Information only.
backup_growth() {
  local d out n b gn gb dn db; d=$(mktemp -d)
  if rclone lsf -R --files-only "ente-s3:$PHOTO_BUCKET" --exclude "/$PHOTO_CFG_DIR/**" >"$d/src" 2>/dev/null &&
    rclone lsf -R --files-only --format ps --separator $'\t' "${BACKUP_ROOT}objects" >"$d/dst" 2>/dev/null &&
    rclone lsf --files-only --format ps --separator $'\t' --include 'ente_db-*.dump' backup-crypt: >"$d/dumps" 2>/dev/null; then
    out=$(awk -F'\t' 'FILENAME == ARGV[1] {src[$0]; next}
      FILENAME == ARGV[2] {n++; b += $2; if (!($1 in src)) {gn++; gb += $2}; next}
      {dn++; db += $2}
      END {printf "%d %d %d %d %d %d\n", n, b, gn, gb, dn, db}' "$d/src" "$d/dst" "$d/dumps")
    read -r n b gn gb dn db <<<"$out"
    info "backup bucket: $n photos ($(numfmt --to=iec-i --suffix=B "$b")), $gn of them ($(numfmt --to=iec-i --suffix=B "$gb")) no longer in the photo bucket; $dn dumps ($(numfmt --to=iec-i --suffix=B "$db")). Clean-up: README, Backups"
  else warn "cannot list the buckets to measure the backup bucket"; fi
  rm -rf "$d"
}
cmd_verify() {
  load_env
  local out dump n h i live rest lt lu lf rt ru rf ex counts_sql
  rclone listremotes | grep -x 'backup-crypt:' >/dev/null || die "run backup-setup first"
  rclone listremotes | grep -x 'photo-crypt:' >/dev/null || die "run backup-setup first (no config copy in the photo bucket)"
  for ((i = 0; i < 720; i++)); do # a backup that is still running would show false differences: wait for it, up to 6 h
    [[ $(systemctl show ente-backup.service -p ActiveState --value) == activating ]] || break
    ((i)) || log "a backup is running, waiting for it"
    sleep 30
  done
  ((i < 720)) || die "the backup is still running after 6 h"
  trap verify_cleanup EXIT

  echo "== photo objects (checksums)"
  ex=$(new_uploads s3)
  if out=$(rclone check "ente-s3:$PHOTO_BUCKET" "${BACKUP_ROOT}objects" --one-way --checkers 4 --exclude-from "$ex" 2>&1); then
    n=$(grep -oE '[0-9]+ matching files' <<<"$out" | tail -1 || true)
    h=$(grep -oE '[0-9]+ hashes could not be checked' <<<"$out" | tail -1 | grep -oE '^[0-9]+' || true)
    ok "photo bucket is in the backup (${n:-0 matching files}${h:+, $h of them by size: no common checksum, e.g. multipart uploads}; $(($(wc -l <"$ex") - 1)) uploaded after the last backup started, not compared)"
  else bad "photo objects differ from the backup: $(rc_err "$out")"; fi
  rm -f "$ex"
  backup_growth

  echo "== config backup (decrypted, byte for byte)"
  if out=$(rclone check "$DUMP_DIR" backup-crypt: --one-way --download --checkers 4 2>&1); then
    ok "config backup decrypts with the stored passphrase and equals the local copies ($(grep -oE '[0-9]+ matching files' <<<"$out" | tail -1))"
  else bad "config backup differs or cannot be decrypted: $(rc_err "$out")"; fi
  if out=$(rclone check "$DUMP_DIR" photo-crypt: --download --checkers 4 2>&1); then
    ok "config copy in the photo bucket decrypts and equals the local copies ($(grep -oE '[0-9]+ matching files' <<<"$out" | tail -1))"
  else bad "config copy in the photo bucket differs or cannot be decrypted: $(rc_err "$out")"; fi

  # the local newest dump: the step above proved the backed-up copies equal to the local files
  echo "== database dump (test restore into a scratch database)"
  dump=$(cd "$DUMP_DIR" 2>/dev/null && ls ente_db-*.dump 2>/dev/null | sort | tail -1 || true)
  counts_sql="SELECT (SELECT count(*) FROM pg_tables WHERE schemaname = 'public'), (SELECT count(*) FROM users), (SELECT count(*) FROM files)"
  if [[ -z $dump ]]; then bad "no database dump in $DUMP_DIR"
  elif ! vq -d postgres -qc 'DROP DATABASE IF EXISTS ente_verify' -c 'CREATE DATABASE ente_verify' >/dev/null 2>&1 ||
    ! dc cp "$DUMP_DIR/$dump" postgres:/tmp/ente-verify.dump </dev/null >/dev/null 2>&1; then bad "cannot prepare the scratch database"
  elif ! out=$(dc exec -T postgres pg_restore -U pguser -d ente_verify --no-owner --exit-on-error /tmp/ente-verify.dump </dev/null 2>&1); then
    bad "$dump does not restore: $(tail -2 <<<"$out" | tr '\n' ' ')"
  elif ! live=$(vq -d ente_db -c "$counts_sql") || ! rest=$(vq -d ente_verify -c "$counts_sql"); then bad "cannot count rows after the test restore"
  else
    read -r lt lu lf <<<"$live"; read -r rt ru rf <<<"$rest"
    # the dump is older than the live data (an update since may even have added tables), so counts may differ; an empty
    # table that is not empty live is damage
    if ((rt > 0)) && { ((ru > 0)) || ((lu == 0)); } && { ((rf > 0)) || ((lf == 0)); }; then
      ok "$dump restores: $rt tables, $ru users, $rf files (live now: $lt tables, $lu users, $lf files)"
    else bad "restored $dump looks incomplete: $rt tables, $ru users, $rf files (live: $lt tables, $lu users, $lf files)"; fi
  fi
  verify_cleanup; trap - EXIT
  echo
  if ((FAILS)); then echo "$FAILS verify check(s) FAILED"; return 1; fi
  mkdir -p "$BACKUP_STATE"; date -Is >"$BACKUP_STATE/verify-ok"
  echo "backup verified"
}

# ---------------------------------------------------------------- main
OPS_COMMANDS="check verify"
ops_usage() { echo "usage: $0 {${OPS_COMMANDS// /|}}" >&2; exit 2; }

# sourced (tests): define the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  [[ $# -eq 1 && " $OPS_COMMANDS " == *" $1 "* ]] || ops_usage
  [[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $*)" >&2; exit 1; }
  touch "$LOG"; chmod 600 "$LOG"
  main "$@" 2>&1 | tee -a "$LOG"
fi
