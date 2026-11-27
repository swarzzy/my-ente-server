#!/usr/bin/env bash
# ente-tg-bot.sh - optional add-on to ente-setup.sh: Ente's commands for opsbot (../opsbot), the Telegram bot through which ONE
# person (TG_BOT_USER_ID) can
#   /status   a short server summary (Ente's lines, then opsbot's system line)
#   /check    run the full health check            /backup   run a backup now
#   /proxy    the S3 proxy's state; /proxy on | /proxy off      /size   measure both buckets now
# Usage: ente-tg-bot.sh {install|uninstall|status|check}     (and `action NAME`, which opsbot's root helper runs)
#   install    installs or updates opsbot from ../opsbot (token, chat and user from Ente's config) and registers Ente as its
#              plugin "ente". An older ente-tg-bot service (before opsbot) is removed first: both cannot poll one token.
#   uninstall  unregisters the plugin (opsbot itself stays: other services may use it; `opsbot uninstall` removes it)
# Config: TG_BOT_USER_ID in ente-setup.env (your Telegram user id: the same number as TG_CHAT_ID for a private chat).
# Token: TG_BOT_TOKEN in ente-setup.secrets, else the one opsbot (or the older alerts or bot) stored.
#
# Security: opsbot runs as its own unprivileged user and may run as root only `opsbot-action ente ACTION` for the actions
# registered here; the helper runs `ente-tg-bot.sh action ACTION` with the config files install used. These scripts and the
# config must be root's alone (install and check verify it).
BOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) # the real path: it is in the plugin file
# shellcheck source=ente-setup.sh
. "$BOT_DIR/ente-setup.sh" # its helpers and config; its own main does not run when sourced
BOT_SCRIPT=${BOT_SCRIPT:-$BOT_DIR/ente-tg-bot.sh}
OPSBOT_SH=${OPSBOT_SH:-$BOT_DIR/../opsbot/opsbot.sh}   # the repository's copy: installs or updates opsbot
OPSBOT_CLI=${OPSBOT_CLI:-/usr/local/sbin/opsbot}      # the installed one
OPSBOT_TOKEN_FILE=${OPSBOT_TOKEN_FILE:-/etc/opsbot/token}
PLUGIN_FILE=${PLUGIN_FILE:-/etc/opsbot/plugins.d/ente.json}
ALERT_ENV=${ALERT_ENV:-/etc/ente-alert.env}            # the alerts' token before opsbot
PROXY_STATE=${PROXY_STATE:-/var/lib/ente-setup/s3-proxy} # ente-s3-proxy.sh's state file (on|off)
# the bot before opsbot (ente-tg-bot.service and its pieces): install removes it
LEGACY_UNIT=/etc/systemd/system/ente-tg-bot.service
LEGACY_FILES=("$LEGACY_UNIT" /etc/sudoers.d/ente-tg-bot /usr/local/sbin/ente-tg-action /usr/local/lib/ente-setup/ente_tg_bot.py)
LEGACY_TOKEN=/etc/ente-tg-bot/token

# bot_root_files: everything the actions run or source as root, and the link rewriter that /proxy on installs in front of the
# API (it sees every request): anyone who could change one of these could act as root or read the apps' traffic.
bot_root_files() {
  local f
  for f in "$BOT_SCRIPT" "$BOT_DIR/ente-setup.sh" "$BOT_DIR/ente-ops.sh" "$BOT_DIR/ente-s3-proxy.sh" "$BOT_DIR/ente_s3_rewrite.py" \
    "$ENV_FILE" "$SECRETS_FILE"; do
    [[ ! -e $f ]] || echo "$f"
  done
}

# bot_load_env: ente-setup.sh's config plus TG_BOT_USER_ID.
bot_load_env() {
  load_env
  TG_BOT_USER_ID=${TG_BOT_USER_ID:-}
  [[ -n $TG_BOT_USER_ID ]] || die "TG_BOT_USER_ID is not set in $ENV_FILE (your Telegram user id; for a private chat it equals TG_CHAT_ID)"
  [[ $TG_BOT_USER_ID =~ ^[1-9][0-9]*$ ]] || die "TG_BOT_USER_ID must be your Telegram user id (a positive number), not $TG_BOT_USER_ID"
}

