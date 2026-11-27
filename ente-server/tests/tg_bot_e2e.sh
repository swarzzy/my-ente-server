#!/usr/bin/env bash
# End-to-end tests of Ente's Telegram commands (ente-tg-bot.sh, an opsbot plugin) on a deployed server, as root. Installs or
# updates opsbot and the plugin, then runs a second instance of the real opsbot, as its real user with the real sudo rule,
# helper and Ente's actions, against a fake Telegram (../opsbot/tests/fake_telegram.py) on 127.0.0.1, so no real messages are
# needed. Needs TG_BOT_USER_ID in ente-setup.env and a bot token. Runs a real backup and toggles the S3 proxy (if installed);
# leaves the plugin and the proxy as it found them. opsbot's own security (sudo rule, helper, planted modules) is tested by
# ../opsbot/tests/opsbot_e2e.sh. Takes a few minutes. Run: sudo bash tests/tg_bot_e2e.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
BOTSH=./ente-tg-bot.sh HELPER=/usr/local/sbin/opsbot-action PLUGIN=/etc/opsbot/plugins.d/ente.json PY=/usr/local/lib/opsbot/opsbot.py
FAKE_TG=../opsbot/tests/fake_telegram.py
OWNER=$(sed -n 's/^TG_BOT_USER_ID=\([0-9]*\).*/\1/p' ente-setup.env)
DOMAIN=$(sed -n 's/^DOMAIN=\([^ #]*\).*/\1/p' ente-setup.env)
[[ -n $OWNER ]] || { echo "TG_BOT_USER_ID is not set in ente-setup.env" >&2; exit 1; }
STRANGER=555000111
WAS_INSTALLED=no; [[ -e $PLUGIN ]] && WAS_INSTALLED=yes
PROXY_INSTALLED=no; [[ -e /etc/caddy/ente.d/sites/s3-proxy.caddy ]] && PROXY_INSTALLED=yes
PROXY_WAS=$(cat /var/lib/ente-setup/s3-proxy 2>/dev/null || echo off)
chmod 755 "$T"
cleanup() {
  systemctl stop opsbot-e2e.service 2>/dev/null; systemctl reset-failed opsbot-e2e.service 2>/dev/null
  [[ -z ${FAKE:-} ]] || kill "$FAKE" 2>/dev/null
  rm -rf "$T" /var/lib/opsbot-e2e /var/lib/private/opsbot-e2e
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
check "Ente is registered with opsbot" '[[ -f $PLUGIN ]] && /usr/local/sbin/opsbot plugin list | grep -qw ente'
check "the bot service runs as opsbot" '[[ $(ps -o user= -p "$(systemctl show -p MainPID --value opsbot.service)") == opsbot ]]'
check "no bot from before opsbot is left" '! systemctl cat ente-tg-bot.service >/dev/null 2>&1 && ! id ente-tg-bot >/dev/null 2>&1'
h0=$(sha256sum "$PLUGIN" /etc/sudoers.d/opsbot /etc/systemd/system/opsbot.service); pid0=$(systemctl show -p MainPID --value opsbot.service)
run $BOTSH install; check "install again changes nothing and does not restart the bot" \
  '[[ $RC -eq 0 && $(sha256sum "$PLUGIN" /etc/sudoers.d/opsbot /etc/systemd/system/opsbot.service) == "$h0" && $(systemctl show -p MainPID --value opsbot.service) == "$pid0" ]]' "$(cat "$T/out")"
for a in status check backup proxy-on proxy-off proxy-status size; do
  runuser -u opsbot -- sudo -n -l "$HELPER" ente "$a" >/dev/null 2>&1; RC=$?; check "the bot may run: ente $a" '[[ $RC -eq 0 ]]'
done
out=$(runuser -u opsbot -- sudo -n "$HELPER" ente status 2>&1 </dev/null); RC=$?
check "the status action runs through opsbot's helper with Ente's config" '[[ $RC -eq 0 && $out == *"Ente is up"* ]]' "$out"

echo "== the bot against a fake Telegram"
python3 "$FAKE_TG" "$T/port" & FAKE=$!
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
# ask TEXT [N replies] [TIMEOUT] [FROM]: send, wait for N new replies, leave the last in $T/reply
ask() {
  local n0 i; n0=$(nsent)
  say "{\"text\": \"$1\", \"from\": ${4:-$OWNER}}"
  for ((i = 0; i < ${3:-120} * 5; i++)); do (($(nsent) >= n0 + ${2:-1})) && break; sleep 0.2; done
  last >"$T/reply"
}
reply() { cat "$T/reply"; }
token=$(cat /etc/opsbot/token)
for _ in $(seq 1 25); do [[ $(curl -sS "$API/control/tokens") == *"$(printf %s "$token" | sha256sum | cut -c1-64)"* ]] && break; sleep 0.2; done
check "the bot uses the real token (seen by the fake API)" '[[ $(curl -sS "$API/control/tokens") == *"$(printf %s "$token" | sha256sum | cut -c1-64)"* ]]'

ask "/status"; check "/status: Ente's lines (services, backup, checks, buckets, proxy), then opsbot's system line" \
  '[[ $(reply | head -1) == "✅ Ente is up (museum, web, postgres)" && $(reply) == *"💾 Backup: last good "*" ago · next "* && $(reply) == *" Check: "* && $(reply) == *"🪣 Buckets: "* && $(reply | tail -1) == "🖥 Disk "* && $(reply | wc -l) -le 6 ]]' "$(reply)"
ask "/check" 2 180; check "/check: the check passed, problems listed, the rest counted" \
  '[[ $(reply | head -1) == "✅ Check passed" && $(reply | tail -1) =~ ^[0-9]+\ checks\ OK$ && $(reply) != *"  OK  "* ]]' "$(reply)"
ask "/check@some_bot now"; check "arguments are refused" '[[ $(reply) == "Send /check." ]]' "$(reply)"
ask "/proxy on; reboot"; check "injection attempt is refused" '[[ $(reply) == "Send /proxy, /proxy on, /proxy off." ]]' "$(reply)"
check "and nothing else happened (proxy unchanged)" '[[ $(cat /var/lib/ente-setup/s3-proxy 2>/dev/null || echo off) == "$PROXY_WAS" ]]'

if [[ $PROXY_INSTALLED == yes ]]; then
  ask "/proxy" 2 60; check "/proxy: state of the S3 proxy, its checks counted" '[[ $(reply | head -1) == "🔀 S3 proxy" && $(reply) == *"S3 proxy is "* && $(reply) == *" checks OK" ]]' "$(reply)"
  ask "/proxy on" 2 180; check "/proxy on: switched on (self-test passed)" '[[ $(reply) == "✅ S3 proxy is on"* && $(cat /var/lib/ente-setup/s3-proxy) == on ]]' "$(reply)"
  check "and the API really goes through the rewriter" 'curl -sS -m 10 -o /dev/null -D - "https://api.$DOMAIN/ping" | grep -i "^x-ente-link-rewrite: on" >/dev/null'
  ask "/proxy off" 2 120; check "/proxy off: switched off" '[[ $(reply) == "✅ S3 proxy is off"* && $(cat /var/lib/ente-setup/s3-proxy) == off ]]' "$(reply)"
  systemctl stop ente-s3-rewrite.service
  ask "/check" 2 180; check "a failing /check says what failed" '[[ $(reply | head -1) == "❌ Check found problems" && $(reply) == *"❌ link rewriter not running"* ]]' "$(reply)"
  systemctl start ente-s3-rewrite.service; sleep 3
else
  ask "/proxy" 2 60; check "/proxy without the add-on says it is not installed" '[[ $(reply) == *"not installed"* ]]' "$(reply)"
fi

t0=$(systemctl show -p ExecMainStartTimestampMonotonic --value ente-backup.service)
ask "/backup" 1 30; check "/backup: acknowledged at once" '[[ $(reply) == "⏳ Backing up"* ]]' "$(reply)"
ask "/status" 1 30; check "the bot answers while the backup runs" '[[ $(reply) == *"Ente is up"* ]]' "$(reply)"
for ((i = 0; i < 600; i++)); do [[ $(last) == "✅ Backup done"* || $(last) == "❌ Backup failed"* ]] && break; sleep 1; done
last >"$T/reply"
check "/backup: the result follows" '[[ $(reply | head -1) == "✅ Backup done" && ( $(reply | sed -n 2p) == "Took "*" s." || $(reply | sed -n 2p) == "Took "*" min." ) ]]' "$(reply)"
check "a real backup ran" '[[ $(systemctl show -p ExecMainStartTimestampMonotonic --value ente-backup.service) != "$t0" ]]'

echo "== other people"
t0=$(systemctl show -p ExecMainStartTimestampMonotonic --value ente-backup.service)
n0=$(nsent); say "{\"text\": \"/backup\", \"from\": $STRANGER}"; ask "/status" 1 30
check "a stranger's /backup runs nothing and gets no answer" \
  '[[ $(systemctl show -p ExecMainStartTimestampMonotonic --value ente-backup.service) == "$t0" && $(nsent) == $((n0 + 1)) && $(to_others) == 0 ]]' "$(reply)"
systemctl stop opsbot-e2e.service
check "the token never appears in the bot's log" '! journalctl -u opsbot-e2e.service -u opsbot.service -q -o cat --no-pager | grep -qF "${token#*:}"'

echo "== ente-ops.sh check includes the bot"
run ./ente-ops.sh check; check "check has a telegram bot section with opsbot's checks, and passes" \
  '[[ $RC -eq 0 ]] && grep -q "== telegram bot" "$T/out" && grep -q "registered with opsbot" "$T/out" && grep -q "bot may run nothing else as root" "$T/out"' "$(grep -E "FAIL|bot" "$T/out")"
systemctl stop opsbot.service
run ./ente-ops.sh check; check "check reports a stopped bot" '[[ $RC -ne 0 ]] && grep -q "FAIL  bot not running" "$T/out"' "$(grep FAIL "$T/out")"
systemctl start opsbot.service

echo "== uninstall and install again"
run $BOTSH uninstall; check "uninstall succeeds: Ente is unregistered, opsbot stays" \
  '[[ $RC -eq 0 && ! -e $PLUGIN ]] && systemctl is-active --quiet opsbot.service' "$(cat "$T/out")"
runuser -u opsbot -- sudo -n -l "$HELPER" ente status >/dev/null 2>&1; RC=$?; check "Ente's actions are no longer allowed" '[[ $RC -ne 0 ]]'
run ./ente-ops.sh check; check "check passes without the bot and does not mention it" '[[ $RC -eq 0 ]] && ! grep -q "telegram bot" "$T/out"' "$(grep -E "FAIL|bot" "$T/out")"
run $BOTSH install; check "install again works" '[[ $RC -eq 0 && -f $PLUGIN ]] && systemctl is-active --quiet opsbot.service' "$(cat "$T/out")"

summary
