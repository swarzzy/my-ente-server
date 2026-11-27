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
STATE=${STATE:-/var/lib/drive-backup}   # last-ok, guard, verify-ok, the plan of the last run
UNITS=${UNITS:-/etc/systemd/system}
OPSBOT_CLI=${OPSBOT_CLI:-/usr/local/sbin/opsbot}
LOG=/var/log/drive-backup.log
CMD=drive
FAILS=0

# ---------------------------------------------------------------- helpers
log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$CMD" "$*"; }
die()  { printf '%s [%s] ERROR: %s\n' "$(date '+%F %T')" "$CMD" "$*" >&2; exit 1; }
ok()   { printf '  OK    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '  WARN  %s\n' "$*"; }
rc() { rclone --config "$RCLONE_CONF" "$@"; }

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

# dur SECONDS: "45 s", "12 min", "5 h", "3 days"; ago TIMESTAMP: the same since then, plus " ago"
dur() {
  local s=$1
  if ((s < 120)); then echo "$s s"; elif ((s < 7200)); then echo "$((s / 60)) min"
  elif ((s < 172800)); then echo "$((s / 3600)) h"; else echo "$((s / 86400)) days"; fi
}
ago() { echo "$(dur $(($(date +%s) - $(date -d "$1" +%s))))" ago; }
hours_since() { echo $((($(date +%s) - $(date -d "$1" +%s)) / 3600)); }

# load_config: the env file and, if there, the secrets file; checks the values (they go into rclone.conf and units)
load_config() {
  local v
  [[ -f $ENV_FILE ]] || die "no config: copy drive-backup.env.example to $ENV_FILE and fill it in"
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  # shellcheck source=/dev/null
  [[ ! -f $SECRETS_FILE ]] || . "$SECRETS_FILE"
  DRIVE_S3_PROVIDER=${DRIVE_S3_PROVIDER:-Other} DRIVE_S3_REGION=${DRIVE_S3_REGION:-} DRIVE_S3_PREFIX=${DRIVE_S3_PREFIX:-}
  DRIVE_B2_PREFIX=${DRIVE_B2_PREFIX:-} DRIVE_MAX_CHANGE=${DRIVE_MAX_CHANGE:-10} DRIVE_HC_URL=${DRIVE_HC_URL:-}
  for v in DRIVE_S3_ENDPOINT DRIVE_S3_BUCKET DRIVE_B2_BUCKET; do [[ -n ${!v:-} ]] || die "$v is not set in $ENV_FILE"; done
  for v in DRIVE_S3_PROVIDER DRIVE_S3_ENDPOINT DRIVE_S3_REGION DRIVE_S3_BUCKET DRIVE_S3_PREFIX DRIVE_B2_BUCKET DRIVE_B2_PREFIX; do
    [[ ${!v} =~ ^[A-Za-z0-9._/@+-]*$ && ${!v} != *..* ]] || die "$v may only hold letters, digits and . _ / @ + - (not ..)"
  done
  [[ $DRIVE_MAX_CHANGE =~ ^[1-9][0-9]?$|^100$ ]] || die "DRIVE_MAX_CHANGE must be a percentage (1-100), not $DRIVE_MAX_CHANGE"
  [[ -z $DRIVE_HC_URL || $DRIVE_HC_URL =~ ^https://[A-Za-z0-9._/:@%+=?\&-]+$ ]] || die "DRIVE_HC_URL must be an https URL"
  SRC=drive:$DRIVE_S3_BUCKET${DRIVE_S3_PREFIX:+/$DRIVE_S3_PREFIX}
  DST=drivebak:$DRIVE_B2_BUCKET${DRIVE_B2_PREFIX:+/$DRIVE_B2_PREFIX}
}

# config_env: "ENV_FILE=... SECRETS_FILE=...", the absolute paths this run reads: the units and the bot run it with them
config_env() {
  local e s
  e=$(realpath -m -- "$ENV_FILE") s=$(realpath -m -- "$SECRETS_FILE")
  [[ $e$s =~ ^[A-Za-z0-9_./@+-]+$ ]] || die "ENV_FILE and SECRETS_FILE paths may only hold letters, digits and _ . / @ + -"
  echo "ENV_FILE=$e SECRETS_FILE=$s"
}

# ---------------------------------------------------------------- sync
# plan: what the sync would do, from its own dry run (so the guard and the sync always judge a file the same way) and the
# backup's listing with sizes: "NEW CHANGED TOTAL COUNT BYTES": files new to the backup, files of it the sync would overwrite
# or remove, the files it holds now, and how many files and bytes it will hold afterwards
plan() {
  python3 -I - "$STATE/plan.json" "$STATE/backup.list" <<'PY'
import json, sys
have = {}
for line in open(sys.argv[2]):
    size, _, name = line.rstrip("\n").partition(";")
    have[name] = int(size)
new = changed = 0
count, size = len(have), sum(have.values())
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    what, name = e.get("skipped"), e.get("object")
    if what == "copy" and name in have:
        changed, size = changed + 1, size - have[name] + e.get("size", 0)
    elif what == "copy":
        new, count, size = new + 1, count + 1, size + e.get("size", 0)
    elif what == "delete" and name in have:
        changed, count, size = changed + 1, count - 1, size - have[name]
print(new, changed, len(have), count, size)
PY
}

# cmd_run [force]: the guard, then the sync. The guard stops when more than DRIVE_MAX_CHANGE % of the backup's files would be
# overwritten or removed: a ransomware-encrypted or wiped drive must not replace the backup unnoticed. FORCE syncs anyway.
cmd_run() {
  local force=${1:-} new changed total count bytes st=0
  load_config
  install -d -m 700 "$STATE"
  exec 9>"$STATE/lock"
  flock -n 9 || die "a sync or verify is already running"
  rc lsf --max-depth 1 "$SRC" >/dev/null 2>"$STATE/plan.err" || die "cannot read the drive $SRC: $(tail -1 "$STATE/plan.err")"
  # the backup's files; its folder may not exist yet (exit 3: the first run), but its bucket must
  rc lsf -R --files-only --format sp "$DST" >"$STATE/backup.list" 2>"$STATE/plan.err" || st=$?
  if ((st)); then
    ((st == 3)) && rc lsf --max-depth 1 drivebak: 2>/dev/null | grep -qx "$DRIVE_B2_BUCKET/" ||
      die "cannot read the backup $DST (bucket, key?): $(tail -1 "$STATE/plan.err")"
  fi
  rc sync "$SRC" "$DST" --fast-list --dry-run --use-json-log -v 2>"$STATE/plan.json" ||
    die "cannot plan the sync: $(grep -o '"msg":"[^"]*' "$STATE/plan.json" | tail -1 | cut -c8-)"
  read -r new changed total count bytes < <(plan)
  if [[ $force != force ]] && ((total > 0 && changed * 100 > total * DRIVE_MAX_CHANGE)); then
    echo "$changed $total" >"$STATE/guard"
    die "guard: $changed of $total files in the backup would change or go ($((changed * 100 / total))% > $DRIVE_MAX_CHANGE%), nothing synced. Look at the drive; if it is right: /drive_force (or $0 run --force)"
  fi
  log "syncing: $new new, $changed changed or gone, $((total - changed)) unchanged${force:+ (forced)}"
  # --max-delete: a second stop, for what changed since the plan
  rc sync "$SRC" "$DST" --fast-list $([[ $force == force ]] || echo "--max-delete $((total * DRIVE_MAX_CHANGE / 100 + 1))") ||
    die "sync failed (the backup keeps what it had; the next run continues)"
  rm -f "$STATE/guard"
  echo "$(date -Is) $count $bytes" >"$STATE/last-ok"
  log "synced: the backup holds $count files"
  [[ -z $DRIVE_HC_URL ]] || curl -fsS -m 20 --retry 3 -o /dev/null "$DRIVE_HC_URL" || log "heartbeat ping failed"
}

# cmd_verify: the backup has every file of the drive at the same size, and a sample of 5 is the same byte for byte
cmd_verify() {
  local out
  load_config
  install -d -m 700 "$STATE"
  exec 9>"$STATE/lock"
  flock -w 21600 9 || die "a sync has run for 6 hours: verify skipped" # files in flight are not differences
  out=$(rc check "$SRC" "$DST" --one-way 2>&1) || die "the backup differs from the drive: $(grep -E 'ERROR|differences' <<<"$out" | tail -3)"
  rc lsf -R --files-only "$SRC" | shuf -n 5 >"$STATE/sample" || true
  if [[ -s $STATE/sample ]]; then
    out=$(rc check "$SRC" "$DST" --download --files-from "$STATE/sample" 2>&1) || die "a sampled file differs byte for byte: $(tail -2 <<<"$out")"
  fi
  date -Is >"$STATE/verify-ok"
  log "verify passed: every file of the drive is in the backup, $(wc -l <"$STATE/sample") sampled byte for byte"
}

# cmd_restore TIME [PATH]: the backup as it was at TIME (e.g. "2026-11-20 12:00", the server's time) into a new folder here
cmd_restore() {
  local at=${1:-} path=${2:-} out
  [[ -n $at ]] && date -d "$at" >/dev/null 2>&1 || die "usage: $0 restore 'YYYY-MM-DD HH:MM' [PATH in the vault]"
  [[ $path =~ ^[A-Za-z0-9._/=+-]*$ && $path != *..* ]] || die "PATH: letters, digits and . _ / = + - only"
  load_config
  out=/var/tmp/drive-restore-$(date +%F-%H%M%S)
  install -d -m 700 "$out"
  rc copy "$DST${path:+/$path}" "$out" --b2-version-at "$(date -u -d "$at" +%FT%TZ)" || die "restore failed"
  log "restored $(find "$out" -type f | wc -l) files as of $at into $out (open it with Cryptomator, or copy it back with a key that may write)"
}

# ---------------------------------------------------------------- bot actions (run as root by opsbot's helper)
# act_status: the /status line
act_status() {
  local d n b g
  if [[ -f $STATE/guard ]]; then
    read -r n b <"$STATE/guard"
    echo "⚠️ Drive: the guard stopped the sync: $n of $b files would change (/drive_force once the drive looks right)"
  elif [[ -f $STATE/last-ok ]]; then
    read -r d n b <"$STATE/last-ok"
    g=🗂; (($(hours_since "$d") < 36)) || g=⚠️
    echo "$g Drive: last sync $(ago "$d") · $n files, $(numfmt --to=iec-i --suffix=B "$b" 2>/dev/null || echo "$b bytes")"
  else echo "⚠️ Drive: no sync yet"; fi
}

bot_action() {
  case $1 in
    status) act_status ;;
    sync) cmd_run 2>&1 | sed -E 's/^[0-9-]+ [0-9:]+ \[[^]]*\] //; s/^ERROR: /❌ /' ;;
    force)
      [[ -f $STATE/guard ]] || { echo "Nothing to force: the guard has not stopped a sync. /drive_sync runs one."; return 1; }
      cmd_run force 2>&1 | sed -E 's/^[0-9-]+ [0-9:]+ \[[^]]*\] //; s/^ERROR: /❌ /' ;;
    *) usage ;;
  esac
}

