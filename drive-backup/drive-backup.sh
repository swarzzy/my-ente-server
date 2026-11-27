#!/usr/bin/env bash
# drive-backup.sh - nightly copy of an S3 bucket (Mountain Duck's Cryptomator vault: only encrypted files) to a Backblaze B2
# bucket that keeps every changed and deleted file for its lifecycle's days, with a guard against mass changes; an opsbot
# plugin (/drive_sync, /drive_force, a /status line). See README.md.
set -euo pipefail
umask 022

DB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ENV_FILE=${ENV_FILE:-$DB_DIR/drive-backup.env}
SECRETS_FILE=${SECRETS_FILE:-$DB_DIR/drive-backup.secrets}
ETC=${ETC:-/etc/drive-backup}
RCLONE_CONF=${RCLONE_CONF:-$ETC/rclone.conf}
STATE=${STATE:-/var/lib/drive-backup}   # last-ok, verify-ok, guard, and the last run's plan
UNITS=${UNITS:-/etc/systemd/system}
OPSBOT_CLI=${OPSBOT_CLI:-/usr/local/sbin/opsbot}
NOTIFY_UNIT=${NOTIFY_UNIT:-/usr/local/bin/opsbot-notify-unit}
LOG=${LOG:-/var/log/drive-backup.log}
STALE_H=36       # a last good sync older than this is a problem
VERIFY_H=720     # a sync verifies the backup when the last verify is older than this (30 days)
CMD=drive
FAILS=0

# ---------------------------------------------------------------- helpers
log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$CMD" "$*"; }
# die MESSAGE [STATUS]: 1 an error, 3 the guard held changes back, 4 the verify failed (each has its own alert title)
die()  { log "ERROR: $1" >&2; exit "${2:-1}"; }
ok()   { printf '  OK    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '  WARN  %s\n' "$*"; }
# rc: rclone with the keys; at most about 200 MB of upload buffers (B2 uploads big files in 96 MB parts), for a small server
rc() { rclone --config "$RCLONE_CONF" --transfers 2 --b2-upload-concurrency 1 "$@"; }
hours_since() { echo $((($(date +%s) - $(date -d "$1" +%s)) / 3600)); }
# lock FLOCK-ARGS: the one lock of run and verify (verify must not see files in flight)
lock() { install -d -m 700 "$STATE"; exec 9>"$STATE/lock"; flock "$@" 9; }

# write_file FILE [MODE] < content: replaces FILE only if the content differs (then logs it)
write_file() {
  local f=$1 m=${2:-644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ -f $f ]] && cmp -s "$tmp" "$f"; then chmod "$m" "$f"; rm -f "$tmp"; return 0; fi
  install -m "$m" "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  log "wrote $f"
}

