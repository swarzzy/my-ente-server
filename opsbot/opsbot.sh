#!/usr/bin/env bash
# opsbot.sh - a Telegram bot through which ONE person runs the fixed actions that services register as plugins, and
# notifications that any root script or systemd unit can send. Independent of any service.
# Usage: opsbot.sh {install|uninstall|status|check}
#        opsbot.sh plugin {add FILE.json|remove NAME|list}
#   install    the notification path (opsbot-notify, opsbot-notify-unit, opsbot-alert@.service) and, with a user id, the bot
#              service. Reads OPSBOT_TOKEN (from @BotFather), OPSBOT_CHAT_ID (where notifications go; default: the user id)
#              and OPSBOT_USER_ID (the ONE person the bot obeys; empty = notifications only) from the environment; a re-run
#              keeps the stored values for those not given. Sends a test message when the token or chat changes.
#   uninstall  remove it all, registered plugins included (the services that registered them stay)
#   status     its checks and recent bot activity;  check: the OK/FAIL lines only (exit 1 on a FAIL)
#   plugin add FILE.json   register a plugin (see README.md): checked, copied to /etc/opsbot/plugins.d, sudo rule regenerated,
#              the bot reloads its commands. remove NAME: the reverse. list: what is registered.
# Security: the bot runs as the unprivileged user opsbot and may run exactly one thing as root: /usr/local/sbin/opsbot-action
# PLUGIN ACTION for the registered pairs (the sudo rule lists each). The helper checks the pair again against the root-owned
# plugin file and that what it runs is root's alone. The token is in /etc/opsbot/token (600), handed to the bot as a systemd
# credential and to curl on stdin, never on a command line.
set -euo pipefail
umask 022

OB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
OB_ETC=/etc/opsbot
CONF=$OB_ETC/opsbot.conf
TOKEN_FILE=$OB_ETC/token
PLUGINS=$OB_ETC/plugins.d
LIB=/usr/local/lib/opsbot
PY=$LIB/opsbot.py
CLI=/usr/local/sbin/opsbot
HELPER=/usr/local/sbin/opsbot-action
NOTIFY=/usr/local/bin/opsbot-notify
NOTIFY_UNIT=/usr/local/bin/opsbot-notify-unit
ALERT_UNIT=/etc/systemd/system/opsbot-alert@.service
UNIT=/etc/systemd/system/opsbot.service
STARTED_WITH=$OB_ETC/bot.started # the hash of what the running bot was started with (program, unit, token)
SUDOERS=/etc/sudoers.d/opsbot
BOT_USER=opsbot
LOG=/var/log/opsbot.log
TG_API=${TG_API:-https://api.telegram.org}
FAILS=0
CMD=opsbot

# ---------------------------------------------------------------- helpers
log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$CMD" "$*"; }
die()  { printf '%s [%s] ERROR: %s\n' "$(date '+%F %T')" "$CMD" "$*" >&2; exit 1; }
ok()   { printf '  OK    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

# write_file FILE [MODE] < content: replaces FILE only if the content differs (then logs it).
write_file() {
  local f=$1 m=${2:-644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ -f $f ]] && cmp -s "$tmp" "$f"; then chmod "$m" "$f"; rm -f "$tmp"; return 0; fi
  install -m "$m" "$tmp" "$f"
  rm -f "$tmp"
  log "wrote $f"
}

# conf_get NAME: a value from the stored config (empty if none)
conf_get() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -1; }
stored_token() { cat "$TOKEN_FILE" 2>/dev/null || true; }

# tg METHOD [curl args...]: call the Bot API with TOKEN (from the environment of the caller); the URL, which holds the token,
# goes to curl on stdin
tg() {
  local m=$1; shift
  curl -fsS -m 20 --retry 3 -o /dev/null -K - "$@" <<<"url = \"$TG_API/bot$TOKEN/$m\""
}

