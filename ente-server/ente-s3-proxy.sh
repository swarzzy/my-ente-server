#!/usr/bin/env bash
# ente-s3-proxy.sh - optional add-on to ente-setup.sh: route the apps' photo uploads and downloads through this server.
# Usage: ente-s3-proxy.sh {install|on|off|status|check|uninstall}
#   install    the link rewriter service and the proxy site (state unchanged, off at first)
#   on | off   switch museum's bucket links to https://$S3_PROXY_HOST/<bucket>/ or back to the bucket (installs if needed)
#   status     the state and the checks          check   the checks only (ente-ops.sh check runs this)
#   uninstall  remove everything; links point at the bucket again
# Config: S3_PROXY_HOST in ente-setup.env (its DNS record pointing here); the bucket's endpoint and name come from museum.yaml
# (what museum signs its links for), the rest from ente-setup.sh's config.
# Needs ente-setup.sh (and ente_s3_rewrite.py) next to it, and `ente-setup.sh install` done.
#
# How: while on, API traffic goes through ente-s3-rewrite (ente_s3_rewrite.py), which rewrites museum's pre-signed links;
# Caddy forwards $S3_PROXY_HOST, only the bucket path and only the apps' methods, to the real endpoint with its own Host, so
# the signatures stay valid. This script owns the hook files of ente-setup.sh's Caddyfile: the API upstream and the proxy site.
PROXY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ente-setup.sh
. "$PROXY_DIR/ente-setup.sh" # its helpers and config; its own main does not run when sourced
PROXY_STATE=${PROXY_STATE:-/var/lib/ente-setup/s3-proxy}
PROXY_SITE=$CADDY_SITES/s3-proxy.caddy
REWRITE_PY=/usr/local/lib/ente-setup/ente_s3_rewrite.py
REWRITE_UNIT=/etc/systemd/system/ente-s3-rewrite.service
REWRITE_PORT=8081

