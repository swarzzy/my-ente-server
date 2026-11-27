#!/usr/bin/env bash
# Tests for `ente-setup.sh update` and `ente-ops.sh pg-update` / `rclone-update` / `news` (at the end): a failed download changes nothing (image-pins and the rollback point image-pins.prev stay
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


echo "== pg-update: Postgres minor releases"
# pg_run: ente-ops.sh pg-update with stubs. The running build is 15.1; PG_NEW=<n> makes the pulled postgres:15 build 15.<n> (unset: 15.1,
# current). STAMP: age of the last good backup (default 2 hours; "none" for none); RUNNING=<unit> is running now; FAIL_PULL,
# PING_FAIL. docker compose calls go to $T/dc.log.
pg_run() {
  : >"$T/dc.log"; mkdir -p "$T/state"; rm -f "$T/state/last-ok-s3"
  [[ ${STAMP:-} == none ]] || date -Is -d "${STAMP:-2 hours} ago" >"$T/state/last-ok-s3"
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-ops.sh"
    ENTE_DIR=$T/ente BACKUP_STATE=$T/state
    set +e
    systemctl() { [[ $* == "show ${RUNNING:-none} -p ActiveState --value" ]] && echo activating; return 0; }
    wait_healthy() { echo "healthy $1" >>"$T/dc.log"; }; url_ok() { [[ -z ${PING_FAIL:-} ]]; }
    dc() {
      echo "$*" >>"$T/dc.log"
      case "$*" in
        "ps -q postgres") echo cid-pg ;;
        "pull -q postgres") [[ -z ${FAIL_PULL:-} ]] ;;
      esac
    }
    docker() {
      case "$*" in
        "inspect -f {{.Config.Image}} cid-pg") echo postgres:15 ;;
        "inspect -f {{.Image}} cid-pg") echo sha256:1 ;;
        "image inspect -f {{.Id}} postgres:15") echo "sha256:${PG_NEW:-1}" ;;
        "image inspect -f {{range .Config.Env}}{{println .}}{{end}} sha256:"*) local a="$*"; [[ -z ${PG_SAME:-} ]] || a=1; printf 'PATH=/usr/bin\nPG_VERSION=15.%s\n' "${a##*sha256:}" ;;
        "image prune -f") echo prune >>"$T/dc.log" ;;
        *) echo "unexpected docker $*" >&2; return 1 ;;
      esac
    }
    main pg-update ) >"$T/out" 2>&1
}
changed() { grep -qx "up -d postgres" "$T/dc.log"; }
pg_run; RC=$?
check "the running build is the newest: nothing changes" '((RC == 0)) && grep -q "postgres 15.1 is current" "$T/out" && ! changed' "$(cat "$T/out" "$T/dc.log")"
PG_NEW=2 pg_run; RC=$?
check "a newer 15.x and a fresh backup: postgres recreated, then museum restarted and checked, old image pruned" \
  '((RC == 0)) && grep -q "postgres 15.1 -> 15.2" "$T/out" && grep -q "updated to 15.2" "$T/out" &&
   [[ $(grep -nE "^(up -d postgres|healthy postgres|restart museum|healthy museum|prune)$" "$T/dc.log" | cut -d: -f2 | paste -sd,) == "up -d postgres,healthy postgres,restart museum,healthy museum,prune" ]]' \
  "$(cat "$T/out" "$T/dc.log")"
PG_NEW=2 PG_SAME=1 pg_run; RC=$?
check "a rebuilt image of the same release: applied, and the log says so" '((RC == 0)) && grep -q "postgres 15.1: a rebuilt image" "$T/out" && changed' "$(cat "$T/out")"
PG_NEW=2 STAMP='40 hours' pg_run; RC=$?
check "the last good backup is 40 h old: not applied, and it fails (an alert)" '((RC != 0)) && grep -q "no good backup in the last 36 h" "$T/out" && ! changed' "$(cat "$T/out")"
PG_NEW=2 STAMP=none pg_run; RC=$?
check "never a good backup: not applied, fails" '((RC != 0)) && grep -q "no good backup" "$T/out" && ! changed' "$(cat "$T/out")"
for u in ente-backup.service ente-verify.service; do
  PG_NEW=2 RUNNING=$u pg_run; RC=$?
  check "$u is running: waits for next week, no failure" '((RC == 0)) && grep -q "$u is running" "$T/out" && ! changed' "$(cat "$T/out")"