# bot_token: print the bot token: the secrets file or environment, else opsbot's, the older alerts' or the older bot's stored one;
# die if there is none.
bot_token() {
  local t=${TG_BOT_TOKEN:-}
  [[ -n $t || ! -f $OPSBOT_TOKEN_FILE ]] || t=$(cat "$OPSBOT_TOKEN_FILE")
  if [[ -z $t && -f $ALERT_ENV ]]; then t=$(. "$ALERT_ENV"; echo "${TG_BOT_TOKEN:-}"); fi
  [[ -n $t || ! -f $LEGACY_TOKEN ]] || t=$(cat "$LEGACY_TOKEN")
  [[ -n $t ]] || die "no bot token: set TG_BOT_TOKEN in $SECRETS_FILE"
  printf '%s\n' "$t"
}

# plugin_json: Ente's plugin file for opsbot: the commands, what each action is called and says, and how the helper runs it
# (this script, with the config files this run reads).
plugin_json() {
  local ce; ce=$(config_env)
  python3 -I - "$BOT_SCRIPT" "$ce" <<'PY'
import json, sys
script, ce = sys.argv[1], sys.argv[2]
env = dict(kv.split("=", 1) for kv in ce.split())
busy_proxy = "⏳ Busy: the last /proxy command hasn't finished yet."
print(json.dumps({
    "name": "ente",
    "exec": ["/bin/bash", script, "action"],
    "env": env,
    "status": "status",
    "commands": [
        {"command": "check", "description": "Full health check (about 30 s)", "action": "check"},
        {"command": "backup", "description": "Back up now", "action": "backup"},
        {"command": "proxy", "description": "S3 proxy: state, /proxy on, /proxy off",
         "args": {"": "proxy-status", "status": "proxy-status", "on": "proxy-on", "off": "proxy-off"},
         "usage": "Send /proxy, /proxy on or /proxy off."},
        {"command": "size", "description": "Measure both buckets now", "action": "size"},
    ],
    "actions": {
        "status": {"fail": "❌ Could not get Ente's status"},
        "check": {"started": "⏳ Checking (about 30 s)...", "ok": "✅ Check passed", "fail": "❌ Check found problems",
                  "busy": "⏳ A check is already running."},
        "backup": {"started": "⏳ Backing up...", "ok": "✅ Backup done", "fail": "❌ Backup failed",
                   "busy": "⏳ A backup is already running."},
        "proxy-status": {"started": "⏳ Checking the S3 proxy...", "ok": "🔀 S3 proxy", "fail": "❌ S3 proxy has problems",
                         "lock": "proxy", "busy": busy_proxy},
        "proxy-on": {"started": "⏳ Turning the S3 proxy on...", "ok": "✅ S3 proxy is on",
                     "fail": "❌ Could not turn the S3 proxy on", "lock": "proxy", "busy": busy_proxy},
        "proxy-off": {"started": "⏳ Turning the S3 proxy off...", "ok": "✅ S3 proxy is off",
                      "fail": "❌ Could not turn the S3 proxy off", "lock": "proxy", "busy": busy_proxy},
        "size": {"started": "⏳ Measuring the buckets (lists every object: a minute for a big library)...",
                 "ok": "🪣 Bucket usage", "fail": "❌ Could not measure the buckets",
                 "busy": "⏳ The buckets are already being measured."},
    },
}, indent=2, ensure_ascii=False))
PY
}

# remove_legacy: the bot before opsbot (its service, user, sudo rule, helper and token). It polled the same token, which
# Telegram allows only once at a time.
remove_legacy() {
  local f found=no
  for f in "${LEGACY_FILES[@]}" "$LEGACY_TOKEN"; do [[ ! -e $f ]] || found=yes; done
  id ente-tg-bot >/dev/null 2>&1 && found=yes
  [[ $found == yes ]] || return 0
  if systemctl cat ente-tg-bot.service >/dev/null 2>&1; then systemctl disable --now ente-tg-bot.service >/dev/null 2>&1 || true; fi
  rm -f "${LEGACY_FILES[@]}"
  rm -rf "$(dirname "$LEGACY_TOKEN")" /var/lib/ente-tg-bot /var/lib/private/ente-tg-bot
  systemctl daemon-reload
  if id ente-tg-bot >/dev/null 2>&1; then
    pkill -TERM -u ente-tg-bot 2>/dev/null && sleep 2
    pkill -KILL -u ente-tg-bot 2>/dev/null && sleep 1
    userdel ente-tg-bot || die "could not remove the old bot's user ente-tg-bot (ps -u ente-tg-bot)"
  fi
  log "removed the older ente-tg-bot service: opsbot takes over"
}