# proxy_load_env: ente-setup.sh's config plus S3_PROXY_HOST (a host name of its own), and LINK_ENDPOINT / LINK_BUCKET: the
# bucket museum signs its links for, read from museum.yaml (the source of truth after install), so proxy and links never differ.
proxy_load_env() {
  load_env
  [[ -n $S3_PROXY_HOST ]] || die "S3_PROXY_HOST is not set in $ENV_FILE (e.g. s3.$DOMAIN, with its DNS record pointing here)"
  [[ $S3_PROXY_HOST =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "S3_PROXY_HOST must be a bare host name, not $S3_PROXY_HOST"
  [[ -f $ENTE_DIR/museum.yaml ]] || die "run ente-setup.sh install first"
  local M_KEY M_SECRET M_ENDPOINT M_REGION M_BUCKET
  eval "$(museum_s3)"
  LINK_ENDPOINT=$M_ENDPOINT LINK_BUCKET=$M_BUCKET
  [[ $S3_PROXY_HOST != "api.$DOMAIN" && $S3_PROXY_HOST != "$LINK_ENDPOINT" ]] && ! web_hosts | grep -qx "${S3_PROXY_HOST%.$DOMAIN}" ||
    die "S3_PROXY_HOST must be a host name of its own, not $S3_PROXY_HOST"
}

# proxy_state: on|off. set_proxy_state on|off: persist it.
proxy_state() { if [[ $(cat "$PROXY_STATE" 2>/dev/null) == on ]]; then echo on; else echo off; fi; }
set_proxy_state() {
  install -d -m 755 "$(dirname "$PROXY_STATE")"
  (umask 077; echo "$1" >"$PROXY_STATE")
  chmod 600 "$PROXY_STATE"
}

# render_api_upstream on|off: the API's reverse_proxy directive (the content of ente-setup.sh's API hook file).
render_api_upstream() {
  if [[ $1 == on ]]; then
    # through the link rewriter; museum directly if the rewriter does not answer (links then point at the bucket again)
    cat <<EOF
reverse_proxy 127.0.0.1:$REWRITE_PORT 127.0.0.1:8080 {
	lb_policy first
	lb_try_duration 3s
	fail_duration 10s
}
EOF
  else
    echo "reverse_proxy 127.0.0.1:8080"
  fi
}

# render_proxy_site: the proxy's site block. It stays while installed, so links handed out while on keep working after off.
# Only the photo bucket and only the methods the apps use are forwarded, with the real endpoint as Host: pre-signed links
# sign the host, so the request must reach the provider as if sent there directly.
render_proxy_site() {
  cat <<EOF
$S3_PROXY_HOST {
	import sec
	@bucket {
		path /$LINK_BUCKET/*
		method GET HEAD PUT POST OPTIONS
	}
	handle @bucket {
		reverse_proxy https://$LINK_ENDPOINT {
			header_up Host $LINK_ENDPOINT
			header_up -X-Forwarded-For
			header_up -X-Forwarded-Proto
			header_up -X-Forwarded-Host
			flush_interval -1
		}
	}
	handle {
		respond 404
	}
}
EOF
}

# rewrite_unit: the systemd unit of the link rewriter.
rewrite_unit() {
  cat <<EOF
[Unit]
Description=Ente S3 link rewriter (pre-signed bucket links -> https://$S3_PROXY_HOST/$LINK_BUCKET/)
After=network.target

[Service]
ExecStart=/usr/bin/python3 $REWRITE_PY --listen 127.0.0.1:$REWRITE_PORT --upstream 127.0.0.1:8080 --from-host $LINK_ENDPOINT --to-host $S3_PROXY_HOST --bucket $LINK_BUCKET
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
MemoryMax=256M
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

# install_rewriter: install the rewriter and its unit; restart it only when something changed.
install_rewriter() {
  local h0 h1
  [[ -f $PROXY_DIR/ente_s3_rewrite.py ]] || die "ente_s3_rewrite.py is missing next to $0 (copy the whole ente-server folder)"
  h0=$({ cat "$REWRITE_PY" "$REWRITE_UNIT" 2>/dev/null || true; } | sha256sum) # absent on first install
  install -d -m 755 "$(dirname "$REWRITE_PY")"
  write_file "$REWRITE_PY" 644 <"$PROXY_DIR/ente_s3_rewrite.py"
  rewrite_unit | write_file "$REWRITE_UNIT"
  h1=$(cat "$REWRITE_PY" "$REWRITE_UNIT" | sha256sum)
  systemctl daemon-reload
  systemctl enable ente-s3-rewrite.service >/dev/null 2>&1
  if [[ $h0 != "$h1" ]] || ! systemctl is-active --quiet ente-s3-rewrite.service; then systemctl restart ente-s3-rewrite.service; fi
  url_ok "http://127.0.0.1:$REWRITE_PORT/ping" 10 || die "the link rewriter does not answer (journalctl -u ente-s3-rewrite)"
}

# apply_caddy: write the proxy site and the API upstream for the current state, validate the whole Caddy config and reload.
# Runs under with_rollback, which puts the previous files back when it fails.
apply_caddy() {
  render_proxy_site | write_file "$PROXY_SITE"
  render_api_upstream "$(proxy_state)" | write_file "$CADDY_API_UPSTREAM"
  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 ||
    die "the Caddy config with the proxy is invalid (caddy validate --config $CADDYFILE)"
  systemctl reload-or-restart caddy
}

# proxy_probe_url: a pre-signed GET link (valid 5 minutes) for a key that does not exist, pointing at the proxy host.
# Through a working proxy the provider answers 404 NoSuchKey: proof that forwarding, Host and signature are right.
proxy_probe_url() {
  local M_KEY M_SECRET M_ENDPOINT M_REGION M_BUCKET
  eval "$(museum_s3)"
  M_KEY=$M_KEY M_SECRET=$M_SECRET M_ENDPOINT=$M_ENDPOINT M_REGION=$M_REGION M_BUCKET=$M_BUCKET P=$S3_PROXY_HOST python3 -I - <<'PY'
import os, boto3
from botocore.config import Config
e = os.environ
c = boto3.client("s3", endpoint_url="https://" + e["M_ENDPOINT"], region_name=e["M_REGION"], aws_access_key_id=e["M_KEY"],
                 aws_secret_access_key=e["M_SECRET"], config=Config(s3={"addressing_style": "path"}, signature_version="s3v4"))
u = c.generate_presigned_url("get_object", Params={"Bucket": e["M_BUCKET"], "Key": "ente-setup-proxy-probe/none"}, ExpiresIn=300)
print(u.replace("https://%s/" % e["M_ENDPOINT"], "https://%s/" % e["P"], 1))
PY
}

# proxy_checks: OK/FAIL lines (counted in FAILS): the parts that work in both states, then the state itself.
proxy_checks() { proxy_checks_base; proxy_check_state; }

# proxy_checks_base [TRIES]: rewriter, signed link through the proxy host, CORS, 404. TRIES x 3 s to wait for a new certificate.
proxy_checks_base() {
  local out st i
  if systemctl is-active --quiet ente-s3-rewrite.service; then ok "link rewriter running"; else bad "link rewriter not running (journalctl -u ente-s3-rewrite)"; fi
  out=$(curl -sS -m 5 -D - "http://127.0.0.1:$REWRITE_PORT/ping" 2>&1 || true)
  if grep -qi '^x-ente-link-rewrite: on' <<<"$out" && grep -q pong <<<"$out"; then ok "link rewriter answers and reaches museum"
  else bad "link rewriter does not answer correctly on 127.0.0.1:$REWRITE_PORT"; fi
  for ((i = 0; i < ${1:-1}; i++)); do
    out=$(curl -sS -m 15 "$(proxy_probe_url)" 2>&1 || true)
    [[ $out != *NoSuchKey* ]] || break
    sleep 3
  done
  if [[ $out == *NoSuchKey* ]]; then ok "https://$S3_PROXY_HOST forwards signed links to $LINK_ENDPOINT"
  else bad "https://$S3_PROXY_HOST does not forward signed links: $(head -c 160 <<<"$out" | tr '\n' ' ')"; fi
  out=$(curl -sS -m 10 -o /dev/null -D - -X OPTIONS -H "Origin: https://web.$DOMAIN" -H "Access-Control-Request-Method: PUT" \
    "https://$S3_PROXY_HOST/$LINK_BUCKET/ente-check" 2>&1 || true)
  if grep -qi '^access-control-allow-origin:' <<<"$out"; then ok "CORS preflight through the proxy allowed for https://web.$DOMAIN"
  else bad "CORS preflight through the proxy not allowed (web uploads through the proxy will fail)"; fi
  st=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "https://$S3_PROXY_HOST/" 2>&1 || true)
  if [[ $st == 404 ]]; then ok "proxy site refuses paths outside the bucket"; else bad "proxy site answers $st outside the bucket (expected 404)"; fi
}

# proxy_check_state: the API goes through the rewriter exactly when the proxy is on.
proxy_check_state() {
  local out
  out=$(curl -sS -m 10 -o /dev/null -D - "https://api.$DOMAIN/ping" 2>&1 || true)
  if [[ $(proxy_state) == on ]]; then
    if grep -qi '^x-ente-link-rewrite: on' <<<"$out"; then ok "proxy ON: bucket links point at https://$S3_PROXY_HOST"
    else bad "proxy is on but the API does not go through the link rewriter (falling back to museum?)"; fi
  else
    if grep -qi '^x-ente-link-rewrite' <<<"$out"; then bad "proxy is off but the API still goes through the link rewriter"
    else ok "proxy OFF: bucket links point at $LINK_ENDPOINT"; fi
  fi
}

# ---------------------------------------------------------------- commands
# The add-on's files, for rolling back a failed install or switch (snapshot_proxy DIR / restore_proxy DIR). The unit comes first.
proxy_files() { echo "$REWRITE_UNIT" "$REWRITE_PY" "$PROXY_SITE" "$CADDY_API_UPSTREAM" "$PROXY_STATE"; }
snapshot_proxy() { local f i=0; for f in $(proxy_files); do i=$((i + 1)); [[ ! -e $f ]] || cp -p "$f" "$1/$i"; done; }
restore_proxy() {
  local f i=0
  [[ -e $1/1 ]] || systemctl disable --now ente-s3-rewrite.service >/dev/null 2>&1 || true # there was no rewriter before
  for f in $(proxy_files); do i=$((i + 1)); if [[ -e $1/$i ]]; then cp -p "$1/$i" "$f"; else rm -f "$f"; fi; done
  [[ -e $CADDY_API_UPSTREAM ]] || render_api_upstream off >"$CADDY_API_UPSTREAM"
  systemctl daemon-reload
  if [[ -e $REWRITE_UNIT ]]; then systemctl restart ente-s3-rewrite.service || true; else systemctl stop ente-s3-rewrite.service 2>/dev/null || true; fi
  systemctl reload-or-restart caddy || true
}

# with_rollback WHAT FUNC [ARGS]: run FUNC in a subshell; if any step fails, put the add-on's files and state back and die.
with_rollback() {
  local what=$1 snap rc errexit=$-; shift
  snap=$(mktemp -d); snapshot_proxy "$snap"
  # not `if ! (...)`: bash ignores set -e in a condition, so a failing step would not stop FUNC
  set +e; (set -e; "$@"); rc=$?
  [[ $errexit != *e* ]] || set -e
  if ((rc != 0)); then
    restore_proxy "$snap"; rm -rf "$snap"
    die "$what; everything is back as it was"
  fi
  rm -rf "$snap"
}

# do_install: the rewriter, the state (off at first) and the Caddy files.
do_install() {
  grep -qF "import $CADDY_API_UPSTREAM" "$CADDYFILE" 2>/dev/null ||
    die "$CADDYFILE has no add-on hooks: re-run ente-setup.sh install (a newer version) first"
  install_rewriter
  [[ -e $PROXY_STATE ]] || set_proxy_state off
  apply_caddy
}
proxy_cmd_install() {
  proxy_load_env
  with_rollback "S3 proxy not installed" do_install
  log "S3 proxy installed for https://$S3_PROXY_HOST ($(proxy_state))"
}

# do_switch on|off: install if needed; before `on` goes live, test everything that works in both states; then switch.
do_switch() {
  local want=$1 f0
  do_install
  if [[ $want == on ]]; then
    f0=$FAILS; proxy_checks_base 20
    ((FAILS == f0)) || die "proxy self-test failed before switching"
  fi
  set_proxy_state "$want"
  apply_caddy
  f0=$FAILS; proxy_check_state
  ((FAILS == f0)) || die "proxy self-test failed: the API does not follow the switch"
}

# switch on|off: do_switch; any failure puts the add-on's files and state back as they were.
proxy_cmd_switch() {
  local want=$1 was
  proxy_load_env
  was=$(proxy_state)
  with_rollback "S3 proxy not switched $want (still $was)" do_switch "$want"
  log "S3 proxy $want (was $was)"
}

proxy_cmd_status() {
  proxy_load_env
  [[ -e $PROXY_SITE ]] || { echo "S3 proxy is not installed ($0 install)"; return 1; }
  echo "S3 proxy is $(proxy_state)"
  proxy_checks
  ((FAILS == 0))
}

# check: only the OK/FAIL lines (for ente-ops.sh check); exit 1 on any FAIL.
proxy_cmd_check() {
  proxy_load_env
  [[ -e $PROXY_SITE ]] || { bad "S3 proxy is not installed"; return 1; }
  proxy_checks
  ((FAILS == 0))
}

proxy_cmd_uninstall() {
  load_env
  command -v caddy >/dev/null || die "caddy is not installed"
  if systemctl cat ente-s3-rewrite.service >/dev/null 2>&1; then systemctl disable --now ente-s3-rewrite.service >/dev/null 2>&1 || true; fi
  rm -f "$REWRITE_UNIT" "$REWRITE_PY" "$PROXY_SITE" "$PROXY_STATE"
  systemctl daemon-reload
  install -d -m 755 "$CADDY_SITES"
  render_api_upstream off | write_file "$CADDY_API_UPSTREAM"
  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 || die "Caddy config invalid after removing the proxy"
  systemctl reload-or-restart caddy
  log "S3 proxy uninstalled; bucket links point at the bucket again"
}

proxy_usage() { echo "usage: $0 {install|on|off|status|check|uninstall}" >&2; exit 2; }

proxy_main() {
  case $1 in
    install) proxy_cmd_install ;;
    on | off) proxy_cmd_switch "$1" ;;
    status) proxy_cmd_status ;;
    check) proxy_cmd_check ;;
    uninstall) proxy_cmd_uninstall ;;
    *) proxy_usage ;;
  esac
}

# sourced (tests): define the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  [[ $# -eq 1 && " install on off status check uninstall " == *" $1 "* ]] || proxy_usage
  [[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $1)" >&2; exit 1; }
  CMD="s3-proxy $1"
  if [[ $1 == check ]]; then proxy_main check; exit; fi # quiet, not logged: run by ente-ops.sh check
  touch "$LOG"; chmod 600 "$LOG"
  proxy_main "$1" 2>&1 | tee -a "$LOG"
fi
