# buckets_lib.sh - shared setup for the tests that need the two "buckets" (source it): local folders behind rclone alias
# remotes, a fake Ente dir, the real backup script generated into the temp dir with its fixed paths redirected, docker as a
# stub (FAKE_DUMP sets the dump content). Gives T, check/pass/fail, in_setup, remotes, conf_get, backup_script, run_backup, summary.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
command -v rclone >/dev/null || { echo "rclone is not installed: run this on the server"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export RCLONE_CONFIG=$T/rclone.conf
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/        /' | head -20; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }

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
# backup_script: generate the real backup script and its env file into $T/root, then $T/backup.sh with the paths redirected
backup_script() {
  in_setup '
    write_file() { local f=$T/root$1; mkdir -p "$(dirname "$f")"; cat >"$f"; chmod "${2:-644}" "$f"; }
    systemctl() { :; }
    ALERT_ONFAIL= SCRIPT_DIR=$T install_backup_units' >/dev/null 2>&1
  sed -e "s|/opt/my-ente|$T/ente|g; s|/var/backups/ente|$T/dumps|g; s|/var/lib/ente-backup|$T/state|g" \
    "$T/root/usr/local/bin/ente-backup.sh" >"$T/backup.sh"
}
run_backup() { ( set -a; . "$T/root/etc/ente-backup.env"; set +a; PATH=$T/bin:$PATH bash "$T/backup.sh" ) >"$T/out" 2>&1; }
summary() { echo; echo "$PASS passed, $FAIL failed"; ((FAIL == 0)); }
