#!/usr/bin/env bash
# ente-backup.sh - one backup run of an Ente server set up by ente-setup.sh. Standalone: it needs only bash, docker compose,
# rclone (with the remotes backup-setup made) and its config, not ente-setup.sh.
#   1. dumps Postgres (verified, atomic) and keeps 7 days of dumps next to museum.yaml, compose*.yaml and image-pins;
#   2. syncs them, encrypted, to the backup bucket (backup-crypt:) and mirrors the photo bucket to <backup bucket>/objects;
#      files gone from the photo bucket are deleted from the mirror, and the backup bucket keeps them as old versions;
#      more than BACKUP_DELETE_WARN of them sends a Telegram warning, the run goes on; more than 20 dump deletions stop it;
#   3. syncs the same encrypted config into the photo bucket (photo-crypt:), so either bucket alone restores everything;
#   4. after a fully good run, pings HC_URL. Each step leaves a stamp in BACKUP_STATE for `ente-ops.sh check`.
# Installed by `ente-setup.sh backup-setup` as /usr/local/bin/ente-backup.sh and run by ente-backup.service (daily, 03:00).
# By hand: sudo systemctl start ente-backup.service (or run the installed script as root). Exit 1 on any failed step.
#
# Config (environment; /etc/ente-backup.env is read when BACKUP_ROOT is not set):
#   BACKUP_ROOT, PHOTO_BUCKET, PHOTO_CFG_DIR    where to (written by backup-setup)
#   BACKUP_DELETE_WARN (500), BACKUP_KEEP_DELETED_DAYS (60), HC_URL (optional)
#   ENTE_DIR (/opt/my-ente), DUMP_DIR (/var/backups/ente), BACKUP_STATE (/var/lib/ente-backup),
#   ENTE_ALERT (/usr/local/bin/ente-alert), RCLONE_CONFIG (/root/.config/rclone/rclone.conf)   paths; tests point them elsewhere
set -euo pipefail
umask 077
if [[ -z ${BACKUP_ROOT:-} && -r ${ENTE_BACKUP_ENV:-/etc/ente-backup.env} ]]; then
  set -a; . "${ENTE_BACKUP_ENV:-/etc/ente-backup.env}"; set +a
fi
: "${BACKUP_ROOT:?not set (run ente-setup.sh backup-setup)}" "${PHOTO_BUCKET:?not set}" "${PHOTO_CFG_DIR:?not set}"
BACKUP_DELETE_WARN=${BACKUP_DELETE_WARN:-500} BACKUP_KEEP_DELETED_DAYS=${BACKUP_KEEP_DELETED_DAYS:-60} HC_URL=${HC_URL:-}
ENTE_DIR=${ENTE_DIR:-/opt/my-ente} DUMPS=${DUMP_DIR:-/var/backups/ente} STATE=${BACKUP_STATE:-/var/lib/ente-backup}
ALERT=${ENTE_ALERT:-/usr/local/bin/ente-alert}
export RCLONE_CONFIG=${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}
START=$(date -Is)
OPTS=(--checkers 4 --transfers 4)

cd "$ENTE_DIR"
mkdir -p "$DUMPS" "$STATE"; chmod 700 "$DUMPS"
dump="$DUMPS/ente_db-$(date +%F).dump"
docker compose exec -T postgres pg_dump -U pguser -d ente_db -Fc > "$dump.tmp"
[[ -s "$dump.tmp" ]] || { echo "ERROR: empty database dump" >&2; rm -f "$dump.tmp"; exit 1; }
docker compose exec -T postgres pg_restore -l < "$dump.tmp" > /dev/null || { echo "ERROR: dump unreadable" >&2; rm -f "$dump.tmp"; exit 1; }
mv "$dump.tmp" "$dump"
find "$DUMPS" -name 'ente_db-*.dump' -mtime +6 -delete
cp museum.yaml compose.yaml compose.override.yaml "$DUMPS/"
[[ ! -f image-pins ]] || cp image-pins "$DUMPS/"

