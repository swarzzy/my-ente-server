#!/usr/bin/env bash
# Tests for opsbot.sh: install (config checks, notifications only, with the bot, re-runs), plugin add/remove/list with the real
# validator and sudo rule, the checks, the notification scripts against a fake Telegram (tests/fake_telegram.py) on 127.0.0.1,
# and the command line. Every path opsbot.sh writes is moved into a temp dir; systemctl, useradd, Telegram's API (for install)
# and, where it is missing, visudo are stubbed. Changes nothing outside the temp dir. Needs bash, python3, curl and iconv.
# Run: bash tests/test_opsbot_cli.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OB=$(cd "$HERE/.." && pwd)
FAKE=
trap '[[ -z $FAKE ]] || kill "$FAKE" 2>/dev/null; rm -rf "$T"' EXIT
TOKEN=123456789:AAH-test_token-abcdefghijklmnopqrstuv TOKEN2=987654321:AAH-other_token-abcdefghijklmnopqrstu
R=$T/root

# in_ob CODE: source opsbot.sh with every path under $R and the outside world stubbed, run CODE. Telegram calls go to
# $T/tg.log (sendMessage fails with SEND_FAILS), systemctl calls to $T/systemctl.log.
in_ob() {
  mkdir -p "$R/sbin" "$R/bin" "$R/systemd" "$R/sudoers.d"
  ( # shellcheck source=/dev/null
    . "$OB/opsbot.sh"
    OB_ETC=$R/etc/opsbot CONF=$R/etc/opsbot/opsbot.conf TOKEN_FILE=$R/etc/opsbot/token PLUGINS=$R/etc/opsbot/plugins.d
    LIB=$R/lib PY=$R/lib/opsbot.py CLI=$R/sbin/opsbot HELPER=$R/sbin/opsbot-action NOTIFY=$R/bin/opsbot-notify
    NOTIFY_UNIT=$R/bin/opsbot-notify-unit ALERT_UNIT=$R/systemd/opsbot-alert@.service UNIT=$R/systemd/opsbot.service
    SUDOERS=$R/sudoers.d/opsbot STARTED_WITH=$R/etc/opsbot/bot.started
    tg() { echo "tg $1 token=$TOKEN ${*:2}" >>"$T/tg.log"; [[ $1 != sendMessage || -z ${SEND_FAILS:-} ]]; }
    systemctl() {
      echo "systemctl $*" >>"$T/systemctl.log"
      case $1 in is-active) [[ -z ${BOT_DOWN:-} ]] ;; cat) [[ -e $UNIT ]] ;; *) return 0 ;; esac
    }
    id() { [[ -n ${USER_EXISTS:-} ]]; }; useradd() { echo "useradd $*" >>"$T/systemctl.log"; }; userdel() { :; }; pkill() { return 1; }
    sleep() { :; }
    if [[ -n ${VISUDO_FAILS:-} ]]; then visudo() { return 1; }; elif ! command -v visudo >/dev/null; then visudo() { :; }; fi
    set +e
    eval "$1" ) 2>&1
}
conf() { cat "$R/etc/opsbot/opsbot.conf"; }

echo "== install: what it needs"
out=$(in_ob 'cmd_install'); check "no token: says so" '[[ $out == *"OPSBOT_TOKEN is not set"* && ! -e $R/etc ]]' "$out"
for bad in "OPSBOT_TOKEN=nope" "OPSBOT_TOKEN=123:short"; do
  out=$(in_ob "$bad OPSBOT_CHAT_ID=5 cmd_install"); check "refuses $bad" '[[ $out == *"does not look like a bot token"* ]]' "$out"
done
for bad in "OPSBOT_USER_ID=-100123" "OPSBOT_USER_ID=0" "OPSBOT_USER_ID='1 --api-base http://x'"; do
  out=$(in_ob "OPSBOT_TOKEN=$TOKEN $bad cmd_install"); check "refuses $bad" '[[ $out == *"OPSBOT_USER_ID must be"* ]]' "$out"
