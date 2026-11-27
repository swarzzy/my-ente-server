#!/usr/bin/env bash
# Tests for the Telegram alerts backup-setup installs through opsbot: setup_alerts with a fake opsbot install, then the real
# ente-alert-unit with opsbot's real opsbot-notify-unit and opsbot-notify (generated into a temp dir) against a fake Telegram
# (../opsbot/tests/fake_telegram.py) on 127.0.0.1, with systemctl and journalctl stubbed. Checks what a failed check, verify or
# backup sends, and where the token and chat id go. Changes nothing outside a temp dir. Needs bash, python3, curl and iconv.
# Run: bash tests/test_alerts.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OPSBOT=$HERE/../../opsbot
FAKE=
trap '[[ -z $FAKE ]] || kill "$FAKE" 2>/dev/null; rm -rf "$T"' EXIT

TOKEN=123456789:AAH-test_token-abcdefghijklmnopqrstuv CHAT=-1001234567
printf '%s\n' DOMAIN=photos.example.org S3_ENDPOINT=s3.example.net S3_REGION=r1 S3_BUCKET=photos \
  BACKUP_S3_ENDPOINT=b2.example.net BACKUP_S3_REGION=r2 BACKUP_S3_BUCKET=bk "TG_CHAT_ID=$CHAT" >"$T/env"
printf 'TG_BOT_TOKEN=%s\n' "$TOKEN" >"$T/secrets"
mkdir -p "$T/bin"
# a fake opsbot.sh: records how it was run; a fake opsbot-notify: records the message, fails with NOTIFY_FAILS
printf '#!/bin/bash\n{ echo "args=$*"; echo "token=${OPSBOT_TOKEN-unset}"; echo "chat=${OPSBOT_CHAT_ID-unset}"; echo "user=${OPSBOT_USER_ID-unset}"; } >"%s"\nexit "${OPSBOT_FAILS:-0}"\n' \
  "$T/opsbot.log" >"$T/bin/opsbot.sh"
printf '#!/bin/bash\necho "$1" >>"%s"\n[[ -z ${NOTIFY_FAILS:-} ]]\n' "$T/notify.log" >"$T/bin/notify"
chmod 755 "$T/bin/opsbot.sh" "$T/bin/notify"

echo "== setup_alerts installs opsbot and Ente's alert units"
# run_setup: setup_alerts into $T/root (the generated ente-alert-unit calls $T/bin/opsbot-notify-unit)
run_setup() {
  ( ENV_FILE=$T/env SECRETS_FILE=$T/secrets CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-setup.sh"
    set +e
    load_env
    OPSBOT_SH=$T/bin/opsbot.sh OPSBOT_NOTIFY=$T/bin/notify OPSBOT_TOKEN_FILE=$T/none ALERT_LEGACY=("$T/legacy.env" "$T/legacy-alert")
    write_file() { local f=$T/root$1; mkdir -p "$(dirname "$f")"; cat >"$f"; chmod "${2:-644}" "$f"; }
    systemctl() { :; }
    SCRIPT_DIR=/opt/ente-server setup_alerts; echo "onfail=[$ALERT_ONFAIL]" ) >"$T/out" 2>&1
}
OPSBOT_USER_ID=999 OPSBOT_FAILS=1 run_setup; RC=$?
check "an opsbot install that fails stops it, before anything is installed" \
  'grep -q "opsbot install failed" "$T/out" && [[ ! -e $T/root ]]' "$(tail -3 "$T/out")"
check "opsbot is installed with the token and chat of this config, and its bot left as it is (no user id passed)" \
  '[[ $(cat "$T/opsbot.log") == "$(printf "args=install\ntoken=%s\nchat=%s\nuser=unset" "$TOKEN" "$CHAT")" ]]' "$(cat "$T/opsbot.log")"
