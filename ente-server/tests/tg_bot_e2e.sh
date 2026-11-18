#!/usr/bin/env bash
# End-to-end tests of the Telegram bot on a deployed server, as root. Runs a second instance of the real bot, as the real
# ente-tg-bot user with the real sudo rule, helper and actions, against a fake Telegram (tests/fake_telegram.py) on
# 127.0.0.1, so no real messages are needed. Needs TG_BOT_USER_ID in ente-setup.env and a bot token. Runs a real backup
# and toggles the S3 proxy (if installed); leaves the bot and the proxy as it found them. Takes a few minutes.
# Run: sudo bash tests/tg_bot_e2e.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
BOTSH=./ente-tg-bot.sh HELPER=/usr/local/sbin/ente-tg-action UNIT=/etc/systemd/system/ente-tg-bot.service
OWNER=$(sed -n 's/^TG_BOT_USER_ID=\([0-9]*\).*/\1/p' ente-setup.env)
DOMAIN=$(sed -n 's/^DOMAIN=\([^ #]*\).*/\1/p' ente-setup.env)
[[ -n $OWNER ]] || { echo "TG_BOT_USER_ID is not set in ente-setup.env" >&2; exit 1; }
STRANGER=555000111
WAS_INSTALLED=no; [[ -e $UNIT ]] && WAS_INSTALLED=yes
PROXY_INSTALLED=no; [[ -e /etc/caddy/ente.d/sites/s3-proxy.caddy ]] && PROXY_INSTALLED=yes
PROXY_WAS=$(cat /var/lib/ente-setup/s3-proxy 2>/dev/null || echo off)
chmod 755 "$T"
cleanup() {
  systemctl stop ente-tg-bot-e2e.service 2>/dev/null; systemctl reset-failed ente-tg-bot-e2e.service 2>/dev/null
  [[ -z ${FAKE:-} ]] || kill "$FAKE" 2>/dev/null
  rm -rf "$T" /var/lib/ente-tg-bot-e2e /var/lib/private/ente-tg-bot-e2e
  if [[ $PROXY_INSTALLED == yes ]]; then ./ente-s3-proxy.sh "$PROXY_WAS" </dev/null >/dev/null 2>&1; fi
  if [[ $WAS_INSTALLED == no ]]; then $BOTSH uninstall </dev/null >/dev/null 2>&1; fi
}
trap cleanup EXIT
RC=0
run() { "$@" </dev/null >"$T/out" 2>&1; RC=$?; }

echo "== harness"
false; RC=$?; check "a failing command is seen as failing (harness self-test)" '[[ $RC -ne 0 ]]'

echo "== install"
run $BOTSH install; check "install succeeds" '[[ $RC -eq 0 ]]' "$(cat "$T/out")"
check "the bot service runs as ente-tg-bot" '[[ $(ps -o user= -p "$(systemctl show -p MainPID --value ente-tg-bot.service)") == ente-tg-bot ]]'
token=$(cat /etc/ente-tg-bot/token)
check "the token is not on any command line" '! ps -eo args | grep -F -- "${token#*:}" | grep -vq grep'
check "token file is root-only" '[[ $(stat -c "%U %a" /etc/ente-tg-bot/token) == "root 600" && $(stat -c "%a" /etc/ente-tg-bot) == 700 ]]'
h0=$(sha256sum "$UNIT" /etc/sudoers.d/ente-tg-bot "$HELPER"); pid0=$(systemctl show -p MainPID --value ente-tg-bot.service)
run $BOTSH install; check "install again changes nothing and does not restart the bot" \
  '[[ $RC -eq 0 && $(sha256sum "$UNIT" /etc/sudoers.d/ente-tg-bot "$HELPER") == "$h0" && $(systemctl show -p MainPID --value ente-tg-bot.service) == "$pid0" ]]' "$(cat "$T/out")"

echo "== what the bot user may run as root"
as_bot() { runuser -u ente-tg-bot -- "$@" </dev/null >/dev/null 2>&1; }
for a in status check backup proxy-on proxy-off proxy-status; do
  as_bot sudo -n -l "$HELPER" "$a"; RC=$?; check "may run: ente-tg-action $a" '[[ $RC -eq 0 ]]'
