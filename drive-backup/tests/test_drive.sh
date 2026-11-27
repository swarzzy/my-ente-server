#!/usr/bin/env bash
# Tests for drive-backup.sh with real rclone on local folders standing in for the buckets (rclone "alias" remotes): config
# checks, the first sync, the guard (changes and deletions over the limit stop it, new files do not), forcing past it, the
# /status line, check, verify, the lock, the rclone.conf it writes, the units and the plugin file (checked by opsbot's own
# validator). Restoring an older version needs B2: tests/drive_e2e.sh. Changes nothing outside a temp dir.
# Needs bash, python3 and rclone. Run: bash tests/test_drive.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v rclone >/dev/null || { echo "rclone is not installed"; exit 1; }
OPSBOT_PY=$HERE/../../opsbot/opsbot.py
mkdir -p "$T/src/vault/d" "$T/dst/bak" "$T/st" "$T/units" "$T/etc"
printf '[drive]\ntype = alias\nremote = %s/src\n\n[drivebak]\ntype = alias\nremote = %s/dst\n' "$T" "$T" >"$T/rclone.conf"
cat >"$T/env" <<'X'
DRIVE_S3_ENDPOINT=s3.example.net
DRIVE_S3_BUCKET=vault
DRIVE_B2_BUCKET=bak
DRIVE_B2_PREFIX=drive
X
# in_db CODE: source drive-backup.sh with every path in $T, run CODE
in_db() {
  ( ENV_FILE=$T/env SECRETS_FILE=$T/secrets RCLONE_CONF=$T/rclone.conf STATE=$T/st UNITS=$T/units ETC=$T/etc LOG=$T/log CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../drive-backup.sh"
    set +e
    eval "$1" ) 2>&1
}
files() { find "$1" -type f | wc -l; }
for i in $(seq 1 20); do head -c $((100 + i)) /dev/urandom >"$T/src/vault/d/f$i.c9r"; done

echo "== config"
out=$(in_db 'ENV_FILE=$T/none; load_config; echo LOADED'); check "no config file: says which" '[[ $out == *"no config: copy drive-backup.env.example"* && $out != *LOADED* ]]' "$out"
for bad in "DRIVE_S3_BUCKET=\$'a\\tb'" "DRIVE_B2_PREFIX=../x" "DRIVE_S3_ENDPOINT='x;id'" "DRIVE_MAX_CHANGE=0" "DRIVE_MAX_CHANGE=101" "DRIVE_HC_URL=http://x"; do
  cp "$T/env" "$T/env.bak"; echo "$bad" >>"$T/env"
  out=$(in_db 'load_config; echo LOADED'); check "refuses $bad" '[[ $out != *LOADED* && $out == *"${bad%%=*}"* ]]' "$out"
  mv "$T/env.bak" "$T/env"
done
out=$(in_db 'load_config; echo "$SRC $DST $DRIVE_MAX_CHANGE"'); check "the drive and the backup paths, 10% by default" '[[ $out == "drive:vault drivebak:bak/drive 10" ]]' "$out"

