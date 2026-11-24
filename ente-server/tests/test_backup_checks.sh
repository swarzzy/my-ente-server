#!/usr/bin/env bash
# Tests for the backup and its safety nets: it never deletes in the backup bucket, `verify` catches a
# broken backup and reports the backup bucket's growth, and the backup part of `check` (check_backup) failing on a stale or
# missing result.
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

echo "== backup: never deletes in the backup bucket"
mkdir -p "$T/s3/photo/bulk"; for i in $(seq 1 30); do echo "$i" >"$T/s3/photo/bulk/$i"; done
run_backup; RC=$?
check "30 new photos are copied" '((RC == 0)) && [[ $(find "$B/objects/bulk" -type f | wc -l) -eq 30 ]]' "$(tail -3 "$T/out")"
rm -r "$T/s3/photo/bulk"
run_backup; RC=$?
check "all 30 gone from the photo bucket: the run succeeds and the backup still has them" \
  '((RC == 0)) && [[ $(find "$B/objects/bulk" -type f | wc -l) -eq 30 ]]' "$(tail -3 "$T/out")"
for i in $(seq -w 1 25); do echo old >"$T/dumps/ente_db-2000-01-$i.dump"; done
run_backup
rm "$T/dumps"/ente_db-2000-01-*.dump
run_backup; RC=$?
check "25 old dumps gone locally: the run succeeds and the backup bucket keeps all 25" \
  '((RC == 0)) && [[ $(rclone lsf backup-crypt: --include "ente_db-2000-*" | wc -l) -eq 25 ]]' "$(tail -3 "$T/out")"
check "... while the copy in the photo bucket follows the server (only its dumps)" \
  '[[ $(rclone lsf photo-crypt: --include "ente_db-2000-*" | wc -l) -eq 0 && -n $(rclone lsf photo-crypt: --include "ente_db-*") ]]' "$(rclone lsf photo-crypt:)"

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
        *"-d ente_db "*) echo "${LIVE_TABLES:-86} 3 10" ;;
        *"-d ente_verify "*) if grep -q EMPTY "$T/pg.dump"; then echo "86 0 0"; else echo "86 3 10"; fi ;;
      esac
    }
    cmd_verify' >"$T/out" 2>&1
}
fails() { grep -c '^  FAIL' "$T/out"; }
echo "PGDMP older" >"$T/dumps/ente_db-2000-02-01.dump"; run_backup # an older dump on the server too: verify must take the newest
verify_run; RC=$?
check "a good backup (the backup bucket also holds old dumps the server no longer has): verify passes" \
  '((RC == 0)) && grep -q "^backup verified" "$T/out"' "$(cat "$T/out")"
check "... and records it for check" '[[ -s $T/state/verify-ok ]]'
# du_of DIR [FIND ARGS]: "BYTES COUNT" of the files under DIR, what rclone size reports for a local "bucket"
du_of() { find "$1" -type f "${@:2}" -printf '%s\n' | awk '{b += $1; n++} END {print b + 0, n + 0}'; }
want_p=$(du_of "$T/s3/photo" -not -path "*/ente-backup-config/*"); want_b=$(du_of "$B")
check "... and measures both buckets: photos without the config copy, the whole backup bucket" \
  '[[ $(sed -n 2p "$T/state/usage") == "photo $want_p" && $(sed -n 3p "$T/state/usage") == "backup $want_b" && $(sed -n 1p "$T/state/usage") == "date "* ]] &&
   grep -q "^  INFO  bucket usage saved: photos .* files; backup .* files" "$T/out"' \
  "want photo $want_p, backup $want_b; got: $(cat "$T/state/usage" 2>&1)"
rm "$T/state/usage"; echo big >"$P/new-one"
in_setup 'cmd_size' >"$T/out" 2>&1; RC=$?
want_p=$(du_of "$T/s3/photo" -not -path "*/ente-backup-config/*")
check "size measures now and saves it (a new photo counted at once)" \
  '((RC == 0)) && [[ $(sed -n 2p "$T/state/usage") == "photo $want_p" ]] && grep -q "^photo bucket photo: .* files$" "$T/out" && grep -q "^backup bucket .*: .* files$" "$T/out"' \
  "$(cat "$T/out" "$T/state/usage" 2>&1)"