# ---------------------------------------------------------------- install
# remotes: the drive (S3) and the backup (B2's own API: a deleted file is hidden, which needs no delete right). From the
# secrets file; without it the existing rclone.conf stays (the secrets file may be deleted after install).
write_remotes() {
  local v
  if [[ -z ${DRIVE_S3_ACCESS_KEY:-}${DRIVE_B2_KEY:-} && -f $RCLONE_CONF ]]; then log "keys: kept from $RCLONE_CONF"; return 0; fi
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
${DRIVE_S3_REGION:+region = $DRIVE_S3_REGION
}access_key_id = $DRIVE_S3_ACCESS_KEY
secret_access_key = $DRIVE_S3_SECRET_KEY

[drivebak]
type = b2
account = $DRIVE_B2_KEY_ID
key = $DRIVE_B2_KEY
EOF
}

# key_checks: both buckets answer, and whether the backup key could delete for good (WARN: still safe, less so). Whether the
# drive key could write is not tried: that would put a file into the vault.
key_checks() {
  local t=.drive-backup-key-test
  rc lsf --max-depth 1 "$SRC" >/dev/null 2>&1 && ok "the drive can be read" || bad "cannot read the drive $SRC (endpoint, bucket, key?)"
  if echo test | rc rcat "$DST/$t" 2>/dev/null; then ok "the backup can be written"
  else bad "cannot write the backup $DST (bucket, key?)"; return; fi
  if rc deletefile --b2-hard-delete "$DST/$t" 2>/dev/null; then warn "the backup key can delete for good: give it no deleteFiles (README)"
  else ok "the backup key cannot delete for good (no deleteFiles): changed and deleted files stay for the lifecycle's days"
    rc deletefile "$DST/$t" 2>/dev/null || true; fi # hidden; the lifecycle removes it
}

