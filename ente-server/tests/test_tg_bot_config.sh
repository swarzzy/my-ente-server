#!/usr/bin/env bash
# Tests for ente-tg-bot.sh: config validation, the token source, the generated unit, sudo rule and root helper, and the
# command line. Runs anywhere bash is; where visudo is installed (the server) the sudo rule is also validated. Changes
# nothing on the machine: when run as root, the command-line checks run as an unprivileged user on a copy.
# Run: bash tests/test_tg_bot_config.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
for bad in "TG_BOT_USER_ID=" "TG_BOT_USER_ID='1 --api-base http://evil.example'" "TG_BOT_USER_ID=-100123" "TG_BOT_USER_ID=0"; do
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
in_bot "$U" "" "bot_helper" >"$T/helper.real"
check "the real helper starts actions as a transient unit, from /, with a time limit" 'grep -q "^cd / " "$T/helper.real" && grep -q "^exec systemd-run .*--wait --pipe.*RuntimeMaxSec=" "$T/helper.real"' "$(cat "$T/helper.real")"
( cd "$T" && BOT_RUN="env -i" in_bot "$U" "" "BOT_SCRIPT=$T/fake-bot.sh bot_helper" ) >"$T/helper"; chmod 755 "$T/helper"
printf '#!/bin/bash\necho "forwarded: $* cwd=$PWD leak=${LEAK:-none}"\n' >"$T/fake-bot.sh"
out=$(cd "$T" && LEAK=secret "$T/helper" status 2>&1); check "helper passes on neither the working directory nor the environment" '[[ $out == "forwarded: action status cwd=/ leak=none" ]]' "$out"
printf '#!/bin/bash\necho "forwarded: $*"\n' >"$T/fake-bot.sh"
for a in status check backup proxy-on proxy-off proxy-status; do
  out=$("$T/helper" "$a" 2>&1); check "helper forwards '$a'" '[[ $out == "forwarded: action $a" ]]' "$out"
done
for a in "rm" "status;id" "" "../x" "--help" "STATUS"; do
  out=$("$T/helper" "$a" 2>&1); rc=$?; check "helper refuses '$a'" '[[ $rc -eq 2 && $out != *forwarded* ]]' "$out"
done
out=$("$T/helper" status check 2>&1); rc=$?; check "helper refuses two arguments" '[[ $rc -eq 2 && $out != *forwarded* ]]' "$out"
printf '#!/bin/bash\necho "files: $ENV_FILE $SECRETS_FILE"\n' >"$T/fake-bot.sh"
( cd "$T" && BOT_RUN="env -i" in_bot "$U" "" "BOT_SCRIPT=$T/fake-bot.sh bot_helper" ) >"$T/helper2"; chmod 755 "$T/helper2"
out=$("$T/helper2" status 2>&1)
check "helper runs the actions with the config and secrets files the install used" '[[ $out == "files: $(realpath "$T/env") $(realpath "$T/secrets")" ]]' "$out"
check "helper does not pass the environment through (absolute paths only)" '! grep -qE "\\\$[A-Z_]+[^0-9]" <(grep -v "^#" "$T/helper" | grep -v "\\\$1\|\\\$#")' "$(cat "$T/helper")"

echo "== failing actions still report"
if [[ $EUID -ne 0 ]]; then # here ente-ops.sh check fails with "run as root": the reply must carry that, not be empty
  out=$(in_bot "$U" "" 'bot_load_env; act_check; echo "rc=$?"' 2>&1)
  check "a failing check returns its output and exit code" '[[ $out == *"run as root"* && $out == *"rc=1"* ]]' "$out"
fi
out=$(in_bot "$U" "" 'bot_load_env; bot_root_files' 2>&1)
check "the root-only check covers the scripts, the link rewriter, the env file and the secrets file" \
  '[[ $out == *"ente-tg-bot.sh"* && $out == *"ente-setup.sh"* && $out == *"ente-ops.sh"* && $out == *"ente-s3-proxy.sh"* && $out == *"ente_s3_rewrite.py"* && $out == *"$T/env"* && $out == *"$T/secrets"* ]]' "$out"

