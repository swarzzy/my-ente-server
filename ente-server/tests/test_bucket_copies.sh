#!/usr/bin/env bash
# Tests for "either bucket alone + BACKUP_PASSPHRASE restores everything": the encrypted config copy in the photo bucket
# (photo-crypt), the real backup script writing both copies while keeping that copy out of the photo mirror, the exclusion in
# check/verify (new_uploads), the ownership check on the photo bucket, and restore's choice of source and how it resumes an interrupted run.
# The buckets are local folders behind rclone alias remotes and docker is a stub, so this changes nothing outside a temp dir.
# Needs bash, python3 and rclone (the server has them). Run: bash tests/test_bucket_copies.sh
set -uo pipefail
# shellcheck source=buckets_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/buckets_lib.sh"

echo "== photo-crypt remote"
remotes 'correct horse'
check "photo-crypt points at <photo bucket>/ente-backup-config/config" '[[ $(conf_get photo-crypt remote) == ente-s3:photo/ente-backup-config/config ]]' "$(conf_get photo-crypt remote)"
check "photo-crypt uses backup-crypt's passphrase" '[[ -n $(conf_get photo-crypt password) && $(conf_get photo-crypt password) == "$(conf_get backup-crypt password)" ]]'
check "photo-crypt is a crypt remote" '[[ $(conf_get photo-crypt type) == crypt ]]'

echo "== the backup script"
# generate the real script and env file into the temp dir, then point its fixed paths there too
backup_script
check "install_backup_units wrote the script and its env file" '[[ -s $T/root/usr/local/bin/ente-backup.sh && -s $T/root/etc/ente-backup.env ]]'
check "the env file names the config copy's folder" 'grep -qx "PHOTO_CFG_DIR=\"ente-backup-config\"" "$T/root/etc/ente-backup.env"'
check "the paths were redirected (no /var or /opt left)" '! grep -E "/var/(backups|lib)/ente|/opt/my-ente" "$T/backup.sh" >/dev/null'
run_backup; RC=$?
check "a backup run succeeds" '((RC == 0))' "$(tail -5 "$T/out")"
check "photos are mirrored to the backup bucket" '[[ $(cat "$T/b2/bk/objects/1580559962386439/aaa" 2>/dev/null) == photo-a ]]'
check "the config copy is in the photo bucket" '[[ -d $T/s3/photo/ente-backup-config/config ]]'
check "the config copy is NOT mirrored into the backup's objects/" '[[ ! -e $T/b2/bk/objects/ente-backup-config ]]' "$(find "$T/b2/bk/objects" | head)"
check "the copy's names are encrypted (no plaintext museum.yaml or dump name)" \
  '! find "$T/s3/photo/ente-backup-config" | grep -E "museum|ente_db|compose" >/dev/null'
check "the copy's contents are encrypted" '! grep -r "KEY-ONE" "$T/s3/photo/ente-backup-config" >/dev/null'
check "the copy decrypts: museum.yaml equals the live one" 'rclone cat photo-crypt:museum.yaml 2>/dev/null | cmp -s - "$T/ente/museum.yaml"'
check "the copy holds today's dump" 'rclone lsf photo-crypt: 2>/dev/null | grep -x "ente_db-$(date +%F).dump" >/dev/null'
check "the backup bucket's copy decrypts too" 'rclone cat backup-crypt:museum.yaml 2>/dev/null | cmp -s - "$T/ente/museum.yaml"'
check "both stamps are written (s3, photo-config)" '[[ -s $T/state/last-ok-s3 && -s $T/state/last-ok-photo-config ]]'
rm "$T/s3/photo/1580559962386439/bbb"
run_backup; RC=$?
check "a second run succeeds" '((RC == 0))' "$(tail -5 "$T/out")"
check "a deleted photo is deleted from the mirror too (its history is the backup bucket's old versions)" '[[ ! -e $T/b2/bk/objects/1580559962386439/bbb && -f $T/b2/bk/objects/1580559962386439/aaa ]]'
check "with the copy present, it is still not mirrored into objects/ (the exclusion, not luck)" \
  '[[ -d $T/s3/photo/ente-backup-config && ! -e $T/b2/bk/objects/ente-backup-config ]]' "$(find "$T/b2/bk/objects" | head)"
check "no deleted/ folder is made" '[[ ! -e $T/b2/bk/deleted ]]'
check "the config copy is still in the photo bucket" 'rclone lsf photo-crypt: 2>/dev/null | grep -x museum.yaml >/dev/null'
chmod 000 "$T/s3/photo/ente-backup-config"
run_backup; RC=$?
chmod 755 "$T/s3/photo/ente-backup-config"
if [[ $EUID -ne 0 ]]; then # root ignores the permission, so this case only runs unprivileged
  check "a failing config copy fails the run" '((RC != 0)) && grep -q "config copy to the photo bucket failed" "$T/out"' "$(tail -5 "$T/out")"