done
out=$(in_ob "OPSBOT_TOKEN=$TOKEN OPSBOT_CHAT_ID=me cmd_install"); check "refuses a chat id that is not a number" '[[ $out == *"OPSBOT_CHAT_ID must be"* ]]' "$out"
out=$(in_ob "OPSBOT_TOKEN=$TOKEN cmd_install"); check "no chat and no user: says where notifications should go" '[[ $out == *"OPSBOT_CHAT_ID is not set"* ]]' "$out"
out=$(SEND_FAILS=1 in_ob "OPSBOT_TOKEN=$TOKEN OPSBOT_CHAT_ID=-1001234567 cmd_install")
check "a test message that cannot be sent stops it, before anything is installed" '[[ $out == *"could not send to chat -1001234567"* && ! -e $R/etc ]]' "$out"

echo "== install: notifications only"
rm -f "$T/tg.log"
out=$(in_ob "OPSBOT_TOKEN=$TOKEN OPSBOT_CHAT_ID=-1001234567 cmd_install")
check "succeeds without a user id, and says there is no bot" '[[ $out == *"notifications on (chat -1001234567)"*"No bot"* && ! -e $R/systemd/opsbot.service ]]' "$out"
check "checks the token and sends a test message to the chat" \
  '[[ $(cat "$T/tg.log") == "$(printf "tg getMe token=%s \ntg sendMessage token=%s --data-urlencode chat_id=-1001234567 --data-urlencode text=🔔 opsbot on %s is set up: notifications arrive here." "$TOKEN" "$TOKEN" "$(hostname)")" ]]' "$(cat "$T/tg.log")"
