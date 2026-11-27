#!/usr/bin/env bash
# End-to-end tests of opsbot on a server where it is installed with a bot (opsbot.sh install with OPSBOT_USER_ID), as root.
# Registers a test plugin "e2e" (a small script in /usr/local/lib/opsbot-e2e), checks the real sudo rule and helper, then runs
# a second instance of the real bot as the real opsbot user against a fake Telegram (tests/fake_telegram.py) on 127.0.0.1, so
# no real messages are needed. Leaves opsbot as it found it (the test plugins removed). Takes about a minute.
# Run: sudo bash tests/opsbot_e2e.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -f /etc/opsbot/opsbot.conf ]] || { echo "opsbot is not installed (opsbot.sh install)" >&2; exit 1; }
OWNER=$(sed -n 's/^USER_ID=//p' /etc/opsbot/opsbot.conf)
[[ -n $OWNER ]] || { echo "opsbot is installed without a bot (OPSBOT_USER_ID)" >&2; exit 1; }
HELPER=/usr/local/sbin/opsbot-action CLI=/usr/local/sbin/opsbot PY=/usr/local/lib/opsbot/opsbot.py
E2E=/usr/local/lib/opsbot-e2e
STRANGER=555000111
chmod 755 "$T"
cleanup() {
  systemctl stop opsbot-e2e.service 2>/dev/null; systemctl reset-failed opsbot-e2e.service 2>/dev/null
  [[ -z ${FAKE:-} ]] || kill "$FAKE" 2>/dev/null
  pkill -f "$E2E/plugin.sh" 2>/dev/null
  "$CLI" plugin remove e2e >/dev/null 2>&1; "$CLI" plugin remove e2e-two >/dev/null 2>&1
  rm -rf "$T" "$E2E" /var/lib/opsbot-e2e /var/lib/private/opsbot-e2e /tmp/opsbot-e2e-pwned
}
trap cleanup EXIT
RC=0
run() { "$@" </dev/null >"$T/out" 2>&1; RC=$?; }
as_bot() { runuser -u opsbot -- "$@" </dev/null >/dev/null 2>&1; }

echo "== harness"
false; RC=$?; check "a failing command is seen as failing (harness self-test)" '[[ $RC -ne 0 ]]'

echo "== register a plugin"
install -d -m 755 "$E2E"
cat >"$E2E/plugin.sh" <<'X'
#!/bin/sh
case $1 in
  status) echo "🧪 e2e plugin is up (env $E2E_GREETING)" ;;
  who) echo "user=$(id -un) cwd=$(pwd) leak=${LEAK:-none}" ;;
  slow) sleep 4; echo "slow done" ;;
  fail) echo "ERROR: it broke"; exit 3 ;;
  long) sleep 300 ;;
  two) echo "two here" ;;
esac
X
chmod 755 "$E2E/plugin.sh"
cat >"$E2E/e2e.json" <<X
{"name": "e2e", "exec": ["/bin/sh", "$E2E/plugin.sh"], "env": {"E2E_GREETING": "hello"}, "status": "status",
 "commands": [{"command": "e2e_who", "description": "who runs it", "action": "who"},
              {"command": "e2e_slow", "description": "slow", "action": "slow"},
              {"command": "e2e_fail", "description": "fails", "action": "fail"},
              {"command": "e2e_long", "description": "long", "action": "long"}],
 "actions": {"status": {}, "who": {"ok": "👤 who"},
             "slow": {"started": "⏳ slow...", "ok": "✅ slow done", "busy": "⏳ slow is busy"},
             "fail": {"started": "⏳ failing...", "fail": "❌ it failed"},
             "long": {"started": "⏳ long..."}}}
X
cat >"$E2E/e2e-two.json" <<X
{"name": "e2e-two", "exec": ["/bin/sh", "$E2E/plugin.sh"], "commands": [{"command": "e2e_two", "description": "two", "action": "two"}],
 "actions": {"two": {}}}
