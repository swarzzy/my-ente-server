#!/usr/bin/env bash
# Tests for `ente-setup.sh update`: a failed download changes nothing (image-pins and the rollback point image-pins.prev stay
# as they were), a real update moves the pins and keeps the old ones as the rollback point, and a re-run keeps that point.
# docker, docker compose and systemd are stubs, so this runs anywhere bash is and changes nothing outside a temp dir.
# Run: bash tests/test_update.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
# FAIL_PULL=museum|web|postgres makes that download fail; BACKUP=ok|fail: a backup service exists and its run works or
# fails (unset: no backup configured); PING_FAIL=1: museum does not answer after the update. Every docker compose call is
# logged to $T/dc.log.
update_run() {
  : >"$T/dc.log"
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-setup.sh"
    ENTE_DIR=$T/ente PINS=$T/ente/image-pins
    set +e
    load_env
    systemctl() {
      case "$*" in
        "cat ente-backup.service") [[ -n ${BACKUP:-} ]] ;;
        "start ente-backup.service") echo "backup ran" >>"$T/dc.log"; [[ $BACKUP == ok ]] ;;
        *) return 1 ;;
      esac
    }
    ensure_pins() { :; }; write_override() { :; }; wait_healthy() { :; }; url_ok() { [[ -z ${PING_FAIL:-} ]]; }
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

echo "== the backup before the update (the rollback point)"
reset; LATEST=3 BACKUP=ok update_run; RC=$?
check "with a backup service: a backup runs first, then the update" \
  '((RC == 0)) && [[ $(head -1 "$T/dc.log") == "backup ran" && $(cat "$T/ente/image-pins") == "$NEW" ]]' "$(cat "$T/dc.log"; tail -3 "$T/out")"
reset; LATEST=3 BACKUP=fail update_run; RC=$?
check "the backup fails: no update at all" \
  '((RC != 0)) && grep -q "backup failed; not updating" "$T/out" && unchanged && ! grep -qx "up -d" "$T/dc.log"' "$(tail -3 "$T/out")"
reset; LATEST=3 update_run
check "no backup configured: says so and updates anyway" 'grep -q "updating without a rollback point" "$T/out"' "$(cat "$T/out")"

echo "== museum does not come back after the update"
reset; LATEST=3 PING_FAIL=1 update_run; RC=$?
check "update fails and points at the previous versions" '((RC != 0)) && grep -q "museum /ping fails after the update; the previous versions are in" "$T/out"' "$(tail -3 "$T/out")"
check "... which hold the builds that ran before" '[[ $(cat "$T/ente/image-pins.prev") == "$OLD" ]]' "$(cat "$T/ente/image-pins.prev")"

echo "== ensure_pins: a pinned build that is gone from the registry"
# pins_run: ensure_pins with docker stubbed: GONE=1 makes the pinned builds unpullable; RUNNING=1 gives museum and web
# running containers whose images are digest 5 and 6; :latest is digest 9 and 10
pins_run() {
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-setup.sh"
    ENTE_DIR=$T/ente PINS=$T/ente/image-pins
    set +e
    load_env
    dc() { [[ $1 == ps && -n ${RUNNING:-} ]] && echo "cid-$3"; return 0; }
    docker() {
      case "$*" in
        "image inspect "*"@sha256:"* | "pull -q "*"@sha256:"*) [[ -z ${GONE:-} ]] ;;
        "inspect -f {{.Image}} cid-museum") echo img-museum ;;
        "inspect -f {{.Image}} cid-web") echo img-web ;;
        *"img-museum") echo "$M@sha256:$(d 5)" ;;
        *"img-web") echo "$W@sha256:$(d 6)" ;;
        *" $M:latest") echo "$M@sha256:$(d 9)" ;;
        *" $W:latest") echo "$W@sha256:$(d 10)" ;;
        *) echo "unexpected docker $*" >&2; return 1 ;;
      esac
    }
    ensure_pins ) >"$T/out" 2>&1
}
reset; pins_run
check "pins still pullable: kept as they are" '[[ $(cat "$T/ente/image-pins") == "$OLD" ]] && ! grep -q WARN "$T/out"' "$(cat "$T/out")"
reset; GONE=1 RUNNING=1 pins_run
check "pins gone, containers running: pinned to the running builds, with a warning" \
  '[[ $(cat "$T/ente/image-pins") == "$(printf "museum %s\nweb %s" "$M@sha256:$(d 5)" "$W@sha256:$(d 6)")" ]] && grep -q "can no longer be pulled" "$T/out"' "$(cat "$T/ente/image-pins" "$T/out")"
reset; GONE=1 pins_run
check "pins gone, nothing running: pinned to the latest builds" \
  '[[ $(cat "$T/ente/image-pins") == "$(printf "museum %s\nweb %s" "$M@sha256:$(d 9)" "$W@sha256:$(d 10)")" ]]' "$(cat "$T/ente/image-pins" "$T/out")"

summary