# load_config: the env file and, if there, the secrets file. ENV_FILE and SECRETS_FILE become absolute: the units and the bot
# run this script with them. Values that go into rclone.conf must be one plain word; bucket and folder names one line.
load_config() {
  local v
  [[ -f $ENV_FILE ]] || die "no config: copy drive-backup.env.example to $ENV_FILE and fill it in"
  ENV_FILE=$(realpath -- "$ENV_FILE") SECRETS_FILE=$(realpath -m -- "$SECRETS_FILE")
  [[ $ENV_FILE$SECRETS_FILE$DB_DIR$RCLONE_CONF =~ ^[A-Za-z0-9_./@+-]+$ ]] || die "the paths of this script and its config may only hold letters, digits and _ . / @ + -"
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  # shellcheck source=/dev/null
  [[ ! -f $SECRETS_FILE ]] || . "$SECRETS_FILE"
  DRIVE_S3_PROVIDER=${DRIVE_S3_PROVIDER:-Other} DRIVE_S3_REGION=${DRIVE_S3_REGION:-} DRIVE_S3_PREFIX=${DRIVE_S3_PREFIX:-}
  DRIVE_B2_PREFIX=${DRIVE_B2_PREFIX:-} DRIVE_MAX_CHANGE=${DRIVE_MAX_CHANGE:-10} DRIVE_HC_URL=${DRIVE_HC_URL:-}
  for v in DRIVE_S3_ENDPOINT DRIVE_S3_BUCKET DRIVE_B2_BUCKET; do [[ -n ${!v:-} ]] || die "$v is not set in $ENV_FILE"; done
  for v in DRIVE_S3_PROVIDER DRIVE_S3_ENDPOINT DRIVE_S3_REGION; do
    [[ ${!v} =~ ^[A-Za-z0-9._:/-]*$ ]] || die "$v may only hold letters, digits and . _ : / -"
  done
  for v in DRIVE_S3_BUCKET DRIVE_S3_PREFIX DRIVE_B2_BUCKET DRIVE_B2_PREFIX; do
    [[ ! ${!v} =~ [[:cntrl:]] && ${!v} != *..* ]] || die "$v: one line, no .."
  done
  [[ $DRIVE_MAX_CHANGE =~ ^[1-9][0-9]?$|^100$ ]] || die "DRIVE_MAX_CHANGE must be a percentage (1-100), not $DRIVE_MAX_CHANGE"
  [[ -z $DRIVE_HC_URL || $DRIVE_HC_URL =~ ^https://[A-Za-z0-9._/:@%+=?\&-]+$ ]] || die "DRIVE_HC_URL must be an https URL"
  SRC=drive:$DRIVE_S3_BUCKET${DRIVE_S3_PREFIX:+/$DRIVE_S3_PREFIX}
  DST=drivebak:$DRIVE_B2_BUCKET${DRIVE_B2_PREFIX:+/$DRIVE_B2_PREFIX}
}

# preflight: both buckets answer (their folders may not exist yet: the first run; an empty bucket lists fine)
preflight() {
  local b
  for b in "drive:$DRIVE_S3_BUCKET" "drivebak:$DRIVE_B2_BUCKET"; do
    rc lsf --max-depth 1 "$b" >/dev/null 2>"$STATE/plan.err" || die "cannot read the bucket $b (name, key?): $(tail -1 "$STATE/plan.err")"
  done
}

# ---------------------------------------------------------------- sync
# cmd_run [force]: the guard, then the sync. The guard is the sync's own dry run (rclone's report: + new, * overwritten,
# - removed, = same), so both judge each file the same way. It stops when more than DRIVE_MAX_CHANGE % of the backup's files
# would be overwritten or removed: a ransomware-encrypted or wiped drive must not replace the backup unnoticed. Then it copies
# only the new files and holds the rest back (exit 3: a warning). From then on nothing is synced, until FORCE (after a look)
# syncs everything, or the drive is back as the backup has it. Once a month the sync then verifies the backup.
cmd_run() {
  local force=${1:-} new changed gone total n b limit=()
  load_config
  lock -n || die "a sync is already running"
  preflight
  rc sync "$SRC" "$DST" --fast-list --dry-run --combined "$STATE/plan" --dest-after "$STATE/after" --format sp \
    2>"$STATE/plan.err" || die "cannot plan the sync: $(tail -1 "$STATE/plan.err")"
  # a vault always holds files: none is a wrong bucket or folder, not a first run
  grep -q '^[+*=] ' "$STATE/plan" || die "the drive $SRC has no files (DRIVE_S3_BUCKET, DRIVE_S3_PREFIX?): nothing synced"
  new=$(grep -c '^+ ' "$STATE/plan" || true) changed=$(grep -c '^[*-] ' "$STATE/plan" || true)
  gone=$(grep -c '^- ' "$STATE/plan" || true) total=$(grep -c '^[=*-] ' "$STATE/plan" || true)
  [[ $force != force || -f $STATE/guard ]] || die "nothing to force: the guard holds nothing back"
  if [[ $force != force && -f $STATE/guard ]] && ((changed)); then
    echo "$changed $total" >"$STATE/guard"
    log "WARN: guard: $changed of $total files in the backup would change or go: nothing synced until /drive_force (or $0 run --force), or until the drive is back as the backup has it" >&2
    exit 3
  fi
  if [[ $force != force ]] && ((changed * 100 > total * DRIVE_MAX_CHANGE)); then
    echo "$changed $total" >"$STATE/guard"
    sed -n 's/^+ //p' "$STATE/plan" >"$STATE/new"
    [[ ! -s $STATE/new ]] || rc copy "$SRC" "$DST" --files-from "$STATE/new" --no-traverse --ignore-existing ||
      die "guard: $changed of $total files would change or go, and copying the $new new ones failed"
    log "WARN: guard: $changed of $total files in the backup would change or go ($((changed * 100 / total))% > $DRIVE_MAX_CHANGE%): held back, $new new copied. Look at the drive; if it is right: /drive_force (or $0 run --force) applies them" >&2
    exit 3
  fi
  # a second stop for what changes after the plan: deletions only up to what is left of the guard's budget (overwrites cannot
  # be limited; they keep their old version). A forced run has no limit.
  [[ $force == force ]] || limit=(--max-delete $((total * DRIVE_MAX_CHANGE / 100 - (changed - gone))))
  if ((new + changed)); then
    log "syncing: $new new, $changed changed or gone, $((total - changed)) unchanged${force:+ (forced)}"
    rc sync "$SRC" "$DST" --fast-list "${limit[@]}" --dest-after "$STATE/after" --format sp ||
      die "sync failed partway (what it overwrote or removed keeps its old version in B2; the next run continues)"
  else log "nothing to sync: the backup has every file"; fi
  rm -f "$STATE/guard"
  read -r n b < <(awk -F';' '{n++; b += $1} END {print n + 0, b + 0}' "$STATE/after")
  echo "$(date -Is) $n $b" >"$STATE/last-ok"
  log "synced: the backup holds $n files"
  [[ -z $DRIVE_HC_URL ]] || curl -fsS -m 20 --retry 3 -o /dev/null "$DRIVE_HC_URL" || log "heartbeat ping failed"
  [[ -f $STATE/verify-ok ]] && (($(hours_since "$(cat "$STATE/verify-ok")") < VERIFY_H)) && return 0
  # a file a device changes while it runs makes it fail once: only a second failure in a row alerts
  verify && return 0
  [[ ! -f $STATE/verify-failed ]] || die "verify failed twice in a row (see above)" 4
  touch "$STATE/verify-failed"
  log "WARN: verify failed (a file changed while it ran?): it runs again after the next sync" >&2
}

cmd_verify() {
  load_config
  lock -w 21600 || die "a sync has run for 6 hours: verify skipped"
  verify || exit 4
}

# verify (holding the lock): the backup has every file of the drive at the same size, and 5 of them, at random, byte for byte
verify() {
  local out
  if ! out=$(rc check "$SRC" "$DST" --one-way --fast-list --match "$STATE/match" 2>&1); then
    log "ERROR: the backup differs from the drive: $(grep -E 'ERROR|differences' <<<"$out" | tail -3)" >&2; return 1
  fi
  shuf -n 5 "$STATE/match" >"$STATE/sample"
  if [[ -s $STATE/sample ]] && ! out=$(rc check "$SRC" "$DST" --download --files-from "$STATE/sample" 2>&1); then
    log "ERROR: a sampled file differs byte for byte: $(tail -2 <<<"$out")" >&2; return 1
  fi
  date -Is >"$STATE/verify-ok"
  rm -f "$STATE/verify-failed"
  log "verify passed: every file of the drive is in the backup, $(wc -l <"$STATE/sample") sampled byte for byte"
}

# cmd_restore TIME: the whole vault as it was at TIME (e.g. "2026-11-20 12:00", the server's time) into a new folder here. Its
# folder names are encrypted, so the whole vault it is.
cmd_restore() {
  local at=$1 utc out need
  [[ $at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}(:[0-9]{2})?$ ]] && date -d "$at" >/dev/null 2>&1 ||
    die "usage: $0 restore 'YYYY-MM-DD HH:MM' (the server's time)"
  utc=$(date -u -d "@$(date -d "$at" +%s)" +%FT%TZ) # B2 counts in UTC
  load_config
  need=$(rc size --json "$DST" --b2-version-at "$utc" | grep -o '"bytes":[0-9]*' | cut -d: -f2) || die "cannot read the backup"
  (($(df --output=avail -B1 /var/tmp | tail -1) > need)) || die "the vault as of then needs $(numfmt --to=iec-i --suffix=B "$need"), more than /var/tmp has free"
  out=/var/tmp/drive-restore-$(date +%F-%H%M%S)
  install -d -m 700 "$out"
  rc copy "$DST" "$out" --b2-version-at "$utc" || die "restore failed"
  log "restored $(find "$out" -type f | wc -l) files as of $at into $out (open it with Cryptomator, or copy it back with a key that may write)"
}

# ---------------------------------------------------------------- bot actions (run as root by opsbot's helper)
# act_status: the /status line
act_status() {
  local d n b g
  if [[ -f $STATE/guard ]]; then
    read -r n b <"$STATE/guard"
    echo "⚠️ Drive: $n of $b files would change or go: held back, new files copied (/drive_force once the drive looks right)"
  elif [[ -f $STATE/last-ok ]]; then
    read -r d n b <"$STATE/last-ok"
    g=🗂; (($(hours_since "$d") < STALE_H)) || g=⚠️
    echo "$g Drive: last sync $(hours_since "$d") h ago · $n files, $(numfmt --to=iec-i --suffix=B "$b")"
  else echo "⚠️ Drive: no sync yet"; fi
}

# bot_action NAME: status, or a sync (force: past the guard) logged like any run, its reply without timestamps
bot_action() {
  case $1 in
    status) act_status ;;
    sync | force) cmd_run "${1#sync}" 2>&1 | tee -a "$LOG" | sed -E 's/^[0-9-]+ [0-9:]+ \[[^]]*\] //; s/^ERROR: /❌ /; s/^WARN: /⚠️ /' ;;
    *) usage ;;
  esac
}