echo "== sync and the guard"
out=$(in_db 'cmd_run; echo "rc=$?"')
check "first run (an empty backup): everything copied" '[[ $out == *"syncing: 20 new"* && $out == *"rc=0" && $(files "$T/dst/bak/drive") == 20 ]]' "$out"
check "... and recorded: time, files, bytes" '[[ $(cut -d" " -f2 "$T/st/last-ok") == 20 && $(cut -d" " -f3 "$T/st/last-ok") == $(du -cb "$T"/src/vault/d/* | tail -1 | cut -f1) ]]' "$(cat "$T/st/last-ok")"
out=$(in_db act_status); check "/status: when, how many files, how big" '[[ $out == "🗂 Drive: last sync "*" ago · 20 files, "*B ]]' "$out"
head -c 500 /dev/urandom >"$T/src/vault/d/f1.c9r"; rm "$T/src/vault/d/f2.c9r"
out=$(in_db 'cmd_run; echo "rc=$?"')
check "2 of 20 changed or gone (10%): synced" '[[ $out == *"2 changed or gone"* && $out == *"rc=0" && $(files "$T/dst/bak/drive") == 19 ]]' "$out"
for i in $(seq 21 80); do head -c 50 /dev/urandom >"$T/src/vault/d/n$i.c9r"; done
out=$(in_db 'cmd_run; echo "rc=$?"'); check "60 new files: no guard (new files destroy nothing)" '[[ $out == *"rc=0" && $(files "$T/dst/bak/drive") == 79 ]]' "$out"
sleep 1; for i in $(seq 21 30); do head -c 50 /dev/urandom >"$T/src/vault/d/n$i.c9r"; done # rewritten, same size
out=$(in_db 'cmd_run; echo "rc=$?"')
check "10 of 79 rewritten at the same size: the guard counts them as the sync would (a dry run, not sizes)" '[[ $out == *"guard: 10 of 79"* && $out != *"rc=0" ]]' "$out"
in_db 'cmd_run force' >/dev/null
cp -r "$T/dst" "$T/dst.before"
for f in "$T"/src/vault/d/n*.c9r; do head -c 70 /dev/urandom >"$f"; done # "ransomware": most files rewritten
out=$(in_db 'cmd_run; echo "rc=$?"')
check "most files rewritten: the guard stops it, nothing synced" \
  '[[ $out == *"guard: 60 of 79 files in the backup would change or go (75%, more than the 7 allowed), nothing synced"* && $out != *"rc=0" ]] && diff -r "$T/dst" "$T/dst.before" >/dev/null' "$out"
check "... the guard is recorded" '[[ $(cat "$T/st/guard") == "60 79" ]]' "$(cat "$T/st/guard")"
out=$(in_db act_status); check "... /status says so and what to do" '[[ $out == "⚠️ Drive: the guard stopped the sync: 60 of 79 files would change (/drive_force once the drive looks right)" ]]' "$out"
out=$(in_db cmd_check); check "... check fails on it" '[[ $out == *"FAIL  the guard stopped the last sync: 60 of 79 files would change"* ]]' "$out"
out=$(in_db 'cmd_run; echo "rc=$?"'); check "... and the next nightly run stops again" '[[ $out == *"guard:"* && $out != *"rc=0" ]]' "$out"
out=$(in_db 'bot_action force; echo "rc=$?"')
check "/drive_force: synced past the guard, the guard cleared" '[[ $out == *"syncing:"*"(forced)"* && $out == *"rc=0" && ! -e $T/st/guard ]] && diff -r "$T/src/vault" "$T/dst/bak/drive" >/dev/null' "$out"
check "... its reply without timestamps, and it is in the log" '[[ $out != *"[test]"* ]] && grep -q "(forced)" "$T/log"' "$out"
out=$(in_db 'bot_action force; echo "rc=$?"'); check "/drive_force without a stopped sync: nothing to force" '[[ $out == "❌ nothing to force"*"rc=1" ]]' "$out"
rm "$T"/src/vault/d/n2*.c9r "$T"/src/vault/d/n3*.c9r
out=$(in_db 'cmd_run; echo "rc=$?"'); check "19 of 79 deleted (24%): the guard stops it too" '[[ $out == *"guard: 19 of 79"* && $(files "$T/dst/bak/drive") == 79 ]]' "$out"
for i in $(seq 41 50); do rm "$T/src/vault/d/n$i.c9r"; done # 10 more gone since the guard saw 19
out=$(in_db 'cmd_run force; echo "rc=$?"')
check "forcing accepts what the guard saw, not more: 29 now, 19 seen" '[[ $out == *"guard: 29 of 79"*"more than the 21 allowed"* && $out != *"rc=0" && $(files "$T/dst/bak/drive") == 79 ]]' "$out"
out=$(in_db 'cmd_run force; echo "rc=$?"'); check "... forcing again, after a new look: synced" '[[ $out == *"rc=0" && $(files "$T/dst/bak/drive") == 50 ]]' "$out"
echo "DRIVE_MAX_CHANGE=50" >>"$T/env"; for f in "$T"/src/vault/d/n5*.c9r; do head -c 90 /dev/urandom >"$f"; done
out=$(in_db 'cmd_run; echo "rc=$?"'); check "DRIVE_MAX_CHANGE raises the limit" '[[ $out == *"rc=0" ]]' "$out"
sed -i '/DRIVE_MAX_CHANGE/d' "$T/env"
out=$(in_db 'exec 9>"$T/st/lock"; flock -n 9; (cmd_run); echo "rc=$?"'); check "a second run while one runs (or a verify): refused" '[[ $out == *"a sync or verify is already running"* && $out != *"rc=0" ]]' "$out"
echo "DRIVE_B2_BUCKET=bakk" >>"$T/env"; out=$(in_db 'cmd_run; echo "rc=$?"'); sed -i '/^DRIVE_B2_BUCKET=bakk$/d' "$T/env"
check "a backup bucket that does not exist (a typo): an error, not a first run" '[[ $out == *"cannot read the bucket drivebak:bakk (name, key?)"* && $out != *"rc=0" && ! -e $T/dst/bakk ]]' "$out"
mv "$T/src" "$T/src.away"; out=$(in_db 'cmd_run; echo "rc=$?"'); mv "$T/src.away" "$T/src"
check "the drive cannot be read: an error, nothing synced" '[[ $out == *"cannot read the bucket drive:vault"* && $out != *"rc=0" && $(files "$T/dst/bak/drive") == 50 ]]' "$out"

