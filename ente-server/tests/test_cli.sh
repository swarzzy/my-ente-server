#!/usr/bin/env bash
# Tests for the command lines of ente-setup.sh, ente-ops.sh and ente-vpn.sh: known commands, usage errors, no extra
# arguments, root required. Nothing runs for real: as root (on the server) every call runs as an unprivileged user on a copy.
# Run: bash tests/test_cli.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
asuser() { "$@"; }
CLI=$HERE/..
if [[ $EUID -eq 0 ]]; then
  mkdir -p "$T/bin"; cp "$HERE/../ente-setup.sh" "$HERE/../ente-ops.sh" "$HERE/../ente-vpn.sh" "$T/bin/"; chmod 755 "$T" "$T/bin" "$T/bin"/*
  asuser() { setpriv --reuid=65534 --regid=65534 --clear-groups "$@"; }
  CLI=$T/bin
fi
# usage_error SCRIPT ARGS...: the call is refused with the usage line and exit code 2, before asking for root
usage_error() { local out rc; out=$(asuser bash "$CLI/$1" "${@:2}" 2>&1); rc=$?; [[ $rc -eq 2 && $out == *usage* ]]; }
# asks_root SCRIPT ARGS...: the call is accepted and stops only because it is not root
asks_root() { local out; out=$(asuser bash "$CLI/$1" "${@:2}" 2>&1); [[ $out == *"run as root"* ]]; }

echo "== ente-setup.sh"
for c in deploy bootstrap install codes lockdown backup-setup restore update; do
  check "$c is a known command" 'asks_root ente-setup.sh $c'
done
check "no command: usage error" 'usage_error ente-setup.sh'
check "an unknown command: usage error" 'usage_error ente-setup.sh nonsense'
check "an extra argument: usage error" 'usage_error ente-setup.sh install extra'
check "the ente-ops.sh commands are not here" 'usage_error ente-setup.sh check && usage_error ente-setup.sh verify'

echo "== config values that end up in generated files"
printf '%s\n' DOMAIN=photos.example.org S3_ENDPOINT=s3.example.net S3_REGION=r1 S3_BUCKET=photo BACKUP_S3_ENDPOINT=b2.example.net \
  BACKUP_S3_REGION=r2 BACKUP_S3_BUCKET=bk >"$T/base.env"
# load EXTRA: load_env with the base config plus the line EXTRA; prints LOADED or the error
load() {
  { cat "$T/base.env"; printf '%s\n' "$1"; } >"$T/env"
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test; . "$HERE/../ente-setup.sh"; load_env && echo LOADED ) 2>&1
}
for good in "HC_URL=https://hc-ping.com/abc-123" "TG_CHAT_ID=376193354" "TG_CHAT_ID=-1001234567" "TG_BOT_TOKEN=123456:AAH-abc_DEF"; do
  out=$(load "$good"); check "accepts $good" '[[ $out == *LOADED* ]]' "$out"
done
for bad in "HC_URL='https://x/\$(id)'" "HC_URL='https://x/\"q'" "S3_BUCKET='photo bk'" "DOMAIN='a\\b'" "TG_CHAT_ID=me" "TG_BOT_TOKEN='abc def'" \
  "TG_BOT_TOKEN='1:a\$(id)'"; do
  out=$(load "$bad"); check "refuses $bad" '[[ $out != *LOADED* && $out == *"${bad%%=*}"* ]]' "$out"
done

echo "== helpers"
in_setup() { ( ENV_FILE=$T/base.env SECRETS_FILE=$T/none CMD=test; . "$HERE/../ente-setup.sh"; set +e; eval "$1" ) 2>&1; }
echo old >"$T/target"; ino=$(stat -c %i "$T/target"); echo new >"$T/new"
out=$(in_setup 'overwrite_in_place "$T/new" "$T/target"; echo "rc=$?"')
check "overwrite_in_place: new content, same file (inode), the new copy removed" \
  '[[ $(cat "$T/target") == new && $(stat -c %i "$T/target") == "$ino" && ! -e $T/new && $out == *"rc=0"* ]]' "$out"
echo new >"$T/new"
out=$(in_setup 'overwrite_in_place "$T/new" /dev/full; echo "rc=$?"')
check "overwrite_in_place on a full disk: dies, keeps the new content and says where" \
  '[[ $out == *"could not write /dev/full"*"its new content is in $T/new"* && $out != *"rc=0"* && $(cat "$T/new") == new ]]' "$out"
out=$(in_setup 'cd "$T"; ENV_FILE=rel.env SECRETS_FILE=$T/s.secrets config_env')
check "config_env: absolute paths of both files, for the units" '[[ $out == "ENV_FILE=$(realpath "$T")/rel.env SECRETS_FILE=$(realpath "$T")/s.secrets" ]]' "$out"
out=$(in_setup 'ENV_FILE="$T/my env" config_env; echo "rc=$?"')
check "config_env refuses a path a unit line would break on" '[[ $out == *"may only hold"* && $out != *"rc=0"* ]]' "$out"
mkdir -p "$T/open"; cp "$HERE/../ente-setup.sh" "$HERE/../ente-ops.sh" "$T/open/"; chmod 777 "$T/open"
mkdir -p "$T/ente"; echo "key: x" >"$T/ente/museum.yaml"
out=$( ( ENV_FILE=$T/base.env SECRETS_FILE=$T/none CMD=test; . "$T/open/ente-setup.sh"; ENTE_DIR=$T/ente; cmd_backup_setup ) 2>&1 ); rc=$?
check "backup-setup refuses a script folder others can write (root's timers run it)" \
  '((rc != 0)) && [[ $out == *"root'"'"'s timers run the scripts in $T/open"* ]]' "$out"

echo "== WEB_APPS: extra Ente web apps (auth, locker)"
for good in "WEB_APPS=" "WEB_APPS='auth locker'" "WEB_APPS=locker,auth"; do
  out=$(load "$good"); check "accepts $good" '[[ $out == *LOADED* ]]' "$out"
done
out=$(load "WEB_APPS='auth cast'"); check "refuses an app it does not know" '[[ $out != *LOADED* && $out == *"unknown app '"'"'cast'"'"'"* ]]' "$out"
out=$( { cat "$T/base.env"; echo "WEB_APPS='auth locker'"; } >"$T/env"; ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test; . "$HERE/../ente-setup.sh"
  load_env; echo "cors=$S3_CORS_ORIGINS"; PINS=$T/none ENTE_DIR=$T/wo; mkdir -p "$ENTE_DIR"
  write_file() { cat >"$1"; }; dc() { :; }; write_override; cat "$T/wo/compose.override.yaml" ) 2>&1 )
check "... its apps are published on 127.0.0.1 only, through compose.override.yaml" \
  'grep -qx "      - 127.0.0.1:3003:3003 # auth web app" <<<"$out" && grep -qx "      - 127.0.0.1:3009:3009 # locker web app" <<<"$out"' "$out"
check "... and may upload to the photo bucket (CORS)" \
  '[[ $out == *"cors=https://web.photos.example.org,https://albums.photos.example.org,https://auth.photos.example.org,https://locker.photos.example.org"* ]]' "$out"
out=$( ( ENV_FILE=$T/base.env SECRETS_FILE=$T/none CMD=test; . "$HERE/../ente-setup.sh"; load_env; PINS=$T/none ENTE_DIR=$T/wo
  write_file() { cat >"$1"; }; dc() { :; }; write_override; cat "$T/wo/compose.override.yaml" ) 2>&1 )
check "without WEB_APPS the override publishes nothing extra" '! grep -q "ports:" <<<"$out"' "$out"

echo "== the photo bucket: museum.yaml once it has one, else the env file"
# bucket_run CODE: load_env with the base config (S3_ENDPOINT=s3.example.net, S3_BUCKET=photo) and $T/mb/museum.yaml, then CODE
bucket_run() { ( ENV_FILE=$T/base.env SECRETS_FILE=$T/none CMD=test; . "$HERE/../ente-setup.sh"; ENTE_DIR=$T/mb; set +e; load_env; eval "$1" ) 2>&1; }
mkdir -p "$T/mb"; rm -f "$T/mb/museum.yaml"
out=$(bucket_run 'echo "$PHOTO_ENDPOINT/$PHOTO_BUCKET $PHOTO_CFG_ROOT"')
check "no museum.yaml yet (before install, early in restore): the env file's" '[[ $out == "s3.example.net/photo ente-s3:photo/ente-backup-config/" ]]' "$out"
printf 'key:\n  encryption: x\n' >"$T/mb/museum.yaml"
out=$(bucket_run 'echo "$PHOTO_ENDPOINT/$PHOTO_BUCKET"'); check "museum.yaml without a bucket: the env file's" '[[ $out == "s3.example.net/photo" ]]' "$out"
printf 's3:\n  b2-eu-cen:\n    key: k\n    secret: s\n    endpoint: s3.museum.net\n    region: r\n    bucket: museum-bucket\n' >"$T/mb/museum.yaml"
out=$(bucket_run 'echo "$PHOTO_ENDPOINT/$PHOTO_BUCKET $PHOTO_CFG_ROOT"')
check "museum.yaml names another bucket (S3_* edited, install not re-run): museum's" \
  '[[ $out == "s3.museum.net/museum-bucket ente-s3:museum-bucket/ente-backup-config/" ]]' "$out"
out=$(bucket_run 'write_file() { cat >"$T/mb/$(basename "$1")"; }; systemctl() { :; }; SCRIPT_DIR=$HERE/..; install_backup_units; cat "$T/mb/ente-backup.env"')
check "... and the backup gets museum's bucket" 'grep -qx "PHOTO_BUCKET=\"museum-bucket\"" <<<"$out"' "$out"
out=$(bucket_run 'echo "M_KEY=[${M_KEY:-}]"'); check "... without leaving museum's keys in the shell" '[[ $out == "M_KEY=[]" ]]' "$out"

echo "== ente-ops.sh"
for c in check verify; do check "$c is a known command" 'asks_root ente-ops.sh $c'; done
check "no command: usage error" 'usage_error ente-ops.sh'
check "a setup command is not here" 'usage_error ente-ops.sh install'
check "an extra argument: usage error" 'usage_error ente-ops.sh check extra'
out=$(asuser bash "$CLI/ente-ops.sh" 2>&1); check "the usage line lists exactly check and verify" '[[ $out == *"{check|verify}"* ]]' "$out"

echo "== ente-vpn.sh"
for c in install status uninstall; do check "$c is a known command" 'asks_root ente-vpn.sh $c'; done
# port_ok PORT: awg_port_ok for that AWG_PORT
port_ok() { ( CMD=test; . "$HERE/../ente-vpn.sh"; AWG_PORT=$1; awg_port_ok ); }
check "AWG_PORT 1024, 24786 and 65535 are accepted" 'port_ok 1024 && port_ok 24786 && port_ok 65535'
check "AWG_PORT 1023, 65536, 0, 51820x and '1 2' are refused" '! port_ok 1023 && ! port_ok 65536 && ! port_ok 0 && ! port_ok 51820x && ! port_ok "1 2"'
check "no command: usage error" 'usage_error ente-vpn.sh'
check "an unknown command: usage error" 'usage_error ente-vpn.sh start'
summary
