#!/usr/bin/env bash
# Tests for the S3 proxy parts of ente-setup.sh: config validation, the generated Caddyfile in each state,
# the state file and the rewriter's systemd unit. Runs anywhere bash and python3 are; where caddy is installed
# (the server) every generated Caddyfile is also validated and its routes inspected with `caddy adapt`.
# Run: bash tests/test_proxy_config.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/        /' | head -20; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }

base_env() {
  cat <<'X'
DOMAIN=photos.example.org
ADMIN_USER=ops
ADMIN_SSH_PUBKEY="ssh-ed25519 AAAA test"
S3_PROVIDER=IDrive
S3_ENDPOINT=s3.eu-west-4.idrivee2.com
S3_REGION=eu-west-4
S3_BUCKET=ente-dev
BACKUP_S3_ENDPOINT=s3.us-east-005.backblazeb2.com
BACKUP_S3_REGION=us-east-005
BACKUP_S3_BUCKET=ente-backup
X
}
# in_script ENV_EXTRA CODE: source the script with a config made of base_env + ENV_EXTRA, then run CODE (in a subshell)
in_script() {
  base_env >"$T/env"; printf '%s\n' "$1" >>"$T/env"
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none PROXY_STATE=$T/state CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-setup.sh"
    set +e
    eval "$2" )
}

echo "== config validation"
for good in "S3_PROXY_HOST=" "S3_PROXY_HOST=s3.photos.example.org" "S3_PROXY_HOST=files.other.net"; do
  out=$(in_script "$good" 'load_env && echo LOADED' 2>&1); check "accepts $good" '[[ $out == *LOADED* ]]' "$out"
done
for bad in "S3_PROXY_HOST=https://s3.photos.example.org" "S3_PROXY_HOST=api.photos.example.org" "S3_PROXY_HOST=web.photos.example.org" \
  "S3_PROXY_HOST=albums.photos.example.org" "S3_PROXY_HOST=s3.eu-west-4.idrivee2.com" "S3_PROXY_HOST='a b.org'" "S3_PROXY_HOST=nodot"; do
  out=$(in_script "$bad" 'load_env && echo LOADED' 2>&1); check "rejects $bad" '[[ $out != *LOADED* && $out == *S3_PROXY_HOST* ]]' "$out"
done

echo "== state file"
rm -f "$T/state"
out=$(in_script "S3_PROXY_HOST=s3.photos.example.org" 'load_env; proxy_state'); check "state defaults to off" '[[ $out == off ]]' "$out"
out=$(in_script "S3_PROXY_HOST=s3.photos.example.org" 'load_env; set_proxy_state on; proxy_state'); check "state can be set on" '[[ $out == on ]]' "$out"
check "state file is root-only readable (600)" '[[ $(stat -c %a "$T/state") == 600 ]]'
echo garbage >"$T/state"
out=$(in_script "S3_PROXY_HOST=s3.photos.example.org" 'load_env; proxy_state'); check "unknown state reads as off" '[[ $out == off ]]' "$out"
out=$(in_script "S3_PROXY_HOST=" 'load_env; set_proxy_state on; proxy_state'); check "without S3_PROXY_HOST the proxy is always off" '[[ $out == off ]]' "$out"

echo "== Caddyfile"
render() { rm -f "$T/state"; in_script "$1" "load_env; ${2:+set_proxy_state $2;} render_caddyfile" >"$T/$3.caddy" 2>"$T/$3.err"; }
render "S3_PROXY_HOST=" "" none
render "S3_PROXY_HOST=s3.photos.example.org" off off
render "S3_PROXY_HOST=s3.photos.example.org" on on
for c in none off on; do check "renders ($c)" '[[ -s $T/$c.caddy && ! -s $T/$c.err ]]' "$(cat "$T/$c.err")"; done
api_block() { awk '/^api\./,/^}/' "$T/$1.caddy"; }
s3_block() { awk '/^s3\.photos\.example\.org/,/^}/' "$T/$1.caddy"; }
check "none: no proxy site" '! grep -q "^s3\." "$T/none.caddy"'
check "none: api goes straight to museum" '[[ $(api_block none | grep reverse_proxy) == *"reverse_proxy 127.0.0.1:8080" ]]' "$(api_block none)"
check "off: proxy site exists (links handed out while on keep working)" 'grep -q "^s3\.photos\.example\.org {" "$T/off.caddy"'
check "off: api goes straight to museum" '[[ $(api_block off | grep reverse_proxy) == *"reverse_proxy 127.0.0.1:8080" ]]' "$(api_block off)"
check "on: api goes through the rewriter, museum as fallback" \
  'api_block on | grep -q "reverse_proxy 127.0.0.1:8081 127.0.0.1:8080" && api_block on | grep -q "lb_policy first"' "$(api_block on)"