# count_deletes SRC DST [FILTER...]: how many files a sync from SRC would delete from DST (in DST, not in SRC).
# A SRC that cannot be listed fails; a DST that cannot be listed (first run) counts as empty.
count_deletes() {
  local src=$1 dst=$2 s d; shift 2
  s=$(rclone lsf -R --files-only "$@" "$src") || { echo "ERROR: cannot list $src" >&2; return 1; }
  d=$(rclone lsf -R --files-only "$@" "$dst" 2>/dev/null) || d=
  LC_ALL=C comm -13 <(LC_ALL=C sort <<<"$s") <(LC_ALL=C sort <<<"$d") | grep -c . || true
}
# limit_deletes MAX SRC DST: fail if a sync would delete more than MAX files (the dumps have no other history). rclone's own
# --max-delete only stops AFTER deleting that many, so the limit is checked before the sync (--max-delete stays as a cap).
limit_deletes() {
  local n; n=$(count_deletes "$2" "$3") || return 1
  ((n <= $1)) || { echo "ERROR: syncing would delete $n files from $3 (limit $1); nothing synced" >&2; return 1; }
}
# warn_deletes N SINCE: many photo files are gone from the photo bucket. The sync goes ahead: the backup bucket keeps old
# versions, so they stay recoverable for BACKUP_KEEP_DELETED_DAYS. Telegram warning (if alerts are on) and a stamp for check.
warn_deletes() {
  local n=$1 since=$2
  echo "WARNING: $n photo files are gone from the photo bucket since the last backup (warning above $BACKUP_DELETE_WARN)" >&2
  echo "$START $n" > "$STATE/deletes-warn"
  [[ -x $ALERT ]] || return 0
  printf '%s\n' "$n files disappeared from the photo bucket since the last backup (warning above $BACKUP_DELETE_WARN)." \
    "The backup ran: they stay in the backup bucket as old versions for $BACKUP_KEEP_DELETED_DAYS days." \
    "Fine after a big cleanup in Ente. If not, put them back as of the last backup:" \
    "rclone copy --s3-version-at '$since' ${BACKUP_ROOT}objects ente-s3:$PHOTO_BUCKET" |
    "$ALERT" "⚠️ Ente backup: $n photo files deleted on $(hostname)" || echo "WARNING: the Telegram warning failed" >&2
}
# target NAME CRYPT ROOT: config + dumps to CRYPT, photo objects to ROOT/objects. Success leaves a per-target stamp for
# `check`: the time the run STARTED, so that objects uploaded after it are not expected in the backup.
target() {
  local name=$1 crypt=$2 root=$3 n since
  echo "== $name"
  limit_deletes 20 "$DUMPS" "$crypt:" || return 1
  rclone sync "$DUMPS" "$crypt:" --checkers 4 --max-delete 20 || return 1
  n=$(count_deletes "ente-s3:$PHOTO_BUCKET" "${root}objects" --exclude "/$PHOTO_CFG_DIR/**") || return 1
  since=$(cat "$STATE/last-ok-$name" 2>/dev/null || echo "$START")
  ((n <= BACKUP_DELETE_WARN)) || warn_deletes "$n" "$since"
  rclone sync "ente-s3:$PHOTO_BUCKET" "${root}objects" --size-only "${OPTS[@]}" --exclude "/$PHOTO_CFG_DIR/**" || return 1
  echo "$START" > "$STATE/last-ok-$name"
}

rc=0
target s3 backup-crypt "$BACKUP_ROOT" || { echo "ERROR: backup to the S3 bucket failed" >&2; rc=1; }
# the same encrypted config/ also inside the photo bucket: either bucket alone + the passphrase restores everything
echo "== config copy in the photo bucket"
if limit_deletes 20 "$DUMPS" photo-crypt: && rclone sync "$DUMPS" photo-crypt: --checkers 4 --max-delete 20; then
  echo "$START" > "$STATE/last-ok-photo-config"
else echo "ERROR: config copy to the photo bucket failed" >&2; rc=1; fi
((rc == 0)) || exit 1
# heartbeat (healthchecks.io, Better Stack, ...): only after a fully good run. A failed ping does not fail the backup
# (that would send a false "backup failed"); `check` reports it instead.
if [[ -n $HC_URL ]]; then
  if curl -fsS -m 15 --retry 3 --retry-all-errors -o /dev/null "$HC_URL"; then date -Is > "$STATE/hc-ok"; rm -f "$STATE/hc-fail"
  else echo "WARNING: heartbeat ping to HC_URL failed; the backup itself succeeded" >&2; date -Is > "$STATE/hc-fail"; fi
fi
