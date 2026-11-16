#!/usr/bin/env bash
# Tests for the safety nets around the backup: the backup's deletion limits and 60-day purge of deleted/, `verify` catching a
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

echo "== backup: deletion limits"
mkdir -p "$T/s3/photo/bulk"; for i in $(seq 1 501); do echo "$i" >"$T/s3/photo/bulk/$i"; done
run_backup; RC=$?
check "501 new photos are mirrored" '((RC == 0)) && [[ $(find "$B/objects/bulk" -type f | wc -l) -eq 501 ]]' "$(tail -3 "$T/out")"
stamp=$(cat "$T/state/last-ok-s3")
mv "$T/s3/photo/bulk" "$T/bulk.saved"
sleep 1; run_backup; RC=$?
check "all 501 gone from the photo bucket: the run fails (more than 500 deletions)" '((RC != 0)) && grep -q "would delete 501 files" "$T/out"' "$(tail -3 "$T/out")"
check "... and every one of them is still in the backup's objects/" '[[ $(find "$B/objects/bulk" -type f | wc -l) -eq 501 ]]' \
  "$(find "$B/objects/bulk" -type f | wc -l) left"
check "... and the failed run leaves no new 'last good backup' stamp" '[[ $(cat "$T/state/last-ok-s3") == "$stamp" ]]'
mv "$T/bulk.saved" "$T/s3/photo/bulk"
run_backup; RC=$?
check "the photos are back: the next run succeeds" '((RC == 0))' "$(tail -3 "$T/out")"
mkdir -p "$T/bulk500"; for i in $(seq 1 500); do mv "$T/s3/photo/bulk/$i" "$T/bulk500/"; done
run_backup; RC=$?
check "exactly 500 gone: the run succeeds" '((RC == 0))' "$(tail -3 "$T/out")"
check "... and moves them to deleted/<today>/, not away" \
  '[[ $(find "$B/deleted/$(date +%F)/bulk" -type f | wc -l) -eq 500 && $(find "$B/objects/bulk" -type f | wc -l) -eq 1 ]]'
mv "$T/bulk500"/* "$T/s3/photo/bulk/"; run_backup

for i in $(seq -w 1 21); do echo old >"$T/dumps/ente_db-2000-01-$i.dump"; done
run_backup; RC=$?
check "21 more dumps are uploaded" '((RC == 0)) && [[ $(rclone lsf backup-crypt: --include "ente_db-2000-*" | wc -l) -eq 21 ]]' "$(tail -3 "$T/out")"
mkdir -p "$T/dumps.saved"; mv "$T/dumps"/ente_db-2000-01-*.dump "$T/dumps.saved/"
run_backup; RC=$?
check "all 21 gone locally: the run fails (more than 20 dump deletions)" '((RC != 0)) && grep -q "would delete 21 files" "$T/out"' "$(tail -3 "$T/out")"
check "... and the backup bucket still has all 21" '[[ $(rclone lsf backup-crypt: --include "ente_db-2000-*" | wc -l) -eq 21 ]]'
check "... and so does the copy in the photo bucket" '[[ $(rclone lsf photo-crypt: --include "ente_db-2000-*" | wc -l) -eq 21 ]]'
mv "$T/dumps.saved"/* "$T/dumps/"

echo "== backup: deleted/ keeps 60 days"
old=$(date -d '61 days ago' +%F) recent=$(date -d '59 days ago' +%F)
mkdir -p "$B/deleted/$old/x" "$B/deleted/$recent/x" "$B/deleted/not-a-date/x"
for d in "$old" "$recent" not-a-date; do echo f >"$B/deleted/$d/x/f"; done
run_backup; RC=$?
check "a run succeeds" '((RC == 0))' "$(tail -3 "$T/out")"
check "deleted/ older than 60 days is purged" '[[ ! -e $B/deleted/$old ]]'
check "deleted/ from 59 days ago is kept" '[[ -f $B/deleted/$recent/x/f ]]'
check "a folder that is not a date is never purged" '[[ -f $B/deleted/not-a-date/x/f ]]'

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
fresh() { local f; for f in last-ok-s3 last-ok-photo-config verify-ok hc-ok; do date -Is >"$T/state/$f"; done; rm -f "$T/state/hc-fail"; }
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
touch "$T/ente/.restore-finishing"; TS=$now cb_run
check "an unfinished restore: FAIL" 'one_fail "a restore did not finish"' "$(grep FAIL "$T/out")"
rm "$T/ente/.restore-finishing"

summary