fi

echo "== check / verify: the copy is not a missing photo"
in_setup 'f=$(new_uploads s3); cat "$f"; rm -f "$f"' >"$T/ex" 2>/dev/null
check "new_uploads always excludes /ente-backup-config/**" 'grep -qxF "/ente-backup-config/**" "$T/ex"'
check "new_uploads reads the test's stamps, so old photos are not excluded" '[[ $(wc -l <"$T/ex") -eq 1 ]]' "$(cat "$T/ex")"
echo photo-c >"$T/s3/photo/1580559962386439/ccc"
in_setup 'f=$(new_uploads s3); cat "$f"; rm -f "$f"' >"$T/ex2" 2>/dev/null
check "a photo uploaded after the last backup is excluded (not yet backed up)" 'grep -qxF "/1580559962386439/ccc" "$T/ex2"' "$(cat "$T/ex2")"
rm "$T/s3/photo/1580559962386439/ccc"
check "rclone check photo bucket vs backup passes with that exclusion" \
  'rclone check ente-s3:photo backup:bk/objects --one-way --size-only --exclude-from "$T/ex" >/dev/null 2>&1'
check "... and would fail without it (so the test is not vacuous)" '! rclone check ente-s3:photo backup:bk/objects --one-way --size-only >/dev/null 2>&1'

echo "== ownership check on the photo bucket's copy"
in_setup 'check_backup_owner "$PHOTO_CFG_ROOT" photo-crypt "the photo copy"' >/dev/null 2>&1; RC=$?
check "same instance: accepted" '((RC == 0))'
sed -i 's/KEY-ONE/KEY-TWO/' "$T/ente/museum.yaml"
in_setup 'check_backup_owner "$PHOTO_CFG_ROOT" photo-crypt "the photo copy"' >"$T/out" 2>&1; RC=$?
check "another instance's copy: refused" '((RC != 0)) && grep -q DIFFERENT "$T/out"' "$(cat "$T/out")"
sed -i 's/KEY-TWO/KEY-ONE/' "$T/ente/museum.yaml"

echo "== restore: which bucket"
src() { in_setup 'restore_source' 2>/dev/null; }
check "both copies equal: the backup bucket" '[[ $(src) == backup-crypt: ]]' "$(src)"
echo newer | rclone rcat photo-crypt:ente_db-2999-01-01.dump 2>/dev/null
check "photo bucket has the newer dump: the photo bucket" '[[ $(src) == photo-crypt: ]]' "$(src)"
rclone deletefile photo-crypt:ente_db-2999-01-01.dump
mv "$T/b2" "$T/b2.lost"; mkdir -p "$T/b2/bk"
check "backup bucket lost (new, empty one): the photo bucket" '[[ $(src) == photo-crypt: ]]' "$(src)"
mkdir "$T/r"; rclone copy "$(src)" "$T/r" 2>/dev/null
check "... and the copy has everything restore needs (dump, compose.yaml, museum.yaml)" \
  '[[ -n $(find "$T/r" -name "ente_db-*.dump") && -f $T/r/compose.yaml ]] && cmp -s "$T/r/museum.yaml" "$T/ente/museum.yaml"'
in_setup '[[ -n $(rclone lsf --max-depth 1 "${BACKUP_ROOT}objects" 2>/dev/null | head -1) ]]'; RC=$?
check "... restore sees no objects to copy back from the empty backup bucket" '((RC != 0))'
rm -rf "$T/b2"; mv "$T/b2.lost" "$T/b2"
mv "$T/s3" "$T/s3.lost"; mkdir -p "$T/s3/photo"
check "photo bucket lost (new, empty one): the backup bucket" '[[ $(src) == backup-crypt: ]]' "$(src)"
in_setup '[[ -n $(rclone lsf --max-depth 1 "${BACKUP_ROOT}objects" 2>/dev/null | head -1) ]]'; RC=$?
check "... restore finds the photo objects to copy back" '((RC == 0))'
rm -rf "$T/b2/bk"; mkdir -p "$T/b2/bk"
in_setup 'restore_source' >/dev/null 2>&1; RC=$?
check "neither bucket has a copy: restore_source fails" '((RC != 0))'
rm -rf "$T/s3"; mv "$T/s3.lost" "$T/s3"
remotes 'wrong passphrase'
in_setup 'restore_source' >/dev/null 2>&1; RC=$?
check "wrong passphrase: restore_source fails (nothing readable)" '((RC != 0))'
remotes 'correct horse'
check "right passphrase again: the photo copy is found" '[[ $(src) == photo-crypt: ]]' "$(src)"

