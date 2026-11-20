#!/usr/bin/env bash
# Runs tests/proxy_browser_e2e.py on the server (as root) in the official Playwright container:
# opens registration for a throwaway account, turns the proxy on, answers the test's hand-offs, then deletes the account,
# closes registration again (the admin stays) and restores the proxy state. The first run builds a local image with Playwright
# installed and keeps it (about 5.5 GB on disk), so later runs skip the download; KEEP_IMAGE=0 removes it afterwards.
# Needs Docker (installed by `install`) and S3_PROXY_HOST.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
DOMAIN=$(sed -n 's/^DOMAIN=\([^ #]*\).*/\1/p' ente-setup.env)
PROXY=$(sed -n 's/^S3_PROXY_HOST=\([^ #]*\).*/\1/p' ente-setup.env)
REAL=$(python3 -c 'import yaml; print(yaml.safe_load(open("/opt/my-ente/museum.yaml"))["s3"]["b2-eu-cen"]["endpoint"])')
BASE=mcr.microsoft.com/playwright/python:v1.49.0-noble
IMAGE=ente-e2e-playwright:1.49.0 # BASE + the playwright package
M=/opt/my-ente/museum.yaml STATE=/var/lib/ente-setup/s3-proxy
ORIG=$(cat "$STATE" 2>/dev/null || echo off)
EMAIL=${EMAIL:-"proxy-e2e-$(date +%s)@$DOMAIN"}  # EMAIL=... MODE=delete: only delete that leftover test account
W=$(mktemp -d /root/proxy-browser-e2e.XXXX); mkdir -p "$W/upload"; cp tests/proxy_browser_e2e.py "$W/"
psql() { (cd /opt/my-ente && docker compose exec -T postgres psql -U pguser -d ente_db -At -c "$1" </dev/null); }
locked=no; grep -qx '  disable-registration: true' "$M" && locked=yes
admin=$(sed -n 's/^  admins: \[\(.*\)\]$/\1/p' "$M")
cleanup() {
  echo "== cleanup"
  n=$(psql "select count(*) from users where encrypted_email is not null and user_id <> ${admin:-0} and creation_time > $T0")
  if [[ $n != 0 && ${MODE:-} != delete ]]; then
    echo "  test account still exists: deleting it in a second browser run"
    docker run --rm --ipc=host -v "$W":/w -w /w -e WEB="web.$DOMAIN" -e PROXY="$PROXY" -e REAL="$REAL" -e EMAIL="$EMAIL" -e MODE=delete "$IMAGE" \
      python proxy_browser_e2e.py 2>&1 | grep -E '^  (ok|FAIL)'
    n=$(psql "select count(*) from users where encrypted_email is not null and user_id <> ${admin:-0} and creation_time > $T0")
  fi
  if [[ $n == 0 ]]; then echo "  test account deleted"; else echo "  WARNING: the test account $EMAIL still exists; delete it in the web app"; fi
  if [[ $locked == yes ]]; then
    sed -i '/^# END ente-setup internal/i\  disable-registration: true' "$M"
    (cd /opt/my-ente && docker compose restart museum >/dev/null 2>&1)
  fi
  grep -qx '  disable-registration: true' "$M" && echo "  registration closed again"
  [[ $(sed -n 's/^  admins: \[\(.*\)\]$/\1/p' "$M") == "$admin" ]] && echo "  admin unchanged ($admin)"
  ./ente-s3-proxy.sh "$ORIG" </dev/null >/dev/null 2>&1 && echo "  proxy back to $ORIG"
  if [[ ${KEEP_IMAGE:-1} == 0 ]]; then
    docker rmi "$IMAGE" >/dev/null 2>&1; docker builder prune -af >/dev/null 2>&1; echo "  test image removed"
  fi
  rm -rf "$W"
}
T0=$(($(date +%s) * 1000000))
[[ ${MODE:-} != delete ]] || T0=0
trap cleanup EXIT

echo "== setup"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  printf 'FROM %s\nRUN pip install -q playwright==1.49.0\n' "$BASE" | docker build -q -t "$IMAGE" - >/dev/null || { echo "cannot build $IMAGE"; exit 1; }
  docker rmi "$BASE" >/dev/null 2>&1 || true # its layers stay in IMAGE
  echo "  built $IMAGE (kept for the next runs; KEEP_IMAGE=0 removes it)"
fi
if [[ $locked == yes ]]; then
  sed -i '/^  disable-registration: true$/d' "$M"
  (cd /opt/my-ente && docker compose restart museum >/dev/null 2>&1); sleep 5
  echo "  registration opened for the test"
fi
./ente-s3-proxy.sh on </dev/null >/dev/null 2>&1 || { echo "proxy on failed"; exit 1; }
echo "  proxy on"

docker run --rm --ipc=host -v "$W":/w -w /w -e WEB="web.$DOMAIN" -e PROXY="$PROXY" -e REAL="$REAL" -e EMAIL="$EMAIL" -e MODE="${MODE:-}" "$IMAGE" \
  python proxy_browser_e2e.py >"$W/out" 2>&1 &
pid=$!
while kill -0 $pid 2>/dev/null; do
  if [[ -e $W/need_code && ! -e $W/code.txt ]]; then
    sleep 3
    c=$(cd /opt/my-ente && docker compose logs --no-log-prefix --since 10m museum 2>/dev/null | grep -a "$EMAIL" | grep -oE 'Verification code: [0-9]{6}' | tail -1 | grep -oE '[0-9]{6}')
    [[ -z $c ]] || echo "$c" >"$W/code.txt"
  fi
  if [[ -e $W/need_bucket_check && ! -e $W/bucket_checked ]]; then
    # every object the browser uploaded through the proxy must be in the bucket and complete (a multipart upload exists only
    # once completed), with the size museum recorded for it
    if [[ -s $W/uploaded_keys ]]; then python3 tests/proxy_bucket_check.py "$W/uploaded_keys" >"$W/bucket.out" 2>&1
    else echo "FAIL no uploaded keys recorded" >"$W/bucket.out"; fi
    echo done >"$W/bucket_checked"
  fi
  if [[ -e $W/need_proxy_off && ! -e $W/proxy_off_done ]]; then
    ./ente-s3-proxy.sh off </dev/null >/dev/null 2>&1 && echo done >"$W/proxy_off_done"
  fi
  sleep 1
done
wait $pid; rc=$?
grep -E '^(==|  ok|  FAIL|    requests|RESULT)|Error|Traceback' "$W/out"
if [[ ${MODE:-} != delete ]]; then
  echo "== objects uploaded through the proxy, checked in the bucket"
  b=$(cat "$W/bucket.out" 2>/dev/null || echo "FAIL not checked")
  if [[ $b == PASS* ]]; then echo "  ok    ${b#PASS }"; else echo "  FAIL  ${b#FAIL }"; rc=1; fi
fi
[[ ! -e $W/upload-failed.png ]] || cp "$W/upload-failed.png" /root/proxy-e2e-upload-failed.png
exit $rc