py() { python3 -I "$PY" "$@"; }
installed() { [[ -f $CONF && -f $PY ]]; }
bot_on() { [[ -n $(conf_get USER_ID) ]]; }

# ---------------------------------------------------------------- generated files
notify_script() {
  cat <<EOF
#!/usr/bin/env bash
# Managed by opsbot.sh. opsbot-notify TITLE < BODY: send TITLE and the end of BODY (Telegram allows 4096 characters) to the
# notification chat, as one message. Needs root (it reads the token). Exit status: whether Telegram took it.
set -euo pipefail
[[ \$# -eq 1 ]] || { echo "usage: opsbot-notify TITLE < BODY" >&2; exit 2; }
chat=\$(sed -n 's/^CHAT_ID=//p' $CONF | head -1)
body=''
[[ -t 0 ]] || body=\$(tail -c 3500 | iconv -c -f utf-8 -t utf-8 || true)
text=\$1
[[ -z \$body ]] || text+=\$'\n\n'"\$body"
curl -fsS -m 20 --retry 3 -o /dev/null -K - --data-urlencode "chat_id=\$chat" --data-urlencode "text=\$text" \\
  <<<"url = \"$TG_API/bot\$(cat $TOKEN_FILE)/sendMessage\""
EOF
}

notify_unit_script() {
  cat <<EOF
#!/usr/bin/env bash
# Managed by opsbot.sh. opsbot-notify-unit UNIT [TITLE] [PATTERN]: tell Telegram that UNIT's last run failed, with the lines
# of its log that say why (those matching PATTERN, an extended regex, default ERROR|FAIL; "  FAIL  x" shown as "❌ x"), else
# the end of its log. Used by opsbot-alert@.service: add OnFailure=opsbot-alert@%n.service to any unit.
set -euo pipefail
u=\$1 h=\$(hostname)
title=\${2:-"❌ \$u failed on \$h"} why=\${3:-'ERROR|FAIL'}
id=\$(systemctl show -p InvocationID --value "\$u" 2>/dev/null || true)
if [[ -n \$id ]]; then out=\$(journalctl -q -o cat --no-pager "_SYSTEMD_INVOCATION_ID=\$id" || true)
else out=\$(journalctl -q -o cat --no-pager -u "\$u" -n 40 || true); fi
# -a: a stray non-UTF-8 byte must not make it "binary"
if grep -aqE "\$why" <<<"\$out"; then out=\$(grep -aE "\$why" <<<"\$out" | sed -E 's/^  FAIL  /❌ /' | tail -n 30)
else out=\$(tail -n 15 <<<"\$out"); fi
printf '%s\n' "\$out" | $NOTIFY "\$title"
EOF
}

alert_unit() {
  cat <<EOF
[Unit]
Description=Telegram alert for a failed %i (opsbot)

[Service]
Type=oneshot
ExecStart=$NOTIFY_UNIT %i
EOF
}

helper_script() {
  cat <<EOF
#!/bin/bash
# Managed by opsbot.sh. The only command the opsbot user may run as root (see $SUDOERS): one registered plugin action.
exec /usr/bin/python3 -I $PY action "\$@"
EOF
}

# bot_unit USER_ID: the bot's service. The boundary is the separate user and the sudo rule (actions run as transient units of
# their own, not inside this service). No filesystem sandboxing yet: sudo itself needs to write (its timestamps, the log).
bot_unit() {
  cat <<EOF
[Unit]
Description=opsbot: Telegram commands from user $1 only
After=network-online.target
Wants=network-online.target

[Service]
User=$BOT_USER
Group=$BOT_USER
ExecStart=/usr/bin/python3 -I $PY bot --user-id $1 --state-dir /var/lib/opsbot --plugins $PLUGINS --action-cmd "sudo -n $HELPER"
ExecReload=/bin/kill -HUP \$MAINPID
LoadCredential=token:$TOKEN_FILE
StateDirectory=opsbot
StateDirectoryMode=0700
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

# write_sudoers: the rule for every registered action (none: a comment only; a broken plugin is left out and named on stderr),
# validated before it replaces the old one. Returns 1, changing nothing, if it cannot be made.
write_sudoers() {
  local tmp rc=0
  tmp=$(mktemp)
  if ! py sudoers "$BOT_USER" "$HELPER" --plugins "$PLUGINS" >"$tmp"; then echo "could not make the sudo rule" >&2; rc=1
  elif ! visudo -cf "$tmp" >/dev/null; then echo "the generated sudo rule is invalid" >&2; rc=1
  elif ! cmp -s "$tmp" "$SUDOERS"; then # each step checked: callers run this in a condition, where set -e is off
    if install -m 440 "$tmp" "$SUDOERS"; then log "wrote $SUDOERS"; else echo "could not write $SUDOERS" >&2; rc=1; fi
  fi
  rm -f "$tmp"
  return "$rc"
}

# reload: the bot re-reads the plugins and its command menu (within one poll, under a minute)
reload() { if systemctl is-active --quiet opsbot.service; then systemctl reload opsbot.service; fi; }

# ---------------------------------------------------------------- install / uninstall
cmd_install() {
  local user chat token old_user old_chat old_token src_py h
  for c in python3 curl sudo visudo systemctl iconv; do command -v "$c" >/dev/null || die "$c is not installed"; done
  old_user=$(conf_get USER_ID) old_chat=$(conf_get CHAT_ID) old_token=$(stored_token)
  user=${OPSBOT_USER_ID-$old_user}
  chat=${OPSBOT_CHAT_ID:-${old_chat:-$user}}
  token=${OPSBOT_TOKEN:-$old_token}
  [[ -n $token ]] || die "OPSBOT_TOKEN is not set (the bot's token from @BotFather)"
  [[ $token =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]] || die "OPSBOT_TOKEN does not look like a bot token (123456:ABC...)"
  [[ -z $user || $user =~ ^[1-9][0-9]{0,15}$ ]] || die "OPSBOT_USER_ID must be a person's Telegram id (a positive number), not $user"
  [[ -n $chat ]] || die "OPSBOT_CHAT_ID is not set (where notifications go; for a private chat your user id)"
  [[ $chat =~ ^-?[1-9][0-9]{0,15}$ ]] || die "OPSBOT_CHAT_ID must be a chat id (a number; groups start with -100), not $chat"
  src_py=$OB_DIR/opsbot.py; [[ -f $src_py ]] || src_py=$PY
  [[ -f $src_py ]] || die "opsbot.py is missing next to $0 (copy the whole opsbot folder)"
  TOKEN=$token tg getMe 2>/dev/null || die "Telegram rejected the token, or api.telegram.org is unreachable"
  if [[ $token != "$old_token" || $chat != "$old_chat" ]]; then
    TOKEN=$token tg sendMessage --data-urlencode "chat_id=$chat" \
      --data-urlencode "text=🔔 opsbot on $(hostname) is set up: notifications arrive here." 2>/dev/null ||
      die "could not send to chat $chat: wrong chat id, or nobody pressed Start in the bot / the bot is not in the group"
  fi
  install -d -m 755 "$OB_ETC" "$PLUGINS" "$LIB"
  printf 'USER_ID=%s\nCHAT_ID=%s\n' "$user" "$chat" | write_file "$CONF" 644
  printf '%s\n' "$token" | write_file "$TOKEN_FILE" 600
  write_file "$PY" 644 <"$src_py"
  [[ $(readlink -f "$0") == "$CLI" ]] || write_file "$CLI" 755 <"$OB_DIR/opsbot.sh"
  helper_script | write_file "$HELPER" 755
  notify_script | write_file "$NOTIFY" 755
  notify_unit_script | write_file "$NOTIFY_UNIT" 755
  alert_unit | write_file "$ALERT_UNIT"
  if [[ -z $user ]]; then
    remove_bot
    systemctl daemon-reload
    log "notifications on (chat $chat): opsbot-notify TITLE < BODY, or OnFailure=opsbot-alert@%n.service in a unit. No bot (OPSBOT_USER_ID empty)."
    return 0
  fi
  id "$BOT_USER" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$BOT_USER"
  write_sudoers || die "the sudo rule was not updated (see above)"
  bot_unit "$user" | write_file "$UNIT"
  # restart when what the bot depends on (the token too: it reads it only at start) differs from what it was last started
  # with; stored only once it runs, so an install that stopped half-way restarts it on the next run
  h=$(cat "$PY" "$UNIT" "$TOKEN_FILE" | sha256sum)
  systemctl daemon-reload
  systemctl enable opsbot.service >/dev/null 2>&1
  if [[ $h != "$(cat "$STARTED_WITH" 2>/dev/null)" ]] || ! systemctl is-active --quiet opsbot.service; then systemctl restart opsbot.service; fi
  sleep 3
  systemctl is-active --quiet opsbot.service || die "the bot does not stay up (journalctl -u opsbot)"
  echo "$h" >"$STARTED_WITH"
  log "opsbot installed: notifications to chat $chat, commands from user $user (send /status to the bot). Plugins: $(plugin_names)"
}

plugin_names() { local n; n=$(find "$PLUGINS" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//' | sort | paste -sd' '); echo "${n:-none}"; }

# remove_bot: the bot service, its user, sudo rule and helper; notifications stay
remove_bot() {
  if systemctl cat opsbot.service >/dev/null 2>&1; then systemctl disable --now opsbot.service >/dev/null 2>&1 || true; fi
  [[ ! -e $UNIT ]] || { rm -f "$UNIT"; log "removed the bot service"; }
  rm -f "$SUDOERS" "$STARTED_WITH"
  rm -rf /var/lib/opsbot /var/lib/private/opsbot
  if id "$BOT_USER" >/dev/null 2>&1; then
    # anything else still running as the bot user (a test instance, a stuck action) would block userdel
    pkill -TERM -u "$BOT_USER" 2>/dev/null && sleep 2
    pkill -KILL -u "$BOT_USER" 2>/dev/null && sleep 1
    userdel "$BOT_USER" || die "could not remove the user $BOT_USER (ps -u $BOT_USER)"
  fi
}

cmd_uninstall() {
  local p
  p=$(plugin_names)
  remove_bot
  rm -f "$HELPER" "$NOTIFY" "$NOTIFY_UNIT" "$ALERT_UNIT" "$CLI"
  rm -rf "$LIB" "$OB_ETC"
  systemctl daemon-reload
  log "opsbot uninstalled (plugins that were registered: $p; units with OnFailure=opsbot-alert@ no longer alert)"
}

# ---------------------------------------------------------------- plugins
# plugin add FILE: validate (also that what it runs is root's alone and that its commands are free), register, regenerate the
# sudo rule (until that works, the bot may not run the plugin's actions: check says so), reload the bot.
cmd_plugin_add() {
  local f=$1 name
  installed || die "opsbot is not installed (opsbot.sh install)"
  [[ -f $f ]] || die "no such file: $f"
  name=$(py validate "$f" --plugins "$PLUGINS" 2>&1) || die "plugin refused: ${name#opsbot: }"
  write_file "$PLUGINS/$name.json" 644 <"$f"
  if bot_on; then write_sudoers || die "the sudo rule was not updated (see above)"; reload; fi
  log "plugin $name registered: $(py list --plugins "$PLUGINS" 2>/dev/null | sed -n "s/^$name: //p")"
}

cmd_plugin_remove() {
  local name=$1
  [[ $name =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "not a plugin name: $name"
  [[ -f $PLUGINS/$name.json ]] || { log "plugin $name is not registered"; return 0; }
  rm -f "$PLUGINS/$name.json"
  if bot_on; then write_sudoers || die "the sudo rule was not updated (see above)"; reload; fi
  log "plugin $name removed"
}

cmd_plugin_list() {
  installed || die "opsbot is not installed"
  local out; out=$(py list --plugins "$PLUGINS") || true # a broken plugin is named on stderr
  echo "${out:-no plugins registered}"
}

# ---------------------------------------------------------------- checks
checks() {
  local out n user p a
  user=$(conf_get USER_ID)
  # list exits 1 and names a broken plugin on stderr (the bot and the sudo rule leave it out)
  if out=$(py list --plugins "$PLUGINS" 2>&1 >/dev/null); then ok "plugins: $(plugin_names)"
  else bad "a plugin is broken and left out: ${out//opsbot: /}"; fi
  # anyone who could change what root runs for the bot could run anything as root
  if out=$(py root-only --plugins "$PLUGINS" "$PY" "$HELPER" "$NOTIFY" "$NOTIFY_UNIT" "$CONF" "$TOKEN_FILE" "$PLUGINS" 2>/dev/null)
  then ok "what root runs for opsbot is root's alone"
  else bad "a file root runs for opsbot is writable by others: $out"; fi
  [[ $(stat -c %a "$TOKEN_FILE" 2>/dev/null) == 600 ]] && ok "token file is root-only" || bad "token file $TOKEN_FILE is not mode 600"
  if [[ -z $user ]]; then ok "notifications only (no bot: OPSBOT_USER_ID not set)"; return; fi
  if systemctl is-active --quiet opsbot.service; then ok "bot running (commands from user $user only)"
  else bad "bot not running (journalctl -u opsbot)"; fi
  n=0
  while read -r p a; do
    runuser -u "$BOT_USER" -- sudo -n -l "$HELPER" "$p" "$a" >/dev/null 2>&1 || { bad "bot may not run $p $a (sudo rule $SUDOERS)"; n=1; }
  done < <(py actions --plugins "$PLUGINS" 2>/dev/null)
  ((n)) || ok "bot may run every registered action"
  if runuser -u "$BOT_USER" -- sudo -n -l /bin/bash >/dev/null 2>&1 || runuser -u "$BOT_USER" -- sudo -n -l "$HELPER" x y >/dev/null 2>&1
  then bad "bot may run more than its actions as root (check $SUDOERS)"; else ok "bot may run nothing else as root"; fi
  n=$(journalctl -u opsbot.service --since -1h -q -o cat 2>/dev/null | grep -cE '^[0-9-]+ [0-9:]+ Telegram API:' || true)
  if ((n <= 5)); then ok "bot reaches Telegram ($n errors in the last hour)"; else bad "bot cannot reach Telegram reliably: $n errors in the last hour"; fi
}

cmd_check() {
  installed || { bad "opsbot is not installed"; return 1; }
  checks
  ((FAILS == 0))
}

cmd_status() {
  installed || { echo "opsbot is not installed ($0 install)"; return 1; }
  checks
  if bot_on; then echo "recent activity:"; journalctl -u opsbot.service -q -o cat -n 8 --no-pager 2>/dev/null | sed 's/^/  /'; fi
  ((FAILS == 0))
}

usage() { echo "usage: $0 {install|uninstall|status|check} | plugin {add FILE.json|remove NAME|list}" >&2; exit 2; }

# sourced (tests): define the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "$#:${1:-}:${2:-}" in
    1:install: | 1:uninstall: | 1:status: | 1:check: | 2:plugin:list | 3:plugin:add | 3:plugin:remove) ;;
    *) usage ;;
  esac
  [[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $*)" >&2; exit 1; }
  CMD="opsbot $1${2:+ $2}"
  case $1 in
    check) cmd_check; exit ;;   # quiet, not logged: run by other services' checks
    status) cmd_status; exit ;;
  esac
  touch "$LOG"; chmod 600 "$LOG"
  case $1 in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    plugin) "cmd_plugin_$2" "${3:-}" ;;
  esac 2>&1 | tee -a "$LOG"
  exit "${PIPESTATUS[0]}"
fi