done
as_bot sudo -n /usr/bin/id; RC=$?; check "may not run: id" '[[ $RC -ne 0 ]]'
as_bot sudo -n /bin/bash -c true; RC=$?; check "may not run: bash" '[[ $RC -ne 0 ]]'
as_bot sudo -n "$HELPER" rm; RC=$?; check "may not run: ente-tg-action rm" '[[ $RC -ne 0 ]]'
as_bot sudo -n "$HELPER" status check; RC=$?; check "may not run: ente-tg-action with two arguments" '[[ $RC -ne 0 ]]'
as_bot sudo -n "$HELPER"; RC=$?; check "may not run: ente-tg-action without an argument" '[[ $RC -ne 0 ]]'
as_bot touch /etc/ente-e2e-probe; RC=$?; check "cannot write system files itself" '[[ $RC -ne 0 && ! -e /etc/ente-e2e-probe ]]'
as_bot cat /etc/ente-tg-bot/token; RC=$?; check "cannot read the token file itself (only via its systemd credential)" '[[ $RC -ne 0 ]]'
run "$HELPER" nonsense; check "the helper refuses unknown actions even for root" '[[ $RC -eq 2 ]]'

echo "== nothing of the bot user's reaches root"
rm -f /tmp/ente-e2e-pwned
runuser -u ente-tg-bot -- sh -c 'cd /var/lib/ente-tg-bot && printf "open(\"/tmp/ente-e2e-pwned\", \"w\").write(\"x\")\n" > yaml.py && cp yaml.py shlex.py && cp yaml.py boto3.py && sudo -n /usr/local/sbin/ente-tg-action proxy-status; sudo -n /usr/local/sbin/ente-tg-action check' </dev/null >"$T/out" 2>&1
check "python modules planted in the bot's directory are not loaded by root" '[[ ! -e /tmp/ente-e2e-pwned ]]' "$(tail -3 "$T/out")"
check "and the action still ran" 'grep -q "OK" "$T/out"' "$(tail -3 "$T/out")"
rm -f /var/lib/ente-tg-bot/yaml.py /var/lib/ente-tg-bot/shlex.py /var/lib/ente-tg-bot/boto3.py /tmp/ente-e2e-pwned
check "Caddy's admin API is closed to the bot user" '! runuser -u ente-tg-bot -- curl -s -m 5 -o /dev/null --unix-socket /run/caddy/admin.sock http://localhost/config/ && ! runuser -u ente-tg-bot -- curl -s -m 5 -o /dev/null http://localhost:2019/config/'
check "and open to root" 'curl -fsS -m 5 -o /dev/null --unix-socket /run/caddy/admin.sock http://localhost/config/'

echo "== the bot against a fake Telegram"
python3 tests/fake_telegram.py "$T/port" & FAKE=$!
for i in $(seq 1 50); do [[ -s $T/port ]] && break; sleep 0.1; done
PORT=$(cat "$T/port"); API=http://127.0.0.1:$PORT
systemd-run --quiet --unit ente-tg-bot-e2e -p User=ente-tg-bot -p Group=ente-tg-bot -p LoadCredential=token:/etc/ente-tg-bot/token \
  -p StateDirectory=ente-tg-bot-e2e /usr/bin/python3 /usr/local/lib/ente-setup/ente_tg_bot.py --user-id "$OWNER" \
  --state-dir /var/lib/ente-tg-bot-e2e --action-cmd "sudo -n $HELPER" --api-base "$API" --poll-timeout 2