NOTIFY_FAILS=1 run_setup
check "a test message that cannot be sent stops it, before anything is installed" \
  'grep -q "could not send to TG_CHAT_ID" "$T/out" && [[ ! -e $T/root ]]' "$(tail -3 "$T/out")"
rm -f "$T/notify.log"
echo old >"$T/legacy.env"; echo old >"$T/legacy-alert"
run_setup
R=$T/root
check "it sends a test message through opsbot" '[[ $(cat "$T/notify.log") == "🔔 Ente alerts on "*"(photos.example.org) are set up."* ]]' "$(cat "$T/notify.log" 2>/dev/null)"
check "the token is in none of Ente's files (opsbot keeps it)" '! grep -rqF -- "${TOKEN#*:}" "$R"' "$(grep -rlF -- "${TOKEN#*:}" "$R")"
check "the alerts from before opsbot are removed" '[[ ! -e $T/legacy.env && ! -e $T/legacy-alert ]] && grep -q "removed the alerts from before opsbot" "$T/out"'
check "the backup unit gets OnFailure=ente-alert@" 'grep -qx "onfail=\[OnFailure=ente-alert@%n.service\]" "$T/out"' "$(tail -2 "$T/out")"
check "the check unit alerts on failure and runs ente-ops.sh check" \
  'grep -qx "OnFailure=ente-alert@%n.service" "$R/etc/systemd/system/ente-check.service" && grep -q "ente-ops.sh\" check$" "$R/etc/systemd/system/ente-check.service"'
check "the monthly news unit runs ente-ops.sh news on the 2nd, alerts on failure, with the same config files" \
  'grep -q "ente-ops.sh\" news$" "$R/etc/systemd/system/ente-news.service" && grep -qx "OnFailure=ente-alert@%n.service" "$R/etc/systemd/system/ente-news.service" &&
   grep -qx "Environment=ENV_FILE=$(realpath "$T/env") SECRETS_FILE=$(realpath "$T/secrets")" "$R/etc/systemd/system/ente-news.service" &&
   grep -qx "OnCalendar=\*-\*-02 10:00:00" "$R/etc/systemd/system/ente-news.timer"' "$(cat "$R/etc/systemd/system/ente-news."* 2>&1)"
check "... with the config and secrets files setup used (not the default ones)" \
  'grep -qx "Environment=ENV_FILE=$(realpath "$T/env") SECRETS_FILE=$(realpath "$T/secrets")" "$R/etc/systemd/system/ente-check.service"' \
  "$(grep Environment "$R/etc/systemd/system/ente-check.service")"
check "ente-alert@ runs ente-alert-unit, which hands over to opsbot-notify-unit" \
  'grep -qx "ExecStart=/usr/local/bin/ente-alert-unit %i" "$R/etc/systemd/system/ente-alert@.service" && grep -q "^exec $T/bin/notify-unit " "$R/usr/local/bin/ente-alert-unit"' \
  "$(tail -2 "$R/usr/local/bin/ente-alert-unit")"
rm -f "$T/opsbot.log"
out=$( ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test; . "$HERE/../ente-setup.sh"; set +e; load_env
  OPSBOT_SH=$T/bin/opsbot.sh OPSBOT_NOTIFY=$T/bin/notify OPSBOT_TOKEN_FILE=$T/none ALERT_LEGACY=("$T/x" "$T/y"); setup_alerts ) 2>&1 )
check "no token in the secrets file and none stored: it asks for TG_BOT_TOKEN" '[[ $out == *"TG_BOT_TOKEN is not set"* && ! -e $T/opsbot.log ]]' "$out"
printf "TG_BOT_TOKEN='%s'\n" "$TOKEN" >"$T/legacy.env"
out=$( ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test; . "$HERE/../ente-setup.sh"; set +e; load_env
  OPSBOT_SH=$T/bin/opsbot.sh OPSBOT_NOTIFY=$T/bin/notify OPSBOT_TOKEN_FILE=$T/none ALERT_LEGACY=("$T/legacy.env" "$T/y")
  write_file() { cat >/dev/null; }; systemctl() { :; }; setup_alerts ) 2>&1 )
