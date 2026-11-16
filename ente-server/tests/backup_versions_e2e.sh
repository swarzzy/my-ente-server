#!/usr/bin/env bash
# End to end, against the REAL backup bucket: a file the backup's mirror deletes stays there as an old version, and the
# command the Telegram warning gives (rclone copy --s3-version-at) brings it back. Also checks the bucket's version setting
# (backup_versions get). Works only under a throwaway prefix (ente-setup-e2e-<random>/) and removes it, all versions
# included, at the end. Needs root, after backup-setup. Run: sudo bash tests/backup_versions_e2e.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
[[ $EUID -eq 0 ]] || { echo "run as root (sudo bash $0)" >&2; exit 1; }
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/        /' | head -20; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }
# in_setup CODE: run CODE with ente-ops.sh's functions and the real config loaded
in_setup() { ( . ./ente-ops.sh; CMD=test; set +e; load_env; eval "$1" ); }
export RCLONE_CONFIG=/root/.config/rclone/rclone.conf
rclone listremotes | grep -x 'backup:' >/dev/null || { echo "no backup remote: run backup-setup first" >&2; exit 1; }
ROOT=$(in_setup 'echo "$BACKUP_ROOT"' 2>/dev/null)
[[ $ROOT == backup:*/ ]] || { echo "cannot read BACKUP_ROOT" >&2; exit 1; }
P=ente-setup-e2e-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
D=$ROOT$P
T=$(mktemp -d)
# purge_prefix: delete every version and delete marker under the test prefix (the lifecycle rule would only drop them later)
purge_prefix() {
  python3 -I - "$RCLONE_CONFIG" "${ROOT#backup:}" "$P/" <<'PY'
import configparser, sys, boto3
from botocore.config import Config
conf, bucket, prefix = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3]
c = configparser.RawConfigParser(); c.read(conf); r = c["backup"]
s3 = boto3.client("s3", endpoint_url="https://" + r["endpoint"], region_name=r.get("region") or None,
                  aws_access_key_id=r["access_key_id"], aws_secret_access_key=r["secret_access_key"],
                  config=Config(s3={"addressing_style": "path"}))
n = 0
for page in s3.get_paginator("list_object_versions").paginate(Bucket=bucket, Prefix=prefix):
    for v in page.get("Versions", []) + page.get("DeleteMarkers", []):
        s3.delete_object(Bucket=bucket, Key=v["Key"], VersionId=v["VersionId"]); n += 1
print(n)
PY
}
trap 'purge_prefix >/dev/null 2>&1; rm -rf "$T"' EXIT

echo "== the bucket keeps old versions"
read -r st days <<<"$(in_setup 'backup_versions get' 2>/dev/null | tail -1)"
check "versioning is on and old versions expire after BACKUP_KEEP_DELETED_DAYS" \
  '[[ $st == Enabled && $days == "$(in_setup "echo \$BACKUP_KEEP_DELETED_DAYS" 2>/dev/null)" ]]' "$st $days"

echo "== a file the mirror deletes can be brought back"
mkdir -p "$T/src" "$T/back"
echo "photo one" >"$T/src/one"; echo "photo two" >"$T/src/two"
rclone sync "$T/src" "$D" 2>"$T/err"; RC=$?
check "mirror two files" '((RC == 0)) && [[ $(rclone lsf "$D" | sort | tr "\n" " ") == "one two " ]]' "$(cat "$T/err")"
sleep 2; since=$(date -Is); sleep 2
rm "$T/src/one"
rclone sync "$T/src" "$D" 2>"$T/err"; RC=$?
check "the next mirror run deletes it from the current files" '((RC == 0)) && [[ $(rclone lsf "$D") == two ]]' "$(cat "$T/err"; rclone lsf "$D")"
check "... but the bucket still has it as an old version" 'rclone lsf --s3-versions "$D" | grep "^one-v" >/dev/null' "$(rclone lsf --s3-versions "$D")"
rclone copy --s3-version-at "$since" "$D" "$T/back" 2>"$T/err"; RC=$?
check "the warning's command (copy --s3-version-at the last backup) brings it back, content intact" \
  '((RC == 0)) && [[ $(cat "$T/back/one" 2>/dev/null) == "photo one" && $(cat "$T/back/two" 2>/dev/null) == "photo two" ]]' "$(cat "$T/err"; ls "$T/back")"

echo "== clean up"
n=$(purge_prefix 2>&1); RC=$?
check "every version and delete marker under the test prefix is removed" \
  '((RC == 0)) && [[ -z $(rclone lsf --s3-versions "$D" 2>/dev/null) ]]' "$n"

echo
echo "$PASS passed, $FAIL failed"
((FAIL == 0))