echo "== status and check"
out=$(in_db 'cmd_check; echo "rc=$?"'); check "check: a recent good sync is OK (the timers are not on here)" '[[ $out == *"OK    last good sync"* && $out == *"FAIL  a timer is off"* ]]' "$out"
echo "$(date -Is -d '40 hours ago') 50 1000" >"$T/st/last-ok"
out=$(in_db act_status); check "/status: a sync over 36 h old is a warning" '[[ $out == "⚠️ Drive: last sync 40 h ago"* ]]' "$out"
out=$(in_db cmd_check); check "... and a FAIL in check" '[[ $out == *"FAIL  last good sync is older than 36 h"* ]]' "$out"
rm "$T/st/last-ok"; out=$(in_db act_status); check "no sync yet: says so" '[[ $out == "⚠️ Drive: no sync yet" ]]' "$out"

echo "== verify"
out=$(in_db 'cmd_verify; echo "rc=$?"'); check "verify: every file there, a sample of those byte for byte" '[[ $out == *"verify passed: every file of the drive is in the backup, 5 sampled"* && $out == *"rc=0" ]]' "$out"
f=$(find "$T/dst/bak/drive" -type f | head -1); head -c 7 /dev/urandom >>"$f"
out=$(in_db 'cmd_verify; echo "rc=$?"'); check "a file in the backup that differs: verify fails" '[[ $out == *"the backup differs from the drive"* && $out != *"rc=0" ]]' "$out"

echo "== keys, units, plugin"
printf 'DRIVE_S3_ACCESS_KEY=AKID1\nDRIVE_S3_SECRET_KEY=sec/ret+1=\nDRIVE_B2_KEY_ID=0051\nDRIVE_B2_KEY=K005abc\n' >"$T/secrets"
out=$(in_db 'load_config; RCLONE_CONF=$T/etc/rclone.conf; write_remotes; echo rc=$?')
check "the keys go into rclone.conf (600): the drive over S3, the backup over B2's own API" \
  '[[ $(stat -c %a "$T/etc/rclone.conf") == 600 ]] && grep -qx "type = b2" "$T/etc/rclone.conf" && grep -qx "account = 0051" "$T/etc/rclone.conf" && grep -qx "endpoint = s3.example.net" "$T/etc/rclone.conf"' "$(cat "$T/etc/rclone.conf")"
