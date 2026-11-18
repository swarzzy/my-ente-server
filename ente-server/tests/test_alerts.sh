#!/usr/bin/env bash
# Tests for the Telegram alerts backup-setup installs: the real ente-alert and ente-alert-unit scripts, generated into a temp
# dir and pointed at a fake Telegram (tests/fake_telegram.py) on 127.0.0.1, with systemctl and journalctl stubbed. Checks
# what a failed check, verify or backup sends, the length limit, broken UTF-8, and where the token and chat id go.
# Changes nothing outside a temp dir. Needs bash, python3, curl and iconv. Run: bash tests/test_alerts.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FAKE=
trap '[[ -z $FAKE ]] || kill "$FAKE" 2>/dev/null; rm -rf "$T"' EXIT

TOKEN=123456789:AAH-test_token-abcdefghijklmnopqrstuv CHAT=-1001234567
printf '%s\n' DOMAIN=photos.example.org S3_ENDPOINT=s3.example.net S3_REGION=r1 S3_BUCKET=photos \
  BACKUP_S3_ENDPOINT=b2.example.net BACKUP_S3_REGION=r2 BACKUP_S3_BUCKET=bk "TG_CHAT_ID=$CHAT" >"$T/env"
printf 'TG_BOT_TOKEN=%s\n' "$TOKEN" >"$T/secrets"

echo "== setup_alerts writes the alert path"
# run_setup: setup_alerts into $T/root with Telegram's API stubbed (calls logged to $T/tg; sendMessage fails with SEND_FAILS)
run_setup() {
  ( ENV_FILE=$T/env SECRETS_FILE=$T/secrets CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-setup.sh"
    set +e
    load_env
    write_file() { local f=$T/root$1; mkdir -p "$(dirname "$f")"; cat >"$f"; chmod "${2:-644}" "$f"; }
    systemctl() { :; }
    tg_api() { echo "$*" >>"$T/tg"; [[ $1 != sendMessage || -z ${SEND_FAILS:-} ]]; }
    SCRIPT_DIR=/opt/ente-server setup_alerts ) >"$T/out" 2>&1
}
SEND_FAILS=1 run_setup; RC=$?
check "a test message that cannot be sent stops it, before anything is installed" \
  '((RC != 0)) && grep -q "could not send to TG_CHAT_ID" "$T/out" && [[ ! -e $T/root ]]' "$(tail -3 "$T/out")"
rm -f "$T/tg"
run_setup
R=$T/root
check "it sends a test message to the chat" 'grep -q "^sendMessage .*chat_id=$CHAT" "$T/tg"' "$(cat "$T/tg" 2>/dev/null)"
check "the token and chat id are stored in /etc/ente-alert.env, mode 600" \
  '[[ $(stat -c %a "$R/etc/ente-alert.env") == 600 ]] && grep -qx "TG_BOT_TOKEN='"'"'$TOKEN'"'"'" "$R/etc/ente-alert.env" && grep -qx "TG_CHAT_ID='"'"'$CHAT'"'"'" "$R/etc/ente-alert.env"' \
  "$(tail -3 "$T/out")"
