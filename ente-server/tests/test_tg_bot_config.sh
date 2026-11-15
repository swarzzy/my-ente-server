#!/usr/bin/env bash
# Tests for ente-tg-bot.sh: config validation, the token source, the generated unit, sudo rule and root helper, and the
# command line. Runs anywhere bash is; where visudo is installed (the server) the sudo rule is also validated. Changes
# nothing on the machine: when run as root, the command-line checks run as an unprivileged user on a copy.
# Run: bash tests/test_tg_bot_config.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/        /' | head -20; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }

TOKEN=123456789:AAH-test_token-abcdefghijklmnopqrstuv
base_env() {
  cat <<'X'
DOMAIN=photos.example.org
ADMIN_USER=ops
ADMIN_SSH_PUBKEY="ssh-ed25519 AAAA test"
S3_ENDPOINT=s3.eu-west-4.idrivee2.com
S3_REGION=eu-west-4
S3_BUCKET=ente-dev
BACKUP_S3_ENDPOINT=s3.us-east-005.backblazeb2.com
BACKUP_S3_REGION=us-east-005
BACKUP_S3_BUCKET=ente-backup
X
}
# in_bot ENV_EXTRA SECRETS CODE: source ente-tg-bot.sh with a config, a secrets file and a private alert env, run CODE
in_bot() {
  base_env >"$T/env"; printf '%s\n' "$1" >>"$T/env"
  printf '%s\n' "$2" >"$T/secrets"; chmod 600 "$T/secrets"
  ( ENV_FILE=$T/env SECRETS_FILE=$T/secrets ALERT_ENV=$T/alert.env CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-tg-bot.sh"
    set +e
    eval "$3" )
}
U=TG_BOT_USER_ID=376193354

echo "== config validation"
out=$(in_bot "$U" "TG_BOT_TOKEN=$TOKEN" 'bot_load_env && echo "LOADED $TG_BOT_USER_ID"' 2>&1)
check "accepts a user id" '[[ $out == *"LOADED 376193354"* ]]' "$out"
for bad in "TG_BOT_USER_ID=" "TG_BOT_USER_ID=-1001234567" "TG_BOT_USER_ID=0" "TG_BOT_USER_ID=abc" "TG_BOT_USER_ID='1 2'" "TG_BOT_USER_ID=0123"; do
  out=$(in_bot "$bad" "TG_BOT_TOKEN=$TOKEN" 'bot_load_env && echo LOADED' 2>&1)
  check "rejects $bad" '[[ $out != *LOADED* && $out == *TG_BOT_USER_ID* ]]' "$out"
done

echo "== bot token"
rm -f "$T/alert.env"
out=$(in_bot "$U" "TG_BOT_TOKEN=$TOKEN" 'bot_load_env; bot_token' 2>&1); check "token from the secrets file" '[[ $out == "$TOKEN" ]]' "$out"
printf "TG_BOT_TOKEN='%s'\nTG_CHAT_ID='1'\n" "$TOKEN" >"$T/alert.env"
out=$(in_bot "$U" "" 'bot_load_env; bot_token' 2>&1); check "token from the alerts' env file when the secrets file has none" '[[ $out == "$TOKEN" ]]' "$out"
rm -f "$T/alert.env"
out=$(in_bot "$U" "" 'bot_load_env; bot_token </dev/null && echo GOT' 2>&1); check "no token anywhere is an error" '[[ $out != *GOT* && $out == *TG_BOT_TOKEN* ]]' "$out"
out=$(in_bot "$U" "TG_BOT_TOKEN=not-a-token" 'bot_load_env; bot_token && echo GOT' 2>&1); check "a malformed token is refused" '[[ $out != *GOT* ]]' "$out"

echo "== service unit"
out=$(in_bot "$U" "TG_BOT_TOKEN=$TOKEN" 'bot_load_env; bot_unit')
check "runs as its own unprivileged user" '[[ $out == *"User=ente-tg-bot"* && $out == *"Group=ente-tg-bot"* && $out != *"User=root"* ]]' "$out"
check "gets the token as a systemd credential, never on the command line" '[[ $out == *"LoadCredential=token:/etc/ente-tg-bot/token"* && $out != *"$TOKEN"* ]]' "$out"
check "serves only the configured user" '[[ $out == *"--user-id 376193354"* ]]' "$out"
check "runs actions only through sudo and the helper" '[[ $out == *"--action-cmd \"sudo -n /usr/local/sbin/ente-tg-action\""* ]]' "$out"
check "keeps its state in its own directory and restarts on failure" '[[ $out == *"StateDirectory=ente-tg-bot"* && $out == *"Restart=always"* ]]' "$out"
check "does not set NoNewPrivileges (sudo needs it)" '[[ $out != *"NoNewPrivileges=yes"* ]]' "$out"

echo "== sudo rule"
in_bot "$U" "" 'bot_sudoers' >"$T/sudoers"
check "allows exactly the six actions, as root, for the bot user only" \
  '[[ $(grep -c "^ente-tg-bot ALL=(root) NOPASSWD:" "$T/sudoers") == 1 && $(grep -o "/usr/local/sbin/ente-tg-action [a-z-]*" "$T/sudoers" | sort | tr "\n" " ") == "/usr/local/sbin/ente-tg-action backup /usr/local/sbin/ente-tg-action check /usr/local/sbin/ente-tg-action proxy-off /usr/local/sbin/ente-tg-action proxy-on /usr/local/sbin/ente-tg-action proxy-status /usr/local/sbin/ente-tg-action status " ]]' "$(cat "$T/sudoers")"
