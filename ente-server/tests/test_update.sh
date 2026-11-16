#!/usr/bin/env bash
# Tests for `ente-setup.sh update`: a failed download changes nothing (image-pins and the rollback point image-pins.prev stay
# as they were), a real update moves the pins and keeps the old ones as the rollback point, and a re-run keeps that point.
# docker, docker compose and systemd are stubs, so this runs anywhere bash is and changes nothing outside a temp dir.
# Run: bash tests/test_update.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/        /' | head -20; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }

printf '%s\n' DOMAIN=photos.example.org S3_ENDPOINT=s3.example.net S3_REGION=r1 S3_BUCKET=photo \
  BACKUP_S3_ENDPOINT=b2.example.net BACKUP_S3_REGION=r2 BACKUP_S3_BUCKET=bk >"$T/env"
d() { printf '%064d' "$1"; } # a fake sha256 digest
M=ghcr.io/ente/server W=ghcr.io/ente/web
OLD="museum $M@sha256:$(d 1)
web $W@sha256:$(d 2)"
NEW="museum $M@sha256:$(d 3)
web $W@sha256:$(d 4)"
PREV="museum $M@sha256:$(d 7)
web $W@sha256:$(d 8)"

# update_run: cmd_update on $T/ente with stubs. LATEST=<n> makes :latest of both images digest n and n+1 (museum, web);
# FAIL_PULL=museum|web|postgres makes that download fail. Every docker compose call is logged to $T/dc.log.
update_run() {
  : >"$T/dc.log"
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-setup.sh"
    ENTE_DIR=$T/ente PINS=$T/ente/image-pins
    set +e
    load_env
    systemctl() { return 1; } # no backup service: no rollback-point backup in the test
    ensure_pins() { :; }; write_override() { :; }; wait_healthy() { :; }; url_ok() { :; }
    docker() {
      case "$*" in
        "pull -q $M:latest") [[ ${FAIL_PULL:-} != museum ]] ;;
        "pull -q $W:latest") [[ ${FAIL_PULL:-} != web ]] ;;
        "image inspect -f "*" $M:latest") echo "$M@sha256:$(d "$LATEST")" ;;
        "image inspect -f "*" $W:latest") echo "$W@sha256:$(d $((LATEST + 1)))" ;;
        "image prune -f") : ;;
        *) echo "unexpected docker $*" >&2; return 1 ;;
      esac
    }
    dc() { echo "$*" >>"$T/dc.log"; [[ "$*" != "pull -q postgres" || ${FAIL_PULL:-} != postgres ]]; }
    cmd_update ) >"$T/out" 2>&1
}
reset() { mkdir -p "$T/ente"; printf '%s\n' "$OLD" >"$T/ente/image-pins"; printf '%s\n' "$PREV" >"$T/ente/image-pins.prev"; }
unchanged() { [[ $(cat "$T/ente/image-pins") == "$OLD" && $(cat "$T/ente/image-pins.prev") == "$PREV" ]]; }

echo "== a failed download changes nothing"
for f in museum web postgres; do
  reset; LATEST=3 FAIL_PULL=$f update_run; RC=$?
  check "the $f download fails: update stops at it" '((RC != 0)) && grep -q "cannot pull .*${f/museum/server}" "$T/out"' "$(tail -3 "$T/out")"
  check "... image-pins and image-pins.prev are unchanged" 'unchanged' "$(cat "$T/ente/image-pins" "$T/ente/image-pins.prev")"
  check "... no container was recreated" '! grep -qx "up -d" "$T/dc.log"' "$(cat "$T/dc.log")"
done

echo "== a real update"
reset; LATEST=3 update_run; RC=$?
check "new builds: update succeeds" '((RC == 0))' "$(tail -3 "$T/out")"
check "... image-pins names the new builds" '[[ $(cat "$T/ente/image-pins") == "$NEW" ]]' "$(cat "$T/ente/image-pins")"
check "... image-pins.prev holds the builds that ran before (the rollback point)" '[[ $(cat "$T/ente/image-pins.prev") == "$OLD" ]]' "$(cat "$T/ente/image-pins.prev")"
check "... the containers are recreated" 'grep -qx "up -d" "$T/dc.log"' "$(cat "$T/dc.log")"
LATEST=3 update_run; RC=$?
check "re-run with nothing new: succeeds and keeps the rollback point" \
  '((RC == 0)) && [[ $(cat "$T/ente/image-pins") == "$NEW" && $(cat "$T/ente/image-pins.prev") == "$OLD" ]]' "$(tail -3 "$T/out")"

echo
echo "$PASS passed, $FAIL failed"
((FAIL == 0))
