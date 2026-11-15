#!/usr/bin/env bash
# Tests for ente-s3-proxy.sh and its hooks in ente-setup.sh: config validation, the state file, the main Caddyfile's import
# hooks, the files the proxy script owns (API upstream, proxy site), the rewriter's unit and the command lines. Runs anywhere
# bash and python3 are; where caddy is installed (the server) the assembled configs are also validated and inspected.
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
# in_proxy ENV_EXTRA CODE: source ente-s3-proxy.sh (which sources ente-setup.sh) with base_env + ENV_EXTRA and a private
# Caddy directory, then run CODE in a subshell
in_proxy() {
  base_env >"$T/env"; printf '%s\n' "$1" >>"$T/env"
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none PROXY_STATE=$T/state CADDY_DIR=$T/caddy CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-s3-proxy.sh"
    set +e
    eval "$2" )
}
# in_setup ENV_EXTRA CODE: the same with only ente-setup.sh
in_setup() {
  base_env >"$T/env"; printf '%s\n' "$1" >>"$T/env"
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none CADDY_DIR=$T/caddy CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-setup.sh"
    set +e
    eval "$2" )
}
P=S3_PROXY_HOST=s3.photos.example.org

echo "== config validation"
for good in "$P" "S3_PROXY_HOST=files.other.net"; do
  out=$(in_proxy "$good" 'proxy_load_env && echo LOADED' 2>&1); check "accepts $good" '[[ $out == *LOADED* ]]' "$out"
done
for bad in "S3_PROXY_HOST=" "S3_PROXY_HOST=https://s3.photos.example.org" "S3_PROXY_HOST=api.photos.example.org" "S3_PROXY_HOST=web.photos.example.org" \
  "S3_PROXY_HOST=albums.photos.example.org" "S3_PROXY_HOST=s3.eu-west-4.idrivee2.com" "S3_PROXY_HOST='a b.org'" "S3_PROXY_HOST=nodot"; do
  out=$(in_proxy "$bad" 'proxy_load_env && echo LOADED' 2>&1); check "rejects $bad" '[[ $out != *LOADED* && $out == *S3_PROXY_HOST* ]]' "$out"
done
out=$(in_setup "S3_PROXY_HOST=whatever" 'load_env && echo LOADED' 2>&1); check "ente-setup.sh itself does not validate the proxy's setting" '[[ $out == *LOADED* ]]' "$out"

echo "== state file"
rm -f "$T/state"
out=$(in_proxy "$P" 'proxy_load_env; proxy_state'); check "state defaults to off" '[[ $out == off ]]' "$out"
out=$(in_proxy "$P" 'proxy_load_env; set_proxy_state on; proxy_state'); check "state can be set on" '[[ $out == on ]]' "$out"
check "state file is root-only readable (600)" '[[ $(stat -c %a "$T/state") == 600 ]]'
echo garbage >"$T/state"
out=$(in_proxy "$P" 'proxy_load_env; proxy_state'); check "unknown state reads as off" '[[ $out == off ]]' "$out"

