#!/usr/bin/env bash
# End-to-end tests of `ente-setup.sh proxy` on a deployed server, as root. Needs S3_PROXY_HOST in ente-setup.env and
# its DNS record. Touches only the proxy (Caddy reloads, the rewriter service) and leaves the proxy as it found it.
# Run: sudo bash tests/proxy_e2e.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
SETUP=./ente-setup.sh STATE=/var/lib/ente-setup/s3-proxy
DOMAIN=$(sed -n 's/^DOMAIN=\([^ #]*\).*/\1/p' ente-setup.env)
PROXY=$(sed -n 's/^S3_PROXY_HOST=\([^ #]*\).*/\1/p' ente-setup.env)
[[ -n $PROXY ]] || { echo "S3_PROXY_HOST is not set in ente-setup.env" >&2; exit 1; }
ORIG=$(cat "$STATE" 2>/dev/null || echo off)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/        /' | tail -15; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }
run() { "$SETUP" "$@" </dev/null >"$T/out" 2>&1; RC=$?; }  # RC: exit code of the last run
api_rewrites() { curl -sS -m 10 -o /dev/null -D - "https://api.$DOMAIN/ping" | grep -i '^x-ente-link-rewrite: on' >/dev/null; }
api_code() { curl -sS -m 10 -o /dev/null -w '%{http_code}' "$@"; }
caddy_has_s3() { grep -q "^$PROXY {" /etc/caddy/Caddyfile; }
# probe_status: HTTP status of a pre-signed GET, through the proxy, for an object that exists
mkobj() {
  python3 - "$PROXY" <<'PY'
import sys, boto3, yaml
from botocore.config import Config
m = yaml.safe_load(open("/opt/my-ente/museum.yaml"))["s3"]["b2-eu-cen"]
c = boto3.client("s3", endpoint_url="https://" + m["endpoint"], region_name=m["region"], aws_access_key_id=m["key"],
                 aws_secret_access_key=m["secret"], config=Config(s3={"addressing_style": "path"}, signature_version="s3v4"))
c.put_object(Bucket=m["bucket"], Key="e2e-proxy-test/old-link", Body=b"still here")
u = c.generate_presigned_url("get_object", Params={"Bucket": m["bucket"], "Key": "e2e-proxy-test/old-link"}, ExpiresIn=3600)
print(u.replace("https://%s/" % m["endpoint"], "https://%s/" % sys.argv[1], 1))
PY
}
rmobj() {
  python3 - <<'PY'
import boto3, yaml
from botocore.config import Config
m = yaml.safe_load(open("/opt/my-ente/museum.yaml"))["s3"]["b2-eu-cen"]
boto3.client("s3", endpoint_url="https://" + m["endpoint"], region_name=m["region"], aws_access_key_id=m["key"],
             aws_secret_access_key=m["secret"], config=Config(s3={"addressing_style": "path"})).delete_object(Bucket=m["bucket"], Key="e2e-proxy-test/old-link")
PY
}

echo "== harness"
false; RC=$?; check "a failing command is seen as failing (harness self-test)" '[[ $RC -ne 0 ]]'
true; RC=$?; check "a succeeding command is seen as succeeding (harness self-test)" '[[ $RC -eq 0 ]]'

echo "== off"
run proxy off; check "proxy off succeeds" '[[ $RC -eq 0 ]]' "$(cat "$T/out")"
check "state file says off" '[[ $(cat $STATE) == off ]]'
check "API answers without the rewriter" '! api_rewrites'
check "proxy site stays configured while off" 'caddy_has_s3'
run proxy status; check "proxy status passes while off" '[[ $RC -eq 0 ]] && grep -q "S3 proxy is off" "$T/out"' "$(cat "$T/out")"

echo "== on"
run proxy on; check "proxy on succeeds (self-test included)" '[[ $RC -eq 0 ]]' "$(cat "$T/out")"
check "state file says on" '[[ $(cat $STATE) == on ]]'
check "API goes through the rewriter" 'api_rewrites'
h0=$(sha256sum /etc/caddy/Caddyfile)
run proxy on; check "proxy on again is a no-op" '[[ $RC -eq 0 && $(sha256sum /etc/caddy/Caddyfile) == "$h0" ]]' "$(cat "$T/out")"
run check; check "check passes with the proxy on" '[[ $RC -eq 0 ]] && grep -q "proxy ON" "$T/out"' "$(grep -E "FAIL|proxy" "$T/out")"
run install; check "install keeps the proxy on" '[[ $RC -eq 0 && $(cat $STATE) == on ]] && api_rewrites' "$(tail -5 "$T/out")"