say() { curl -sS -m 5 -o /dev/null -X POST -H 'Content-Type: application/json' -d "$1" "$API/control/message"; }
nsent() { curl -sS -m 5 "$API/control/sent" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
last() { curl -sS -m 5 "$API/control/sent" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[-1]["text"] if d else "")'; }
to_others() { curl -sS -m 5 "$API/control/sent" | python3 -c "import json,sys; print(sum(1 for m in json.load(sys.stdin) if m['chat_id'] != $OWNER))"; }
# ask TEXT [N replies] [TIMEOUT]: send as the owner, wait for N new replies, leave the last in $T/reply
ask() {
  local n0; n0=$(nsent)
  say "{\"text\": \"$1\", \"from\": ${4:-$OWNER}}"
  for ((i = 0; i < ${3:-120} * 5; i++)); do (($(nsent) >= n0 + ${2:-1})) && break; sleep 0.2; done
  last >"$T/reply"
}
reply() { cat "$T/reply"; }
check "the bot uses the real token (seen by the fake API)" \
  '[[ $(curl -sS "$API/control/tokens") == *"$(printf %s "$token" | sha256sum | cut -c1-64)"* ]] || { sleep 3; [[ $(curl -sS "$API/control/tokens") == *"$(printf %s "$token" | sha256sum | cut -c1-64)"* ]]; }'

ask "/status"; check "/status: five short lines: services, backup, checks, system, proxy" \
  '[[ $(reply | head -1) == "✅ Ente is up (museum, web, postgres)" && $(reply) == *"💾 Backup: last good "*" ago · next "* && $(reply) == *"🩺 Check: "* && $(reply) == *"🖥 Disk "* && $(reply | wc -l) -le 5 ]]' "$(reply)"
ask "/check" 2 180; check "/check: the check passed, problems listed, the rest counted" \
  '[[ $(reply | head -1) == "✅ Check passed" && $(reply | tail -1) =~ ^[0-9]+\ checks\ OK$ && $(reply) != *"  OK  "* ]]' "$(reply)"
ask "/check@some_bot now"; check "arguments are refused" '[[ $(reply) == "/check takes nothing after it. Just send /check." ]]' "$(reply)"
ask "/proxy on; reboot"; check "injection attempt is refused" '[[ $(reply) == "Send /proxy, /proxy on or /proxy off." ]]' "$(reply)"
check "and nothing else happened (no reboot pending from us, proxy unchanged)" '[[ $(cat /var/lib/ente-setup/s3-proxy 2>/dev/null || echo off) == "$PROXY_WAS" ]]'

if [[ $PROXY_INSTALLED == yes ]]; then
  ask "/proxy" 2 60; check "/proxy: state of the S3 proxy, its checks counted" '[[ $(reply | head -1) == "🔀 S3 proxy" && $(reply) == *"S3 proxy is "* && $(reply) == *" checks OK" ]]' "$(reply)"
  ask "/proxy on" 2 180; check "/proxy on: switched on (self-test passed)" '[[ $(reply) == "✅ S3 proxy is on"* && $(cat /var/lib/ente-setup/s3-proxy) == on ]]' "$(reply)"
  check "and the API really goes through the rewriter" 'curl -sS -m 10 -o /dev/null -D - "https://api.$DOMAIN/ping" | grep -i "^x-ente-link-rewrite: on" >/dev/null'
  ask "/proxy off" 2 120; check "/proxy off: switched off" '[[ $(reply) == "✅ S3 proxy is off"* && $(cat /var/lib/ente-setup/s3-proxy) == off ]]' "$(reply)"
else
  ask "/proxy" 2 60; check "/proxy without the add-on says it is not installed" '[[ $(reply) == *"not installed"* ]]' "$(reply)"
fi

if [[ $PROXY_INSTALLED == yes ]]; then
  systemctl stop ente-s3-rewrite.service
  ask "/check" 2 180; check "a failing /check says what failed" '[[ $(reply | head -1) == "❌ Check found problems" && $(reply) == *"❌ link rewriter not running"* ]]' "$(reply)"
  systemctl start ente-s3-rewrite.service; sleep 3
fi
pid=$(systemctl show -p MainPID --value ente-tg-bot-e2e.service); n0=$(nsent)
say "{\"text\": \"/check\", \"from\": $OWNER}"
for ((i = 0; i < 50; i++)); do pgrep -f "ente-tg-bot.sh action check" >/dev/null && break; sleep 0.2; done
systemctl kill -s KILL ente-tg-bot-e2e.service; sleep 2
check "an action keeps running when the bot is killed (it is a unit of its own)" '! systemctl is-active --quiet ente-tg-bot-e2e.service && pgrep -f "ente-tg-bot.sh action check" >/dev/null'
for ((i = 0; i < 120; i++)); do pgrep -f "ente-tg-bot.sh action check" >/dev/null || break; sleep 1; done
systemctl reset-failed ente-tg-bot-e2e.service 2>/dev/null
systemd-run --quiet --unit ente-tg-bot-e2e -p User=ente-tg-bot -p Group=ente-tg-bot -p LoadCredential=token:/etc/ente-tg-bot/token \
  -p StateDirectory=ente-tg-bot-e2e /usr/bin/python3 /usr/local/lib/ente-setup/ente_tg_bot.py --user-id "$OWNER" \
  --state-dir /var/lib/ente-tg-bot-e2e --action-cmd "sudo -n $HELPER" --api-base "$API" --poll-timeout 2
sleep 3
t0=$(systemctl show -p ExecMainStartTimestampMonotonic --value ente-backup.service)
ask "/backup" 1 30; check "/backup: acknowledged at once" '[[ $(reply) == "⏳ Backing up"* ]]' "$(reply)"
ask "/status" 1 30; check "the bot answers while the backup runs" '[[ $(reply) == *"Ente is up"* ]]' "$(reply)"
for ((i = 0; i < 600; i++)); do [[ $(last) == "✅ Backup done"* || $(last) == "❌ Backup failed"* ]] && break; sleep 1; done
last >"$T/reply"
check "/backup: the result follows" '[[ $(reply | head -1) == "✅ Backup done" && $(reply | sed -n 2p) == "Took "*" s." || $(reply | sed -n 2p) == "Took "*" min." ]]' "$(reply)"
check "a real backup ran" '[[ $(systemctl show -p ExecMainStartTimestampMonotonic --value ente-backup.service) != "$t0" ]]'

echo "== other people and other chats"
t0=$(systemctl show -p ExecMainStartTimestampMonotonic --value ente-backup.service)
ask "/backup" 1 20 "$STRANGER"
check "a stranger's /backup runs nothing" '[[ $(systemctl show -p ExecMainStartTimestampMonotonic --value ente-backup.service) == "$t0" ]]'
check "the owner is told about it" '[[ $(reply) == "🚫 Someone else wrote to me, I ignored it:"*"(id $STRANGER)"* ]]' "$(reply)"
check "the stranger gets no answer at all" '[[ $(to_others) == 0 ]]'
n0=$(nsent); say "{\"text\": \"/backup\", \"from\": $OWNER, \"chat\": -100555, \"type\": \"group\"}"; sleep 5
check "the owner's command in a group is ignored" '[[ $(nsent) == "$n0" && $(systemctl show -p ExecMainStartTimestampMonotonic --value ente-backup.service) == "$t0" ]]'
n0=$(nsent); say "{\"text\": \"/backup\", \"from\": $OWNER, \"age\": 300}"; sleep 5
check "an old command is not run" '[[ $(last) == "⏰ Skipped /backup"* && $(systemctl show -p ExecMainStartTimestampMonotonic --value ente-backup.service) == "$t0" ]]' "$(last)"
check "the token never appears in the bot's log" '! journalctl -u ente-tg-bot-e2e.service -u ente-tg-bot.service -q -o cat --no-pager | grep -qF "${token#*:}"'

echo "== ente-ops.sh check includes the bot"
run ./ente-ops.sh check; check "check has a telegram bot section and passes" '[[ $RC -eq 0 ]] && grep -q "== telegram bot" "$T/out" && grep -q "bot may run nothing else as root" "$T/out"' "$(grep -E "FAIL|bot" "$T/out")"
systemctl stop ente-tg-bot.service
run ./ente-ops.sh check; check "check reports a stopped bot" '[[ $RC -ne 0 ]] && grep -q "FAIL  telegram bot not running" "$T/out"' "$(grep FAIL "$T/out")"
systemctl start ente-tg-bot.service

echo "== uninstall and install again"
runuser -u ente-tg-bot -- sleep 300 & lingering=$!   # besides the e2e instance: uninstall must stop the user's processes
sleep 1
run $BOTSH uninstall; check "uninstall succeeds" '[[ $RC -eq 0 ]]' "$(cat "$T/out")"
check "processes of the bot user were stopped" '! kill -0 $lingering 2>/dev/null && ! systemctl is-active --quiet ente-tg-bot-e2e.service'
wait $lingering 2>/dev/null
check "everything is gone: service, user, sudo rule, helper, token" \
  '! systemctl cat ente-tg-bot.service >/dev/null 2>&1 && ! id ente-tg-bot >/dev/null 2>&1 && [[ ! -e /etc/sudoers.d/ente-tg-bot && ! -e $HELPER && ! -e /etc/ente-tg-bot ]]'
run ./ente-ops.sh check; check "check passes without the bot and does not mention it" '[[ $RC -eq 0 ]] && ! grep -q "telegram bot" "$T/out"' "$(grep -E "FAIL|bot" "$T/out")"
run $BOTSH install; check "install again works" '[[ $RC -eq 0 ]] && systemctl is-active --quiet ente-tg-bot.service' "$(cat "$T/out")"

summary