echo "== hooks in the main Caddyfile (ente-setup.sh)"
rm -rf "$T/caddy"
in_setup "" 'load_env; ensure_caddy_hooks; render_caddyfile' >"$T/main.caddy" 2>"$T/main.err"
check "renders" '[[ -s $T/main.caddy && ! -s $T/main.err ]]' "$(cat "$T/main.err")"
check "API upstream comes from the hook file" 'awk "/^api\./,/^}/" "$T/main.caddy" | grep -q "^	import $T/caddy/ente.d/api-upstream.caddy$"' "$(awk '/^api\./,/^}/' "$T/main.caddy")"
check "extra sites are imported from ente.d/sites" 'grep -q "^import $T/caddy/ente.d/sites/\*.caddy$" "$T/main.caddy"'
check "no proxy code left in the main Caddyfile" '! grep -qE "8081|s3\.photos|ente_s3_rewrite" "$T/main.caddy"'
check "ensure_caddy_hooks creates the sites directory" '[[ -d $T/caddy/ente.d/sites ]]'
check "the sites directory is never empty (an empty import glob makes Caddy warn)" '[[ -n $(ls "$T/caddy/ente.d/sites"/*.caddy 2>/dev/null) ]]'
check "ensure_caddy_hooks creates the default API upstream (museum)" '[[ $(cat "$T/caddy/ente.d/api-upstream.caddy") == "reverse_proxy 127.0.0.1:8080" ]]'
echo "custom" >"$T/caddy/ente.d/api-upstream.caddy"
in_setup "" 'load_env; ensure_caddy_hooks' >/dev/null 2>&1
check "ensure_caddy_hooks never overwrites the API upstream (the proxy script owns it)" '[[ $(cat "$T/caddy/ente.d/api-upstream.caddy") == custom ]]'
in_setup "$P
CSP_REPORT_ONLY=yes" 'load_env; render_caddyfile' >"$T/csp.caddy" 2>/dev/null
check "with CSP_REPORT_ONLY=yes the proxy host is allowed in connect-src" 'grep -q "connect-src .*https://s3.photos.example.org" "$T/csp.caddy"'

echo "== files owned by ente-s3-proxy.sh"
out=$(in_proxy "$P" 'proxy_load_env; render_api_upstream off'); check "API upstream when off: museum" '[[ $out == "reverse_proxy 127.0.0.1:8080" ]]' "$out"
out=$(in_proxy "$P" 'proxy_load_env; render_api_upstream on')
check "API upstream when on: rewriter, museum as fallback" '[[ $out == "reverse_proxy 127.0.0.1:8081 127.0.0.1:8080 {"* && $out == *"lb_policy first"* && $out == *"lb_try_duration"* ]]' "$out"
in_proxy "$P" 'proxy_load_env; render_proxy_site' >"$T/site.caddy"
check "proxy site serves only the photo bucket" 'grep -q "path /ente-dev/\*" "$T/site.caddy"' "$(cat "$T/site.caddy")"
check "proxy site allows only the methods the apps use" 'grep -Eq "method GET HEAD PUT POST OPTIONS$" "$T/site.caddy"'
check "proxy site sends the real endpoint as Host (keeps signatures valid)" 'grep -q "header_up Host s3.eu-west-4.idrivee2.com" "$T/site.caddy"'
check "proxy site upstream is the real endpoint over https" 'grep -q "reverse_proxy https://s3.eu-west-4.idrivee2.com" "$T/site.caddy"'
check "proxy site streams (no buffering)" 'grep -q "flush_interval -1" "$T/site.caddy"'
check "anything else on the proxy site gets 404" 'grep -q "respond 404" "$T/site.caddy"'
check "proxy site uses the main file's security headers" 'grep -q "^	import sec$" "$T/site.caddy"'

