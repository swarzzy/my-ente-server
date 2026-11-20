#!/usr/bin/env bash
# End-to-end tests of ente-s3-proxy.sh on a deployed server, as root. Needs S3_PROXY_HOST in ente-setup.env and its DNS
# record. Touches only the proxy (Caddy reloads, the rewriter service) and leaves it as it found it (installed or not, on/off).
# Run: sudo bash tests/proxy_e2e.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
SETUP=./ente-setup.sh OPS=./ente-ops.sh PROXYSH=./ente-s3-proxy.sh STATE=/var/lib/ente-setup/s3-proxy SITE=/etc/caddy/ente.d/sites/s3-proxy.caddy
DOMAIN=$(sed -n 's/^DOMAIN=\([^ #]*\).*/\1/p' ente-setup.env)
PROXY=$(sed -n 's/^S3_PROXY_HOST=\([^ #]*\).*/\1/p' ente-setup.env)
[[ -n $PROXY ]] || { echo "S3_PROXY_HOST is not set in ente-setup.env" >&2; exit 1; }
ORIG=$(cat "$STATE" 2>/dev/null || echo off)
WAS_INSTALLED=no; [[ -e $SITE ]] && WAS_INSTALLED=yes
run() { "$SETUP" "$@" </dev/null >"$T/out" 2>&1; RC=$?; }  # RC: exit code of the last run
ops() { "$OPS" "$@" </dev/null >"$T/out" 2>&1; RC=$?; }
prx() { "$PROXYSH" "$@" </dev/null >"$T/out" 2>&1; RC=$?; }
api_rewrites() { curl -sS -m 10 -o /dev/null -D - "https://api.$DOMAIN/ping" | grep -i '^x-ente-link-rewrite: on' >/dev/null; }
api_code() { curl -sS -m 10 -o /dev/null -w '%{http_code}' "$@"; }
caddy_has_s3() { [[ -e $SITE ]] && grep -q "^$PROXY {" "$SITE"; }
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

echo "== install"
prx install; check "ente-s3-proxy.sh install succeeds" '[[ $RC -eq 0 ]]' "$(cat "$T/out")"
check "the proxy site is in its own file" 'caddy_has_s3 && ! grep -q "^$PROXY {" /etc/caddy/Caddyfile'
check "the main Caddyfile only has the hooks" 'grep -q "ente.d/api-upstream.caddy" /etc/caddy/Caddyfile && grep -q "ente.d/sites/\*.caddy" /etc/caddy/Caddyfile'
h0=$(sha256sum /etc/caddy/Caddyfile "$SITE" /etc/caddy/ente.d/api-upstream.caddy)
prx install; check "install again changes nothing" '[[ $RC -eq 0 && $(sha256sum /etc/caddy/Caddyfile "$SITE" /etc/caddy/ente.d/api-upstream.caddy) == "$h0" ]]' "$(cat "$T/out")"

echo "== off"
prx off; check "proxy off succeeds" '[[ $RC -eq 0 ]]' "$(cat "$T/out")"
check "state file says off" '[[ $(cat $STATE) == off ]]'
check "API answers without the rewriter" '! api_rewrites'
check "proxy site stays configured while off" 'caddy_has_s3'
prx status; check "status passes while off" '[[ $RC -eq 0 ]] && grep -q "S3 proxy is off" "$T/out"' "$(cat "$T/out")"
prx check; check "check passes while off and prints only check lines" '[[ $RC -eq 0 ]] && ! grep -vqE "^  (OK|WARN)  " "$T/out"' "$(cat "$T/out")"

echo "== on"
prx on; check "proxy on succeeds (self-test included)" '[[ $RC -eq 0 ]]' "$(cat "$T/out")"
check "state file says on" '[[ $(cat $STATE) == on ]]'
check "API goes through the rewriter" 'api_rewrites'
h0=$(sha256sum /etc/caddy/Caddyfile "$SITE" /etc/caddy/ente.d/api-upstream.caddy)
prx on; check "proxy on again is a no-op" '[[ $RC -eq 0 && $(sha256sum /etc/caddy/Caddyfile "$SITE" /etc/caddy/ente.d/api-upstream.caddy) == "$h0" ]]' "$(cat "$T/out")"
ops check; check "ente-ops.sh check includes the proxy and passes" '[[ $RC -eq 0 ]] && grep -q "== s3 proxy" "$T/out" && grep -q "proxy ON" "$T/out"' "$(grep -E "FAIL|proxy" "$T/out")"
run install; check "ente-setup.sh install leaves the proxy on" '[[ $RC -eq 0 && $(cat $STATE) == on ]] && api_rewrites && caddy_has_s3' "$(tail -5 "$T/out")"

echo "== the rewriter fails"
systemctl stop ente-s3-rewrite.service
check "API still answers when the rewriter is down (museum fallback)" '[[ $(api_code "https://api.$DOMAIN/ping") == 200 ]] && ! api_rewrites'
st=$(api_code -X POST -H 'Content-Type: application/json' -d '{"email":"fallback-probe@'"$DOMAIN"'","purpose":"signup"}' "https://api.$DOMAIN/users/ott")
check "requests with a body also fall back (got $st, not 502)" '[[ $st != 502 && $st != 000 ]]'
ops check; check "ente-ops.sh check reports the dead rewriter" '[[ $RC -ne 0 ]] && grep -q "FAIL  link rewriter not running" "$T/out"' "$(grep FAIL "$T/out")"
prx on; check "proxy on restarts the rewriter" '[[ $RC -eq 0 ]] && systemctl is-active --quiet ente-s3-rewrite.service' "$(cat "$T/out")"
sleep 11 # Caddy retries the rewriter after fail_duration
check "API goes through the rewriter again" 'api_rewrites'
pid=$(systemctl show -p MainPID --value ente-s3-rewrite.service); kill -9 "$pid"; sleep 4
check "systemd restarts a killed rewriter" '[[ $(systemctl show -p MainPID --value ente-s3-rewrite.service) != "$pid" ]] && systemctl is-active --quiet ente-s3-rewrite.service'