check "stores the chat, no user" '[[ $(conf) == "$(printf "USER_ID=\nCHAT_ID=-1001234567")" ]]' "$(conf)"
check "the token in a root-only file, and in no other file" \
  '[[ $(stat -c %a "$R/etc/opsbot/token") == 600 && $(cat "$R/etc/opsbot/token") == "$TOKEN" && $(grep -rlF -- "${TOKEN#*:}" "$R") == "$R/etc/opsbot/token" ]]' "$(grep -rlF -- "${TOKEN#*:}" "$R")"
check "installs the bot program, its own command, the helper and the notification scripts and unit" \
  '[[ -f $R/lib/opsbot.py && -x $R/sbin/opsbot && -x $R/sbin/opsbot-action && -x $R/bin/opsbot-notify && -x $R/bin/opsbot-notify-unit && -f $R/systemd/opsbot-alert@.service ]]'
check "the alert unit runs opsbot-notify-unit for the failed unit" 'grep -qx "ExecStart=$R/bin/opsbot-notify-unit %i" "$R/systemd/opsbot-alert@.service"'
check "the helper runs opsbot.py isolated (no modules from the working directory)" 'grep -qx "exec /usr/bin/python3 -I $R/lib/opsbot.py action \"\$@\"" "$R/sbin/opsbot-action"' "$(cat "$R/sbin/opsbot-action")"
rm -f "$T/tg.log"
out=$(in_ob "cmd_install")
check "a re-run with nothing given keeps everything and sends no test message" \
  '[[ $(conf) == "$(printf "USER_ID=\nCHAT_ID=-1001234567")" && $(cat "$T/tg.log") == "tg getMe"* && $(cat "$T/tg.log") != *sendMessage* && $out != *wrote* ]]' "$out"
out=$(in_ob "OPSBOT_TOKEN=$TOKEN2 cmd_install")
check "a new token is checked with a test message and stored" '[[ $(tail -1 "$T/tg.log") == "tg sendMessage token=$TOKEN2 "* && $(cat "$R/etc/opsbot/token") == "$TOKEN2" ]]' "$(cat "$T/tg.log")"

echo "== install: the bot"
rm -f "$T/systemctl.log"
out=$(in_ob "OPSBOT_USER_ID=376193354 cmd_install")
check "with a user id: the bot service, enabled and started" \
  '[[ $out == *"opsbot installed: notifications to chat -1001234567, commands from user 376193354"* && $(cat "$T/systemctl.log") == *"enable opsbot.service"*"restart opsbot.service"* ]]' "$out"
check "... its user is created" 'grep -q "^useradd --system .* opsbot$" "$T/systemctl.log"'
check "... the chat stays where it was" '[[ $(conf) == "$(printf "USER_ID=376193354\nCHAT_ID=-1001234567")" ]]' "$(conf)"
u=$(cat "$R/systemd/opsbot.service")
check "the unit runs the bot as its own unprivileged user" '[[ $u == *"User=opsbot"* && $u == *"Group=opsbot"* && $u != *"User=root"* ]]' "$u"
check "... gets the token as a systemd credential, never on the command line" '[[ $u == *"LoadCredential=token:$R/etc/opsbot/token"* && $u != *"${TOKEN2#*:}"* ]]' "$u"
check "... serves only the configured user, runs actions only through sudo and the helper" \
  '[[ $u == *"bot --user-id 376193354 "* && $u == *"--action-cmd \"sudo -n $R/sbin/opsbot-action\""* && $u == *"python3 -I "* ]]' "$u"
check "... reloads its plugins on systemctl reload, restarts on failure, keeps its state in its own directory" \
  '[[ $u == *"ExecReload=/bin/kill -HUP \$MAINPID"* && $u == *"Restart=always"* && $u == *"StateDirectory=opsbot"* ]]' "$u"
check "... does not set NoNewPrivileges (sudo needs it)" '[[ $u != *"NoNewPrivileges=yes"* ]]' "$u"
check "the sudo rule: nothing registered, so nothing allowed" '[[ $(grep -vc "^#" "$R/sudoers.d/opsbot") == 0 && $(stat -c %a "$R/sudoers.d/opsbot") == 440 ]]' "$(cat "$R/sudoers.d/opsbot")"
rm -f "$T/systemctl.log"
out=$(USER_EXISTS=1 in_ob "cmd_install")
check "a re-run changes nothing and does not restart the bot" '[[ $out != *wrote* && $(cat "$T/systemctl.log") != *restart* && $(cat "$T/systemctl.log") != *useradd* ]]' "$out $(cat "$T/systemctl.log")"
rm -f "$T/systemctl.log"
out=$(USER_EXISTS=1 in_ob "OPSBOT_TOKEN=$TOKEN cmd_install")
check "a new token alone restarts the bot (it reads the token only at start)" \
  '[[ $(cat "$R/etc/opsbot/token") == "$TOKEN" && $(cat "$T/systemctl.log") == *"restart opsbot.service"* ]]' "$out $(cat "$T/systemctl.log")"
echo "$TOKEN2" >"$R/etc/opsbot/token"; rm -f "$T/systemctl.log"   # as if an install stopped after writing a new token
out=$(USER_EXISTS=1 in_ob "cmd_install")
check "... also when an earlier install stopped after writing it (the next run restarts it)" '[[ $(cat "$T/systemctl.log") == *"restart opsbot.service"* ]]' "$out $(cat "$T/systemctl.log")"
rm -f "$T/systemctl.log"; out=$(USER_EXISTS=1 in_ob "cmd_install")
check "... and only then" '[[ $(cat "$T/systemctl.log") != *restart* ]]' "$(cat "$T/systemctl.log")"
out=$(BOT_DOWN=1 USER_EXISTS=1 in_ob "cmd_install")
check "a bot that does not stay up is an error" '[[ $out == *"the bot does not stay up"* ]]' "$out"
out=$(USER_EXISTS=1 in_ob "OPSBOT_USER_ID= cmd_install")
check "OPSBOT_USER_ID emptied: the bot goes, notifications stay" \
  '[[ $out == *"removed the bot service"* && ! -e $R/systemd/opsbot.service && ! -e $R/sudoers.d/opsbot && -x $R/bin/opsbot-notify && $(conf) == "USER_ID="* ]]' "$out"
rm -rf "$R"
out=$(in_ob "OPSBOT_TOKEN=$TOKEN OPSBOT_USER_ID=5 cmd_install")
check "a first install with only a user id: notifications go to that user" '[[ $(conf) == "$(printf "USER_ID=5\nCHAT_ID=5")" ]]' "$out"

echo "== plugins"
mkdir -p "$T/src"
demo() { # demo NAME COMMAND EXEC: a plugin file in $T/src
  printf '{"name": "%s", "exec": ["%s"], "status": "st", "commands": [{"command": "%s", "description": "Do it", "action": "go"}],
    "actions": {"st": {}, "go": {"started": "⏳"}}}\n' "$1" "${3:-/bin/true}" "$2" >"$T/src/$1.json"
}
demo demo doit
rm -f "$T/systemctl.log"
out=$(in_ob "cmd_plugin_add $T/src/demo.json")
check "add: registered, with its commands" '[[ $out == *"plugin demo registered: /doit (+ /status)"* && -f $R/etc/opsbot/plugins.d/demo.json ]]' "$out"
check "... the sudo rule now allows exactly its actions" \
  '[[ $(grep -v "^#" "$R/sudoers.d/opsbot") == "opsbot ALL=(root) NOPASSWD: $R/sbin/opsbot-action demo st, $R/sbin/opsbot-action demo go" ]]' "$(cat "$R/sudoers.d/opsbot")"