check "the token is in no other file" '[[ $(grep -rlF -- "${TOKEN#*:}" "$R") == "$R/etc/ente-alert.env" ]]' "$(grep -rlF -- "${TOKEN#*:}" "$R")"
check "the check unit alerts on failure and runs ente-ops.sh check" \
  'grep -qx "OnFailure=ente-alert@%n.service" "$R/etc/systemd/system/ente-check.service" && grep -q "ente-ops.sh\" check$" "$R/etc/systemd/system/ente-check.service"'

echo "== emptying TG_CHAT_ID removes the alerts"
mkdir -p "$T/off"; for f in timer service alert-unit env alert alert-script; do echo x >"$T/off/$f"; done
out=$( ( ENV_FILE=$T/env SECRETS_FILE=$T/secrets CMD=test
  # shellcheck source=/dev/null
  . "$HERE/../ente-setup.sh"
  set +e
  load_env; TG_CHAT_ID=
  ALERT_FILES=("$T"/off/*)
  systemctl() { echo "systemctl $*" >>"$T/off.log"; }
  ALERT_ONFAIL=x; setup_alerts; echo "onfail=[$ALERT_ONFAIL]" ) 2>&1 )
check "all six files are removed, the timer stopped, OnFailure dropped" \
  '[[ -z $(ls "$T/off") && $(cat "$T/off.log") == *"disable --now ente-check.timer"* && $out == *"onfail=[]"* && $out == *"alerts removed"* ]]' "$out"
out=$( ( ENV_FILE=$T/env SECRETS_FILE=$T/secrets CMD=test; . "$HERE/../ente-setup.sh"; set +e; load_env; TG_CHAT_ID=
  ALERT_FILES=("$T/off/none"); systemctl() { echo "systemctl $*"; }; setup_alerts ) 2>&1 )
check "... and with nothing installed it does nothing" '[[ -z $out ]]' "$out"

python3 "$HERE/fake_telegram.py" "$T/port" & FAKE=$!
for _ in $(seq 50); do [[ -s $T/port ]] && break; sleep 0.1; done
PORT=$(cat "$T/port")
# the generated scripts with their fixed paths and Telegram's URL pointed into the test
mkdir -p "$T/bin"
for f in ente-alert ente-alert-unit; do
  sed -e "s|/etc/ente-alert.env|$R/etc/ente-alert.env|g; s|/usr/local/bin/ente-alert|$T/bin/ente-alert|g" \
    -e "s|https://api.telegram.org|http://127.0.0.1:$PORT|g" "$R/usr/local/bin/$f" >"$T/bin/$f"
  chmod 755 "$T/bin/$f"
done
printf '#!/bin/sh\necho test-invocation\n' >"$T/bin/systemctl"
printf '#!/bin/sh\ncat "%s"\n' "$T/journal" >"$T/bin/journalctl"
chmod 755 "$T/bin/systemctl" "$T/bin/journalctl"
# alert UNIT: run ente-alert-unit as the alert service would, with $T/journal as the unit's output
alert() { PATH=$T/bin:$PATH "$T/bin/ente-alert-unit" "$1" >"$T/out" 2>&1; }
# last: the text of the last message the fake received (field chat_id or text)
last() { curl -fsS "http://127.0.0.1:$PORT/control/sent" | python3 -I -c "import json, sys; print(json.load(sys.stdin)[-1][sys.argv[1]])" "$1"; }
sent() { curl -fsS "http://127.0.0.1:$PORT/control/sent" | python3 -I -c "import json, sys; print(len(json.load(sys.stdin)))"; }

echo "== what an alert says"
printf '%s\n' "== containers" "  OK    museum healthy" "  WARN  sign-ups are open" "  FAIL  web exited" "== backup" \
  "  FAIL  last backup is older than 36 h" "" "2 check(s) FAILED" >"$T/journal"
alert ente-check.service; RC=$?
check "a failed check sends a message" '((RC == 0)) && [[ $(sent) -eq 1 ]]' "$(cat "$T/out")"
check "... to the configured chat" '[[ $(last chat_id) == "$CHAT" ]]'
check "... titled 'Daily check found problems on <host>'" '[[ $(last text | head -1) == "⚠️ Daily check found problems on $(hostname)" ]]' "$(last text)"
check "... with only the FAIL lines, as ❌ lines (no OK, WARN or verdict noise)" \
  '[[ $(last text | tail -n +3) == "$(printf "❌ web exited\n❌ last backup is older than 36 h")" ]]' "$(last text)"
check "... sent with the configured token" \
  '[[ $(curl -fsS "http://127.0.0.1:$PORT/control/tokens") == "[\"$(printf %s "$TOKEN" | sha256sum | cut -d" " -f1)\"]" ]]'
printf '%s\n' "== database dump" "  OK    restores" "  FAIL  restored dump looks incomplete" "" "1 verify check(s) FAILED" >"$T/journal"
alert ente-verify.service
check "a failed verify: 'Monthly backup verify found problems', FAIL lines only" \
  '[[ $(last text | head -1) == "⚠️ Monthly backup verify found problems on $(hostname)" && $(last text | tail -n +3) == "❌ restored dump looks incomplete" ]]' "$(last text)"
{ seq -f "backup line %g" 1 20; echo "ERROR: backup to the S3 bucket failed"; seq -f "backup line %g" 21 40; } >"$T/journal"
alert ente-backup.service
check "a failed backup: 'Backup failed on <host>' with its ERROR line only" \
  '[[ $(last text | head -1) == "❌ Backup failed on $(hostname)" && $(last text | tail -n +3) == "ERROR: backup to the S3 bucket failed" ]]' "$(last text)"
seq -f "backup line %g" 1 40 >"$T/journal"
alert ente-backup.service
check "... and without an ERROR line, the last 15 log lines" \
  '[[ $(last text | sed -n 3p) == "backup line 26" && $(last text | tail -1) == "backup line 40" ]]' "$(last text | head -4)"
printf '%s\n' "something" "ERROR: it broke" >"$T/journal"
alert ente-other.service
check "another unit: '<unit> failed on <host>'" '[[ $(last text | head -1) == "❌ ente-other.service failed on $(hostname)" && $(last text) == *"it broke" ]]' "$(last text)"

echo "== limits"
seq -f "  FAIL  a very long failure line number %g ........................................" 1 200 >"$T/journal"
alert ente-check.service
check "a long report is cut to its end and fits Telegram's 4096 characters" \
  '[[ $(last text | wc -m) -le 4096 && $(last text | tail -1) == *"number 200 "* ]]' "$(last text | wc -m)"
printf '  FAIL  broken \xff\xfe utf-8 here\n' >"$T/journal"
alert ente-check.service; RC=$?
check "broken UTF-8 in the log does not stop the alert" '((RC == 0)) && [[ $(last text) == *"broken  utf-8 here"* ]]' "$(cat "$T/out"; last text)"
: >"$T/journal"
alert ente-backup.service; RC=$?
check "an empty log still sends the title" '((RC == 0)) && [[ $(last text) == "❌ Backup failed on $(hostname)" ]]' "$(last text)"
kill "$FAKE"; wait "$FAKE" 2>/dev/null; FAKE=
alert ente-check.service; RC=$?
check "Telegram unreachable: the alert fails (the unit shows failed)" '((RC != 0))'

summary