# bot_checks: OK/FAIL lines (counted in FAILS): registered, opsbot's own checks, and that Ente's scripts root runs are root's
bot_checks() {
  local out n
  if [[ -f $PLUGIN_FILE ]]; then ok "registered with opsbot (/check, /backup, /proxy, /size and /status lines)"
  else bad "Ente is not registered with opsbot ($0 install)"; fi
  if [[ -x $OPSBOT_CLI ]]; then
    out=$("$OPSBOT_CLI" check 2>&1) || true
    printf '%s\n' "$out" | grep -E '^  (OK|FAIL)' || true
    n=$(grep -c '^  FAIL' <<<"$out" || true); FAILS=$((FAILS + n))
  else bad "opsbot is not installed ($0 install)"; fi
  # shellcheck disable=SC2046
  if out=$(root_only_writable $(bot_root_files) 2>&1); then ok "Ente's scripts the bot runs as root are root's alone"
  else bad "Ente's scripts the bot runs as root are writable by others: $out"; fi
  [[ ! -e $LEGACY_UNIT ]] || bad "the older ente-tg-bot service is still installed ($0 install moves to opsbot)"
}

# ---------------------------------------------------------------- actions (run as root by the helper)
# dur SECONDS: "45 s", "12 min", "5 h", "3 days". ago TIMESTAMP: the same, since then, plus " ago".
dur() {
  local s=$1
  if ((s < 120)); then echo "$s s"; elif ((s < 7200)); then echo "$((s / 60)) min"
  elif ((s < 172800)); then echo "$((s / 3600)) h"; else echo "$((s / 86400)) days"; fi
}
ago() { echo "$(dur $(($(date +%s) - $(date -d "$1" +%s 2>/dev/null || date +%s)))) ago"; }

# bucket_usage FILE: the bucket line of /status, from the last measurement (verify, monthly, or /size).
bucket_usage() {
  local U_DATE U_PHOTO U_BACKUP
  if usage_get "$1"; then echo "🪣 Buckets: photos $U_PHOTO · backup $U_BACKUP · measured $(ago "$U_DATE")"
  else echo "🪣 Buckets: not measured yet (/size)"; fi
}