if command -v caddy >/dev/null; then
  # assemble the real layout for each state and let caddy validate it
  assemble() { # assemble NAME STATE (none|off|on)
    local d=$T/$1; rm -rf "$d"
    ( ENV_FILE=$T/env SECRETS_FILE=$T/none PROXY_STATE=$T/state CADDY_DIR=$d CMD=test
      . "$HERE/../ente-s3-proxy.sh"; set +e
      proxy_load_env; ensure_caddy_hooks; render_caddyfile >"$d/Caddyfile"
      if [[ $2 != none ]]; then render_proxy_site >"$d/ente.d/sites/s3-proxy.caddy"; render_api_upstream "$2" >"$d/ente.d/api-upstream.caddy"; fi )
  }
  base_env >"$T/env"; echo "$P" >>"$T/env"
  for c in none off on; do
    assemble "$c" "$c"
    out=$(caddy adapt --config "$T/$c/Caddyfile" --adapter caddyfile --validate 2>&1 >"$T/$c.json"); rc=$?
    check "caddy validates the assembled $c config" '[[ $rc -eq 0 ]] && ! grep -qi "warn" <<<"$out"' "$out"
    for f in "$T/$c/Caddyfile" "$T/$c"/ente.d/sites/*.caddy; do
      [[ -e $f ]] || continue
      check "$c: $(basename "$f") is formatted the way caddy fmt formats it" 'diff <(caddy fmt "$f") "$f" >/dev/null' "$(diff <(caddy fmt "$f") "$f")"
    done
  done
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
  check "caddy (none): api goes to museum, no proxy site" '[[ $(ups none api.photos.example.org) == "127.0.0.1:8080" && -z $(ups none s3.photos.example.org) ]]'
  check "caddy (off): api goes to museum, proxy site exists" '[[ $(ups off api.photos.example.org) == "127.0.0.1:8080" && $(ups off s3.photos.example.org) == "s3.eu-west-4.idrivee2.com:443" ]]'
  check "caddy (on): api goes to the rewriter, then museum" '[[ $(ups on api.photos.example.org) == "127.0.0.1:8081,127.0.0.1:8080" ]]' "$(ups on api.photos.example.org)"
else
  echo "  skip  caddy not installed here: assembled configs not validated by caddy (run on the server)"
fi

echo "== rewriter service unit"
out=$(in_proxy "$P" 'proxy_load_env; rewrite_unit')
check "unit runs the rewriter with the right hosts and bucket" \
  '[[ $out == *"--from-host s3.eu-west-4.idrivee2.com"* && $out == *"--to-host s3.photos.example.org"* && $out == *"--bucket ente-dev"* ]]' "$out"
check "unit listens on 127.0.0.1:8081 and forwards to museum on 8080" '[[ $out == *"--listen 127.0.0.1:8081"* && $out == *"--upstream 127.0.0.1:8080"* ]]' "$out"
check "unit runs unprivileged and restarts on failure" '[[ $out == *"DynamicUser=yes"* && $out == *"Restart=always"* ]]' "$out"

echo "== command lines"
# as root (on the server) a known command would really run: run those checks as an unprivileged user on a copy
asuser() { "$@"; }
if [[ $EUID -eq 0 ]]; then
  mkdir -p "$T/bin"; cp "$HERE/../ente-setup.sh" "$HERE/../ente-s3-proxy.sh" "$T/bin/"; chmod 755 "$T" "$T/bin" "$T/bin"/*
  asuser() { setpriv --reuid=65534 --regid=65534 --clear-groups "$@"; }
  CLI=$T/bin
else
  CLI=$HERE/..
fi
out=$(asuser bash "$CLI/ente-s3-proxy.sh" maybe 2>&1); rc=$?
check "ente-s3-proxy.sh with an unknown command is a usage error" '[[ $rc -eq 2 && $out == *usage* ]]' "$out"
out=$(asuser bash "$CLI/ente-s3-proxy.sh" 2>&1); rc=$?; check "ente-s3-proxy.sh without a command is a usage error" '[[ $rc -eq 2 && $out == *usage* ]]' "$out"
for c in install on off status check uninstall; do
  out=$(asuser bash "$CLI/ente-s3-proxy.sh" "$c" 2>&1); rc=$?
  check "ente-s3-proxy.sh $c is a known command (asks for root here)" '[[ $out == *"run as root"* ]]' "$out"
done
out=$(asuser bash "$CLI/ente-setup.sh" proxy 2>&1); rc=$?
check "ente-setup.sh no longer has a proxy command" '[[ $rc -eq 2 && $out == *usage* ]] && ! grep -q "proxy" <<<"$out"' "$out"
out=$(asuser bash "$CLI/ente-setup.sh" nonsense 2>&1); rc=$?
check "ente-setup.sh rejects unknown commands before asking for root" '[[ $rc -eq 2 && $out == *usage* ]]' "$out"
out=$(asuser bash "$CLI/ente-setup.sh" check extra 2>&1); check "ente-setup.sh commands take no argument" '[[ $out == *usage* ]]' "$out"
out=$(asuser bash "$CLI/ente-setup.sh" check 2>&1); check "ente-setup.sh check asks for root" '[[ $out == *"run as root"* ]]' "$out"

echo
echo "$PASS passed, $FAIL failed"
((FAIL == 0))