echo "== what the actions reply"
# act CODE: run CODE (act_* calls) with the server stubbed: three containers (DOWN / EXITED), systemd (BRES, BTS: the last
# backup run; CRES, CTS: the last daily check; BRC: what starting a backup returns), df, free, the journal ($T/journal), and
# fake ente-ops.sh / ente-s3-proxy.sh in $T/fake (their output in $T/fake.out, exit code in FAKE_RC)
mkdir -p "$T/fake" "$T/st" "$T/sites"
for f in ente-ops.sh ente-s3-proxy.sh; do printf '#!/bin/bash\ncat "%s"\nexit "${FAKE_RC:-0}"\n' "$T/fake.out" >"$T/fake/$f"; done
act() {
  in_bot "$U" "" '
    BOT_DIR=$T/fake BACKUP_STATE=$T/st PROXY_STATE=$T/proxy-state REBOOT_FLAG=$T/reboot CADDY_SITES=$T/sites
    bot_load_env
    dc() { [[ $1 == ps && " ${DOWN:-} " != *" $3 "* ]] && echo "cid-$3"; return 0; }
    docker() { local c=${4#cid-}; if [[ " ${EXITED:-} " == *" $c "* ]]; then echo exited; elif [[ $c == web ]]; then echo running; else echo healthy; fi; }
    systemctl() {
      case "$*" in
        "start ente-backup.service") return "${BRC:-0}" ;;
        *"ente-backup.service -p Result "*) echo "${BRES:-success}" ;;
        *"ente-backup.service -p ExecMainExitTimestamp "*) echo "${BTS-Mon 2026-11-16 03:05:00 CET}" ;;
        *"ente-backup.service -p InvocationID "*) echo abc ;;
        *"ente-backup.timer -p NextElapseUSecRealtime "*) echo "Tue 2026-11-17 03:00:00 CET" ;;
        *"ente-check.service -p ExecMainExitTimestamp "*) echo "${CTS-$(date -d "5 hours ago")}" ;;
        *"ente-check.service -p Result "*) echo "${CRES:-success}" ;;
      esac
    }
    journalctl() { cat "$T/journal"; }
    df() { printf "Filesystem Size Used Avail Use%% Mounted\n/dev/x 24G 5.7G 17G 26%% /\n"; }
    free() { printf "              total used free shared buff/cache available\nMem: 1973 564 968 33 654 1408\n"; }
    '"$1" 2>&1
}
stamps() { date -Is -d "$1 ago" >"$T/st/last-ok-s3"; date -Is -d "${2:-$1} ago" >"$T/st/last-ok-photo-config"; date -Is -d "3 days ago" >"$T/st/verify-ok"; }
out=$(act 'dur 45; dur 600; dur 7200; dur 200000' | tr '\n' '|'); check "dur: s, min, h, days" '[[ $out == "45 s|10 min|2 h|2 days|" ]]' "$out"
stamps "2 hours"; rm -f "$T/st/hc-fail" "$T/reboot"
out=$(act act_status)
check "status, all well: four lines, no warnings" '[[ $(wc -l <<<"$out") -eq 4 && $out != *"⚠️"* && $out != *"❌"* ]]' "$out"
check "... services" '[[ $(sed -n 1p <<<"$out") == "✅ Ente is up (museum, web, postgres)" ]]' "$out"
check "... backup: last good and next run" '[[ $(sed -n 2p <<<"$out") == "💾 Backup: last good 2 h ago · next Tue 03:00" ]]' "$out"
check "... check and verify" '[[ $(sed -n 3p <<<"$out") == "🩺 Check: passed 5 h ago · verify: passed 3 days ago" ]]' "$out"
check "... disk, RAM, uptime" '[[ $(sed -n 4p <<<"$out") == "🖥 Disk 26% used (17G free) · RAM 1408 MB free · up "* ]]' "$out"
touch "$T/sites/s3-proxy.caddy"; echo on >"$T/proxy-state"; touch "$T/reboot"; date >"$T/st/hc-fail"
out=$(EXITED=web DOWN=postgres BRES=exit-code CRES=exit-code act act_status)
check "status, problems: a container exited, one missing" '[[ $(sed -n 1p <<<"$out") == "❌ Down: web (exited), postgres (not running)" ]]' "$out"
check "... a failed last run and a failed heartbeat ping" '[[ $(sed -n 2p <<<"$out") == "💾 Backup: last good 2 h ago, the last run failed · next Tue 03:00 · heartbeat ping failed" ]]' "$out"
check "... a check that found problems" '[[ $(sed -n 3p <<<"$out") == "⚠️ Check: found problems 5 h ago (/check)"* ]]' "$out"
check "... a pending reboot, and the proxy" '[[ $(sed -n 4p <<<"$out") == *" · reboot pending" && $(sed -n 5p <<<"$out") == "🔀 S3 proxy: on" ]]' "$out"
rm -f "$T/sites/s3-proxy.caddy" "$T/reboot" "$T/st/hc-fail"
stamps "2 hours" "40 hours"; out=$(act act_status | sed -n 2p)
check "status: the older part of the backup counts, over 36 h is a warning" '[[ $out == "⚠️ Backup: last good 40 h ago · next Tue 03:00" ]]' "$out"
stamps "40 hours" "2 hours"; out=$(act act_status | sed -n 2p)
check "... whichever part it is" '[[ $out == "⚠️ Backup: last good 40 h ago · next Tue 03:00" ]]' "$out"
rm "$T/st/last-ok-photo-config" "$T/st/verify-ok"; out=$(BTS= CTS= act act_status)
check "status after a fresh install: no good backup yet, nothing run" \
  '[[ $(sed -n 2p <<<"$out") == "⚠️ Backup: no good backup yet · next Tue 03:00" && $(sed -n 3p <<<"$out") == "🩺 Check: not run since boot · verify: not passed yet" ]]' "$out"