# act_status: Ente's lines of /status (opsbot adds the system line): services, backup, checks, buckets, and the proxy when
# installed. ⚠️/❌ mark what needs a look.
act_status() {
  local s cid st down='' a b last line ts res nxt
  local state=$BACKUP_STATE
  load_env
  for s in museum web postgres; do
    cid=$(dc ps -q "$s" 2>/dev/null || true)
    st=$([[ -n $cid ]] && docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo "not running")
    [[ $st == healthy || $st == running ]] || down+="${down:+, }$s ($st)"
  done
  if [[ -z $down ]]; then echo "✅ Ente is up (museum, web, postgres)"; else echo "❌ Down: $down"; fi
  # the last fully good backup: the older of its two parts (backup bucket, config copy in the photo bucket)
  a=$(cat "$state/last-ok-s3" 2>/dev/null || true); b=$(cat "$state/last-ok-photo-config" 2>/dev/null || true)
  if [[ -z $a || -z $b ]]; then line="⚠️ Backup: no good backup yet"
  else
    last=$a; [[ $(date -d "$b" +%s) -ge $(date -d "$a" +%s) ]] || last=$b
    if (($(date +%s) - $(date -d "$last" +%s) > 36 * 3600)); then line="⚠️ Backup: last good $(ago "$last")"; else line="💾 Backup: last good $(ago "$last")"; fi
  fi
  res=$(systemctl show ente-backup.service -p Result --value 2>/dev/null || true)
  ts=$(systemctl show ente-backup.service -p ExecMainExitTimestamp --value 2>/dev/null || true)
  [[ -z $ts || $res == success ]] || line+=", the last run failed"
  nxt=$(systemctl show ente-backup.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
  [[ -z $nxt ]] || line+=" · next $(date -d "$nxt" '+%a %H:%M' 2>/dev/null || echo "$nxt")"
  [[ ! -e $state/hc-fail ]] || line+=" · heartbeat ping failed"
  echo "$line"
  ts=$(systemctl show ente-check.service -p ExecMainExitTimestamp --value 2>/dev/null || true)
  res=$(systemctl show ente-check.service -p Result --value 2>/dev/null || true)
  if [[ -z $ts ]]; then line="🩺 Check: not run since boot"
  elif [[ $res == success ]]; then line="🩺 Check: passed $(ago "$ts")"
  else line="⚠️ Check: found problems $(ago "$ts") (/check)"; fi
  if [[ -e $state/verify-ok ]]; then line+=" · verify: passed $(ago "$(cat "$state/verify-ok")")"; else line+=" · verify: not passed yet"; fi
  echo "$line"
  bucket_usage "$state/usage"
  [[ ! -e $CADDY_SITES/s3-proxy.caddy ]] || echo "🔀 S3 proxy: $([[ $(cat "$PROXY_STATE" 2>/dev/null) == on ]] && echo on || echo off)"
}

# act_size: measure both buckets now (ente-ops.sh size, which saves it for /status and check); on failure its last lines.
act_size() {
  local out rc U_DATE U_PHOTO U_BACKUP
  out=$(bash "$BOT_DIR/ente-ops.sh" size 2>&1) && rc=0 || rc=$?
  if ((rc == 0)) && usage_get "$BACKUP_STATE/usage"; then echo "📷 Photos: $U_PHOTO"; echo "💾 Backup: $U_BACKUP"
  else sed -E 's/^[0-9-]+ [0-9:]+ \[[a-z -]+\] //; s/^ERROR: /❌ /' <<<"$out" | tail -3; ((rc)) || rc=1; fi
  return "$rc"
}

# act_check: the check's problems as ❌/⚠️ lines and a count of the rest; the bot's title says passed or not.
act_check() {
  local out rc
  out=$(bash "$BOT_DIR/ente-ops.sh" check 2>&1) && rc=0 || rc=$?
  if ! grep -qE '^  (OK|FAIL|WARN)' <<<"$out"; then tail -3 <<<"$out"; return "$rc"; fi # it did not run
  sed -n 's/^  FAIL  /❌ /p' <<<"$out"   # failures first, then warnings
  sed -n 's/^  WARN  /⚠️ /p' <<<"$out"
  sed -n 's/^  INFO  buckets: /🪣 Buckets: /p' <<<"$out" # the last measurement, as check shows it
  echo "$(grep -c '^  OK' <<<"$out") checks OK"
  return "$rc"
}

# act_backup: run a backup and wait for it; the time it took, and on failure the lines that say why.
act_backup() {
  local t0 id why rc=0
  t0=$SECONDS
  systemctl start ente-backup.service || rc=$?
  id=$(systemctl show ente-backup.service -p InvocationID --value)
  if ((rc == 0)); then echo "Took $(dur $((SECONDS - t0)))."
  else
    echo "Stopped after $(dur $((SECONDS - t0))):"
    why=$([[ -z $id ]] || journalctl -q -o cat --no-pager "_SYSTEMD_INVOCATION_ID=$id")
    if grep -q ERROR <<<"$why"; then grep ERROR <<<"$why" | tail -10; else tail -5 <<<"$why"; fi
  fi
  [[ ! -e $BACKUP_STATE/hc-fail ]] || echo "⚠️ The heartbeat ping failed (the backup itself is fine)."
  return "$rc"
}

# act_proxy on|off|status: what ente-s3-proxy.sh says, without timestamps and with its OK lines counted.
act_proxy() {
  local out rc
  if [[ ! -f $BOT_DIR/ente-s3-proxy.sh || ! -e $CADDY_SITES/s3-proxy.caddy ]]; then
    echo "The S3 proxy is not installed (ente-s3-proxy.sh install)."; return 1
  fi
  out=$(bash "$BOT_DIR/ente-s3-proxy.sh" "$1" 2>&1) && rc=0 || rc=$?
  grep -vE '\] wrote |^\s*$|^  OK  ' <<<"$out" | sed -E 's/^[0-9-]+ [0-9:]+ \[s3-proxy [a-z]+\] //; s/^ERROR: /❌ /; s/^  FAIL  /❌ /' || true
  ! grep -q '^  OK  ' <<<"$out" || echo "$(grep -c '^  OK  ' <<<"$out") checks OK"
  return "$rc"
}

bot_cmd_action() {
  case $1 in
    status) act_status ;;
    check) act_check ;;
    backup) act_backup ;;
    proxy-on) act_proxy on ;;
    proxy-off) act_proxy off ;;
    proxy-status) act_proxy status ;;
    size) act_size ;;
  esac
}

