#!/usr/bin/env bash
# ente-backup.sh - one backup run of an Ente server set up by ente-setup.sh. Standalone: it needs only bash, docker compose,
# rclone (with the remotes backup-setup made) and its config, not ente-setup.sh.
#   1. dumps Postgres (verified, atomic) and keeps 7 days of dumps next to museum.yaml, compose*.yaml and image-pins;
#   2. copies them, encrypted, to the backup bucket (backup-crypt:) and copies the photo bucket to <backup bucket>/objects.
#      It never deletes anything in the backup bucket: deleted photos and old dumps stay there until you clean up by hand;
#   3. syncs the same encrypted config into the photo bucket (photo-crypt:; the last 7 days of dumps), so either bucket
#      alone restores everything;
#   4. after a fully good run, pings HC_URL. Each step leaves a stamp in BACKUP_STATE: last-ok-* for `ente-ops.sh check`,
#      hc-ok / hc-fail for the bot's /status.
# Installed by `ente-setup.sh backup-setup` as /usr/local/bin/ente-backup.sh and run by ente-backup.service (daily, 03:00).
# By hand: sudo systemctl start ente-backup.service (or run the installed script as root). Exit 1 on any failed step.
#
# Config (environment; /etc/ente-backup.env is read when BACKUP_ROOT is not set):
#   BACKUP_ROOT, PHOTO_BUCKET, PHOTO_CFG_DIR    where to (written by backup-setup); HC_URL (optional)
#   ENTE_DIR (/opt/my-ente), DUMP_DIR (/var/backups/ente), BACKUP_STATE (/var/lib/ente-backup),
#   RCLONE_CONFIG (/root/.config/rclone/rclone.conf)   paths; tests point them elsewhere
set -euo pipefail
umask 077
if [[ -z ${BACKUP_ROOT:-} && -r ${ENTE_BACKUP_ENV:-/etc/ente-backup.env} ]]; then
  set -a; . "${ENTE_BACKUP_ENV:-/etc/ente-backup.env}"; set +a
fi
: "${BACKUP_ROOT:?not set (run ente-setup.sh backup-setup)}" "${PHOTO_BUCKET:?not set}" "${PHOTO_CFG_DIR:?not set}"
HC_URL=${HC_URL:-}
ENTE_DIR=${ENTE_DIR:-/opt/my-ente} DUMPS=${DUMP_DIR:-/var/backups/ente} STATE=${BACKUP_STATE:-/var/lib/ente-backup}
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

rc=0
# the backup bucket: copy only, never delete. Success leaves a stamp for `check`: the time the run STARTED, so that
# objects uploaded after it are not expected in the backup.
echo "== backup bucket"
if rclone copy "$DUMPS" backup-crypt: --checkers 4 &&
  rclone copy "ente-s3:$PHOTO_BUCKET" "${BACKUP_ROOT}objects" --size-only "${OPTS[@]}" --exclude "/$PHOTO_CFG_DIR/**"; then
  echo "$START" > "$STATE/last-ok-s3"
else echo "ERROR: backup to the S3 bucket failed" >&2; rc=1; fi
# the same encrypted config/ also inside the photo bucket: either bucket alone + the passphrase restores everything
echo "== config copy in the photo bucket"
if rclone sync "$DUMPS" photo-crypt: --checkers 4; then
  echo "$START" > "$STATE/last-ok-photo-config"
else echo "ERROR: config copy to the photo bucket failed" >&2; rc=1; fi
((rc == 0)) || exit 1
# heartbeat (healthchecks.io, Better Stack, ...): only after a fully good run. A failed ping does not fail the backup
# (that would send a false "backup failed"); the heartbeat service notices the missing ping and alerts by itself.
if [[ -n $HC_URL ]]; then
  if curl -fsS -m 15 --retry 3 --retry-all-errors -o /dev/null "$HC_URL"; then date -Is > "$STATE/hc-ok"; rm -f "$STATE/hc-fail"
  else echo "WARNING: heartbeat ping to HC_URL failed; the backup itself succeeded" >&2; date -Is > "$STATE/hc-fail"; fi
fi