check "... the token of the alerts before opsbot is moved over (secrets file deleted after the first install)" \
  'grep -qx "token=$TOKEN" "$T/opsbot.log"' "$out"

echo "== emptying TG_CHAT_ID removes Ente's alerts"
mkdir -p "$T/off"; for f in timer service alert-unit unit-script news-timer news-service; do echo x >"$T/off/$f"; done
out=$( ( ENV_FILE=$T/env SECRETS_FILE=$T/secrets CMD=test
  # shellcheck source=/dev/null
  . "$HERE/../ente-setup.sh"
  set +e
  load_env; TG_CHAT_ID=
  ALERT_FILES=("$T"/off/*)
  systemctl() { echo "systemctl $*" >>"$T/off.log"; }
  ALERT_ONFAIL=x; setup_alerts; echo "onfail=[$ALERT_ONFAIL]" ) 2>&1 )
check "all its files are removed, the timers stopped, OnFailure dropped" \
  '[[ -z $(ls "$T/off") && $(cat "$T/off.log") == *"disable --now ente-check.timer ente-news.timer"* && $out == *"onfail=[]"* && $out == *"alerts removed"* ]]' "$out"
out=$( ( ENV_FILE=$T/env SECRETS_FILE=$T/secrets CMD=test; . "$HERE/../ente-setup.sh"; set +e; load_env; TG_CHAT_ID=
  ALERT_FILES=("$T/off/none"); systemctl() { echo "systemctl $*"; }; setup_alerts ) 2>&1 )
check "... and with nothing installed it does nothing" '[[ -z $out ]]' "$out"

python3 "$OPSBOT/tests/fake_telegram.py" "$T/port" & FAKE=$!
for _ in $(seq 50); do [[ -s $T/port ]] && break; sleep 0.1; done
PORT=$(cat "$T/port")
# opsbot's notification scripts, generated with their files in $T/ob and Telegram's URL pointed at the fake
mkdir -p "$T/ob"; printf 'USER_ID=\nCHAT_ID=%s\n' "$CHAT" >"$T/ob/opsbot.conf"; echo "$TOKEN" >"$T/ob/token"
( TG_API=http://127.0.0.1:$PORT
  # shellcheck source=/dev/null
  . "$OPSBOT/opsbot.sh"
  CONF=$T/ob/opsbot.conf TOKEN_FILE=$T/ob/token NOTIFY=$T/bin/notify
  notify_script >"$T/bin/notify"; notify_unit_script >"$T/bin/notify-unit" )
chmod 755 "$T/bin/notify" "$T/bin/notify-unit"
printf '#!/bin/sh\necho test-invocation\n' >"$T/bin/systemctl"
printf '#!/bin/sh\ncat "%s"\n' "$T/journal" >"$T/bin/journalctl"
chmod 755 "$T/bin/systemctl" "$T/bin/journalctl"
# alert UNIT: run Ente's ente-alert-unit as ente-alert@ would, with $T/journal as the unit's output
alert() { PATH=$T/bin:$PATH "$R/usr/local/bin/ente-alert-unit" "$1" >"$T/out" 2>&1; }
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
printf '%s\n' "something" "  FAIL  not an error here" "ERROR: it broke" >"$T/journal"
alert ente-other.service
check "another unit: '<unit> failed on <host>', its ERROR lines" \
  '[[ $(last text | head -1) == "❌ ente-other.service failed on $(hostname)" && $(last text | tail -n +3) == "ERROR: it broke" ]]' "$(last text)"
kill "$FAKE"; wait "$FAKE" 2>/dev/null; FAKE=
alert ente-check.service; RC=$?
check "Telegram unreachable: the alert fails (the unit shows failed)" '((RC != 0))'

summary