cp "$T/state/usage" "$T/usage.before"
in_setup 'PHOTO_BUCKET=does-not-exist; measure_buckets' >"$T/out" 2>&1; RC=$?
check "a bucket that cannot be listed: it fails and the last measurement stays" '((RC != 0)) && cmp -s "$T/state/usage" "$T/usage.before"' "$(cat "$T/out")"
rm "$P/new-one"
check "... with the backup bucket's growth: 32 photos, the 30 gone from the photo bucket, 27 dumps" \
  'grep -q "INFO  backup bucket: 32 photos (.*), 30 of them (.*) no longer in the photo bucket; 27 dumps" "$T/out"' "$(grep INFO "$T/out")"
check "... and the newest local dump restored" 'grep -q "OK    ente_db-$(date +%F).dump restores: 86 tables, 3 users, 10 files" "$T/out"' "$(cat "$T/out")"
LIVE_TABLES=87 verify_run; RC=$?
check "an update added a table since the dump: no false FAIL" '((RC == 0))' "$(grep FAIL "$T/out")"
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
# cb_run: check_backup with systemd stubbed: RUNNING (a backup is running now), NO_VERIFY_TIMER (timer not enabled);
# Telegram alerts on unless NO_ALERTS.
cb_run() {
  in_setup '
    TG_CHAT_ID=${NO_ALERTS--100123} HC_URL=
    systemctl() {
      case "$*" in
        "is-enabled --quiet ente-verify.timer") [[ -z ${NO_VERIFY_TIMER:-} ]] ;;
        "is-enabled --quiet ente-rclone-update.timer") [[ -z ${NO_RCLONE_TIMER:-} ]] ;;
        "is-enabled --quiet ente-news.timer") [[ -z ${NO_NEWS_TIMER:-} ]] ;;
        *ActiveState*) if [[ -n ${RUNNING:-} ]]; then echo activating; else echo inactive; fi ;;
      esac
    }
    check_backup' >"$T/out" 2>&1
}
fresh() { local f; for f in last-ok-s3 last-ok-photo-config verify-ok; do date -Is >"$T/state/$f"; done; }
ago() { date -Is -d "$1 ago"; }
one_fail() { [[ $(fails) -eq 1 ]] && grep -q "^  FAIL.*$1" "$T/out"; }
fresh; cb_run
check "all fresh: no FAIL, no WARN" '[[ $(fails) -eq 0 ]] && ! grep -q WARN "$T/out"' "$(cat "$T/out")"
ago '35 hours' >"$T/state/last-ok-s3"; cb_run
check "the last good backup is 35 h old: no FAIL" '[[ $(fails) -eq 0 ]]' "$(cat "$T/out")"
ago '40 hours' >"$T/state/last-ok-s3"; cb_run
check "the last good backup is 40 h old: FAIL" 'one_fail "last good backup is older than 36 h"' "$(grep FAIL "$T/out")"
RUNNING=1 cb_run
check "... still a FAIL while a backup runs" 'one_fail "last good backup is older than 36 h" && grep -q "a backup is running now" "$T/out"' "$(cat "$T/out")"
rm "$T/state/last-ok-s3" "$T/state/last-ok-photo-config"; cb_run
check "never a good backup: FAIL for it and for the config copy" \
  '[[ $(fails) -eq 2 ]] && grep -q "FAIL  last good backup: none yet" "$T/out" && grep -q "FAIL  config copy in the photo bucket: none yet" "$T/out"' "$(cat "$T/out")"
