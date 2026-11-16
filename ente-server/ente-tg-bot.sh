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
BOT_ACTIONS="status check backup proxy-on proxy-off proxy-status"
# How the helper starts an action: as a transient unit of its own, so it gets a clean environment and working directory
# (nothing of the bot user's reaches root), survives a restart of the bot, and is stopped after 6 hours.
BOT_RUN=${BOT_RUN:-systemd-run --quiet --wait --pipe --collect -p RuntimeMaxSec=21600}

# bot_root_files: everything the actions run or source as root.
bot_root_files() {
  local f
  for f in "$BOT_SCRIPT" "$BOT_DIR/ente-setup.sh" "$BOT_DIR/ente-ops.sh" "$BOT_DIR/ente-s3-proxy.sh" "$ENV_FILE" "$SECRETS_FILE"; do [[ ! -e $f ]] || echo "$f"; done
}

# bot_load_env: ente-setup.sh's config plus a valid TG_BOT_USER_ID (a person's id: positive).
bot_load_env() {
  load_env
  TG_BOT_USER_ID=${TG_BOT_USER_ID:-}
  [[ $TG_BOT_USER_ID =~ ^[1-9][0-9]{0,15}$ ]] ||
    die "TG_BOT_USER_ID must be your Telegram user id (a positive number; for a private chat it equals TG_CHAT_ID)"
}