# ---------------------------------------------------------------- commands
bot_cmd_install() {
  local token tmp
  bot_load_env
  token=$(bot_token)
  [[ -f $OPSBOT_SH ]] || die "opsbot is missing: $OPSBOT_SH (copy the repository's opsbot folder next to ente-server)"
  # shellcheck disable=SC2046
  root_only_writable $(bot_root_files) ||
    die "the files the bot's actions run as root must be owned by root and writable by root only (chown -R root: $BOT_DIR; chmod -R go-w $BOT_DIR)"
  remove_legacy
  OPSBOT_TOKEN=$token OPSBOT_CHAT_ID=${TG_CHAT_ID:-$TG_BOT_USER_ID} OPSBOT_USER_ID=$TG_BOT_USER_ID bash "$OPSBOT_SH" install ||
    die "opsbot install failed (see above)"
  tmp=$(mktemp -d)
  plugin_json >"$tmp/ente.json" || { rm -rf "$tmp"; die "could not write the plugin file"; }
  "$OPSBOT_CLI" plugin add "$tmp/ente.json" || { rm -rf "$tmp"; die "opsbot refused the plugin (see above)"; }
  rm -rf "$tmp"
  log "telegram bot ready: send /status to it from your Telegram account (user $TG_BOT_USER_ID)"
}

bot_cmd_uninstall() {
  load_env
  if [[ -x $OPSBOT_CLI ]]; then "$OPSBOT_CLI" plugin remove ente; else rm -f "$PLUGIN_FILE"; fi
  remove_legacy
  log "Ente's bot commands removed (opsbot stays for its notifications and other plugins: '$OPSBOT_CLI uninstall' removes it)"
}

bot_cmd_status() {
  bot_load_env
  [[ -e $PLUGIN_FILE || -e $LEGACY_UNIT ]] || { echo "the telegram bot is not installed ($0 install)"; return 1; }
  bot_checks
  echo "recent activity:"; journalctl -u opsbot.service -q -o cat -n 8 --no-pager 2>/dev/null | sed 's/^/  /'
  ((FAILS == 0))
}

# check: only the OK/FAIL lines (for ente-ops.sh check); exit 1 on any FAIL.
bot_cmd_check() {
  bot_load_env
  bot_checks
  ((FAILS == 0))
}

bot_usage() { echo "usage: $0 {install|uninstall|status|check}" >&2; exit 2; }

# sourced (tests): define the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "$*" in
    install | uninstall | status | check) ;;
    "action status" | "action check" | "action backup" | "action proxy-on" | "action proxy-off" | "action proxy-status" | "action size") ;;
    *) bot_usage ;;
  esac
  [[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $*)" >&2; exit 1; }
  CMD="tg-bot $1"
  case $1 in
    check) bot_cmd_check; exit ;;           # quiet, not logged: run by ente-ops.sh check
    action) bot_cmd_action "$2"; exit ;;    # its output is the bot's reply
  esac
  touch "$LOG"; chmod 600 "$LOG"
  case $1 in
    install) bot_cmd_install ;;
    uninstall) bot_cmd_uninstall ;;
    status) bot_cmd_status ;;
  esac 2>&1 | tee -a "$LOG"
  exit "${PIPESTATUS[0]}"
fi