# ---------------------------------------------------------------- install
# remotes: the drive (S3) and the backup (B2's own API: a deleted file is hidden, which needs no delete right). The keys from
# the secrets file, or without it from the existing rclone.conf (the secrets file may be deleted after install).
write_remotes() {
  local v
  if [[ -z ${DRIVE_S3_ACCESS_KEY:-}${DRIVE_B2_KEY:-} && -f $RCLONE_CONF ]]; then
    log "keys: kept from $RCLONE_CONF"
    for v in access_key_id:DRIVE_S3_ACCESS_KEY secret_access_key:DRIVE_S3_SECRET_KEY account:DRIVE_B2_KEY_ID key:DRIVE_B2_KEY; do
      printf -v "${v#*:}" %s "$(sed -n "s/^${v%%:*} = //p" "$RCLONE_CONF")"
    done
  fi
  for v in DRIVE_S3_ACCESS_KEY DRIVE_S3_SECRET_KEY DRIVE_B2_KEY_ID DRIVE_B2_KEY; do
    [[ -n ${!v:-} ]] || die "$v is not set: put it in $SECRETS_FILE"
    [[ ${!v} =~ ^[A-Za-z0-9/+=_-]+$ ]] || die "$v does not look like a key"
  done
  install -d -m 700 "$ETC"
  write_file "$RCLONE_CONF" 600 <<EOF
[drive]
type = s3
provider = $DRIVE_S3_PROVIDER
endpoint = $DRIVE_S3_ENDPOINT
region = $DRIVE_S3_REGION
access_key_id = $DRIVE_S3_ACCESS_KEY
secret_access_key = $DRIVE_S3_SECRET_KEY

[drivebak]
type = b2
account = $DRIVE_B2_KEY_ID
key = $DRIVE_B2_KEY
EOF
}

