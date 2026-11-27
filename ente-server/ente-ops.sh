#!/usr/bin/env bash
# ente-ops.sh - running an Ente server set up by ente-setup.sh: health checks and backup verification.
# Usage: ente-ops.sh <command> (see OPS_COMMANDS below)
#   check       read-only health report; exit 1 on any FAIL (daily by ente-check.timer when Telegram alerts are on)
#   verify      deep test that the S3 backup restores (monthly by ente-verify.timer)
#   pg-update   Postgres's minor releases (security fixes), weekly by ente-pg-update.timer
#   rclone-update  rclone's new releases (rclone.org's binary, which apt does not update), weekly by ente-rclone-update.timer
#   news        tells Telegram when Ente has newer builds than the pinned ones, monthly by ente-news.timer (alerts on)
#   size        measures both buckets now and saves it (also done by verify); check and the bot's /status show the last one
# Config and secrets: those of ente-setup.sh. Needs ente-setup.sh next to it (its helpers).
OPS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ente-setup.sh
. "$OPS_DIR/ente-setup.sh" # its helpers and config; its own main does not run when sourced

info() { printf '  INFO  %s\n' "$*"; }

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
BOT_MARKER=/etc/opsbot/plugins.d/ente.json # the telegram bot add-on (Ente as an opsbot plugin) is installed when this exists
BOT_LEGACY=/etc/systemd/system/ente-tg-bot.service # the bot before opsbot

# hours_since STAMP: whole hours since the date in STAMP
hours_since() { echo $((($(date +%s) - $(date -d "$1" +%s)) / 3600)); }

# container_state ID: healthy/unhealthy/starting for a container with a health check, else running/exited/...; "gone" if it
# disappeared meanwhile (a FAIL line, not an aborted check)
container_state() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo gone; }

