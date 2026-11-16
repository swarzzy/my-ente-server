#!/usr/bin/env bash
# Tests install's edits against Ente's CURRENT quickstart (fetched from Ente's main branch, as install does): run_quickstart in
# a temp dir with docker stubbed, then apply_edits. Fails when the quickstart's output changed in a way the edits do not
# expect, before a real install does. Needs network (raw.githubusercontent.com), python3 with yaml, base64. Changes nothing
# outside a temp dir. Run: bash tests/test_quickstart.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/        /' | head -20; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }

printf '%s\n' DOMAIN=photos.example.org S3_ENDPOINT=s3.example.net S3_REGION=r1 S3_BUCKET=photos \
  BACKUP_S3_ENDPOINT=b2.example.net BACKUP_S3_REGION=r2 BACKUP_S3_BUCKET=bk >"$T/env"
printf '%s\n' S3_ACCESS_KEY=AKEY S3_SECRET_KEY='se/cret+key' >"$T/secrets"
mkdir -p "$T/bin" "$T/opt"
printf '#!/bin/sh\n[ "$*" = "compose version --short" ] && echo 2.30.0\n' >"$T/bin/docker"; chmod 755 "$T/bin/docker"
# in_setup CODE: source ente-setup.sh with the test config and ENTE_DIR=$T/opt/my-ente, docker stubbed, run CODE
in_setup() {
  ( ENV_FILE=$T/env SECRETS_FILE=$T/secrets CMD=test PATH=$T/bin:$PATH
    # shellcheck source=/dev/null
    . "$HERE/../ente-setup.sh"
    ENTE_DIR=$T/opt/my-ente
    set +e
    load_env
    eval "$1" )
}
y() { python3 -I -c "import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print($2)" "$T/opt/my-ente/$1" 2>&1; }
C=$T/opt/my-ente/compose.yaml M=$T/opt/my-ente/museum.yaml

echo "== the quickstart"
in_setup run_quickstart >"$T/out" 2>&1; RC=$?
check "the current quickstart runs and creates compose.yaml and museum.yaml" '((RC == 0)) && [[ -f $C && -f $M ]]' "$(tail -5 "$T/out")"
((RC == 0)) || { echo; echo "$PASS passed, $FAIL failed"; exit 1; }
cp "$M" "$T/museum.orig"

echo "== install's edits"
ino=$(stat -c %i "$M")
in_setup apply_edits >"$T/out" 2>&1; RC=$?
check "apply_edits accepts the quickstart's layout" '((RC == 0))' "$(tail -5 "$T/out")"
for p in 8080 3000 3002; do
  check "port $p is published on 127.0.0.1 only" 'grep -Eq "^ *- 127\.0\.0\.1:$p:$p( |\$)" "$C" && ! grep -Eq "^ *- $p:$p" "$C"' "$(grep -n "$p" "$C")"
done
check "the web app uses https://api.<domain>" '[[ $(y compose.yaml "d[\"services\"][\"web\"][\"environment\"][\"ENTE_API_ORIGIN\"]") == https://api.photos.example.org ]]' \
  "$(grep -n ENTE_API_ORIGIN "$C")"
check "public albums are on https://albums.<domain>" '[[ $(y museum.yaml "d[\"apps\"][\"public-albums\"]") == https://albums.photos.example.org ]]'
check "the bucket is the external photo bucket, keys from the secrets file" \
  '[[ $(y museum.yaml "sorted(d[\"s3\"][\"b2-eu-cen\"].items())") == "[('"'"'bucket'"'"', '"'"'photos'"'"'), ('"'"'endpoint'"'"', '"'"'s3.example.net'"'"'), ('"'"'key'"'"', '"'"'AKEY'"'"'), ('"'"'region'"'"', '"'"'r1'"'"'), ('"'"'secret'"'"', '"'"'se/cret+key'"'"')]" ]]' \
  "$(y museum.yaml "d[\"s3\"][\"b2-eu-cen\"]")"
check "the two unused buckets are gone and local buckets are off" \
  '[[ $(y museum.yaml "\",\".join(k for k in d[\"s3\"] if isinstance(d[\"s3\"][k], dict)), d[\"s3\"][\"are_local_buckets\"]") == "b2-eu-cen False" ]]' \
  "$(y museum.yaml "d[\"s3\"]")"
check "museum.yaml keeps its generated keys" \
  '[[ $(python3 -I -c "import sys, yaml; a, b = (yaml.safe_load(open(f)) for f in sys.argv[1:]); print(a[\"key\"] == b[\"key\"] and a[\"jwt\"] == b[\"jwt\"])" "$T/museum.orig" "$M") == True ]]'
check "museum.yaml is edited in place (same inode: the container bind-mounts it)" '[[ $(stat -c %i "$M") == "$ino" ]]'
check "the folder is private (700)" '[[ $(stat -c %a "$T/opt/my-ente") == 700 ]]'
sha=$(sha256sum "$C" "$M")
in_setup apply_edits >"$T/out" 2>&1; RC=$?
check "a second run succeeds and changes nothing" '((RC == 0)) && [[ $(sha256sum "$C" "$M") == "$sha" ]]' "$(tail -5 "$T/out")"
printf '%s\n' S3_ACCESS_KEY= S3_SECRET_KEY= >"$T/secrets"
in_setup apply_edits >"$T/out" 2>&1; RC=$?
check "a re-run without keys in the secrets file keeps the keys in museum.yaml" '((RC == 0)) && [[ $(sha256sum "$C" "$M") == "$sha" ]]' "$(tail -5 "$T/out")"

echo "== a changed layout is refused"
cp "$C" "$T/compose.good"
sed -i 's/^\(  *\)minio:$/\1minio2:/' "$C"
in_setup apply_edits >"$T/out" 2>&1; RC=$?
check "an unexpected service: refused, nothing patched blindly" '((RC != 0)) && grep -q "no longer matches the expected layout" "$T/out"' "$(tail -3 "$T/out")"
cp "$T/compose.good" "$C"
in_setup 'run_quickstart' >"$T/out" 2>&1; RC=$?
check "run_quickstart on an existing install: skipped" '((RC == 0)) && grep -q "skipping quickstart" "$T/out"' "$(tail -3 "$T/out")"

echo
echo "$PASS passed, $FAIL failed"
((FAIL == 0))