# key_checks: the backup can be written; whether its key could delete for good, or the drive key write (WARN: still safe,
# less so). The drive's test file goes to the bucket's top, outside the vault's folders (Cryptomator ignores it).
key_checks() {
  local t=.drive-backup-key-test
  if echo test | rc rcat "drive:$DRIVE_S3_BUCKET/$t" 2>/dev/null; then
    warn "the drive key may write: the server needs it read-only (README)"; rc deletefile "drive:$DRIVE_S3_BUCKET/$t" 2>/dev/null || true
  else ok "the drive key is read-only"; fi
  if echo test | rc rcat "$DST/$t" 2>/dev/null; then ok "the backup can be written"
  else bad "cannot write the backup $DST (key?)"; return; fi
  if rc deletefile --b2-hard-delete "$DST/$t" 2>/dev/null; then warn "the backup key can delete for good: give it no deleteFiles (README)"
  else ok "the backup key cannot delete for good (no deleteFiles): changed and deleted files stay for the lifecycle's days"
    rc deletefile "$DST/$t" 2>/dev/null || true; fi # hidden; the lifecycle removes it
}

# lifecycle_check: the backup bucket's lifecycle rules keep a replaced or deleted file 30 days or more. A rule that hides
# files by age, or deletes hidden ones sooner, is a FAIL; no rule (kept for good, the bill grows) a WARN.
lifecycle_check() {
  local out
  out=$(rc backend lifecycle "drivebak:$DRIVE_B2_BUCKET" 2>"$STATE/plan.err") ||
    { warn "cannot read the backup bucket's lifecycle rules: $(tail -1 "$STATE/plan.err")"; return 0; }
  case $(python3 -I -c '
import json, sys
p = sys.argv[1].strip("/") + "/" if sys.argv[1] else ""
rules = [r for r in json.loads(sys.stdin.read()) if p.startswith(r.get("fileNamePrefix") or "") or (r.get("fileNamePrefix") or "").startswith(p)]
short = any(r.get("daysFromUploadingToHiding") or (r.get("daysFromHidingToDeleting") or 30) < 30 for r in rules)
print("short" if short else "ok" if rules else "none")' "$DRIVE_B2_PREFIX" <<<"$out" 2>/dev/null) in
    ok) ok "the backup keeps old versions 30 days or more (lifecycle)" ;;
    none) warn "the backup bucket has no lifecycle rule: old versions are kept for good (README: 30 days)" ;;
    short) bad "the backup bucket's lifecycle hides files by age or deletes old versions within 30 days: $(tr -d '\n ' <<<"$out")" ;;
    *) warn "cannot read the backup bucket's lifecycle rules: $(tail -1 <<<"$out")" ;;
  esac
}