done
PG_NEW=2 FAIL_PULL=1 pg_run; RC=$?
check "the download fails: nothing changes, it fails" '((RC != 0)) && grep -q "cannot pull postgres:15" "$T/out" && ! changed' "$(cat "$T/out")"
PG_NEW=2 PING_FAIL=1 pg_run; RC=$?
check "museum does not answer afterwards: it fails (an alert)" '((RC != 0)) && grep -q "museum /ping fails after the postgres update" "$T/out"' "$(cat "$T/out")"


echo "== rclone-update"
# rc_run: ente-ops.sh rclone-update with a fake rclone binary ($T/rb/rclone, version v1.$V.0 (FROM, default 70) in the file itself, as a real
# selfupdate replaces the binary). TO=<n>: selfupdate brings v1.<n>.0 (unset: nothing newer); SU_FAIL, LSF_FAIL=backup-crypt:|ente-s3:
# make selfupdate or reading that bucket fail; DPKG=1: the binary comes from a package; RUNNING=<unit> is running now.
rc_run() {
  mkdir -p "$T/rb"; [[ -n ${KEEP:-} ]] || rm -f "$T/rb/rclone.prev"
  cat >"$T/rb/rclone" <<'X'
#!/bin/bash
V=70
case $1 in
  version) echo "rclone v1.$V.0" ;;
  selfupdate) [[ -z ${SU_FAIL:-} ]] || exit 1; [[ -z ${TO:-} ]] || sed -i "s/^V=.*/V=$TO/" "$0" ;;
  lsf) [[ $2 != "${LSF_FAIL:-none}"* ]] ;;
  *) exit 1 ;;
esac
X
  sed -i "s/^V=.*/V=${FROM:-70}/" "$T/rb/rclone"; chmod 755 "$T/rb/rclone"
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test PATH=$T/rb:$PATH
    # shellcheck source=/dev/null
    . "$HERE/../ente-ops.sh"
    ENTE_DIR=$T/ente
    set +e
    systemctl() { [[ $* == "show ${RUNNING:-none} -p ActiveState --value" ]] && echo activating; return 0; }
    dpkg() { [[ -n ${DPKG:-} ]]; }
    main rclone-update ) >"$T/out" 2>&1
}
ver() { "$T/rb/rclone" version; }
rc_run; RC=$?
check "nothing newer: rclone stays, no failure" '((RC == 0)) && grep -q "rclone v1.70.0 is current" "$T/out" && [[ $(ver) == "rclone v1.70.0" ]]' "$(cat "$T/out")"
TO=72 rc_run; RC=$?
check "a new release that reads both buckets: kept, the previous binary saved as .prev" \
  '((RC == 0)) && grep -q "rclone v1.70.0 -> v1.72.0" "$T/out" && [[ $(ver) == "rclone v1.72.0" && $("$T/rb/rclone.prev" version) == "rclone v1.70.0" && ! -e $T/rb/rclone.old ]]' "$(cat "$T/out")"
FROM=72 KEEP=1 rc_run; RC=$?
check "... next week, nothing newer: .prev still holds the older version" '((RC == 0)) && [[ $("$T/rb/rclone.prev" version) == "rclone v1.70.0" && ! -e $T/rb/rclone.old ]]' "$(cat "$T/out")"
for b in backup-crypt: ente-s3:; do
  TO=72 LSF_FAIL=$b rc_run; RC=$?
  check "a new release that cannot read $b: the previous one goes back, and it fails (an alert)" \
    '((RC != 0)) && grep -q "rclone v1.72.0 cannot read the buckets: back to v1.70.0" "$T/out" && [[ $(ver) == "rclone v1.70.0" ]]' "$(cat "$T/out")"
done
TO=72 SU_FAIL=1 rc_run; RC=$?
check "selfupdate fails: it fails, rclone unchanged" '((RC != 0)) && grep -q "selfupdate failed (still v1.70.0)" "$T/out" && [[ $(ver) == "rclone v1.70.0" ]]' "$(cat "$T/out")"
TO=72 DPKG=1 rc_run; RC=$?
check "rclone from a Debian package: left to apt" '((RC == 0)) && grep -q "apt updates it" "$T/out" && [[ $(ver) == "rclone v1.70.0" ]]' "$(cat "$T/out")"
TO=72 RUNNING=ente-backup.service rc_run; RC=$?
check "a backup is running: waits for next week" '((RC == 0)) && grep -q "ente-backup.service is running" "$T/out" && [[ $(ver) == "rclone v1.70.0" ]]' "$(cat "$T/out")"