check "... and the bot reloads its commands" 'grep -qx "systemctl reload opsbot.service" "$T/systemctl.log"' "$(cat "$T/systemctl.log")"
demo other doit
out=$(in_ob "cmd_plugin_add $T/src/other.json")
check "a plugin wanting a command another one has is refused" '[[ $out == *"/doit is already demo'"'"'s"* && ! -e $R/etc/opsbot/plugins.d/other.json ]]' "$out"
printf '{"name": "x"}' >"$T/src/broken.json"
out=$(in_ob "cmd_plugin_add $T/src/broken.json"); check "a broken plugin file is refused with the reason" '[[ $out == *"plugin refused: "* && ( $out == *"does not match the file name"* || $out == *"exec:"* ) ]]' "$out"
printf '#!/bin/sh\n' >"$T/src/run.sh"; chmod 777 "$T/src/run.sh"; demo writable wr "$T/src/run.sh"
out=$(in_ob "cmd_plugin_add $T/src/writable.json")
check "a plugin whose program others can write (or that is not root's) is refused" '[[ $out == *"plugin refused: "*"$T/src/run.sh"* && ! -e $R/etc/opsbot/plugins.d/writable.json ]]' "$out"
demo missing ms /nonexistent/plugin.sh
out=$(in_ob "cmd_plugin_add $T/src/missing.json"); check "a plugin whose program is not there is refused" '[[ $out == *"plugin refused: not found: /nonexistent"* ]]' "$out"
out=$(in_ob "cmd_plugin_list"); check "list shows the plugins and their commands" '[[ $out == "demo: /doit (+ /status)" ]]' "$out"
out=$(in_ob "cmd_plugin_add $T/src/demo.json"); check "adding the same plugin again is fine (an update)" '[[ $out == *"plugin demo registered"* ]]' "$out"
out=$(in_ob "cmd_plugin_remove demo")
check "remove: gone, and so is its sudo rule" '[[ $out == *"plugin demo removed"* && ! -e $R/etc/opsbot/plugins.d/demo.json && $(grep -vc "^#" "$R/sudoers.d/opsbot") == 0 ]]' "$out"
out=$(in_ob "cmd_plugin_remove demo"); check "removing one that is not there says so" '[[ $out == *"plugin demo is not registered"* ]]' "$out"
printf '{"name": "demo", "old_key": 1}' >"$R/etc/opsbot/plugins.d/demo.json"   # e.g. from an older schema
out=$(in_ob "cmd_plugin_add $T/src/demo.json")
check "a broken registered copy does not stop the plugin from being added again" '[[ $out == *"plugin demo registered"* ]] && grep -q "opsbot-action demo go" "$R/sudoers.d/opsbot"' "$out"
printf '{' >"$R/etc/opsbot/plugins.d/zz-broken.json"
out=$(USER_EXISTS=1 in_ob "cmd_install")
check "an unrelated broken plugin does not stop install: it is left out of the sudo rule" \
  '[[ $out == *"opsbot installed"* ]] && grep -q "opsbot-action demo go" "$R/sudoers.d/opsbot" && ! grep -q zz-broken "$R/sudoers.d/opsbot"' "$out"