# unit NAME DESCRIPTION SUBCOMMAND CALENDAR: a service that runs this script, alerting through drive-alert@ when it fails, and
# its timer
unit() {
  write_file "$UNITS/$1.service" <<EOF
[Unit]
Description=$2 (drive-backup.sh $3)
After=network-online.target
Wants=network-online.target
OnFailure=drive-alert@%n.service

[Service]
Type=oneshot
Environment=ENV_FILE=$ENV_FILE SECRETS_FILE=$SECRETS_FILE
ExecStart=/bin/bash $DB_DIR/drive-backup.sh $3
EOF
  write_file "$UNITS/$1.timer" <<EOF
[Unit]
Description=$2

[Timer]
OnCalendar=$4
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# units: the nightly sync, the daily check, and the alert for either
units() {
  unit drive-backup "Nightly drive backup" run "*-*-* 04:00:00"
  unit drive-check "Daily drive backup check" check "*-*-* 09:30:00"
  write_file "$UNITS/drive-alert@.service" <<EOF
[Unit]
Description=Telegram alert for a failed %i (drive-backup)

[Service]
Type=oneshot
ExecStart=/bin/bash $DB_DIR/drive-backup.sh alert %i
EOF
}

# cmd_alert UNIT: the alert for a failed drive unit, sent by opsbot, its title from how the unit ended
cmd_alert() {
  local h t st
  h=$(hostname)
  st=$(systemctl show -p ExecMainStatus --value "$1" 2>/dev/null)
  # 1: it exited (else a signal killed it, and the status is the signal's number)
  [[ $(systemctl show -p ExecMainCode --value "$1" 2>/dev/null) == 1 ]] || st=signal
  case $1:$st in
    drive-backup.service:3) t="⚠️ Drive backup held changes back on $h (new files copied)" ;;
    *:4) t="❌ Drive backup verify failed on $h" ;;
    drive-check.service:*) t="⚠️ Drive backup check found problems on $h" ;;
    *) t="❌ Drive backup failed on $h" ;;
  esac
  exec "$NOTIFY_UNIT" "$1" "$t" 'ERROR|WARN|FAIL'
}

plugin_json() {
  cat <<EOF
{
  "name": "drive",
  "exec": ["/usr/bin/env", "ENV_FILE=$ENV_FILE", "SECRETS_FILE=$SECRETS_FILE", "/bin/bash", "$DB_DIR/drive-backup.sh", "action"],
  "root_files": ["$ENV_FILE", "$SECRETS_FILE", "$RCLONE_CONF"],
  "commands": [
    {"command": "drive_sync", "description": "Back up the drive now", "action": "sync"},
    {"command": "drive_force", "description": "Back up the drive past the guard (after a look)", "action": "force"}
  ],
  "actions": {
    "status": {},
    "sync": {"started": "⏳ Backing up the drive...", "ok": "✅ Drive backed up", "fail": "⚠️ Drive backup did not finish"},
    "force": {"started": "⏳ Backing up the drive past the guard...", "ok": "✅ Drive backed up (forced)", "fail": "⚠️ Drive backup did not finish"}
  }
}
EOF
}

