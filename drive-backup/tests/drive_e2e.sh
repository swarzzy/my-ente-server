#!/usr/bin/env bash
# End-to-end test of drive-backup.sh on a test server against real buckets, as root. DRIVE_E2E_ENV and DRIVE_E2E_SECRETS name
# an env and a secrets file for TEST buckets; the test works in a fresh folder in each (DRIVE_S3_PREFIX, DRIVE_B2_PREFIX) and
# removes them, with every version, at the end. Needs opsbot with its bot. Refuses to run where drive-backup is installed.
# Installs, syncs, changes and deletes a file and restores the backup as of before, trips the guard and forces past it through
# opsbot's real helper, verifies, runs the daily check unit, uninstalls. The guard is tripped by hand (not by the service), so
# no alert is sent.
# Run: sudo DRIVE_E2E_ENV=... DRIVE_E2E_SECRETS=... bash tests/drive_e2e.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -f ${DRIVE_E2E_ENV:-} && -f ${DRIVE_E2E_SECRETS:-} ]] || { echo "set DRIVE_E2E_ENV and DRIVE_E2E_SECRETS (test buckets)" >&2; exit 1; }
[[ ! -e /etc/drive-backup ]] || { echo "drive-backup is installed here: run this on a test server" >&2; exit 1; }
HELPER=/usr/local/sbin/opsbot-action
P=drive-e2e-$(date +%s)
chmod 755 "$T"
sed '/^DRIVE_S3_PREFIX=/d; /^DRIVE_B2_PREFIX=/d' "$DRIVE_E2E_ENV" >"$T/env"; printf 'DRIVE_S3_PREFIX=%s\nDRIVE_B2_PREFIX=%s\n' "$P" "$P" >>"$T/env"
install -m 600 "$DRIVE_E2E_SECRETS" "$T/secrets"
# admin.conf: the same remotes with the test keys, to put files into the drive and to clean up (the server's keys may not)
( set -a; umask 077; . "$T/env"; . "$T/secrets"
  printf '[drive]\ntype = s3\nprovider = %s\nendpoint = %s\nregion = %s\naccess_key_id = %s\nsecret_access_key = %s\n\n[drivebak]\ntype = b2\naccount = %s\nkey = %s\n' \
    "${DRIVE_S3_PROVIDER:-Other}" "$DRIVE_S3_ENDPOINT" "${DRIVE_S3_REGION:-}" "$DRIVE_S3_ACCESS_KEY" "$DRIVE_S3_SECRET_KEY" "$DRIVE_B2_KEY_ID" "$DRIVE_B2_KEY" >"$T/admin.conf"
  echo "SRC=drive:$DRIVE_S3_BUCKET/$P DST=drivebak:$DRIVE_B2_BUCKET/$P" >"$T/paths" )
. "$T/paths"
adm() { rclone --config "$T/admin.conf" "$@"; }
DB() { ENV_FILE=$T/env SECRETS_FILE=$T/secrets ./drive-backup.sh "$@" </dev/null >"$T/out" 2>&1; RC=$?; }
cleanup() {
  ENV_FILE=$T/env ./drive-backup.sh uninstall >/dev/null 2>&1
  adm purge "$SRC" >/dev/null 2>&1
  adm delete --b2-versions --b2-hard-delete "$DST" >/dev/null 2>&1; adm cleanup "$DST" >/dev/null 2>&1 # cleanup: hide markers
  rm -rf "$T" ${RESTORED:+"$RESTORED"}
}
trap cleanup EXIT
RC=0

echo "== install"
mkdir -p "$T/seed/d"; for i in $(seq 1 20); do head -c $((1000 + i)) /dev/urandom >"$T/seed/d/f$i.c9r"; done
adm copy "$T/seed" "$SRC" || { echo "cannot seed the drive" >&2; exit 1; }
DB install; check "install succeeds" '[[ $RC -eq 0 ]]' "$(cat "$T/out")"
check "... it tried the keys (the test keys may do more: warned) and left no test file" 'grep -q "the backup can be written" "$T/out" && grep -qE "(OK|WARN)  .*(cannot delete for good|can delete for good)" "$T/out" && grep -qE "(OK|WARN)  the drive key (is read-only|may write)" "$T/out" && ! adm lsf "${SRC%/*}" | grep -q key-test' "$(cat "$T/out")"
check "... and read the lifecycle rules (30 days, or none: a warning)" 'grep -qE "OK    the backup keeps old versions 30 days|WARN  the backup bucket has no lifecycle rule" "$T/out"' "$(cat "$T/out")"
check "... the keys are in a root-only rclone.conf" '[[ $(stat -c "%U %a" /etc/drive-backup/rclone.conf) == "root 600" ]]'
check "... registered with opsbot, the timers on" '/usr/local/sbin/opsbot plugin list | grep -qw drive && systemctl is-enabled --quiet drive-backup.timer && systemctl is-enabled --quiet drive-check.timer'
# the first run has ended once its main process has an exit time
for _ in $(seq 1 90); do [[ $(systemctl show -p ExecMainExitTimestampMonotonic --value drive-backup.service) == 0 ]] || break; sleep 2; done
check "the first sync (started by install) copied the drive and verified it" '[[ $(adm lsf -R --files-only "$DST" | wc -l) == 20 && $(systemctl show -p Result --value drive-backup.service) == success ]] && journalctl -u drive-backup.service --no-pager | grep -q "verify passed"' "$(journalctl -u drive-backup.service -n 5 --no-pager)"

