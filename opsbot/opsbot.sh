#!/usr/bin/env bash
# opsbot.sh - install opsbot (a Telegram bot for one person, and notifications) and register plugins. See README.md.
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

# write_file FILE [MODE] < content: replaces FILE only if the content differs (then logs it); fails if it cannot (also where
# set -e is off: in a condition).
write_file() {
  local f=$1 m=${2:-644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ -f $f ]] && cmp -s "$tmp" "$f"; then chmod "$m" "$f"; rm -f "$tmp"; return 0; fi
  install -m "$m" "$tmp" "$f" || { rm -f "$tmp"; echo "could not write $f" >&2; return 1; }
  rm -f "$tmp"
  log "wrote $f"
}

# conf_get NAME: a value from the stored config (empty if none)
conf_get() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -1; }

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
ExecStart=/usr/bin/python3 -I $PY bot --user-id $1 --state-dir /var/lib/opsbot
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

# sudo_rule: the rule for every registered action (none: a comment only; a broken plugin is left out and named on stderr)
sudo_rule() { py sudoers "$BOT_USER" "$HELPER" --plugins "$PLUGINS"; }
# write_sudoers: install it once visudo accepts it; returns 1, changing nothing, if it cannot be made
write_sudoers() {
  local tmp rc=1
  tmp=$(mktemp)
  sudo_rule >"$tmp" && visudo -cf "$tmp" >/dev/null && write_file "$SUDOERS" 440 <"$tmp" && rc=0
  rm -f "$tmp"
  return "$rc"
}

# reload: the bot re-reads the plugins and its command menu (within one poll, under a minute)
reload() { if systemctl is-active --quiet opsbot.service; then systemctl reload opsbot.service; fi; }

# ---------------------------------------------------------------- install / uninstall
cmd_install() {
  local user chat token old_user old_chat old_token src_py h
  for c in python3 curl sudo visudo systemctl iconv; do command -v "$c" >/dev/null || die "$c is not installed"; done
  old_user=$(conf_get USER_ID) old_chat=$(conf_get CHAT_ID) old_token=$(cat "$TOKEN_FILE" 2>/dev/null || true)
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
  if [[ $h != "$(cat "$STARTED_WITH" 2>/dev/null)" ]] || ! systemctl is-active --quiet opsbot.service; then
    systemctl restart opsbot.service
    sleep 3 # does it stay up?
  fi
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
  log "plugin $name registered (plugins: $(plugin_names))"
}

cmd_plugin_remove() {
  local name=$1
  [[ $name =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "not a plugin name: $name"
  [[ -f $PLUGINS/$name.json ]] || { log "plugin $name is not registered"; return 0; }
  rm -f "$PLUGINS/$name.json"
  if bot_on; then write_sudoers || die "the sudo rule was not updated (see above)"; reload; fi
  log "plugin $name removed"
}

cmd_plugin_list() { installed || die "opsbot is not installed"; plugin_names; }

# ---------------------------------------------------------------- check
# check: OK/FAIL lines; exit 1 on a FAIL
cmd_check() {
  local out n user
  installed || { bad "opsbot is not installed"; return 1; }
  user=$(conf_get USER_ID)
  # anyone who could change what root runs for the bot could run anything as root; a broken plugin (left out by the bot and
  # the sudo rule) fails this too
  if out=$(py root-only --plugins "$PLUGINS" "$PY" "$HELPER" "$NOTIFY" "$NOTIFY_UNIT" "$CONF" "$TOKEN_FILE" "$PLUGINS" 2>&1)
  then ok "plugins: $(plugin_names); what root runs for them and for opsbot is root's alone"
  else bad "a plugin is broken or a file root runs is writable by others: ${out//opsbot: /}"; fi
  [[ $(stat -c %a "$TOKEN_FILE" 2>/dev/null) == 600 ]] && ok "token file is root-only" || bad "token file $TOKEN_FILE is not mode 600"
  if [[ -z $user ]]; then ok "notifications only (no bot: OPSBOT_USER_ID not set)"; ((FAILS == 0)); return; fi
  if systemctl is-active --quiet opsbot.service; then ok "bot running (commands from user $user only)"
  else bad "bot not running (journalctl -u opsbot)"; fi
  if sudo_rule 2>/dev/null | cmp -s - "$SUDOERS"
  then ok "the sudo rule lists exactly the registered actions"; else bad "the sudo rule is out of date ($0 install rewrites it)"; fi
  if runuser -u "$BOT_USER" -- sudo -n -l /bin/bash >/dev/null 2>&1 || runuser -u "$BOT_USER" -- sudo -n -l "$HELPER" x y >/dev/null 2>&1
  then bad "bot may run more than its actions as root (check $SUDOERS)"; else ok "bot may run nothing else as root"; fi
  n=$(journalctl -u opsbot.service --since -1h -q -o cat 2>/dev/null | grep -cE '^[0-9-]+ [0-9:]+ Telegram API:' || true)
  if ((n <= 5)); then ok "bot reaches Telegram ($n errors in the last hour)"; else bad "bot cannot reach Telegram reliably: $n errors in the last hour"; fi
  ((FAILS == 0))
}

usage() { echo "usage: $0 {install|uninstall|check} | plugin {add FILE.json|remove NAME|list}" >&2; exit 2; }

# sourced (tests): define the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "$#:${1:-}:${2:-}" in
    1:install: | 1:uninstall: | 1:check: | 2:plugin:list | 3:plugin:add | 3:plugin:remove) ;;
    *) usage ;;
  esac
  [[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $*)" >&2; exit 1; }
  CMD="opsbot $1${2:+ $2}"
  [[ $1 != check ]] || { cmd_check; exit; } # not logged: other services' checks run it
  touch "$LOG"; chmod 600 "$LOG"
  case $1 in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    plugin) "cmd_plugin_$2" "${3:-}" ;;
  esac 2>&1 | tee -a "$LOG"
  exit "${PIPESTATUS[0]}"
fi