echo "== the rewriter fails"
systemctl stop ente-s3-rewrite.service
check "API still answers when the rewriter is down (museum fallback)" '[[ $(api_code "https://api.$DOMAIN/ping") == 200 ]] && ! api_rewrites'
st=$(api_code -X POST -H 'Content-Type: application/json' -d '{"email":"fallback-probe@'"$DOMAIN"'","purpose":"signup"}' "https://api.$DOMAIN/users/ott")
check "requests with a body also fall back (got $st, not 502)" '[[ $st != 502 && $st != 000 ]]'
run check; check "check reports the dead rewriter" '[[ $RC -ne 0 ]] && grep -q "FAIL  link rewriter not running" "$T/out"' "$(grep FAIL "$T/out")"
run proxy on; check "proxy on restarts the rewriter" '[[ $RC -eq 0 ]] && systemctl is-active --quiet ente-s3-rewrite.service' "$(cat "$T/out")"
sleep 11 # Caddy retries the rewriter after fail_duration
check "API goes through the rewriter again" 'api_rewrites'
pid=$(systemctl show -p MainPID --value ente-s3-rewrite.service); kill -9 "$pid"; sleep 4
check "systemd restarts a killed rewriter" '[[ $(systemctl show -p MainPID --value ente-s3-rewrite.service) != "$pid" ]] && systemctl is-active --quiet ente-s3-rewrite.service'

echo "== a failed self-test rolls back"
run proxy off
sed "s/^S3_PROXY_HOST=.*/S3_PROXY_HOST=no-dns-e2e.$DOMAIN/" ente-setup.env >"$T/bad.env"
ENV_FILE=$T/bad.env "$SETUP" proxy on </dev/null >"$T/out" 2>&1; RC=$?
check "proxy on fails when the proxy host does not work" '[[ $RC -ne 0 ]] && grep -q "self-test failed" "$T/out"' "$(tail -5 "$T/out")"
check "and leaves the proxy off" '[[ $(cat $STATE) == off ]] && ! api_rewrites'
run proxy off; check "the real config is back" '[[ $RC -eq 0 ]] && caddy_has_s3 && ! grep -q no-dns-e2e /etc/caddy/Caddyfile' "$(cat "$T/out")"

echo "== links handed out while on keep working after off"
run proxy on
url=$(mkobj)
run proxy off
check "a proxied link still downloads after proxy off" '[[ $(curl -sS -m 20 "$url") == "still here" ]]'
rmobj

echo "== removing the feature"
sed "s/^S3_PROXY_HOST=.*/S3_PROXY_HOST=/" ente-setup.env >"$T/none.env"
ENV_FILE=$T/none.env "$SETUP" install </dev/null >"$T/out" 2>&1; RC=$?
check "install without S3_PROXY_HOST succeeds" '[[ $RC -eq 0 ]]' "$(tail -5 "$T/out")"
check "rewriter service is removed" '! systemctl cat ente-s3-rewrite.service >/dev/null 2>&1 && [[ ! -e /usr/local/lib/ente-setup/ente_s3_rewrite.py ]]'
check "proxy site and state are removed" '! caddy_has_s3 && [[ ! -e $STATE ]] && ! api_rewrites'
ENV_FILE=$T/none.env "$SETUP" proxy on </dev/null >"$T/out" 2>&1; RC=$?
check "proxy on refuses without S3_PROXY_HOST" '[[ $RC -ne 0 ]] && grep -q "S3_PROXY_HOST" "$T/out"'
run install; check "install with S3_PROXY_HOST brings it back (off)" '[[ $RC -eq 0 ]] && caddy_has_s3 && systemctl is-active --quiet ente-s3-rewrite.service && ! api_rewrites' "$(tail -5 "$T/out")"

echo "== S3 through the proxy (tests/proxy_e2e_s3.py)"
if python3 tests/proxy_e2e_s3.py >"$T/out" 2>&1; then pass "$(grep -E '^Ran ' "$T/out"), $(grep -o '50 MB through.*s' "$T/out" | head -1)"
else fail "S3 end-to-end tests" "$(cat "$T/out")"; fi

echo "== back to $ORIG"
run proxy "$ORIG"; check "proxy restored to $ORIG" '[[ $RC -eq 0 && $(cat $STATE) == "$ORIG" ]]' "$(cat "$T/out")"
echo
echo "$PASS passed, $FAIL failed"
((FAIL == 0))
