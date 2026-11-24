#!/usr/bin/env bash
# ente-tg-bot.sh - optional add-on to ente-setup.sh: a Telegram bot through which ONE person (TG_BOT_USER_ID) can
#   /status   a short server summary          /check   run the full health check
#   /backup   run a backup now                /proxy   the S3 proxy's state;  /proxy on | /proxy off
# Usage: ente-tg-bot.sh {install|uninstall|status|check}     (and `action NAME`, used by the root helper)
# Config: TG_BOT_USER_ID in ente-setup.env (your Telegram user id: the same number as TG_CHAT_ID for a private chat).
# Token: the alert bot's (TG_BOT_TOKEN in ente-setup.secrets, or the one backup-setup stored in /etc/ente-alert.env).
#
# Security: the bot (ente_tg_bot.py) runs as the unprivileged user ente-tg-bot, long-polls Telegram (no open port),
# accepts only private messages from TG_BOT_USER_ID and maps commands to six fixed action names. The only thing it may
# run as root is /usr/local/sbin/ente-tg-action with one of those names (a sudo rule listing exactly those six command
# lines); the helper checks the name again and runs `ente-tg-bot.sh action NAME`. Both scripts must be root's alone.
BOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) # the real path: it is embedded in the root helper
# shellcheck source=ente-setup.sh
. "$BOT_DIR/ente-setup.sh" # its helpers and config; its own main does not run when sourced
BOT_USER=ente-tg-bot
BOT_PY=/usr/local/lib/ente-setup/ente_tg_bot.py
BOT_UNIT=/etc/systemd/system/ente-tg-bot.service
BOT_TOKEN_FILE=/etc/ente-tg-bot/token
BOT_SUDOERS=/etc/sudoers.d/ente-tg-bot
BOT_HELPER=/usr/local/sbin/ente-tg-action
BOT_SCRIPT=${BOT_SCRIPT:-$BOT_DIR/ente-tg-bot.sh}
ALERT_ENV=${ALERT_ENV:-/etc/ente-alert.env}
PROXY_STATE=${PROXY_STATE:-/var/lib/ente-setup/s3-proxy} # ente-s3-proxy.sh's state file (on|off)
REBOOT_FLAG=/var/run/reboot-required
BOT_ACTIONS="status check backup proxy-on proxy-off proxy-status"
# How the helper starts an action: as a transient unit of its own, so it gets a clean environment and working directory
# (nothing of the bot user's reaches root), survives a restart of the bot, and is stopped after 6 hours.
BOT_RUN=${BOT_RUN:-systemd-run --quiet --wait --pipe --collect -p RuntimeMaxSec=21600}

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

# bot_token: print the bot token (secrets file / environment first, else the alerts' env file); die if there is none.
bot_token() {
  local t=${TG_BOT_TOKEN:-}
  if [[ -z $t && -f $ALERT_ENV ]]; then t=$(. "$ALERT_ENV"; echo "${TG_BOT_TOKEN:-}"); fi
  [[ -n $t ]] || die "no bot token: set TG_BOT_TOKEN in $SECRETS_FILE (or set up the alerts with backup-setup first)"
  printf '%s\n' "$t"
}