cp "$R/sudoers.d/opsbot" "$T/sudoers.before"
demo other2 other2
out=$(VISUDO_FAILS=1 in_ob "cmd_plugin_add $T/src/other2.json")
check "a sudo rule that cannot be made is an error, and the old rule stays" '[[ $out == *"the sudo rule was not updated"* ]] && cmp -s "$T/sudoers.before" "$R/sudoers.d/opsbot"' "$out"
rm -f "$R/etc/opsbot/plugins.d/zz-broken.json" "$R/etc/opsbot/plugins.d/other2.json"; in_ob "cmd_plugin_remove demo" >/dev/null
out=$(in_ob "cmd_plugin_remove ../etc"); check "remove refuses a name that is not one" '[[ $out == *"not a plugin name"* ]]' "$out"

echo "== checks"
in_ob "cmd_plugin_add $T/src/demo.json" >/dev/null
out=$(in_ob 'py() { [[ $1 == root-only ]] || python3 -I "$PY" "$@"; }; runuser() { :; }; FAILS=0; checks; echo FAILS=$FAILS')
check "a healthy install: plugins, root-only files, token, bot, sudo" \
  '[[ $out == *"OK    plugins: demo"* && $out == *"OK    token file is root-only"* && $out == *"OK    bot running"* && $out == *FAILS=1* ]]' "$out"
check "... (the stubbed runuser lets the bot run anything: that is reported)" '[[ $out == *"FAIL  bot may run more than its actions"* ]]' "$out"
chmod 644 "$R/etc/opsbot/token"; printf '{' >"$R/etc/opsbot/plugins.d/bad.json"
out=$(in_ob 'py() { if [[ $1 == root-only ]]; then echo "group/world-writable: /x"; return 1; fi; python3 -I "$PY" "$@"; }; runuser() { return 1; }; FAILS=0; checks; echo FAILS=$FAILS')
check "a broken plugin file, a file others can write and a readable token are FAILs" \
  '[[ $out == *"FAIL  a plugin is broken and left out: skipped plugin bad.json"* && $out == *"FAIL  a file root runs for opsbot is writable by others: group/world-writable: /x"* && $out == *"FAIL  token file"* ]]' "$out"
rm "$R/etc/opsbot/plugins.d/bad.json"; chmod 600 "$R/etc/opsbot/token"
out=$(in_ob 'py() { [[ $1 == root-only ]] || python3 -I "$PY" "$@"; }; runuser() { return 1; }; FAILS=0; checks; echo FAILS=$FAILS')
check "a bot the sudo rule does not let run its actions is a FAIL" '[[ $out == *"FAIL  bot may not run demo st"* && $out == *"FAIL  bot may not run demo go"* && $out == *FAILS=2 ]]' "$out"

echo "== notifications"
python3 "$HERE/fake_telegram.py" "$T/port" & FAKE=$!
for _ in $(seq 50); do [[ -s $T/port ]] && break; sleep 0.1; done
PORT=$(cat "$T/port")
mkdir -p "$T/n"; printf 'USER_ID=\nCHAT_ID=-1001234567\n' >"$T/n/conf"; echo "$TOKEN" >"$T/n/token"
( TG_API=http://127.0.0.1:$PORT
  # shellcheck source=/dev/null
  . "$OB/opsbot.sh"
  CONF=$T/n/conf TOKEN_FILE=$T/n/token NOTIFY=$T/n/opsbot-notify
  notify_script >"$T/n/opsbot-notify"; notify_unit_script >"$T/n/opsbot-notify-unit" )
chmod 755 "$T/n/opsbot-notify" "$T/n/opsbot-notify-unit"
printf '#!/bin/sh\necho test-invocation\n' >"$T/n/systemctl"
printf '#!/bin/sh\ncat "%s"\n' "$T/journal" >"$T/n/journalctl"
chmod 755 "$T/n/systemctl" "$T/n/journalctl"
last() { curl -fsS "http://127.0.0.1:$PORT/control/sent" | python3 -I -c "import json, sys; print(json.load(sys.stdin)[-1][sys.argv[1]])" "$1"; }
sent() { curl -fsS "http://127.0.0.1:$PORT/control/sent" | python3 -I -c "import json, sys; print(len(json.load(sys.stdin)))"; }
printf 'line one\nline two\n' | "$T/n/opsbot-notify" "📦 Title here"; rc=$?
check "opsbot-notify sends the title and the body as one message" '((rc == 0)) && [[ $(last text) == "$(printf "📦 Title here\n\nline one\nline two")" ]]' "$(last text)"
check "... to the configured chat, with the configured token" \
  '[[ $(last chat_id) == -1001234567 && $(curl -fsS "http://127.0.0.1:$PORT/control/tokens") == "[\"$(printf %s "$TOKEN" | sha256sum | cut -d" " -f1)\"]" ]]'