echo "== a failed self-test rolls back"
prx off
sed "s/^S3_PROXY_HOST=.*/S3_PROXY_HOST=no-dns-e2e.$DOMAIN/" ente-setup.env >"$T/bad.env"
ENV_FILE=$T/bad.env PROXY_CERT_TRIES=2 "$PROXYSH" on </dev/null >"$T/out" 2>&1; RC=$? # it can never work: no minute of waiting
check "proxy on fails when the proxy host does not work" '[[ $RC -ne 0 ]] && grep -q "self-test failed" "$T/out"' "$(tail -5 "$T/out")"
check "and puts the add-on's files back (no trace of the bad host)" '! grep -rq no-dns-e2e /etc/caddy /etc/systemd/system/ente-s3-rewrite.service'
check "and leaves the proxy off" '[[ $(cat $STATE) == off ]] && ! api_rewrites'
prx off; check "the real config is back" '[[ $RC -eq 0 ]] && caddy_has_s3 && ! grep -rq no-dns-e2e /etc/caddy' "$(cat "$T/out")"

echo "== a broken add-on setting fails the main check"
sed "s/^S3_PROXY_HOST=.*/S3_PROXY_HOST=/" ente-setup.env >"$T/none.env"
ENV_FILE=$T/none.env "$OPS" check </dev/null >"$T/out" 2>&1; RC=$?
check "ente-ops.sh check fails when the add-on's check cannot run" '[[ $RC -ne 0 ]] && grep -q "FAIL  the s3 proxy check did not run" "$T/out"' "$(grep -E "FAIL|proxy" "$T/out")"

echo "== links handed out while on keep working after off"
prx on
url=$(mkobj)
prx off
check "a proxied link still downloads after proxy off" '[[ $(curl -sS -m 20 "$url") == "still here" ]]'
rmobj

echo "== uninstall"
prx uninstall; check "uninstall succeeds" '[[ $RC -eq 0 ]]' "$(cat "$T/out")"
REWRITE_UNIT_FILE=/etc/systemd/system/ente-s3-rewrite.service
check "rewriter service is removed" '! systemctl cat ente-s3-rewrite.service >/dev/null 2>&1 && [[ ! -e /usr/local/lib/ente-setup/ente_s3_rewrite.py ]]'
check "proxy site and state are removed, API goes to museum" '[[ ! -e $SITE && ! -e $STATE ]] && ! api_rewrites && [[ $(cat /etc/caddy/ente.d/api-upstream.caddy) == "reverse_proxy 127.0.0.1:8080" ]]'
check "the API still answers" '[[ $(api_code "https://api.$DOMAIN/ping") == 200 ]]'
ops check; check "ente-ops.sh check passes without the proxy and does not mention it" '[[ $RC -eq 0 ]] && ! grep -q "s3 proxy" "$T/out"' "$(grep -E "FAIL|proxy" "$T/out")"
prx uninstall; check "uninstall again is harmless" '[[ $RC -eq 0 ]]' "$(cat "$T/out")"
# a step in the middle fails (the state file cannot be written): the rest must not go on, and everything is undone
PROXY_STATE=/proc/ente-e2e/state "$PROXYSH" install </dev/null >"$T/out" 2>&1; RC=$?
check "a first install whose step fails stops and says so" '[[ $RC -ne 0 ]] && grep -q "S3 proxy not installed; everything is back as it was" "$T/out"' "$(tail -5 "$T/out")"
check "... and leaves nothing behind (no rewriter, no site, the API on museum)" \
  '! systemctl is-enabled --quiet ente-s3-rewrite.service 2>/dev/null && ! systemctl is-active --quiet ente-s3-rewrite.service && [[ ! -e $SITE && ! -e $REWRITE_UNIT_FILE && ! -e /usr/local/lib/ente-setup/ente_s3_rewrite.py ]] && ! api_rewrites && [[ $(api_code "https://api.$DOMAIN/ping") == 200 ]]'
prx on; check "on installs it again (and turns it on)" '[[ $RC -eq 0 ]] && caddy_has_s3 && api_rewrites' "$(cat "$T/out")"
sed "s/^S3_PROXY_HOST=.*/S3_PROXY_HOST=/" ente-setup.env >"$T/none.env"
ENV_FILE=$T/none.env "$PROXYSH" on </dev/null >"$T/out" 2>&1; RC=$?
check "on refuses without S3_PROXY_HOST" '[[ $RC -ne 0 ]] && grep -q "S3_PROXY_HOST" "$T/out"'

echo "== S3 through the proxy (tests/proxy_e2e_s3.py)"
if python3 tests/proxy_e2e_s3.py >"$T/out" 2>&1; then pass "$(grep -E '^Ran ' "$T/out"), $(grep -o '50 MB through.*s' "$T/out" | head -1)"
else fail "S3 end-to-end tests" "$(cat "$T/out")"; fi

echo "== back to how it was"
if [[ $WAS_INSTALLED == yes ]]; then
  prx "$ORIG"; check "proxy restored to $ORIG" '[[ $RC -eq 0 && $(cat $STATE) == "$ORIG" ]]' "$(cat "$T/out")"
else
  prx uninstall; check "proxy uninstalled again" '[[ $RC -eq 0 && ! -e $SITE ]]' "$(cat "$T/out")"
fi
summary