printf '%s\n' "== a" "  OK    one" "  WARN  sign-ups are open" "  OK    two" "  FAIL  web exited" "  OK    three" "" "1 check(s) FAILED" >"$T/fake.out"
out=$(FAKE_RC=1 act 'act_check; echo "rc=$?"')
check "check: problems as ❌/⚠️ lines, the rest counted, exit code kept" '[[ $out == "$(printf "❌ web exited\n⚠️ sign-ups are open\n3 checks OK\nrc=1")" ]]' "$out"
printf '%s\n' "something" "run as root (sudo x)" >"$T/fake.out"
out=$(FAKE_RC=1 act 'act_check; echo "rc=$?"'); check "check that did not run: its last lines" '[[ $out == *"run as root"* && $out == *"rc=1" ]]' "$out"

printf '%s\n' "== backup bucket" "x" "ERROR: backup to the S3 bucket failed" "y" >"$T/journal"
out=$(act 'act_backup; echo "rc=$?"'); check "backup that worked: how long it took" '[[ $out == "$(printf "Took 0 s.\nrc=0")" ]]' "$out"
out=$(BRC=3 act 'act_backup; echo "rc=$?"'); check "backup that failed: its ERROR lines" '[[ $out == "$(printf "Stopped after 0 s:\nERROR: backup to the S3 bucket failed\nrc=3")" ]]' "$out"
seq -f "line %g" 1 9 >"$T/journal"; date >"$T/st/hc-fail"
out=$(BRC=1 act act_backup); check "... without ERROR lines: the last five, and a failed heartbeat" '[[ $out == "$(printf "Stopped after 0 s:\nline 5\nline 6\nline 7\nline 8\nline 9\n⚠️ The heartbeat ping failed (the backup itself is fine).")" ]]' "$out"
rm -f "$T/st/hc-fail"

out=$(act 'act_proxy status; echo "rc=$?"'); check "proxy not installed: says so" '[[ $out == "$(printf "The S3 proxy is not installed (ente-s3-proxy.sh install).\nrc=1")" ]]' "$out"
touch "$T/sites/s3-proxy.caddy"
printf '%s\n' "2026-11-16 10:00:00 [s3-proxy on] wrote /etc/caddy/x" "  OK    a" "  OK    b" "  FAIL  c broke" "" \
  "2026-11-16 10:00:01 [s3-proxy on] ERROR: S3 proxy not switched on (still off); everything is back as it was" >"$T/fake.out"
out=$(FAKE_RC=1 act 'act_proxy on; echo "rc=$?"')
check "proxy: no timestamps or file notes, problems as ❌, OK lines counted" \
  '[[ $out == "$(printf "❌ c broke\n❌ S3 proxy not switched on (still off); everything is back as it was\n2 checks OK\nrc=1")" ]]' "$out"
rm -f "$T/sites/s3-proxy.caddy"

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
  mkdir -p "$T/bin"; cp "$HERE/../ente-setup.sh" "$HERE/../ente-ops.sh" "$HERE/../ente-tg-bot.sh" "$T/bin/"; chmod 755 "$T" "$T/bin" "$T/bin"/*
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

summary