check "... the token is on no command line it runs (it goes to curl on stdin)" '! grep -q "token.*--data\|--data.*token" "$T/n/opsbot-notify" && grep -q "<<<\"url = " "$T/n/opsbot-notify"'
"$T/n/opsbot-notify" "Just a title" </dev/null; check "... a title alone (empty body)" '[[ $(last text) == "Just a title" ]]' "$(last text)"
seq -f "a long line number %g ..............................................................." 1 300 | "$T/n/opsbot-notify" "Long"
check "... a long body is cut to its end and fits Telegram's 4096 characters" '[[ $(last text | wc -m) -le 4096 && $(last text | tail -1) == *"number 300 "* ]]' "$(last text | wc -m)"
printf 'broken \xff\xfe utf-8 here\n' | "$T/n/opsbot-notify" "Bytes"; rc=$?
check "... broken UTF-8 does not stop it" '((rc == 0)) && [[ $(last text) == *"broken  utf-8 here"* ]]' "$(last text)"
out=$("$T/n/opsbot-notify" 2>&1); rc=$?; check "... without a title: a usage error" '((rc == 2)) && [[ $out == *usage* ]]' "$out"
unit() { PATH=$T/n:$PATH "$T/n/opsbot-notify-unit" "$@" >"$T/out" 2>&1; }
printf '%s\n' "== a" "  OK    fine" "  FAIL  web exited" "some noise" "ERROR: disk full" "" >"$T/journal"
unit demo.service
check "opsbot-notify-unit: '<unit> failed on <host>', its FAIL (as ❌) and ERROR lines" \
  '[[ $(last text | head -1) == "❌ demo.service failed on $(hostname)" && $(last text | tail -n +3) == "$(printf "❌ web exited\nERROR: disk full")" ]]' "$(last text)"
unit demo.service "⚠️ Demo is unhappy" '^some'
check "... with the caller's title and pattern" '[[ $(last text) == "$(printf "⚠️ Demo is unhappy\n\nsome noise")" ]]' "$(last text)"
seq -f "log line %g" 1 40 >"$T/journal"; unit demo.service
check "... nothing matches: the last 15 log lines" '[[ $(last text | sed -n 3p) == "log line 26" && $(last text | tail -1) == "log line 40" ]]' "$(last text | head -4)"
: >"$T/journal"; unit demo.service; check "... an empty log: the title alone" '[[ $(last text) == "❌ demo.service failed on $(hostname)" ]]' "$(last text)"
kill "$FAKE"; wait "$FAKE" 2>/dev/null; FAKE=
unit demo.service; rc=$?; check "Telegram unreachable: it fails (the alert unit shows failed)" '((rc != 0))'

echo "== command line"
asuser() { "$@"; }
if [[ $EUID -eq 0 ]]; then cp "$OB/opsbot.sh" "$T/cli.sh"; chmod 755 "$T" "$T/cli.sh"; asuser() { setpriv --reuid=65534 --regid=65534 --clear-groups "$@"; }; CLI=$T/cli.sh
else CLI=$OB/opsbot.sh; fi
for c in "" "maybe" "plugin" "plugin add" "plugin frob x" "install now" "plugin add a b"; do
  # shellcheck disable=SC2086
  out=$(asuser bash "$CLI" $c 2>&1); rc=$?; check "'$c' is a usage error" '[[ $rc -eq 2 && $out == *usage* ]]' "$out"
done
out=$(asuser bash "$CLI" "plugin list" 2>&1); rc=$?; check "'plugin list' as one argument is a usage error (not a silent no-op)" '[[ $rc -eq 2 && $out == *usage* ]]' "$out"
for c in install uninstall status check "plugin list" "plugin add x.json" "plugin remove x"; do
  # shellcheck disable=SC2086
  out=$(asuser bash "$CLI" $c 2>&1); check "'$c' is a known command (asks for root here)" '[[ $out == *"run as root"* ]]' "$out"
done

summary
