# buckets_lib.sh - shared setup for the tests that need the two "buckets" (source it): local folders behind rclone alias
# remotes, a fake Ente dir, the real ente-backup.sh with its paths in the temp dir, docker as a
# stub (FAKE_DUMP sets the dump content). Gives T, check/pass/fail, in_setup, remotes, conf_get, backup_script, run_backup, summary.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v rclone >/dev/null || { echo "rclone is not installed: run this on the server"; exit 1; }
export RCLONE_CONFIG=$T/rclone.conf

cat >"$T/env" <<'X'
DOMAIN=photos.example.org
S3_ENDPOINT=s3.example.net
S3_REGION=r1
S3_BUCKET=photo
BACKUP_S3_ENDPOINT=b2.example.net
BACKUP_S3_REGION=r2
BACKUP_S3_BUCKET=bk
X
# in_setup CODE: source ente-ops.sh (and so ente-setup.sh) with that config and ENTE_DIR in the temp dir, load it, run CODE in a subshell
in_setup() {
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-ops.sh"
    ENTE_DIR=$T/ente RCLONE_CONFIG=$T/rclone.conf BACKUP_STATE=$T/state DUMP_DIR=$T/dumps # never the host's real files
    set +e
    load_env
    eval "$1" )
}
# remotes PASSPHRASE: the two "buckets" as folders, backup-crypt with that passphrase, photo-crypt made by the code under test
remotes() {
  cat >"$RCLONE_CONFIG" <<X
[ente-s3]
type = alias
remote = $T/s3

[backup]
type = alias
remote = $T/b2

[backup-crypt]
type = crypt
remote = backup:bk/config
password = $(rclone obscure "$1")
X
  in_setup make_photo_crypt >/dev/null 2>&1
}
conf_get() { python3 -I -c 'import configparser,sys; c=configparser.RawConfigParser(); c.read(sys.argv[1]); print(c.get(sys.argv[2], sys.argv[3]))' "$RCLONE_CONFIG" "$1" "$2" 2>/dev/null; }

mkdir -p "$T/s3/photo/1580559962386439" "$T/b2/bk" "$T/ente" "$T/bin"
echo photo-a >"$T/s3/photo/1580559962386439/aaa"; echo photo-b >"$T/s3/photo/1580559962386439/bbb"
touch -d '2 hours ago' "$T/s3/photo/1580559962386439/"* # uploaded well before any backup: not "new uploads"
printf 'key:\n  encryption: KEY-ONE\njwt:\n  secret: J\n' >"$T/ente/museum.yaml"
echo 'services: {}' >"$T/ente/compose.yaml"; echo 'services: {}' >"$T/ente/compose.override.yaml"
cat >"$T/bin/docker" <<'X'
#!/bin/bash
case "$*" in
  *pg_dump*) echo "PGDMP fake dump ${FAKE_DUMP:-1}" ;;
  *pg_restore*) cat >/dev/null ;;
  *) echo "unexpected docker $*" >&2; exit 1 ;;
esac
X
chmod 755 "$T/bin/docker"
# backup_script: what backup-setup installs (the backup script, its env file /etc/ente-backup.env, the units), into $T/root
backup_script() {
  in_setup '
    write_file() { local f=$T/root$1; mkdir -p "$(dirname "$f")"; cat >"$f"; chmod "${2:-644}" "$f"; }
    systemctl() { :; }
    ALERT_ONFAIL= SCRIPT_DIR=$HERE/.. install_backup_units' >/dev/null 2>&1
}
# BACKUP_ENV: the backup's paths, all in the temp dir (the script reads them from the environment)
BACKUP_ENV=(ENTE_DIR="$T/ente" DUMP_DIR="$T/dumps" BACKUP_STATE="$T/state" RCLONE_CONFIG="$RCLONE_CONFIG")
# run_backup: one run of the repo's ente-backup.sh with the installed env file, as ente-backup.service runs it
run_backup() { ( set -a; . "$T/root/etc/ente-backup.env"; set +a; env "${BACKUP_ENV[@]}" PATH="$T/bin:$PATH" bash "$HERE/../ente-backup.sh" ) >"$T/out" 2>&1; }