check "no wildcard and no other command" '! grep -qE "\*|ALL$|ALL,|/bin/|/usr/bin/" <(grep -v "^#" "$T/sudoers")' "$(cat "$T/sudoers")"
if command -v visudo >/dev/null; then
  out=$(visudo -cf "$T/sudoers" 2>&1); rc=$?; check "visudo accepts the rule" '[[ $rc -eq 0 ]]' "$out"
  printf 'ente-tg-bot ALL=(root NOPASSWD /x\n' >"$T/bad.sudoers"; visudo -cf "$T/bad.sudoers" >/dev/null 2>&1; rc=$?
  check "a broken rule is seen as broken (harness self-test)" '[[ $rc -ne 0 ]]'
else
  echo "  skip  visudo not installed here (run on the server)"
fi

echo "== root helper"
printf '#!/bin/bash\necho "forwarded: $*"\n' >"$T/fake-bot.sh"
in_bot "$U" "" "BOT_SCRIPT=$T/fake-bot.sh bot_helper" >"$T/helper"; chmod 755 "$T/helper"
for a in status check backup proxy-on proxy-off proxy-status; do
  out=$("$T/helper" "$a" 2>&1); check "helper forwards '$a'" '[[ $out == "forwarded: action $a" ]]' "$out"
done
for a in "rm" "status;id" "" "../x" "--help" "STATUS"; do
  out=$("$T/helper" "$a" 2>&1); rc=$?; check "helper refuses '$a'" '[[ $rc -eq 2 && $out != *forwarded* ]]' "$out"
done
out=$("$T/helper" status check 2>&1); rc=$?; check "helper refuses two arguments" '[[ $rc -eq 2 && $out != *forwarded* ]]' "$out"
check "helper does not pass the environment through (absolute paths only)" '! grep -qE "\\\$[A-Z_]+[^0-9]" <(grep -v "^#" "$T/helper" | grep -v "\\\$1\|\\\$#")' "$(cat "$T/helper")"

echo "== the scripts the helper runs as root must be root's alone"
mkdir -p "$T/own"; touch "$T/own/a"; chmod 755 "$T/own"; chmod 644 "$T/own/a"
out=$(in_bot "$U" "" "root_only_writable $T/own/a" 2>&1); rc=$?
if [[ $EUID -eq 0 ]]; then check "a root-owned, not group/world-writable file passes" '[[ $rc -eq 0 ]]' "$out"; fi
chmod 666 "$T/own/a"
out=$(in_bot "$U" "" "root_only_writable $T/own/a" 2>&1); rc=$?; check "a world-writable file is refused" '[[ $rc -ne 0 ]]' "$out"
chmod 644 "$T/own/a"; chmod 777 "$T/own"
out=$(in_bot "$U" "" "root_only_writable $T/own/a" 2>&1); rc=$?; check "a file in a world-writable directory is refused" '[[ $rc -ne 0 ]]' "$out"
if [[ $EUID -eq 0 ]]; then
  chmod 1777 "$T/own"
  out=$(in_bot "$U" "" "root_only_writable $T/own/a" 2>&1); rc=$?; check "a file in root's sticky world-writable directory (like /tmp) passes" '[[ $rc -eq 0 ]]' "$out"
  chmod 666 "$T/own/a"
  out=$(in_bot "$U" "" "root_only_writable $T/own/a" 2>&1); rc=$?; check "but a world-writable file in it is still refused" '[[ $rc -ne 0 ]]' "$out"
  chmod 644 "$T/own/a"
fi
chmod 755 "$T/own"
if [[ $EUID -ne 0 ]]; then out=$(in_bot "$U" "" "root_only_writable $T/own/a" 2>&1); rc=$?; check "a file not owned by root is refused" '[[ $rc -ne 0 ]]' "$out"; fi

echo "== command lines"
asuser() { "$@"; }
if [[ $EUID -eq 0 ]]; then
  mkdir -p "$T/bin"; cp "$HERE/../ente-setup.sh" "$HERE/../ente-tg-bot.sh" "$T/bin/"; chmod 755 "$T" "$T/bin" "$T/bin"/*
  asuser() { setpriv --reuid=65534 --regid=65534 --clear-groups "$@"; }
  CLI=$T/bin
else
  CLI=$HERE/..
fi
out=$(asuser bash "$CLI/ente-tg-bot.sh" maybe 2>&1); rc=$?; check "unknown command is a usage error" '[[ $rc -eq 2 && $out == *usage* ]]' "$out"
out=$(asuser bash "$CLI/ente-tg-bot.sh" 2>&1); rc=$?; check "no command is a usage error" '[[ $rc -eq 2 && $out == *usage* ]]' "$out"
out=$(asuser bash "$CLI/ente-tg-bot.sh" action rm 2>&1); rc=$?; check "action with an unknown name is a usage error" '[[ $rc -eq 2 ]]' "$out"
for c in install uninstall status check "action status"; do
  # shellcheck disable=SC2086
  out=$(asuser bash "$CLI/ente-tg-bot.sh" $c 2>&1); check "'$c' is a known command (asks for root here)" '[[ $out == *"run as root"* ]]' "$out"
done

echo
echo "$PASS passed, $FAIL failed"
((FAIL == 0))