RUNNING=1 cb_run
check "... but while the first backup runs: only WARNs" '[[ $(fails) -eq 0 && $(grep -c "WARN.*the first backup is running" "$T/out") -eq 2 ]]' "$(cat "$T/out")"
fresh; ago '40 hours' >"$T/state/last-ok-photo-config"; cb_run
check "the config copy is 40 h old: FAIL" 'one_fail "config copy in the photo bucket is older than 36 h"' "$(grep FAIL "$T/out")"
fresh; ago '50 days' >"$T/state/verify-ok"; cb_run
check "the last good verify is 50 days old: FAIL" 'one_fail "verify is older than 45 days"' "$(grep FAIL "$T/out")"
fresh; rm "$T/state/verify-ok"; cb_run
check "verify has never passed: only a WARN" '[[ $(fails) -eq 0 ]] && grep -q "WARN  monthly verify has not passed" "$T/out"' "$(cat "$T/out")"
fresh; NO_NEWS_TIMER=1 cb_run
check "alerts on but the news timer is off: FAIL" 'one_fail "ente-news.timer not enabled"' "$(grep FAIL "$T/out")"
NO_NEWS_TIMER=1 NO_ALERTS= cb_run
check "... no FAIL for it without Telegram alerts" '[[ $(fails) -eq 0 ]]' "$(grep FAIL "$T/out")"
fresh; NO_RCLONE_TIMER=1 cb_run
check "the rclone update timer is off: FAIL" 'one_fail "ente-rclone-update.timer not enabled"' "$(grep FAIL "$T/out")"
fresh; NO_VERIFY_TIMER=1 cb_run
check "the verify timer is off: FAIL" 'one_fail "ente-verify.timer not enabled"' "$(grep FAIL "$T/out")"
NO_ALERTS= cb_run
check "neither Telegram nor a heartbeat: a WARN" '[[ $(fails) -eq 0 ]] && grep -q "WARN  no failure alerts" "$T/out"' "$(cat "$T/out")"
touch "$T/ente/.restore-finishing"; cb_run
check "an unfinished restore: FAIL" 'one_fail "a restore did not finish"' "$(grep FAIL "$T/out")"
rm "$T/ente/.restore-finishing"
E=$T/root/etc/ente-backup.env
sed -i 's/^PHOTO_BUCKET=.*/PHOTO_BUCKET="old"/' "$E"; cb_run
check "the backup copies another bucket than museum uses: FAIL" 'one_fail "the backup copies ?/old, but museum uses s3.example.net/photo"' "$(grep FAIL "$T/out")"
sed -i 's/^PHOTO_BUCKET=.*/PHOTO_BUCKET="photo"/' "$E"

echo "== install moves the backup to a new photo bucket"
cat >>"$T/ente/museum.yaml" <<'X'
s3:
  b2-eu-cen:
    key: K2
    secret: S2
    endpoint: s3.new.net
    region: r9
    bucket: photo2
X
# refresh: install's refresh_backup_source, with the ownership check (it lists the bucket) recorded instead of run
refresh() { in_setup 'check_backup_owner() { echo "OWNER-CHECK $1"; }; refresh_backup_source' >"$T/out" 2>&1; }
check "install runs it once museum is up" 'in_setup "declare -f cmd_install" | grep -q refresh_backup_source'
refresh; RC=$?
check "museum.yaml names a new bucket: the backup's env file follows" '((RC == 0)) && grep -qx "PHOTO_BUCKET=\"photo2\"" "$E"' "$(cat "$T/out"; cat "$E")"
check "... ente-s3 points at its endpoint, with its keys" \
  '[[ $(conf_get ente-s3 endpoint) == s3.new.net && $(conf_get ente-s3 access_key_id) == K2 && $(conf_get ente-s3 secret_access_key) == S2 ]]'
check "... the config copy goes to the new bucket" '[[ $(conf_get photo-crypt remote) == ente-s3:photo2/ente-backup-config/config ]]' "$(conf_get photo-crypt remote)"
check "... once that bucket holds no other instance's backup" 'grep -qx "OWNER-CHECK ente-s3:photo2/ente-backup-config/" "$T/out"' "$(cat "$T/out")"
cb_run
check "... and check is content" '[[ $(fails) -eq 0 ]]' "$(grep FAIL "$T/out")"
refresh; RC=$?
check "a re-run with the same bucket: no second ownership check" '((RC == 0)) && ! grep -q OWNER-CHECK "$T/out"' "$(cat "$T/out")"
sed -i 's/endpoint: s3.new.net/endpoint: s3.other.net/' "$T/ente/museum.yaml"; cb_run
check "museum moved to another endpoint, the backup did not: FAIL" 'one_fail "the backup copies s3.new.net/photo2, but museum uses s3.other.net/photo2"' "$(grep FAIL "$T/out")"
mv "$E" "$T/env.keep"; sum=$(sha256sum "$RCLONE_CONFIG"); refresh; RC=$?
check "no backup set up yet: install leaves rclone and the env file alone" '((RC == 0)) && [[ ! -e $E && $(sha256sum "$RCLONE_CONFIG") == "$sum" ]]'
mv "$T/env.keep" "$E"

summary