rm "$T/secrets"; out=$(in_db 'load_config; RCLONE_CONF=$T/etc/rclone.conf; write_remotes; echo rc=$?')
check "without the secrets file (deleted after install): the keys stay" '[[ $out == *"kept from"* && -s $T/etc/rclone.conf ]]' "$out"
printf 'DRIVE_S3_ACCESS_KEY="a b"\nDRIVE_S3_SECRET_KEY=x\nDRIVE_B2_KEY_ID=x\nDRIVE_B2_KEY=x\n' >"$T/secrets"
out=$(in_db 'load_config; RCLONE_CONF=$T/etc/new.conf; write_remotes; echo rc=$?'); check "a key that is not one is refused" '[[ $out == *"DRIVE_S3_ACCESS_KEY does not look like a key"* && ! -e $T/etc/new.conf ]]' "$out"
rm "$T/secrets"
in_db 'load_config; unit drive-backup "Nightly drive backup" run "*-*-* 04:00:00"; unit drive-verify "Monthly drive backup verify" verify "*-*-01 05:00:00"' >/dev/null
check "the backup unit runs nightly at 04:00 with these config files, alerting through opsbot when it fails" \
  'grep -qx "OnFailure=opsbot-alert@%n.service" "$T/units/drive-backup.service" && grep -qx "Environment=ENV_FILE=$(realpath "$T/env") SECRETS_FILE=$(realpath "$T")/secrets" "$T/units/drive-backup.service" && grep -qx "OnCalendar=\*-\*-\* 04:00:00" "$T/units/drive-backup.timer"' "$(cat "$T/units/drive-backup.service")"
check "verify: monthly, alerting too" 'grep -qx "OnCalendar=\*-\*-01 05:00:00" "$T/units/drive-verify.timer" && grep -q "drive-backup.sh verify$" "$T/units/drive-verify.service"'
mkdir -p "$T/pj"; in_db 'load_config >/dev/null; plugin_json' >"$T/pj/drive.json"
out=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import opsbot; p = opsbot.read_plugin(sys.argv[2]); print(p["name"], " ".join(c["command"] for c in p["commands"]), " ".join(sorted(p["actions"])), len(p["root_files"]))' \
  "$(dirname "$OPSBOT_PY")" "$T/pj/drive.json" 2>&1)
check "the plugin: opsbot accepts it; /drive_sync, /drive_force, a /status line; its config and keys are root_files" '[[ $out == "drive drive_sync drive_force force status sync 3" ]]' "$out"
out=$(in_db 'bot_action rm; echo rc=$?'); check "an action it does not know is a usage error" '[[ $out == *usage* && $out != *"rc=0"* ]]' "$out"

echo "== command line"
CLI=$HERE/../drive-backup.sh
asuser() { "$@"; }
if [[ $EUID -eq 0 ]]; then cp "$CLI" "$T/cli.sh"; chmod 755 "$T" "$T/cli.sh"; CLI=$T/cli.sh; asuser() { setpriv --reuid=65534 --regid=65534 --clear-groups "$@"; }; fi
for c in "" maybe "run now" "restore" "restore 2026-11-20 d/AB" "install x"; do
  # shellcheck disable=SC2086
  out=$(asuser bash "$CLI" $c 2>&1); rc=$?; check "'$c' is a usage error" '[[ $rc -eq 2 && $out == *usage* ]]' "$out"
done
for c in install uninstall check run "run --force" verify "restore 2026-11-20" "action status"; do
  # shellcheck disable=SC2086
  out=$(asuser bash "$CLI" $c 2>&1); check "'$c' is a known command (asks for root here)" '[[ $out == *"run as root"* ]]' "$out"
done

summary