cmd_install() {
  local tmp v
  load_config
  grep -qE '^USER_ID=[1-9]' /etc/opsbot/opsbot.conf 2>/dev/null && [[ -x $OPSBOT_CLI ]] ||
    die "needs opsbot with its bot (../opsbot: opsbot.sh install with OPSBOT_USER_ID, or Ente's ente-tg-bot.sh install)"
  if ! command -v rclone >/dev/null; then curl -fsSL https://rclone.org/install.sh | bash >/dev/null || die "rclone install failed"; fi
  v=$(rclone version | sed -n '1s/^rclone v//p')
  [[ $(printf '1.66\n%s\n' "${v%%-*}" | sort -V | head -1) == 1.66 ]] || die "rclone $v is too old (1.66 or newer: curl https://rclone.org/install.sh | sudo bash)"
  write_remotes
  install -d -m 700 "$STATE"
  preflight
  key_checks; lifecycle_check; ((FAILS == 0)) || die "the backup bucket is not set up as it should be (see above)"
  units
  tmp=$(mktemp -d)
  plugin_json >"$tmp/drive.json"
  "$OPSBOT_CLI" plugin add "$tmp/drive.json" || { rm -rf "$tmp"; die "opsbot refused the plugin (see above)"; }
  rm -rf "$tmp"
  systemctl daemon-reload
  systemctl enable --now drive-backup.timer drive-check.timer >/dev/null 2>&1
  systemctl start --no-block drive-backup.service
  log "drive backup installed: nightly at 04:00, verified monthly, checked daily at 09:30; first run started (journalctl -fu drive-backup). Bot: /drive_sync, /drive_force"
}

cmd_uninstall() {
  systemctl disable --now drive-backup.timer drive-check.timer >/dev/null 2>&1 || true
  systemctl stop drive-backup.service drive-check.service 2>/dev/null || true # a run in progress
  rm -f "$UNITS"/drive-{backup,check}.{service,timer} "$UNITS/drive-alert@.service"
  systemctl daemon-reload
  [[ ! -x $OPSBOT_CLI ]] || "$OPSBOT_CLI" plugin remove drive
  rm -rf "$ETC" "$STATE"
  log "drive backup uninstalled (the buckets are untouched)"
}

# check (daily by drive-check.timer, alerting): OK/FAIL lines; exit 1 on a FAIL
cmd_check() {
  local d n
  load_config
  for d in drive-backup.timer drive-check.timer; do
    if systemctl is-enabled --quiet "$d" 2>/dev/null; then ok "$d on"; else bad "$d is off ($0 install)"; fi
  done
  [[ $(stat -c '%U %a' "$RCLONE_CONF" 2>/dev/null) == "root 600" ]] && ok "keys root-only" || bad "$RCLONE_CONF is missing or not root's alone (600)"
  if [[ -f $STATE/guard ]]; then read -r d n <"$STATE/guard"; bad "the guard holds back changes: $d of $n files would change or go (/drive_force once the drive looks right)"
  elif [[ ! -f $STATE/last-ok ]]; then bad "no good sync yet (journalctl -u drive-backup)"
  else
    read -r d _ <"$STATE/last-ok"
    if (($(hours_since "$d") < STALE_H)); then ok "last good sync $d"; else bad "last good sync is older than $STALE_H h: $d (journalctl -u drive-backup)"; fi
  fi
  d=$(cat "$STATE/verify-ok" 2>/dev/null) || d=
  if [[ -n $d ]] && (($(hours_since "$d") < VERIFY_H + 48)); then ok "last verify passed $d"
  else bad "the backup has not passed a verify in 32 days${d:+ (last: $d)} (journalctl -u drive-backup; $0 verify)"; fi
  lifecycle_check
  ((FAILS == 0))
}

usage() { echo "usage: $0 {install|uninstall|check|run [--force]|verify|restore 'YYYY-MM-DD HH:MM'}" >&2; exit 2; }

# sourced (tests): define the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "$#:${1:-}:${2:-}" in
    1:install: | 1:uninstall: | 1:check: | 1:run: | 2:run:--force | 1:verify: | 2:restore:* | 2:action:* | 2:alert:*) ;;
    *) usage ;;
  esac
  [[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $*)" >&2; exit 1; }
  touch "$LOG"; chmod 600 "$LOG"
  case $1 in
    check) cmd_check; exit ;;
    action) load_config; bot_action "$2"; exit ;; # set -e: a failed action exits with its status
    alert) cmd_alert "$2" ;;
  esac
  case $1 in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    run) cmd_run "${2:+force}" ;;
    verify) cmd_verify ;;
    restore) cmd_restore "$2" ;;
  esac 2>&1 | tee -a "$LOG"
  exit "${PIPESTATUS[0]}"
fi
