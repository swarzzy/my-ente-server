#!/usr/bin/env bash
# Tests for the safety nets around the backup: the warning on a large photo deletion and the dumps' deletion limit, `verify` catching a
# broken backup, and the backup part of `check` (check_backup) failing on a stale, failed or missing result.
# Local "buckets", the real backup script and stubs for docker, Postgres and systemd (see buckets_lib.sh): changes nothing
# outside a temp dir. Needs bash, python3 and rclone (the server has them). Run: bash tests/test_backup_checks.sh
set -uo pipefail
# shellcheck source=buckets_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/buckets_lib.sh"

remotes 'correct horse'
backup_script
run_backup || { echo "setup: the first backup failed"; cat "$T/out"; exit 1; }
B=$T/b2/bk
P=$T/s3/photo/1580559962386439

echo "== backup: a large photo deletion warns, and the backup still runs"
# the alert stub records the title and the message; the threshold (BACKUP_DELETE_WARN) is 5 in this test
printf '#!/bin/sh\necho "TITLE $1" >>"%s"; cat >>"%s"\n' "$T/alert.log" "$T/alert.log" >"$T/bin/ente-alert"; chmod 755 "$T/bin/ente-alert"
bulk() { mkdir -p "$T/s3/photo/bulk"; for i in $(seq 1 "$1"); do echo "$i" >"$T/s3/photo/bulk/$i"; done; }
mirrored() { find "$B/objects/bulk" -type f 2>/dev/null | wc -l; }
bulk 6; run_backup; RC=$?
check "6 new photos are mirrored" '((RC == 0)) && [[ $(mirrored) -eq 6 ]]' "$(tail -3 "$T/out")"
for i in 1 2 3 4 5; do rm "$T/s3/photo/bulk/$i"; done
run_backup; RC=$?
check "5 gone (the threshold): the run succeeds without a warning" \
  '((RC == 0)) && ! grep -q WARNING "$T/out" && [[ ! -e $T/alert.log && ! -e $T/state/deletes-warn && $(mirrored) -eq 1 ]]' "$(tail -3 "$T/out")"
bulk 6; run_backup
since=$(cat "$T/state/last-ok-s3")
rm -r "$T/s3/photo/bulk"
sleep 1; run_backup; RC=$?
check "6 gone (over the threshold): the backup still runs and succeeds" '((RC == 0)) && [[ $(mirrored) -eq 0 ]]' "$(tail -3 "$T/out")"
check "... with a WARNING in its log" 'grep -q "WARNING: 6 photo files are gone from the photo bucket" "$T/out"' "$(cat "$T/out")"
check "... a Telegram warning titled with the count" 'grep -qx "TITLE ⚠️ Ente backup: 6 photo files deleted on $(hostname)" "$T/alert.log"' "$(cat "$T/alert.log")"
check "... that says how long they are kept and how to put them back as of the last backup" \
  'grep -q "old versions for 60 days" "$T/alert.log" && grep -qF "rclone copy --s3-version-at '"'"'$since'"'"' backup:bk/objects ente-s3:photo" "$T/alert.log"' \
  "$(cat "$T/alert.log")"
check "... and a stamp for check (time and count)" '[[ $(cut -d" " -f2 "$T/state/deletes-warn") == 6 ]]' "$(cat "$T/state/deletes-warn")"
check "no deleted/ folder: the history is the backup bucket's old versions" '[[ ! -e $B/deleted ]]'
rm -f "$T/bin/ente-alert" "$T/alert.log" "$T/state/deletes-warn"
bulk 6; run_backup; rm -r "$T/s3/photo/bulk"
run_backup; RC=$?
check "alerts off (no ente-alert): still warns in the log and leaves the stamp, the run succeeds" \
  '((RC == 0)) && grep -q "WARNING: 6 photo files" "$T/out" && [[ -s $T/state/deletes-warn && ! -e $T/alert.log ]]' "$(tail -3 "$T/out")"
rm -f "$T/state/deletes-warn"