# bot_token: print the bot token (secrets file / environment first, else the alerts' env file); die if none is valid.
bot_token() {
  local t=${TG_BOT_TOKEN:-}
  if [[ -z $t && -f $ALERT_ENV ]]; then t=$(. "$ALERT_ENV"; echo "${TG_BOT_TOKEN:-}"); fi
  [[ -n $t ]] || die "no bot token: set TG_BOT_TOKEN in $SECRETS_FILE (or set up the alerts with backup-setup first)"
  [[ $t =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "TG_BOT_TOKEN does not look like a bot token (123456:ABC...)"
  printf '%s\n' "$t"
}

# root_only_writable PATH...: true if each path and every directory above it is owned by root and not group/world-writable.
# The helper runs ente-tg-bot.sh, ente-setup.sh and ente-ops.sh as root: anyone who could change them could run anything as root.
root_only_writable() {
  local p d
  for p in "$@"; do
    d=$(readlink -f "$p") || return 1
    while :; do
      [[ $(stat -c %u "$d") == 0 ]] || { echo "not owned by root: $d" >&2; return 1; }
      # a writable directory is fine only if root's and sticky (like /tmp): others cannot rename or replace root's entries
      if (( (8#$(stat -c %a "$d") & 8#022) != 0 )) && ! [[ -d $d && $(stat -c %u "$d") == 0 && -k $d && $d != "$(readlink -f "$p")" ]]; then
        echo "group/world-writable: $d" >&2; return 1
      fi
      [[ $d != / ]] || break
      d=$(dirname "$d")
    done
  done
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

# bot_helper: the root helper; checks the action name again and runs `ente-tg-bot.sh action NAME`.
bot_helper() {
  cat <<EOF
#!/bin/bash
# Managed by ente-tg-bot.sh. The only command the Telegram bot may run as root (see $BOT_SUDOERS).
[[ \$# -eq 1 ]] || { echo "usage: ente-tg-action ACTION" >&2; exit 2; }
case \$1 in
  status | check | backup | proxy-on | proxy-off | proxy-status) ;;
  *) echo "unknown action" >&2; exit 2 ;;
esac
cd / || exit 1
exec $BOT_RUN /bin/bash "$BOT_SCRIPT" action "\$1"
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
ago() { # ago TIMESTAMP: "3 h ago" etc.
  local s; s=$(($(date +%s) - $(date -d "$1" +%s 2>/dev/null || date +%s)))
  if ((s < 120)); then echo "${s} s ago"; elif ((s < 7200)); then echo "$((s / 60)) min ago"
  elif ((s < 172800)); then echo "$((s / 3600)) h ago"; else echo "$((s / 86400)) days ago"; fi
}

act_status() {
  local s cid st c='' res ts f
  load_env
  echo "📊 Ente on $(hostname) - $(date '+%F %H:%M')"
  for s in museum web postgres; do
    cid=$(dc ps -q "$s" 2>/dev/null || true)
    st=$([[ -n $cid ]] && docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo "not running")
    if [[ $st == healthy || $st == running ]]; then c+="$s ✓  "; else c+="$s ✗ ($st)  "; fi
  done
  echo "Containers: $c"
  res=$(systemctl show ente-backup.service -p Result --value 2>/dev/null)
  ts=$(systemctl show ente-backup.service -p ExecMainExitTimestamp --value 2>/dev/null)
  if [[ -n $ts ]]; then echo "Last backup: $res, $(ago "$ts")"; else echo "Last backup: no run since boot"; fi
  for f in /var/lib/ente-backup/last-ok-*; do
    [[ -e $f ]] && echo "  ${f##*last-ok-}: last good $(ago "$(cat "$f")")"
  done
  echo "  next: $(systemctl show ente-backup.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
  ts=$(systemctl show ente-check.service -p ExecMainExitTimestamp --value 2>/dev/null)
  [[ -z $ts ]] || echo "Daily check: $(systemctl show ente-check.service -p Result --value | sed 's/^success$/passed/; s/^exit-code$/FAILED/'), $(ago "$ts")"
  [[ ! -e /var/lib/ente-backup/verify-ok ]] || echo "Monthly verify: passed $(ago "$(cat /var/lib/ente-backup/verify-ok)")"
  if [[ -e /var/lib/ente-backup/hc-fail ]]; then echo "Heartbeat: last ping FAILED"; elif [[ -e /var/lib/ente-backup/hc-ok ]]; then echo "Heartbeat: pinged $(ago "$(cat /var/lib/ente-backup/hc-ok)")"; fi
  if [[ -e $CADDY_SITES/s3-proxy.caddy ]]; then echo "S3 proxy: $([[ $(cat /var/lib/ente-setup/s3-proxy 2>/dev/null) == on ]] && echo ON || echo off)"; fi
  echo "Disk: $(df -h / | awk 'NR == 2 {print $5 " used, " $4 " free"}'); memory: $(free -m | awk '/^Mem:/ {print $7 " MB available"}')"
  echo "Up $(uptime -p | sed 's/^up //')$([[ -e /var/run/reboot-required ]] && echo '; reboot pending')"
}

act_check() {
  local out rc
  out=$(bash "$BOT_DIR/ente-ops.sh" check 2>&1) && rc=0 || rc=$?
  grep -E '^  (FAIL|WARN)' <<<"$out" | grep -v "check storage usage of both buckets" || true
  echo "$(grep -c '^  OK' <<<"$out") OK"
  tail -1 <<<"$out"
  return $rc
}

act_backup() {
  local t0 res id rc=0
  t0=$SECONDS
  systemctl start ente-backup.service || rc=$?
  res=$(systemctl show ente-backup.service -p Result --value)
  id=$(systemctl show ente-backup.service -p InvocationID --value)
  echo "Result: $res after $(((SECONDS - t0) / 60)) min $(((SECONDS - t0) % 60)) s"
  [[ -z $id ]] || journalctl -q -o cat --no-pager "_SYSTEMD_INVOCATION_ID=$id" | grep -E '^== |ERROR|WARNING' | tail -15 || true
  if [[ -e /var/lib/ente-backup/hc-fail ]]; then echo "Heartbeat ping failed"; elif [[ -e /var/lib/ente-backup/hc-ok ]]; then echo "Heartbeat pinged"; fi
  return $rc
}

act_proxy() { # act_proxy on|off|status
  local out rc
  if [[ ! -f $BOT_DIR/ente-s3-proxy.sh || ! -e $CADDY_SITES/s3-proxy.caddy ]]; then
    echo "The S3 proxy is not installed (ente-s3-proxy.sh install)."; return 1
  fi
  out=$(bash "$BOT_DIR/ente-s3-proxy.sh" "$1" 2>&1) && rc=0 || rc=$?
  grep -vE '\] wrote |^\s*$' <<<"$out" | sed -E 's/^[0-9-]+ [0-9:]+ \[s3-proxy [a-z]+\] //' || true
  return $rc
}

cmd_action() {
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
cmd_install() {
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

cmd_uninstall() {
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

cmd_status() {
  bot_load_env
  [[ -e $BOT_UNIT ]] || { echo "the telegram bot is not installed ($0 install)"; return 1; }
  bot_checks
  echo "recent activity:"; journalctl -u ente-tg-bot.service -q -o cat -n 8 --no-pager 2>/dev/null | sed 's/^/  /'
  ((FAILS == 0))
}

# check: only the OK/FAIL lines (for ente-ops.sh check); exit 1 on any FAIL.
cmd_check() {
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
    check) cmd_check; exit ;;           # quiet, not logged: run by ente-ops.sh check
    action) cmd_action "$2"; exit ;;    # its output is the bot's reply
  esac
  touch "$LOG"; chmod 600 "$LOG"
  case $1 in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
  esac 2>&1 | tee -a "$LOG"
  exit "${PIPESTATUS[0]}"
fi