echo "== restore: an interrupted run never wipes a restored database"
# restore_run: cmd_restore into $T/re with the installers, the remotes' setup, docker compose and the health checks stubbed.
# FAIL_AT=pg_restore|healthy makes that step fail; MUSEUM_UP=1 makes museum look running. Every dc call is logged to $T/dc.log.
R=$T/re
restore_run() {
  : >"$T/dc.log"
  in_setup '
    ENTE_DIR='"$R"' PINS='"$R"'/image-pins DUMP_DIR='"$T"'/re-dumps
    apt_get() { :; }; apt_install() { :; }; install_docker() { :; }; install_caddy() { :; }; install_rclone() { :; }
    make_backup_remotes() { :; }; make_photo_remote_env() { :; }; make_photo_crypt() { :; }; make_photo_remote() { :; }
    configure_host() { :; }; url_ok() { :; }; host_ip() { echo 192.0.2.1; }
    mktemp() { command mktemp -d "$T/restore.XXXXXX"; }
    wait_healthy() { [[ ${FAIL_AT:-} != healthy ]] || die "museum not healthy (test)"; }
    dc() {
      echo "$*" >>"$T/dc.log"
      case "$*" in
        "ps -q museum") [[ -z ${MUSEUM_UP:-} ]] || echo cid ;;
        *pg_restore*) [[ ${FAIL_AT:-} != pg_restore ]] ;;
      esac
    }
    cmd_restore' >"$T/out" 2>&1
}
wiped() { grep -qx 'down -v' "$T/dc.log"; }
FAIL_AT=pg_restore restore_run; RC=$?
check "pg_restore fails: restore fails" '((RC != 0))' "$(tail -3 "$T/out")"
check "... and leaves .restore-incomplete (not .restore-finishing)" '[[ -e $R/.restore-incomplete && ! -e $R/.restore-finishing ]]'
check "... museum was never started" '! grep -qx "up -d" "$T/dc.log"' "$(cat "$T/dc.log")"
MUSEUM_UP=1 restore_run; RC=$?
check "re-run while museum runs: refused, nothing wiped" '((RC != 0)) && ! wiped && [[ -f $R/museum.yaml ]] && grep -q "not wiping" "$T/out"' "$(tail -3 "$T/out")"
restore_run; RC=$?
check "re-run before the database was restored: wipes the half-done attempt and succeeds" '((RC == 0)) && wiped' "$(tail -3 "$T/out")"
check "... and leaves no marker" '[[ ! -e $R/.restore-incomplete && ! -e $R/.restore-finishing && -f $R/museum.yaml ]]'
check "... and keeps the dumps (the next backup would delete missing ones)" '[[ -n $(find "$T/re-dumps" -name "ente_db-*.dump") ]]'
restore_run; RC=$?
check "restore on a finished server: refused, nothing wiped" '((RC != 0)) && ! wiped && grep -q "already exists" "$T/out"' "$(tail -3 "$T/out")"
rm -rf "$R"
FAIL_AT=healthy restore_run; RC=$?
check "museum not healthy after the database restore: restore fails" '((RC != 0)) && grep -qx "exec -T postgres pg_restore -U pguser -d ente_db --clean --if-exists /tmp/restore.dump" "$T/dc.log"' "$(cat "$T/dc.log")"
check "... and leaves .restore-finishing (not .restore-incomplete)" '[[ -e $R/.restore-finishing && ! -e $R/.restore-incomplete ]]'
MUSEUM_UP=1 restore_run; RC=$?
check "re-run after the database restore (museum running, in use): finishes without wiping or restoring again" \
  '((RC == 0)) && ! wiped && ! grep -q pg_restore "$T/dc.log" && [[ ! -e $R/.restore-finishing ]]' "$(cat "$T/out" "$T/dc.log" | tail -8)"

echo "== rclone.conf is replaced atomically"
cp -p "$RCLONE_CONFIG" "$T/conf.before"
printf 'zz=ok\n' | in_setup 'rclone_set extra-remote' >/dev/null 2>&1; RC=$?
check "rclone_set adds a remote and keeps the others" \
  '((RC == 0)) && [[ $(conf_get extra-remote zz) == ok && $(conf_get ente-s3 remote) == "$T/s3" ]]' "$(cat "$RCLONE_CONFIG")"
check "... the config stays private (600)" '[[ $(stat -c %a "$RCLONE_CONFIG") == 600 ]]'
cp -p "$RCLONE_CONFIG" "$T/conf.before"
# an invalid byte makes the write fail half-way (the first section is written, then the encoder fails)
printf 'zz=\xff\n' | LC_ALL=C in_setup 'rclone_set ente-s3' >"$T/out" 2>&1; RC=$?
check "a write that fails half-way: rclone_set fails" '((RC != 0))' "$(tail -3 "$T/out")"
check "... and the config is exactly as before (no remote lost)" 'cmp -s "$RCLONE_CONFIG" "$T/conf.before"' "$(cat "$RCLONE_CONFIG")"
check "... and no temp file is left next to it" '[[ -z $(find "$(dirname "$RCLONE_CONFIG")" -maxdepth 1 -name ".rclone.conf.*") ]]'

summary