for i in $(seq -w 1 21); do echo old >"$T/dumps/ente_db-2000-01-$i.dump"; done
run_backup; RC=$?
check "21 more dumps are uploaded" '((RC == 0)) && [[ $(rclone lsf backup-crypt: --include "ente_db-2000-*" | wc -l) -eq 21 ]]' "$(tail -3 "$T/out")"
mkdir -p "$T/dumps.saved"; mv "$T/dumps"/ente_db-2000-01-*.dump "$T/dumps.saved/"
run_backup; RC=$?
check "all 21 gone locally: the run fails (more than 20 dump deletions)" '((RC != 0)) && grep -q "would delete 21 files" "$T/out"' "$(tail -3 "$T/out")"
check "... and the backup bucket still has all 21" '[[ $(rclone lsf backup-crypt: --include "ente_db-2000-*" | wc -l) -eq 21 ]]'
check "... and so does the copy in the photo bucket" '[[ $(rclone lsf photo-crypt: --include "ente_db-2000-*" | wc -l) -eq 21 ]]'
mv "$T/dumps.saved"/* "$T/dumps/"

echo "== verify catches a broken backup"
# verify_run: cmd_verify with Postgres stubbed: the dump "restores" unless it contains CORRUPT, and the scratch database then
# has no users or files if it contains EMPTY (live: 3 users, 10 files).
verify_run() {
  in_setup '
    systemctl() { [[ $* != *ActiveState* ]] || echo inactive; }
    mktemp() { if [[ ${1:-} == -d ]]; then command mktemp -d "$T/verify.XXXXXX"; else command mktemp; fi; }
    dc() {
      case "$*" in
        "cp "*) cp "$2" "$T/pg.dump" ;;
        *pg_restore*) ! grep -q CORRUPT "$T/pg.dump" ;;
      esac
    }
    vq() {
      case "$*" in
        *"-d ente_db "*) echo "86 3 10" ;;
        *"-d ente_verify "*) if grep -q EMPTY "$T/pg.dump"; then echo "86 0 0"; else echo "86 3 10"; fi ;;
      esac
    }
    cmd_verify' >"$T/out" 2>&1
}
fails() { grep -c '^  FAIL' "$T/out"; }
verify_run; RC=$?
check "a good backup: verify passes" '((RC == 0)) && grep -q "^backup verified" "$T/out"' "$(cat "$T/out")"
check "... and records it for check" '[[ -s $T/state/verify-ok ]]'
vok=$(cat "$T/state/verify-ok")
sleep 1
FAKE_DUMP=CORRUPT run_backup; verify_run; RC=$?
check "a dump that does not restore: FAIL" '((RC != 0)) && [[ $(fails) -eq 1 ]] && grep -q "does not restore" "$T/out"' "$(grep FAIL "$T/out")"
check "... and the 'verify passed' stamp is not renewed" '[[ $(cat "$T/state/verify-ok") == "$vok" ]]'
FAKE_DUMP=EMPTY run_backup; verify_run; RC=$?
check "a dump that restores empty tables: FAIL" '((RC != 0)) && [[ $(fails) -eq 1 ]] && grep -q "looks incomplete" "$T/out"' "$(grep FAIL "$T/out")"
run_backup
echo photo-X >"$B/objects/1580559962386439/aaa" # same size as photo-a: only a checksum sees it
verify_run; RC=$?
check "a photo damaged in the backup (same size): FAIL" '((RC != 0)) && [[ $(fails) -eq 1 ]] && grep -q "photo objects differ" "$T/out"' "$(grep FAIL "$T/out")"
echo photo-a >"$B/objects/1580559962386439/aaa"
sed -i 's/KEY-ONE/KEY-TWO/' "$T/ente/museum.yaml"
verify_run; RC=$?
check "backed-up keys differ from the live ones: FAIL" '((RC != 0)) && [[ $(fails) -eq 1 ]] && grep -q "keys differ" "$T/out"' "$(grep FAIL "$T/out")"
sed -i 's/KEY-TWO/KEY-ONE/' "$T/ente/museum.yaml"
rclone deletefile backup-crypt:compose.yaml
verify_run; RC=$?
check "a file missing from the config backup: FAIL" '((RC != 0)) && [[ $(fails) -eq 1 ]] && grep -q "config backup differs" "$T/out"' "$(grep FAIL "$T/out")"
run_backup
rclone deletefile photo-crypt:museum.yaml
verify_run; RC=$?
check "a file missing from the copy in the photo bucket: FAIL" '((RC != 0)) && [[ $(fails) -eq 1 ]] && grep -q "copy in the photo bucket differs" "$T/out"' "$(grep FAIL "$T/out")"
run_backup; verify_run; RC=$?
check "repaired by the next backup: verify passes again" '((RC == 0))' "$(grep FAIL "$T/out")"

echo "== check: the backup part"
# cb_run: check_backup with systemd stubbed: TS (last run's end; empty = no run since boot), RES (its result),
# NO_BACKUP_TIMER / NO_VERIFY_TIMER (timer not enabled). HC_URL is set, Telegram alerts are off.
cb_run() {
  in_setup '
    HC_URL=https://hc.example.org/ping TG_CHAT_ID=
    backup_versions() { echo "${VERS:-Enabled 60}"; }
    systemctl() {
      case "$*" in
        "is-enabled --quiet ente-backup.timer") [[ -z ${NO_BACKUP_TIMER:-} ]] ;;
        "is-enabled --quiet ente-verify.timer") [[ -z ${NO_VERIFY_TIMER:-} ]] ;;
        *NextElapseUSecRealtime*) echo tomorrow ;;
        *ExecMainExitTimestamp*) echo "${TS-}" ;;
        *"-p Result "*) echo "${RES:-success}" ;;
        *ActiveState*) echo inactive ;;
      esac
    }
    check_backup' >"$T/out" 2>&1
}
fresh() { local f; for f in last-ok-s3 last-ok-photo-config verify-ok hc-ok; do date -Is >"$T/state/$f"; done; rm -f "$T/state/hc-fail" "$T/state/deletes-warn"; }
ago() { date -Is -d "$1 ago"; }
one_fail() { [[ $(fails) -eq 1 ]] && grep -q "^  FAIL.*$1" "$T/out"; }
now=$(date -Is)
fresh; TS=$now cb_run
check "all fresh: no FAIL" '[[ $(fails) -eq 0 ]]' "$(cat "$T/out")"
TS=$now RES=exit-code cb_run
check "the last run failed: FAIL" 'one_fail "last backup run"' "$(grep FAIL "$T/out")"
TS=$(ago '40 hours') cb_run
check "the last run is 40 h old: FAIL" 'one_fail "older than 36 h"' "$(grep FAIL "$T/out")"
TS= cb_run
check "no run since boot, last good backup fresh: no FAIL" '[[ $(fails) -eq 0 ]] && grep -q "no run since boot" "$T/out"' "$(cat "$T/out")"
ago '40 hours' >"$T/state/last-ok-s3"; TS= cb_run
check "no run since boot, last good backup 40 h old: FAIL" 'one_fail "last good backup is older than 36 h"' "$(grep FAIL "$T/out")"
fresh; rm "$T/state/last-ok-photo-config"; TS=$now cb_run
check "no config copy in the photo bucket: FAIL" 'one_fail "no config copy in the photo bucket"' "$(grep FAIL "$T/out")"
fresh; ago '40 hours' >"$T/state/last-ok-photo-config"; TS=$now cb_run
check "the config copy is 40 h old: FAIL" 'one_fail "config copy in the photo bucket is older"' "$(grep FAIL "$T/out")"
fresh; ago '50 days' >"$T/state/verify-ok"; TS=$now cb_run
check "the last good verify is 50 days old: FAIL" 'one_fail "verify is older than 45 days"' "$(grep FAIL "$T/out")"
fresh; rm "$T/state/verify-ok"; TS=$now cb_run
check "verify has never passed: only a WARN" '[[ $(fails) -eq 0 ]] && grep -q "WARN  monthly verify has not passed" "$T/out"' "$(cat "$T/out")"
fresh; TS=$now NO_VERIFY_TIMER=1 cb_run
check "the verify timer is off: FAIL" 'one_fail "ente-verify.timer not enabled"' "$(grep FAIL "$T/out")"
TS=$now NO_BACKUP_TIMER=1 cb_run
check "the backup timer is off: FAIL" 'one_fail "ente-backup.timer not enabled"' "$(grep FAIL "$T/out")"
date -Is >"$T/state/hc-fail"; TS=$now cb_run
check "the heartbeat ping failed: FAIL" 'one_fail "heartbeat ping"' "$(grep FAIL "$T/out")"
fresh; rm "$B/objects/1580559962386439/aaa"; TS=$now cb_run
check "a photo missing from the backup: FAIL" 'one_fail "rclone check failed"' "$(grep FAIL "$T/out")"
run_backup; fresh
VERS="Suspended none" TS=$now cb_run
check "the backup bucket does not keep old versions: FAIL" 'one_fail "does not keep old versions"' "$(grep FAIL "$T/out")"
VERS="Enabled 30" TS=$now cb_run
check "old versions kept for other than the configured days: only a WARN" \
  '[[ $(fails) -eq 0 ]] && grep -q "WARN  the backup bucket keeps old versions for 30 days, not 60" "$T/out"' "$(cat "$T/out")"
VERS=" " TS=$now cb_run
check "the setting cannot be read: FAIL" 'one_fail "cannot read it"' "$(grep FAIL "$T/out")"
echo "$now 812" >"$T/state/deletes-warn"; TS=$now cb_run
check "a large deletion in the last 7 days: a WARN, no FAIL" \
  '[[ $(fails) -eq 0 ]] && grep -q "WARN  812 photo files were deleted" "$T/out"' "$(cat "$T/out")"
echo "$(ago '8 days') 812" >"$T/state/deletes-warn"; TS=$now cb_run
check "... older than 7 days: no longer mentioned" '[[ $(fails) -eq 0 ]] && ! grep -q "photo files were deleted" "$T/out"' "$(cat "$T/out")"
fresh
touch "$T/ente/.restore-finishing"; TS=$now cb_run
check "an unfinished restore: FAIL" 'one_fail "a restore did not finish"' "$(grep FAIL "$T/out")"
rm "$T/ente/.restore-finishing"

summary