X
run "$CLI" plugin add "$E2E/e2e.json"; check "plugin add succeeds" '[[ $RC -eq 0 ]] && grep -q "plugin e2e registered: /e2e_who /e2e_slow /e2e_fail /e2e_long (+ /status)" "$T/out"' "$(cat "$T/out")"
check "the sudo rule lists its actions" 'grep -q "/usr/local/sbin/opsbot-action e2e slow" /etc/sudoers.d/opsbot'
cp "$E2E/plugin.sh" "$E2E/bad.sh"; chmod 777 "$E2E/bad.sh"; sed "s|plugin.sh|bad.sh|; s|\"e2e\"|\"e2e-bad\"|; s|e2e_|bad_|g" "$E2E/e2e.json" >"$E2E/e2e-bad.json"
run "$CLI" plugin add "$E2E/e2e-bad.json"; check "a plugin whose script others can write is refused" '[[ $RC -ne 0 && ! -e /etc/opsbot/plugins.d/e2e-bad.json ]]' "$(cat "$T/out")"

echo "== what the bot user may run as root"
for a in status who slow fail long; do as_bot sudo -n -l "$HELPER" e2e "$a"; RC=$?; check "may run: opsbot-action e2e $a" '[[ $RC -eq 0 ]]'; done
as_bot sudo -n /usr/bin/id; RC=$?; check "may not run: id" '[[ $RC -ne 0 ]]'
as_bot sudo -n /bin/bash -c true; RC=$?; check "may not run: bash" '[[ $RC -ne 0 ]]'
as_bot sudo -n "$HELPER" e2e rm; RC=$?; check "may not run: an action that is not registered" '[[ $RC -ne 0 ]]'
as_bot sudo -n "$HELPER" e2e-two two; RC=$?; check "may not run: a plugin that is not registered" '[[ $RC -ne 0 ]]'
as_bot sudo -n "$HELPER" e2e status extra; RC=$?; check "may not run: extra arguments" '[[ $RC -ne 0 ]]'
as_bot sudo -n "$HELPER"; RC=$?; check "may not run: the helper without arguments" '[[ $RC -ne 0 ]]'
as_bot touch /etc/opsbot-e2e-probe; RC=$?; check "cannot write system files itself" '[[ $RC -ne 0 && ! -e /etc/opsbot-e2e-probe ]]'
as_bot cat /etc/opsbot/token; RC=$?; check "cannot read the token file itself (only via its systemd credential)" '[[ $RC -ne 0 ]]'
run "$HELPER" e2e nonsense; check "the helper refuses unknown actions even for root" '[[ $RC -eq 2 ]]'
out=$(cd /var/lib/opsbot 2>/dev/null || cd /tmp; LEAK=secret runuser -u opsbot -- env LEAK=secret sudo -n "$HELPER" e2e who 2>&1 </dev/null)
check "an action runs as root, from /, without the bot user's environment" '[[ $out == "user=root cwd=/ leak=none" ]]' "$out"

echo "== nothing of the bot user's reaches root"
rm -f /tmp/opsbot-e2e-pwned
runuser -u opsbot -- sh -c 'cd /var/lib/opsbot && for m in json re os signal argparse; do printf "open(\"/tmp/opsbot-e2e-pwned\", \"w\").write(\"x\")\n" > $m.py; done; sudo -n /usr/local/sbin/opsbot-action e2e status' </dev/null >"$T/out" 2>&1
check "python modules planted in the bot's directory are not loaded by root" '[[ ! -e /tmp/opsbot-e2e-pwned ]]' "$(tail -3 "$T/out")"
check "and the action still ran" 'grep -q "e2e plugin is up" "$T/out"' "$(tail -3 "$T/out")"
rm -f /var/lib/opsbot/{json,re,os,signal,argparse}.py /tmp/opsbot-e2e-pwned
chmod 666 /etc/opsbot/plugins.d/e2e.json
out=$(runuser -u opsbot -- sudo -n "$HELPER" e2e status 2>&1 </dev/null); RC=$?
check "a plugin file someone could change is refused by the helper" '[[ $RC -ne 0 && $out == *"refused: group/world-writable"* ]]' "$out"
run "$CLI" check; check "... and opsbot check reports it" '[[ $RC -ne 0 ]] && grep -q "FAIL  a file root runs for opsbot is writable by others" "$T/out"' "$(cat "$T/out")"
chmod 644 /etc/opsbot/plugins.d/e2e.json
chmod 777 "$E2E/plugin.sh"
out=$(runuser -u opsbot -- sudo -n "$HELPER" e2e status 2>&1 </dev/null); RC=$?
check "a plugin script someone could change is refused too" '[[ $RC -ne 0 && $out == *"refused: group/world-writable: $E2E/plugin.sh"* ]]' "$out"
chmod 755 "$E2E/plugin.sh"
run "$CLI" check; check "opsbot check passes again" '[[ $RC -eq 0 ]]' "$(grep FAIL "$T/out")"