check "on: rewriter fallback retries only briefly" 'api_block on | grep -q "lb_try_duration"' "$(api_block on)"
check "proxy site only serves the photo bucket" 's3_block on | grep -q "path /ente-dev/\*"' "$(s3_block on)"
check "proxy site allows only the methods the apps use" 's3_block on | grep -Eq "method GET HEAD PUT POST OPTIONS$"' "$(s3_block on)"
check "proxy site sends the real endpoint as Host (keeps signatures valid)" 's3_block on | grep -q "header_up Host s3.eu-west-4.idrivee2.com"' "$(s3_block on)"
check "proxy site upstream is the real endpoint over https" 's3_block on | grep -q "reverse_proxy https://s3.eu-west-4.idrivee2.com"' "$(s3_block on)"
check "proxy site streams (no buffering)" 's3_block on | grep -q "flush_interval -1"' "$(s3_block on)"
check "anything else on the proxy site gets 404" 's3_block on | grep -q "respond 404"' "$(s3_block on)"
check "web and albums are unchanged by the proxy state" \
  '[[ $(awk "/^web\./,/^}/" "$T/on.caddy") == "$(awk "/^web\./,/^}/" "$T/none.caddy")" && $(awk "/^albums\./,/^}/" "$T/on.caddy") == "$(awk "/^albums\./,/^}/" "$T/none.caddy")" ]]'

if command -v caddy >/dev/null; then
  for c in none off on; do
    out=$(caddy adapt --config "$T/$c.caddy" --adapter caddyfile --validate 2>&1 >"$T/$c.json"); rc=$?
    check "caddy validates the $c config" '[[ $rc -eq 0 ]] && ! grep -qi "warn" <<<"$out"' "$out"
    check "the $c config is formatted the way caddy fmt formats it" 'diff <(caddy fmt "$T/$c.caddy") "$T/$c.caddy" >/dev/null' "$(diff <(caddy fmt "$T/$c.caddy") "$T/$c.caddy")"
  done
  render "S3_PROXY_HOST=s3.photos.example.org
CSP_REPORT_ONLY=yes" on csp
  check "with CSP_REPORT_ONLY=yes the proxy host is allowed in connect-src" 'grep -q "connect-src .*https://s3.photos.example.org" "$T/csp.caddy"'
  out=$(caddy adapt --config "$T/csp.caddy" --adapter caddyfile --validate 2>&1 >/dev/null); rc=$?
  check "caddy validates the CSP config" '[[ $rc -eq 0 ]] && ! grep -qi "warn" <<<"$out"' "$out"
  printf 'api.x {\n\treverse_proxy\n' >"$T/broken.caddy"; caddy adapt --config "$T/broken.caddy" --adapter caddyfile >/dev/null 2>&1; rc=$?
  check "a broken Caddyfile is seen as broken (harness self-test)" '[[ $rc -ne 0 ]]'
  ups() { python3 - "$T/$1.json" "$2" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1])); host = sys.argv[2]
def walk(o, out):
    if isinstance(o, dict):
        if o.get("handler") == "reverse_proxy":
            out.append(",".join(u["dial"] for u in o.get("upstreams", [])))
        for v in o.values(): walk(v, out)
    elif isinstance(o, list):
        for v in o: walk(v, out)
for srv in cfg["apps"]["http"]["servers"].values():
    for r in srv["routes"]:
        if host in [h for m in r.get("match", []) for h in m.get("host", [])]:
            out = []; walk(r, out); print(" ".join(out))
PY
  }
  check "caddy: api upstreams when on are rewriter then museum" '[[ $(ups on api.photos.example.org) == "127.0.0.1:8081,127.0.0.1:8080" ]]' "$(ups on api.photos.example.org)"
  check "caddy: api upstream when off is museum" '[[ $(ups off api.photos.example.org) == "127.0.0.1:8080" ]]' "$(ups off api.photos.example.org)"
  check "caddy: proxy site dials the real endpoint on 443" '[[ $(ups on s3.photos.example.org) == "s3.eu-west-4.idrivee2.com:443" ]]' "$(ups on s3.photos.example.org)"
else
  echo "  skip  caddy not installed here: generated configs not validated by caddy (run on the server)"
fi

echo "== rewriter service unit"
out=$(in_script "S3_PROXY_HOST=s3.photos.example.org" 'load_env; rewrite_unit')
check "unit runs the rewriter with the right hosts and bucket" \
  '[[ $out == *"--from-host s3.eu-west-4.idrivee2.com"* && $out == *"--to-host s3.photos.example.org"* && $out == *"--bucket ente-dev"* ]]' "$out"
check "unit listens on 127.0.0.1:8081 and forwards to museum on 8080" '[[ $out == *"--listen 127.0.0.1:8081"* && $out == *"--upstream 127.0.0.1:8080"* ]]' "$out"
check "unit runs unprivileged and restarts on failure" '[[ $out == *"DynamicUser=yes"* && $out == *"Restart=always"* ]]' "$out"

echo "== command line"
out=$(bash "$HERE/../ente-setup.sh" proxy maybe 2>&1); check "'proxy maybe' is a usage error" '[[ $out == *usage* ]]' "$out"
out=$(bash "$HERE/../ente-setup.sh" check extra 2>&1); check "other commands still take no argument" '[[ $out == *usage* ]]' "$out"

echo
echo "$PASS passed, $FAIL failed"
((FAIL == 0))