# bot_unit: the systemd unit. No filesystem sandboxing (ProtectSystem etc.): the actions run under sudo as children of the
# service and must write the server's files; the boundary is the separate user and the sudo rule.
bot_unit() {
  cat <<EOF
[Unit]
Description=Ente Telegram bot (commands from user $TG_BOT_USER_ID only)
After=network-online.target
Wants=network-online.target

[Service]
User=$BOT_USER
Group=$BOT_USER
ExecStart=/usr/bin/python3 $BOT_PY --user-id $TG_BOT_USER_ID --state-dir /var/lib/ente-tg-bot --action-cmd "sudo -n $BOT_HELPER"
LoadCredential=token:$BOT_TOKEN_FILE
StateDirectory=ente-tg-bot
StateDirectoryMode=0700
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

# bot_sudoers: the only commands the bot user may run as root.
bot_sudoers() {
  local a list=''
  for a in $BOT_ACTIONS; do list+="${list:+, }$BOT_HELPER $a"; done
  echo "# Managed by ente-tg-bot.sh: the Telegram bot may run exactly these, as root, without a password."
  echo "$BOT_USER ALL=(root) NOPASSWD: $list"
}

# bot_helper: the root helper; checks the action name again and runs `ente-tg-bot.sh action NAME`, with the config and secrets
# files the install used.
bot_helper() {
  local ce; ce=$(config_env)
  cat <<EOF
#!/bin/bash
# Managed by ente-tg-bot.sh. The only command the Telegram bot may run as root (see $BOT_SUDOERS).
[[ \$# -eq 1 ]] || { echo "usage: ente-tg-action ACTION" >&2; exit 2; }
case \$1 in
  status | check | backup | proxy-on | proxy-off | proxy-status) ;;
  *) echo "unknown action" >&2; exit 2 ;;
esac
cd / || exit 1
exec $BOT_RUN /usr/bin/env $ce /bin/bash "$BOT_SCRIPT" action "\$1"
EOF
}

# bot_checks: OK/FAIL lines (counted in FAILS).
bot_checks() {
  local out n
  if systemctl is-active --quiet ente-tg-bot.service; then ok "telegram bot running (commands from user $TG_BOT_USER_ID only)"
  else bad "telegram bot not running (journalctl -u ente-tg-bot)"; fi
  if runuser -u "$BOT_USER" -- sudo -n -l "$BOT_HELPER" status >/dev/null 2>&1; then ok "bot may run its actions through sudo"
  else bad "bot may not run its actions (sudo rule $BOT_SUDOERS)"; fi
  if runuser -u "$BOT_USER" -- sudo -n -l /bin/bash >/dev/null 2>&1 || runuser -u "$BOT_USER" -- sudo -n -l "$BOT_HELPER" rm >/dev/null 2>&1
  then bad "bot may run more than its actions as root (check $BOT_SUDOERS)"; else ok "bot may run nothing else as root"; fi
  # shellcheck disable=SC2046
  if out=$(root_only_writable "$BOT_HELPER" $(bot_root_files) 2>&1); then ok "scripts run as root are root's alone"
  else bad "scripts the bot runs as root are writable by others: $out"; fi
  n=$(journalctl -u ente-tg-bot.service --since -1h -q -o cat 2>/dev/null | grep -cE '^[0-9-]+ [0-9:]+ Telegram API:' || true)
  if ((n <= 5)); then ok "bot reaches Telegram ($n errors in the last hour)"; else bad "bot cannot reach Telegram reliably: $n errors in the last hour"; fi
}

# ---------------------------------------------------------------- actions (run as root by the helper)
# dur SECONDS: "45 s", "12 min", "5 h", "3 days". ago TIMESTAMP: the same, since then, plus " ago".
dur() {
  local s=$1
  if ((s < 120)); then echo "$s s"; elif ((s < 7200)); then echo "$((s / 60)) min"
  elif ((s < 172800)); then echo "$((s / 3600)) h"; else echo "$((s / 86400)) days"; fi
}
ago() { echo "$(dur $(($(date +%s) - $(date -d "$1" +%s 2>/dev/null || date +%s)))) ago"; }

# iec BYTES: 845.0MiB. bucket_usage FILE: the bucket line of /status from what the last good backup measured.
iec() { numfmt --to=iec-i --suffix=B --format=%.1f "$1" 2>/dev/null || echo "$1 B"; }
bucket_usage() {
  local k bytes count d='' p='' b=''
  while read -r k bytes count; do
    case $k in
      date) d=$bytes ;;
      photo) p="photos $(iec "$bytes") ($count files)" ;;
      backup) b="backup $(iec "$bytes") ($count files)" ;;
    esac
  done < <(cat "$1" 2>/dev/null)
  if [[ -n $d && -n $p && -n $b ]]; then echo "🪣 Buckets: $p · $b · measured $(ago "$d")"
  else echo "🪣 Buckets: not measured yet (the next good backup does)"; fi
}

# act_status: five or six short lines (proxy only when installed): services, backup, checks, system, buckets, proxy. ⚠️/❌ mark
# what needs a look.
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
  echo "🖥 Disk $(df -h / | awk 'NR == 2 {print $5 " used (" $4 " free)"}') · RAM $(free -m | awk '/^Mem:/ {print $7}') MB free · up $(dur "$(cut -d. -f1 /proc/uptime)")$([[ -e $REBOOT_FLAG ]] && echo ' · reboot pending')"
  bucket_usage "$state/usage"
  [[ ! -e $CADDY_SITES/s3-proxy.caddy ]] || echo "🔀 S3 proxy: $([[ $(cat "$PROXY_STATE" 2>/dev/null) == on ]] && echo on || echo off)"
}

# act_check: the check's problems as ❌/⚠️ lines and a count of the rest; the bot's title says passed or not.
act_check() {
  local out rc
  out=$(bash "$BOT_DIR/ente-ops.sh" check 2>&1) && rc=0 || rc=$?
  if ! grep -qE '^  (OK|FAIL|WARN)' <<<"$out"; then tail -3 <<<"$out"; return "$rc"; fi # it did not run
  sed -n 's/^  FAIL  /❌ /p' <<<"$out"   # failures first, then warnings
  sed -n 's/^  WARN  /⚠️ /p' <<<"$out"
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
  esac
}