echo "== the bot against a fake Telegram"
python3 tests/fake_telegram.py "$T/port" & FAKE=$!
for _ in $(seq 1 50); do [[ -s $T/port ]] && break; sleep 0.1; done
PORT=$(cat "$T/port"); API=http://127.0.0.1:$PORT
start_bot() {
  systemd-run --quiet --unit opsbot-e2e -p User=opsbot -p Group=opsbot -p LoadCredential=token:/etc/opsbot/token \
    -p StateDirectory=opsbot-e2e /usr/bin/python3 -I "$PY" bot --user-id "$OWNER" --state-dir /var/lib/opsbot-e2e \
    --plugins /etc/opsbot/plugins.d --action-cmd "sudo -n $HELPER" --api-base "$API" --poll-timeout 2
}
start_bot
say() { curl -sS -m 5 -o /dev/null -X POST -H 'Content-Type: application/json' -d "$1" "$API/control/message"; }
nsent() { curl -sS -m 5 "$API/control/sent" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
last() { curl -sS -m 5 "$API/control/sent" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[-1]["text"] if d else "")'; }
to_others() { curl -sS -m 5 "$API/control/sent" | python3 -c "import json,sys; print(sum(1 for m in json.load(sys.stdin) if m['chat_id'] != $OWNER))"; }
menu() { curl -sS -m 5 "$API/control/commands"; }
# ask TEXT [N replies] [TIMEOUT] [FROM]: send, wait for N new replies, leave the last in $T/reply
ask() {
  local n0 i; n0=$(nsent)
  say "{\"text\": \"$1\", \"from\": ${4:-$OWNER}}"
  for ((i = 0; i < ${3:-30} * 5; i++)); do (($(nsent) >= n0 + ${2:-1})) && break; sleep 0.2; done
  last >"$T/reply"
}
reply() { cat "$T/reply"; }
token=$(cat /etc/opsbot/token)
for _ in $(seq 1 25); do [[ $(curl -sS "$API/control/tokens") == *"$(printf %s "$token" | sha256sum | cut -c1-64)"* ]] && break; sleep 0.2; done
check "the bot uses the real token (seen by the fake API)" '[[ $(curl -sS "$API/control/tokens") == *"$(printf %s "$token" | sha256sum | cut -c1-64)"* ]]'
check "its command menu has the plugin's commands" '[[ $(menu) == *"\"status\""* && $(menu) == *"\"e2e_slow\""* ]]' "$(menu)"

ask "/status"; check "/status: the plugin's status line (with its env), then the system line" \
  '[[ $(reply) == *"🧪 e2e plugin is up (env hello)"* && $(reply | tail -1) == "🖥 Disk "*" used ("*"MB free · up "* ]]' "$(reply)"
ask "/e2e_who"; check "a quick action replies with its title and output, run as root from /" '[[ $(reply) == "$(printf "👤 who\nuser=root cwd=/ leak=none")" ]]' "$(reply)"
ask "/e2e_slow"; check "a long action says it started" '[[ $(reply) == "⏳ slow..." ]]' "$(reply)"
ask "/e2e_slow"; check "... a second one while it runs is refused" '[[ $(reply) == "⏳ slow is busy" ]]' "$(reply)"
ask "/status"; check "... the bot keeps answering meanwhile" '[[ $(reply) == *"e2e plugin is up"* ]]' "$(reply)"
for ((i = 0; i < 50; i++)); do [[ $(last) == "✅ slow done"* ]] && break; sleep 0.2; done
check "... then its result" '[[ $(last) == "$(printf "✅ slow done\nslow done")" ]]' "$(last)"
ask "/e2e_fail" 2; check "a failing action: its fail title and output, no exit code" '[[ $(reply) == "$(printf "❌ it failed\nERROR: it broke")" ]]' "$(reply)"
ask "/e2e_slow now"; check "arguments a command does not take are refused" '[[ $(reply) == "/e2e_slow takes nothing after it. Just send /e2e_slow." ]]' "$(reply)"
ask "/e2e_who; reboot"; check "an injection attempt is just an unknown command" '[[ $(reply) == "Available actions:"* ]]' "$(reply)"

echo "== plugins coming and going while it runs"
run "$CLI" plugin add "$E2E/e2e-two.json"; check "a second plugin is registered" '[[ $RC -eq 0 ]]' "$(cat "$T/out")"
systemctl kill -s HUP opsbot-e2e.service   # what `systemctl reload opsbot` does to the real bot
ask "/status"  # the reload happens at the next poll
ask "/e2e_two"; check "after a reload its command works" '[[ $(reply) == "two here" ]]' "$(reply)"
check "... and is in the menu" '[[ $(menu) == *"\"e2e_two\""* ]]' "$(menu)"
run "$CLI" plugin remove e2e-two; systemctl kill -s HUP opsbot-e2e.service; ask "/status"
ask "/e2e_two"; check "removed and reloaded: the command is gone" '[[ $(reply) == "Available actions:"* && $(menu) != *"e2e_two"* ]]' "$(reply)"
as_bot sudo -n -l "$HELPER" e2e-two two; RC=$?; check "... and so is its sudo rule" '[[ $RC -ne 0 ]]'

echo "== other people and other chats"
ask "/e2e_who" 1 10 "$STRANGER"; check "a stranger is ignored and the owner told" '[[ $(reply) == "🚫 Someone else wrote, ignored:"*"(id $STRANGER)"* ]]' "$(reply)"
check "the stranger gets no answer at all" '[[ $(to_others) == 0 ]]'
n0=$(nsent); say "{\"text\": \"/e2e_who\", \"from\": $OWNER, \"chat\": -100555, \"type\": \"group\"}"; ask "/status"
check "the owner's command in a group is ignored" '[[ $(nsent) == $((n0 + 1)) && $(reply) == *"e2e plugin is up"* ]]' "$(reply)"
n0=$(nsent); say "{\"text\": \"/e2e_who\", \"from\": $OWNER, \"age\": 300}"
for ((i = 0; i < 50; i++)); do (($(nsent) > n0)) && break; sleep 0.2; done
check "an old command is not run" '[[ $(last) == "⏰ Skipped /e2e_who"* ]]' "$(last)"

echo "== an action outlives the bot"
ask "/e2e_long"
for ((i = 0; i < 50; i++)); do pgrep -f "$E2E/plugin.sh long" >/dev/null && break; sleep 0.2; done
systemctl kill -s KILL opsbot-e2e.service; sleep 2
check "an action keeps running when the bot is killed (it is a unit of its own)" '! systemctl is-active --quiet opsbot-e2e.service && pgrep -f "$E2E/plugin.sh long" >/dev/null'
pkill -f "$E2E/plugin.sh long"
check "the token never appears in the bot's log" '! journalctl -u opsbot-e2e.service -u opsbot.service -q -o cat --no-pager | grep -qF "${token#*:}"'

echo "== remove"
run "$CLI" plugin remove e2e; check "plugin remove succeeds" '[[ $RC -eq 0 && ! -e /etc/opsbot/plugins.d/e2e.json ]]' "$(cat "$T/out")"
as_bot sudo -n -l "$HELPER" e2e status; RC=$?; check "its actions are no longer allowed" '[[ $RC -ne 0 ]]'
run "$CLI" check; check "opsbot check passes" '[[ $RC -eq 0 ]]' "$(grep FAIL "$T/out")"

summary