echo "== versions and restore"
adm cat "$SRC/d/f1.c9r" | sha256sum >"$T/f1.before"; adm cat "$SRC/d/f2.c9r" | sha256sum >"$T/f2.before"
sleep 2; T1=$(TZ=Asia/Tokyo date '+%F %T'); sleep 2 # restore reads the server's time: here Tokyo's, 9 h off UTC
head -c 3000 /dev/urandom | adm rcat "$SRC/d/f1.c9r"; adm deletefile "$SRC/d/f2.c9r"
DB run; check "a changed and a deleted file: synced" '[[ $RC -eq 0 ]] && grep -q "2 changed or gone" "$T/out"' "$(cat "$T/out")"
check "... the backup now has the new file and no longer lists the deleted one" '[[ $(adm cat "$DST/d/f1.c9r" | wc -c) == 3000 ]] && ! adm lsf "$DST/d" | grep -qx f2.c9r'
check "... B2 keeps the old versions" '[[ $(adm lsf --b2-versions "$DST/d" | grep -cE "^f[12]-v[0-9]") -ge 2 ]]' "$(adm lsf --b2-versions "$DST/d" | head)"
TZ=Asia/Tokyo DB restore "$T1"; out=$(sed -n 's/.*into \(\/var\/tmp\/drive-restore-[0-9-]*\).*/\1/p' "$T/out"); RESTORED=$out
check "restore as of before: both files as they were" '[[ $RC -eq 0 && -n $out && $(sha256sum <"$out/d/f1.c9r") == $(cat "$T/f1.before") && $(sha256sum <"$out/d/f2.c9r") == $(cat "$T/f2.before") && $(find "$out" -type f | wc -l) == 20 ]]' "$(cat "$T/out")"

echo "== the guard, and opsbot"
for i in $(seq 3 16); do head -c 2000 /dev/urandom | adm rcat "$SRC/d/f$i.c9r"; done
head -c 500 /dev/urandom | adm rcat "$SRC/d/new.c9r"
DB run; check "14 of 19 files rewritten: held back (exit 3), the new file copied" '[[ $RC -eq 3 ]] && grep -q "WARN: guard: 14 of 19" "$T/out" && [[ $(adm cat "$DST/d/f3.c9r" | wc -c) == 1003 && $(adm cat "$DST/d/new.c9r" | wc -c) == 500 ]]' "$(cat "$T/out")"
out=$(runuser -u opsbot -- sudo -n "$HELPER" drive status 2>&1); check "/status through opsbot's helper: held back" '[[ $out == "⚠️ Drive: 14 of 19 files would change or go: held back"* ]]' "$out"
out=$(runuser -u opsbot -- sudo -n "$HELPER" drive force 2>&1); RC=$?
check "/drive_force through opsbot's helper: synced everything" '[[ $RC -eq 0 && $out == *"(forced)"* && $(adm cat "$DST/d/f3.c9r" | wc -c) == 2000 ]]' "$out"
out=$(runuser -u opsbot -- sudo -n "$HELPER" drive status 2>&1); check "... /status: a recent sync, 20 files" '[[ $out == "🗂 Drive: last sync "*" · 20 files, "* ]]' "$out"
runuser -u opsbot -- sudo -n -l "$HELPER" drive sync >/dev/null 2>&1; RC=$?; check "the bot may run /drive_sync" '[[ $RC -eq 0 ]]'

echo "== verify, check, uninstall"
DB verify; check "verify passes" '[[ $RC -eq 0 ]] && grep -q "verify passed" "$T/out"' "$(cat "$T/out")"
DB check; check "check passes" '[[ $RC -eq 0 ]]' "$(cat "$T/out")"
systemctl start drive-check.service; check "the daily check unit passes" '[[ $(systemctl show -p Result --value drive-check.service) == success ]]' "$(journalctl -u drive-check.service -n 10 --no-pager)"
DB uninstall; check "uninstall: units, keys and plugin gone" '[[ $RC -eq 0 && ! -e /etc/drive-backup && ! -e /etc/systemd/system/drive-backup.service && ! -e /etc/systemd/system/drive-check.timer ]] && ! /usr/local/sbin/opsbot plugin list | grep -qw drive' "$(cat "$T/out")"

summary