units() { # the backup and verify services and timers
  local ce; ce=$(config_env)
  write_file "$UNITS/drive-backup.service" <<EOF
[Unit]
Description=Drive backup: the drive bucket to the backup bucket (drive-backup.sh run)
After=network-online.target
Wants=network-online.target
OnFailure=opsbot-alert@%n.service

[Service]
Type=oneshot
Environment=$ce
ExecStart=/bin/bash $DB_DIR/drive-backup.sh run
EOF
  write_file "$UNITS/drive-backup.timer" <<'EOF'
[Unit]
Description=Nightly drive backup

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  write_file "$UNITS/drive-verify.service" <<EOF
[Unit]
Description=Monthly drive backup verify (drive-backup.sh verify)
After=network-online.target
Wants=network-online.target
OnFailure=opsbot-alert@%n.service

[Service]
Type=oneshot
Environment=$ce
ExecStart=/bin/bash $DB_DIR/drive-backup.sh verify
EOF
  write_file "$UNITS/drive-verify.timer" <<'EOF'
[Unit]
Description=Monthly drive backup verify

[Timer]
OnCalendar=*-*-01 05:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

plugin_json() {
  local ce e s; ce=$(config_env); e=${ce% *} s=${ce#* }
  cat <<EOF
{
  "name": "drive",
  "exec": ["/usr/bin/env", "$e", "$s", "/bin/bash", "$DB_DIR/drive-backup.sh", "action"],
  "root_files": ["${e#ENV_FILE=}", "${s#SECRETS_FILE=}", "$RCLONE_CONF"],
  "commands": [
    {"command": "drive_sync", "description": "Back up the drive now", "action": "sync"},
    {"command": "drive_force", "description": "Back up the drive past the guard (after a look)", "action": "force"}
  ],
  "actions": {
    "status": {},
    "sync": {"started": "⏳ Backing up the drive...", "ok": "✅ Drive backed up", "fail": "❌ Drive backup failed"},
    "force": {"started": "⏳ Backing up the drive past the guard...", "ok": "✅ Drive backed up (forced)", "fail": "❌ Drive backup failed"}
  }
}
EOF
}

cmd_install() {
  local tmp
  load_config
  command -v python3 >/dev/null || die "python3 is not installed"
  grep -qE '^USER_ID=[1-9]' /etc/opsbot/opsbot.conf 2>/dev/null && [[ -x $OPSBOT_CLI ]] ||
    die "needs opsbot with its bot (../opsbot: opsbot.sh install with OPSBOT_USER_ID, or Ente's ente-tg-bot.sh install)"
  if ! command -v rclone >/dev/null; then curl -fsSL https://rclone.org/install.sh | bash >/dev/null || die "rclone install failed"; fi
  write_remotes
  FAILS=0; key_checks; ((FAILS == 0)) || die "the buckets do not answer as they should (see above)"
  units
  tmp=$(mktemp -d)
  plugin_json >"$tmp/drive.json"
  "$OPSBOT_CLI" plugin add "$tmp/drive.json" || { rm -rf "$tmp"; die "opsbot refused the plugin (see above)"; }
  rm -rf "$tmp"
  systemctl daemon-reload
  systemctl enable --now drive-backup.timer drive-verify.timer >/dev/null 2>&1
  systemctl start --no-block drive-backup.service
  log "drive backup installed: nightly at 04:00, verify on the 1st; first run started (journalctl -fu drive-backup). Bot: /drive_sync, /drive_force"
}

cmd_uninstall() {
  systemctl disable --now drive-backup.timer drive-verify.timer >/dev/null 2>&1 || true
  rm -f "$UNITS"/drive-backup.{service,timer} "$UNITS"/drive-verify.{service,timer}
  systemctl daemon-reload
  [[ ! -x $OPSBOT_CLI ]] || "$OPSBOT_CLI" plugin remove drive
  rm -rf "$ETC" "$STATE"
  log "drive backup uninstalled (the buckets are untouched)"
}

# check: OK/WARN/FAIL lines; exit 1 on a FAIL
cmd_check() {
  local d t
  load_config
  if systemctl is-enabled --quiet drive-backup.timer 2>/dev/null; then ok "nightly backup timer on"; else bad "the nightly backup timer is off ($0 install)"; fi
  [[ $(stat -c '%U %a' "$RCLONE_CONF" 2>/dev/null) == "root 600" ]] && ok "keys root-only" || bad "$RCLONE_CONF is missing or not root's alone (600)"
  if [[ -f $STATE/guard ]]; then read -r d t <"$STATE/guard"; bad "the guard stopped the last sync: $d of $t files would change (/drive_force)"
  elif [[ ! -f $STATE/last-ok ]]; then bad "no good sync yet (journalctl -u drive-backup)"
  else
    read -r d _ <"$STATE/last-ok"
    if (($(hours_since "$d") < 36)); then ok "last good sync $d"; else bad "last good sync is older than 36 h: $d (journalctl -u drive-backup)"; fi
  fi
  if [[ -f $STATE/verify-ok ]] && (($(hours_since "$(cat "$STATE/verify-ok")") < 40 * 24)); then ok "verify passed $(cat "$STATE/verify-ok")"
  else warn "the monthly verify has not passed in 40 days ($0 verify)"; fi
  ((FAILS == 0))
}

usage() { echo "usage: $0 {install|uninstall|check|run [--force]|verify|restore 'YYYY-MM-DD HH:MM' [PATH]}" >&2; exit 2; }

# sourced (tests): define the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "$#:${1:-}:${2:-}" in
    1:install: | 1:uninstall: | 1:check: | 1:run: | 2:run:--force | 1:verify: | 2:restore:* | 3:restore:* | 2:action:*) ;;
    *) usage ;;
  esac
  [[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $*)" >&2; exit 1; }
  case $1 in
    check) cmd_check; exit ;;
    action) load_config; bot_action "$2"; exit ;; # set -e: a failed action exits with its status
  esac
  touch "$LOG"; chmod 600 "$LOG"
  case $1 in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    run) cmd_run "${2:+force}" ;;
    verify) cmd_verify ;;
    restore) cmd_restore "$2" "${3:-}" ;;
  esac 2>&1 | tee -a "$LOG"
  exit "${PIPESTATUS[0]}"
fi