# ---------------------------------------------------------------- commands
bot_cmd_install() {
  local token h0 h1 tmp
  bot_load_env
  token=$(bot_token)
  command -v sudo >/dev/null || die "sudo is not installed (run ente-setup.sh bootstrap)"
  [[ -f $BOT_DIR/ente_tg_bot.py ]] || die "ente_tg_bot.py is missing next to $0 (copy the whole ente-server folder)"
  # shellcheck disable=SC2046
  root_only_writable $(bot_root_files) ||
    die "the files the bot's actions run as root must be owned by root and writable by root only (chown -R root: $BOT_DIR; chmod -R go-w $BOT_DIR)"
  TG_BOT_TOKEN=$token tg_api getMe 2>/dev/null || die "Telegram rejected the bot token, or api.telegram.org is unreachable"
  id "$BOT_USER" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$BOT_USER"
  h0=$({ cat "$BOT_PY" "$BOT_UNIT" "$BOT_TOKEN_FILE" 2>/dev/null || true; } | sha256sum)
  install -d -m 755 "$(dirname "$BOT_PY")"
  write_file "$BOT_PY" 644 <"$BOT_DIR/ente_tg_bot.py"
  install -d -m 700 "$(dirname "$BOT_TOKEN_FILE")"
  printf '%s\n' "$token" | write_file "$BOT_TOKEN_FILE" 600
  bot_helper | write_file "$BOT_HELPER" 755
  tmp=$(mktemp); bot_sudoers >"$tmp"
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "generated sudo rule is invalid; not installed"; }
  write_file "$BOT_SUDOERS" 440 <"$tmp"; rm -f "$tmp"
  bot_unit | write_file "$BOT_UNIT"
  h1=$(cat "$BOT_PY" "$BOT_UNIT" "$BOT_TOKEN_FILE" | sha256sum)
  systemctl daemon-reload
  systemctl enable ente-tg-bot.service >/dev/null 2>&1
  if [[ $h0 != "$h1" ]] || ! systemctl is-active --quiet ente-tg-bot.service; then systemctl restart ente-tg-bot.service; fi
  sleep 3
  systemctl is-active --quiet ente-tg-bot.service || die "the bot does not stay up (journalctl -u ente-tg-bot)"
  log "telegram bot installed: send /status to it from your Telegram account (user $TG_BOT_USER_ID)"
}

bot_cmd_uninstall() {
  load_env
  if systemctl cat ente-tg-bot.service >/dev/null 2>&1; then systemctl disable --now ente-tg-bot.service >/dev/null 2>&1 || true; fi
  rm -f "$BOT_UNIT" "$BOT_PY" "$BOT_SUDOERS" "$BOT_HELPER"
  rm -rf "$(dirname "$BOT_TOKEN_FILE")" /var/lib/ente-tg-bot /var/lib/private/ente-tg-bot
  systemctl daemon-reload
  if id "$BOT_USER" >/dev/null 2>&1; then
    # anything else still running as the bot user (a test instance, a stuck action) would block userdel
    pkill -TERM -u "$BOT_USER" 2>/dev/null && sleep 2
    pkill -KILL -u "$BOT_USER" 2>/dev/null && sleep 1
    userdel "$BOT_USER" || die "could not remove the user $BOT_USER (ps -u $BOT_USER); everything else is removed"
  fi
  log "telegram bot uninstalled"
}

bot_cmd_status() {
  bot_load_env
  [[ -e $BOT_UNIT ]] || { echo "the telegram bot is not installed ($0 install)"; return 1; }
  bot_checks
  echo "recent activity:"; journalctl -u ente-tg-bot.service -q -o cat -n 8 --no-pager 2>/dev/null | sed 's/^/  /'
  ((FAILS == 0))
}

# check: only the OK/FAIL lines (for ente-ops.sh check); exit 1 on any FAIL.
bot_cmd_check() {
  bot_load_env
  [[ -e $BOT_UNIT ]] || { bad "telegram bot is not installed"; return 1; }
  bot_checks
  ((FAILS == 0))
}

bot_usage() { echo "usage: $0 {install|uninstall|status|check}" >&2; exit 2; }

# sourced (tests): define the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "$*" in
    install | uninstall | status | check) ;;
    "action status" | "action check" | "action backup" | "action proxy-on" | "action proxy-off" | "action proxy-status") ;;
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