check_services() {
  local s cid st i img days v
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
    if [[ $s == postgres ]]; then v=$(pg_version "$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)"); ok "$s $st${v:+ ($v)}"; continue; fi
    if [[ -z $img ]]; then ok "$s $st"; continue; fi
    ok "$s $st (image built ${img:0:10})"
    days=$(($(hours_since "$img") / 24))
    ((days <= IMAGE_MAX_DAYS)) || warn "$s image is $days days old: read Ente's release notes, then run ente-setup.sh update"
  done
  systemctl is-enabled --quiet ente-pg-update.timer 2>/dev/null ||
    bad "ente-pg-update.timer not enabled: Postgres gets no security updates (run ente-setup.sh backup-setup)"
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
  for u in "api.$DOMAIN/ping" $(web_hosts | sed "s|\$|.$DOMAIN/|"); do
    if curl -fsS -m 10 -o /dev/null "https://$u" 2>/dev/null; then ok "https://$u"; else bad "https://$u does not answer"; fi
  done
  for h in api $(web_hosts); do
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
  local addon name script marker legacy out rc
  for addon in "s3 proxy|ente-s3-proxy.sh|$CADDY_SITES/s3-proxy.caddy" "telegram bot|ente-tg-bot.sh|$BOT_MARKER|$BOT_LEGACY"; do
    IFS='|' read -r name script marker legacy <<<"$addon"
    [[ -e $marker || ( -n $legacy && -e $legacy ) ]] || continue
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
  local s running= b e U_DATE U_PHOTO U_BACKUP
  echo "== backup"
  for s in .restore-incomplete .restore-finishing; do
    [[ ! -e $ENTE_DIR/$s ]] || bad "a restore did not finish ($ENTE_DIR/$s): run ente-setup.sh restore again"
  done
  # the backup copies the bucket in its env file, through the ente-s3 remote: both must be the one museum uses
  b=$(backup_env_bucket) e=$(photo_remote_endpoint)
  if [[ -n $b && ($b != "$PHOTO_BUCKET" || (-n $e && $e != "$PHOTO_ENDPOINT")) ]]; then
    bad "the backup copies ${e:-?}/$b, but museum uses $PHOTO_ENDPOINT/$PHOTO_BUCKET: run ente-setup.sh backup-setup"
  fi
  if [[ $(systemctl show ente-backup.service -p ActiveState --value 2>/dev/null) == activating ]]; then running=1; ok "a backup is running now"; fi
  systemctl is-enabled --quiet ente-rclone-update.timer 2>/dev/null ||
    bad "ente-rclone-update.timer not enabled: rclone gets no updates (run ente-setup.sh backup-setup)"
  stamp_check last-ok-s3 "last good backup" "$running"
  stamp_check last-ok-photo-config "config copy in the photo bucket" "$running"
  s=$(cat "$BACKUP_STATE"/verify-ok 2>/dev/null || true)
  if ! systemctl is-enabled --quiet ente-verify.timer 2>/dev/null; then bad "ente-verify.timer not enabled (run backup-setup)"
  elif [[ -z $s ]]; then warn "monthly verify has not passed yet (run: $0 verify)"
  elif (($(hours_since "$s") > 45 * 24)); then bad "last good verify is older than 45 days ($s)"
  else ok "monthly verify: last passed $s"; fi
  [[ -n $TG_CHAT_ID || -n $HC_URL ]] || warn "no failure alerts (set TG_CHAT_ID or HC_URL)"
  if usage_get "$BACKUP_STATE/usage"; then info "buckets: photos $U_PHOTO; backup $U_BACKUP (measured $U_DATE)"
  else info "buckets: not measured yet (run: $0 size, or wait for the monthly verify)"; fi
  if [[ -n $TG_CHAT_ID ]] && ! systemctl is-enabled --quiet ente-news.timer 2>/dev/null; then
    bad "ente-news.timer not enabled: no monthly note about new Ente builds (run ente-setup.sh backup-setup)"
  fi
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
  if measure_buckets; then usage_get "$BACKUP_STATE/usage"; info "bucket usage saved: photos $U_PHOTO; backup $U_BACKUP"
  else warn "cannot list the buckets to measure them (the last measurement stays)"; fi

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

# ---------------------------------------------------------------- size
# size_of REMOTE [FLAGS]: "BYTES COUNT" of REMOTE as rclone lists it (current objects only; providers that keep old versions
# bill those too). Nothing on failure. The S3 API has no bucket-size call: this lists every object, 1000 per request.
size_of() { rclone size --json "$@" 2>/dev/null | sed -nE 's/.*"count":([0-9]+).*"bytes":([0-9]+).*/\2 \1/p'; }
# measure_buckets: measures the photo bucket (without the config copy) and the whole backup bucket and saves both to
# $BACKUP_STATE/usage (see usage_get). Returns 1, keeping the last measurement, when either cannot be listed.
measure_buckets() {
  local p b
  p=$(size_of "ente-s3:$PHOTO_BUCKET" --exclude "/$PHOTO_CFG_DIR/**") && [[ -n $p ]] || return 1
  b=$(size_of "$BACKUP_ROOT") && [[ -n $b ]] || return 1
  mkdir -p "$BACKUP_STATE"
  printf 'date %s\nphoto %s\nbackup %s\n' "$(date -Is)" "$p" "$b" >"$BACKUP_STATE/usage.tmp" && mv "$BACKUP_STATE/usage.tmp" "$BACKUP_STATE/usage"
}
# size: measure now (by hand, or the bot's /size). Prints one line per bucket.
cmd_size() {
  local U_DATE U_PHOTO U_BACKUP
  load_env
  measure_buckets || die "cannot list the buckets (the last measurement stays)"
  usage_get "$BACKUP_STATE/usage"
  echo "photo bucket $PHOTO_BUCKET: $U_PHOTO"
  echo "backup bucket ${BACKUP_ROOT%/}: $U_BACKUP"
}

# ---------------------------------------------------------------- pg-update
# pg_version IMAGE: the Postgres version an image holds (its PG_VERSION), e.g. 15.14
pg_version() { docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | sed -n 's/^PG_VERSION=//p' || true; }
# pg-update: Postgres's minor releases (security and bug fixes; same data format, so no dump and restore), weekly by
# ente-pg-update.timer. Pulls the image compose names (postgres:15: never a new major version). If it is a newer build than the
# running one, and the last good backup is less than 36 h old (the rollback point), recreates postgres, restarts museum (fresh
# database connections) and checks that it answers. Waits for next week while a backup or verify runs (both use the database).
cmd_pg_update() {
  load_env
  local cid img run new s u
  cid=$(dc ps -q postgres 2>/dev/null || true)
  [[ -n $cid ]] || die "postgres is not running"
  img=$(docker inspect -f '{{.Config.Image}}' "$cid") || die "cannot inspect postgres"
  run=$(docker inspect -f '{{.Image}}' "$cid") || die "cannot inspect postgres"
  dc pull -q postgres || die "cannot pull $img"
  new=$(docker image inspect -f '{{.Id}}' "$img") || die "cannot inspect $img"
  if [[ $new == "$run" ]]; then log "postgres $(pg_version "$run") is current"; return 0; fi
  for u in ente-backup.service ente-verify.service; do
    if [[ $(systemctl show "$u" -p ActiveState --value 2>/dev/null) == activating ]]; then
      log "$u is running: postgres $(pg_version "$new") waits for next week"; return 0
    fi
  done
  s=$(cat "$BACKUP_STATE/last-ok-s3" 2>/dev/null || true)
  [[ -n $s ]] && (($(hours_since "$s") < 36)) ||
    die "postgres $(pg_version "$run") -> $(pg_version "$new") not applied: no good backup in the last 36 h (the rollback point)"
  if [[ $(pg_version "$run") == "$(pg_version "$new")" ]]; then log "postgres $(pg_version "$new"): a rebuilt image (its base system's fixes)"
  else log "postgres $(pg_version "$run") -> $(pg_version "$new")"; fi
  dc up -d postgres
  wait_healthy postgres 120
  dc restart museum >/dev/null
  wait_healthy museum
  url_ok http://127.0.0.1:8080/ping 10 || die "museum /ping fails after the postgres update"
  docker image prune -f >/dev/null
  log "postgres updated to $(pg_version "$new")"
}

# ---------------------------------------------------------------- rclone-update
# rclone_ver: the installed rclone's version, e.g. v1.72.0
rclone_ver() { rclone version 2>/dev/null | awk 'NR == 1 {print $2}' || true; }
# rclone-update: rclone from rclone.org (its install script, as install_rclone does) is a plain binary apt never updates, so
# `rclone selfupdate` (it checks the download's checksum) runs weekly by ente-rclone-update.timer. The new version must still
# read both buckets (the backup bucket's encrypted config, the photo bucket), else the previous binary goes back and it fails
# (an alert). The previous binary stays next to it (.prev) for a rollback by hand. Waits while a backup or verify runs.
# An rclone from a Debian package is left to apt.
cmd_rclone_update() {
  load_env
  local bin old new u
  bin=$(command -v rclone) || die "rclone is not installed"
  bin=$(readlink -f "$bin")
  if dpkg -S "$bin" >/dev/null 2>&1; then log "rclone comes from a Debian package: apt updates it"; return 0; fi
  for u in ente-backup.service ente-verify.service; do
    if [[ $(systemctl show "$u" -p ActiveState --value 2>/dev/null) == activating ]]; then
      log "$u is running: the rclone update waits for next week"; return 0
    fi
  done
  old=$(rclone_ver)
  # the running version, kept aside: it becomes .prev only if a new one arrives (a run with nothing new keeps the old .prev)
  cp -p "$bin" "$bin.old" || { rm -f "$bin.old"; die "cannot keep a copy of $bin (disk full?)"; }
  rclone selfupdate --stable >/dev/null 2>&1 || { rm -f "$bin.old"; die "rclone selfupdate failed (still $old)"; }
  new=$(rclone_ver)
  if [[ $new == "$old" ]]; then rm -f "$bin.old"; log "rclone $old is current"; return 0; fi
  if ! rclone lsf backup-crypt: --max-depth 1 >/dev/null 2>&1 || ! rclone lsf "ente-s3:$PHOTO_BUCKET" --max-depth 1 >/dev/null 2>&1; then
    mv -f "$bin.old" "$bin"
    die "rclone $new cannot read the buckets: back to $(rclone_ver)"
  fi
  mv -f "$bin.old" "$bin.prev"
  log "rclone $old -> $new (the previous one is $bin.prev)"
}

# ---------------------------------------------------------------- news
ALERT_BIN=/usr/local/bin/opsbot-notify # installed by setup_alerts (opsbot)
# reg_info REF: "DIGEST DATE" of REF in the registry: the image index digest (what image-pins hold) and the amd64 build date.
# Asks the registry only; nothing is downloaded.
reg_info() {
  docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}} {{(index .Image "linux/amd64").Created}}' 2>/dev/null |
    awk 'NR == 1 {print $1, $2}'
}
# news: Ente's images have no versions, so this compares the pinned builds with the registry's `latest`. When there is a newer one,
# it says so (with both build dates) and sends it to Telegram if alerts are on; monthly by ente-news.timer. Silent when current.
cmd_news() {
  load_env
  local svc repo pin cur new msg=''
  for svc in museum web; do
    repo=$(repo_of $svc); pin=$(pin_of $svc)
    new=$(reg_info "$repo:latest"); [[ -n $new ]] || die "cannot ask the registry about $repo:latest"
    [[ ${new%% *} != "${pin#*@}" ]] || continue
    cur=$(reg_info "$pin"); cur=${cur#* }
    msg+="$svc: running the build of ${cur:-an unknown date}, a newer one is from ${new#* }"$'
'
  done
  if [[ -z $msg ]]; then log "Ente is current (museum and web are the latest builds)"; return 0; fi
  msg+=$'
'"Read the release notes (https://github.com/ente/ente/releases), then: sudo $SCRIPT_DIR/ente-setup.sh update"
  printf '%s
' "$msg"
  if [[ -n $TG_CHAT_ID && -x $ALERT_BIN ]]; then printf '%s
' "$msg" | "$ALERT_BIN" "🆕 Newer Ente builds for $(hostname)" || die "could not send to Telegram"; fi
}

# ---------------------------------------------------------------- main
OPS_COMMANDS="check verify pg-update rclone-update news size"
ops_usage() { echo "usage: $0 {${OPS_COMMANDS// /|}}" >&2; exit 2; }

# sourced (tests): define the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  [[ $# -eq 1 && " $OPS_COMMANDS " == *" $1 "* ]] || ops_usage
  [[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $*)" >&2; exit 1; }
  touch "$LOG"; chmod 600 "$LOG"
  main "$@" 2>&1 | tee -a "$LOG"
fi