echo "== news: newer Ente builds"
# news_run: ente-ops.sh news with the registry stubbed: LM / LW = the digest numbers of museum's and web's latest (the pins are
# 1 and 2); REG_DOWN: the registry does not answer; NO_ALERT: opsbot not installed; NO_CHAT: Ente's alerts off (TG_CHAT_ID empty,
# opsbot still there for others); SEND_FAIL: Telegram rejects. Sent messages go to $T/sent.
news_run() {
  reset; rm -f "$T/sent"
  printf '#!/bin/bash\n[[ -z $SEND_FAIL ]] || exit 1\n{ echo "TITLE $1"; cat; } >"%s"\n' "$T/sent" >"$T/alert"; chmod 755 "$T/alert"
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test SEND_FAIL=${SEND_FAIL:-}
    # shellcheck source=/dev/null
    . "$HERE/../ente-ops.sh"
    ENTE_DIR=$T/ente PINS=$T/ente/image-pins ALERT_BIN=$T/alert
    [[ -z ${NO_ALERT:-} ]] || ALERT_BIN=$T/none
    set +e
    load_env; TG_CHAT_ID=$([[ -n ${NO_CHAT:-} ]] || echo -1001234567); load_env() { :; }
    docker() {
      [[ -z ${REG_DOWN:-} ]] || return 1
      case "$1 $2 $3 $4" in
        "buildx imagetools inspect $M:latest") echo "sha256:$(d "${LM:-1}") 2026-11-15 05:06:30.1 +0000 UTC" ;;
        "buildx imagetools inspect $W:latest") echo "sha256:$(d "${LW:-2}") 2026-11-18 07:27:37.6 +0000 UTC" ;;
        "buildx imagetools inspect $M@sha256:"*) echo "${4#*@} 2026-10-01 01:00:00.0 +0000 UTC" ;;
        "buildx imagetools inspect $W@sha256:"*) echo "${4#*@} 2026-11-11 07:24:48.1 +0000 UTC" ;;
        *) echo "unexpected docker $*" >&2; return 1 ;;
      esac
    }
    main news ) >"$T/out" 2>&1
}
news_run; RC=$?
check "both builds are the latest: nothing sent" '((RC == 0)) && grep -q "Ente is current" "$T/out" && [[ ! -e $T/sent ]]' "$(cat "$T/out")"
LW=4 news_run; RC=$?
check "a newer web build: Telegram gets it, with both build dates and what to do" \
  '((RC == 0)) && grep -q "^TITLE 🆕 Newer Ente builds for " "$T/sent" && grep -q "^web: running the build of 2026-11-11, a newer one is from 2026-11-18$" "$T/sent" &&
   ! grep -q "^museum" "$T/sent" && grep -q "release notes.*ente-setup.sh update$" "$T/sent"' "$(cat "$T/out" "$T/sent" 2>&1)"
LM=3 LW=4 news_run; RC=$?
check "both newer: both listed" '((RC == 0)) && grep -q "^museum: running the build of 2026-10-01, a newer one is from 2026-11-15$" "$T/sent" && grep -q "^web:" "$T/sent"' "$(cat "$T/sent" 2>&1)"
LW=4 NO_ALERT=1 news_run; RC=$?
check "without Telegram alerts: only printed" '((RC == 0)) && grep -q "^web: running" "$T/out" && [[ ! -e $T/sent ]]' "$(cat "$T/out")"
LW=4 NO_CHAT=1 news_run; RC=$?
check "Ente's alerts off (TG_CHAT_ID empty) while opsbot stays for others: only printed" '((RC == 0)) && grep -q "^web: running" "$T/out" && [[ ! -e $T/sent ]]' "$(cat "$T/out")"
LW=4 SEND_FAIL=1 news_run; RC=$?
check "Telegram rejects it: it fails (the unit's alert retries the message)" '((RC != 0)) && grep -q "could not send to Telegram" "$T/out"' "$(cat "$T/out")"
REG_DOWN=1 news_run; RC=$?
check "the registry does not answer: it fails, nothing sent" '((RC != 0)) && grep -q "cannot ask the registry" "$T/out" && [[ ! -e $T/sent ]]' "$(cat "$T/out")"

summary
