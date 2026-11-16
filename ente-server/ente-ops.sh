#!/usr/bin/env bash
# ente-ops.sh - running an Ente server set up by ente-setup.sh: health checks, backup verification, tests.
# Usage: ente-ops.sh <command> (see OPS_COMMANDS below)
#   check       read-only health report; exit 1 on any FAIL (daily by ente-check.timer when Telegram alerts are on)
#   verify      deep test that the S3 backup restores (monthly by ente-verify.timer)
#   alert-test  send a test message through the Telegram alert path
#   speedtest   a temporary download/upload test endpoint on this server (30 minutes)
# Config and secrets: those of ente-setup.sh. Needs ente-setup.sh next to it (its helpers).
OPS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ente-setup.sh
. "$OPS_DIR/ente-setup.sh" # its helpers and config; its own main does not run when sourced

# new_uploads NAME: prints a temp file of rclone exclude rules naming the photo objects uploaded since the last good backup to
# NAME (s3) started. They are not in that backup yet, and that is not an error. The caller passes it as --exclude-from
# and removes it. It also excludes the config copy ($PHOTO_CFG_DIR/). One listing, no request per object. (An age filter instead would also hide freshly copied backup objects.)
new_uploads() {
  local s f; f=$(mktemp)
  echo "/$PHOTO_CFG_DIR/**" >"$f" # the config copy, not a photo
  if s=$(cat "$BACKUP_STATE/last-ok-$1" 2>/dev/null); then
    rclone lsf -R --files-only --use-server-modtime --max-age "$(($(date +%s) - $(date -d "$s" +%s) + 60))s" "ente-s3:$S3_BUCKET" \
      --exclude "/$PHOTO_CFG_DIR/**" 2>/dev/null |
      sed 's/[][*?{}\\]/\\&/g; s|^|/|' >>"$f" || true
  fi
  echo "$f"
}
# rc_err OUTPUT: the error lines of an rclone run, without timestamps, on one line.
rc_err() { grep -E 'ERROR|Failed to' <<<"$1" | sed -E 's|^[0-9/]+ [0-9:]+ ||' | head -3 | tr '\n' ' ' || true; }

# ---------------------------------------------------------------- check
# check: read-only health report (containers, ports, ssh/firewall/TLS, bucket + CORS, backup freshness, system); exit 1 on any FAIL.
cmd_check() {
  load_env
  local s cid st pol p addrs ts res out ex i
  echo "== containers"
  for s in museum web postgres; do
    cid=$(dc ps -q "$s" 2>/dev/null || true)
    if [[ -z $cid ]]; then bad "$s not running"; continue; fi
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")
    for ((i = 0; i < 20; i++)); do # just restarted (lockdown, update, reboot): give it a minute instead of a false alarm
      [[ $st == starting || $st == restarting ]] || break
      sleep 3
      st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")
    done
    pol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid")
    if [[ $st == healthy || $st == running ]]; then ok "$s $st"; else bad "$s $st"; fi
    if [[ $pol == unless-stopped ]]; then ok "$s restart=$pol"; else bad "$s restart=$pol"; fi
    [[ $s != postgres ]] || continue
    p=$(pin_of "$s")
    if [[ -n $p && $(docker inspect -f '{{.Config.Image}}' "$cid") == "$p" ]]; then
      ok "$s pinned to ${p:0:$((${#p} - 52))} (built $(docker image inspect -f '{{.Created}}' "$p" 2>/dev/null | cut -c1-10))"
    else bad "$s image is not pinned (re-run install)"; fi
  done
  for s in minio socat; do
    if [[ -z $(dc ps -q "$s" 2>/dev/null || true) ]]; then ok "$s not running"; else bad "$s is running"; fi
  done
  for s in .restore-incomplete .restore-finishing; do
    [[ ! -e $ENTE_DIR/$s ]] || bad "a restore did not finish ($ENTE_DIR/$s): run ente-setup.sh restore again"
  done
  if internal_locked; then ok "sign-ups closed"
  elif [[ -n $(internal_admin) ]]; then bad "sign-ups are OPEN although lockdown was done (re-run lockdown)"
  else warn "sign-ups are open: run lockdown once the family has signed up"; fi
  echo "== ports"
  for p in 8080 3000 3002; do
    addrs=$(ss -Htln "sport = :$p" | awk '{print $4}')
    if [[ -z $addrs ]]; then bad "port $p not listening"
    elif grep -qvE '^127\.0\.0\.1:' <<<"$addrs"; then bad "port $p exposed beyond localhost: $(echo "$addrs" | tr '\n' ' ')"
    else ok "port $p on 127.0.0.1 only"; fi
  done
  for p in 3200 3201 5432; do
    if [[ -z $(ss -Htln "sport = :$p") ]]; then ok "port $p not listening"; else bad "port $p is listening"; fi
  done
  echo "== ssh / firewall / web"
  out=$(sshd -T)
  for s in "passwordauthentication no" "permitrootlogin no" "maxauthtries 3"; do
    if grep -qx "$s" <<<"$out"; then ok "sshd $s"; else bad "sshd expected: $s"; fi
  done
  if [[ -n $ADMIN_USER ]] && grep -qx "allowusers $ADMIN_USER" <<<"$out"; then ok "sshd allowusers $ADMIN_USER"; else bad "sshd allowusers not set"; fi
  if [[ -n $(ss -Htln "sport = :$SSH_PORT") ]]; then ok "sshd listening on $SSH_PORT"; else bad "sshd not listening on $SSH_PORT"; fi
  if ufw status | grep '^Status: active' >/dev/null; then ok "ufw active"; else bad "ufw inactive"; fi
  if ufw status | grep -E "^$SSH_PORT/tcp +ALLOW" >/dev/null; then ok "ufw allows $SSH_PORT/tcp"; else bad "ufw does not allow $SSH_PORT/tcp"; fi
  if systemctl is-active --quiet caddy; then ok "caddy active"; else bad "caddy not active"; fi
  if curl -fsS -m 10 "https://api.$DOMAIN/ping" >/dev/null 2>&1; then ok "https://api.$DOMAIN/ping"; else bad "https://api.$DOMAIN/ping"; fi
  out=$(curl -sS -m 10 -o /dev/null -D - "https://web.$DOMAIN/" 2>&1 || true)
  for s in strict-transport-security x-content-type-options x-frame-options; do
    if grep -qi "^$s:" <<<"$out"; then ok "web.$DOMAIN sends $s"; else bad "web.$DOMAIN missing header $s (re-run install)"; fi
  done
  echo "== photo bucket"
  if out=$(rclone lsf "ente-s3:$S3_BUCKET" --max-depth 1 2>&1 >/dev/null); then ok "bucket $S3_BUCKET reachable"; else bad "bucket $S3_BUCKET: $out"; fi
  out=$(curl -sS -m 10 -o /dev/null -D - -X OPTIONS -H "Origin: https://web.$DOMAIN" -H "Access-Control-Request-Method: PUT" \
    "https://$S3_ENDPOINT/$S3_BUCKET/ente-check" 2>&1 || true)
  if grep -qi '^access-control-allow-origin:' <<<"$out"; then ok "CORS preflight from https://web.$DOMAIN allowed"; else bad "CORS preflight from https://web.$DOMAIN not allowed (web uploads will fail)"; fi
  # add-ons, while installed (name, script, the file that marks it installed): their own checks
  local addon name script marker
  for addon in "s3 proxy|ente-s3-proxy.sh|$CADDY_SITES/s3-proxy.caddy" "telegram bot|ente-tg-bot.sh|/etc/systemd/system/ente-tg-bot.service"; do
    IFS='|' read -r name script marker <<<"$addon"
    [[ -e $marker ]] || continue
    echo "== $name"
    if [[ -f $SCRIPT_DIR/$script ]]; then
      out=$(bash "$SCRIPT_DIR/$script" check 2>&1) && i=0 || i=$?
      printf '%s\n' "$out"
      FAILS=$((FAILS + $(grep -c '^  FAIL' <<<"$out" || true)))
      if ((i != 0)) && ! grep -q '^  FAIL' <<<"$out"; then bad "the $name check did not run (exit $i): $(tail -1 <<<"$out" | cut -c1-160)"; fi
    else bad "the $name is installed but $script is not next to $0"; fi
  done
  echo "== backup"
  if systemctl is-enabled --quiet ente-backup.timer 2>/dev/null; then ok "timer enabled, next: $(systemctl show ente-backup.timer -p NextElapseUSecRealtime --value)"; else bad "ente-backup.timer not enabled"; fi
  ts=$(systemctl show ente-backup.service -p ExecMainExitTimestamp --value 2>/dev/null || true)
  res=$(systemctl show ente-backup.service -p Result --value 2>/dev/null || true)
  if [[ -z $ts ]]; then # systemd forgets the result at a reboot: fall back to the stamp the last good run left
    s=$(cat "$BACKUP_STATE"/last-ok-s3 2>/dev/null || true)
    if [[ -z $s ]]; then warn "backup has not run yet"
    elif (($(date +%s) - $(date -d "$s" +%s) > 36 * 3600)); then bad "last good backup is older than 36 h ($s)"
    else ok "last good backup $s (no run since boot)"; fi
  elif [[ $res != success ]]; then bad "last backup run $ts: $res (journalctl -u ente-backup.service)"
    s=$(cat "$BACKUP_STATE"/last-ok-s3 2>/dev/null || true)
    if [[ -n $s ]] && (($(date +%s) - $(date -d "$s" +%s) <= 36 * 3600)); then ok "S3 part of the backup succeeded $s"; fi
  elif (($(date +%s) - $(date -d "$ts" +%s) > 36 * 3600)); then bad "last backup is older than 36 h ($ts)"
  else ok "last backup finished $ts: $res"; fi
  ex=$(new_uploads s3)
  if [[ $(systemctl show ente-backup.service -p ActiveState --value 2>/dev/null) == activating ]]; then warn "a backup is running: comparison with the backup skipped"
  elif out=$(rclone check "ente-s3:$S3_BUCKET" "${BACKUP_ROOT}objects" --one-way --size-only --checkers 4 --exclude-from "$ex" 2>&1); then ok "rclone check: photo bucket is in the backup"
  else bad "rclone check failed: $(echo "$out" | tail -3 | tr '\n' ' ')"; fi
  rm -f "$ex"
  s=$(cat "$BACKUP_STATE"/last-ok-photo-config 2>/dev/null || true)
  if [[ -z $s ]]; then bad "no config copy in the photo bucket yet (the next backup makes it)"
  elif (($(date +%s) - $(date -d "$s" +%s) > 36 * 3600)); then bad "config copy in the photo bucket is older than 36 h ($s)"
  else ok "config copy in the photo bucket $s"; fi
  s=$(cat "$BACKUP_STATE"/verify-ok 2>/dev/null || true)
  if ! systemctl is-enabled --quiet ente-verify.timer 2>/dev/null; then bad "ente-verify.timer not enabled (run backup-setup)"
  elif [[ -z $s ]]; then warn "monthly verify has not passed yet (run: $0 verify)"
  elif (($(date +%s) - $(date -d "$s" +%s) > 45 * 86400)); then bad "last good verify is older than 45 days ($s)"
  else ok "monthly verify: last passed $s"; fi
  if [[ -n $TG_CHAT_ID ]]; then
    if grep -qx 'OnFailure=ente-alert@%n.service' /etc/systemd/system/ente-backup.service 2>/dev/null &&
      systemctl is-enabled --quiet ente-check.timer 2>/dev/null; then ok "telegram alerts on (backup failure, daily check)"
    else bad "telegram alerts not installed (run backup-setup)"; fi
  elif [[ -z $HC_URL ]]; then warn "no failure alerts (set TG_CHAT_ID or HC_URL)"; fi
  if [[ -n $HC_URL ]]; then
    s=$(cat "$BACKUP_STATE"/hc-fail 2>/dev/null || true)
    if [[ -n $s ]]; then bad "heartbeat ping (HC_URL) failed after the backup of $s"
    elif s=$(cat "$BACKUP_STATE"/hc-ok 2>/dev/null); then ok "heartbeat pinged $s (outside monitor)"
    else warn "heartbeat (HC_URL) not pinged yet: it is pinged after the next good backup"; fi
  fi
  echo "== system"
  df -h / | sed 's/^/        /'
  warn "check storage usage of both buckets in the providers' consoles"
  s=$(journalctl -k -q --since '30 days ago' 2>/dev/null | grep -ciE 'out of memory|oom-kill' || true)
  if [[ $s == 0 ]]; then ok "no OOM kills in 30 days"; else bad "$s OOM kernel messages (journalctl -k | grep -i oom)"; fi
  if [[ -e /var/run/reboot-required ]]; then warn "reboot required"; else ok "no reboot pending"; fi
  echo
  if ((FAILS)); then echo "$FAILS check(s) FAILED"; return 1; fi
  echo "all checks passed"
}

# ---------------------------------------------------------------- verify
# verify: deep test of the S3 backup, monthly by ente-verify.timer (a FAIL alerts like the daily check). It proves the backup
# can be restored, which `check` does not: photo objects by checksum, the encrypted config byte for byte, a test restore of the
# newest dump into a scratch database, and the keys in the backed-up museum.yaml. It changes neither the backup nor the live
# database.
VERIFY_TMP=
verify_cleanup() {
  [[ -z $VERIFY_TMP ]] || rm -rf "$VERIFY_TMP"
  dc exec -T postgres rm -f /tmp/ente-verify.dump </dev/null >/dev/null 2>&1 || true
  dc exec -T postgres psql -U pguser -d postgres -qc 'DROP DATABASE IF EXISTS ente_verify' </dev/null >/dev/null 2>&1 || true
}
# vq ARGS: psql in the postgres container, unaligned output with space-separated columns.
vq() { dc exec -T postgres psql -U pguser -At -F ' ' "$@" </dev/null; }
cmd_verify() {
  load_env
  local out dump n i live rest lt lu lf rt ru rf ex
  rclone listremotes | grep -x 'backup-crypt:' >/dev/null || die "run backup-setup first"
  rclone listremotes | grep -x 'photo-crypt:' >/dev/null || die "run backup-setup first (no config copy in the photo bucket)"
  for ((i = 0; i < 720; i++)); do # a backup that is still running would show false differences: wait for it, up to 6 h
    [[ $(systemctl show ente-backup.service -p ActiveState --value) == activating ]] || break
    ((i)) || log "a backup is running, waiting for it"
    sleep 30
  done
  ((i < 720)) || die "the backup is still running after 6 h"
  VERIFY_TMP=$(mktemp -d /root/ente-verify.XXXXXX)
  trap verify_cleanup EXIT

  echo "== photo objects (checksums)"
  ex=$(new_uploads s3)
  if out=$(rclone check "ente-s3:$S3_BUCKET" "${BACKUP_ROOT}objects" --one-way --checkers 4 --exclude-from "$ex" 2>&1); then
    n=$(grep -oE '[0-9]+ matching files' <<<"$out" | tail -1 || true)
    ok "photo bucket is in the backup with the same checksums (${n:-0 matching files}; $(($(wc -l <"$ex") - 1)) uploaded around or after the last backup, not compared)"
    n=$(grep -oE '[0-9]+ hashes could not be checked' <<<"$out" | tail -1 || true)
    [[ -z $n ]] || warn "$n (no common checksum; compared by size)"
  else bad "photo objects differ from the backup: $(rc_err "$out")"; fi
  rm -f "$ex"

  echo "== config backup (decrypted, byte for byte)"
  if out=$(rclone check "$DUMP_DIR" backup-crypt: --download --checkers 4 2>&1); then
    ok "config backup decrypts with the stored passphrase and equals the local copies ($(grep -oE '[0-9]+ matching files' <<<"$out" | tail -1))"
  else bad "config backup differs or cannot be decrypted: $(rc_err "$out")"; fi
  if out=$(rclone check "$DUMP_DIR" photo-crypt: --download --checkers 4 2>&1); then
    ok "config copy in the photo bucket decrypts and equals the local copies ($(grep -oE '[0-9]+ matching files' <<<"$out" | tail -1))"
  else bad "config copy in the photo bucket differs or cannot be decrypted: $(rc_err "$out")"; fi

  echo "== database dump (test restore into a scratch database)"
  dump=$(rclone lsf backup-crypt: --include 'ente_db-*.dump' 2>/dev/null | sort | tail -1 || true)
  if [[ -z $dump ]]; then bad "no database dump in the backup"
  elif ! rclone copy backup-crypt: "$VERIFY_TMP" --include "$dump" --include museum.yaml 2>/dev/null; then bad "cannot download $dump from the backup"
  else
    if [[ ${dump:8:10} < $(date -d yesterday +%F) ]]; then bad "newest dump in the backup is old: $dump"; else ok "newest dump in the backup: $dump"; fi
    n="SELECT (SELECT count(*) FROM pg_tables WHERE schemaname = 'public'), (SELECT count(*) FROM users), (SELECT count(*) FROM files)"
    if ! vq -d postgres -qc 'DROP DATABASE IF EXISTS ente_verify' -c 'CREATE DATABASE ente_verify' >/dev/null 2>&1 ||
      ! dc cp "$VERIFY_TMP/$dump" postgres:/tmp/ente-verify.dump </dev/null >/dev/null 2>&1; then bad "cannot prepare the scratch database"
    elif ! out=$(dc exec -T postgres pg_restore -U pguser -d ente_verify --no-owner --exit-on-error /tmp/ente-verify.dump </dev/null 2>&1); then
      bad "$dump does not restore: $(tail -2 <<<"$out" | tr '\n' ' ')"
    elif ! live=$(vq -d ente_db -c "$n") || ! rest=$(vq -d ente_verify -c "$n"); then bad "cannot count rows after the test restore"
    else
      ok "$dump restores without errors"
      read -r lt lu lf <<<"$live"; read -r rt ru rf <<<"$rest"
      # the dump is older than the live data, so row counts may differ; an empty table that is not empty live is damage
      if [[ $rt == "$lt" ]] && { ((ru > 0)) || ((lu == 0)); } && { ((rf > 0)) || ((lf == 0)); }; then
        ok "restored: $rt tables, $ru users, $rf files (live now: $lt tables, $lu users, $lf files)"
      else bad "restored dump looks incomplete: $rt tables, $ru users, $rf files (live: $lt tables, $lu users, $lf files)"; fi
    fi
    echo "== keys"
    if python3 -I - "$ENTE_DIR/museum.yaml" "$VERIFY_TMP/museum.yaml" <<'PY' 2>/dev/null
import sys, yaml
a, b = (yaml.safe_load(open(f)) for f in sys.argv[1:])
sys.exit(not (a["key"] == b["key"] and a["jwt"] == b["jwt"]))
PY
    then ok "museum.yaml in the backup holds the live encryption keys"
    else bad "museum.yaml in the backup is missing or its keys differ from the live ones"; fi
  fi
  verify_cleanup; trap - EXIT
  echo
  if ((FAILS)); then echo "$FAILS verify check(s) FAILED"; return 1; fi
  mkdir -p "$BACKUP_STATE"; date -Is >"$BACKUP_STATE/verify-ok"
  echo "backup verified"
}

# ---------------------------------------------------------------- speedtest
# speedtest: for 30 minutes serve a download/upload test under https://api.$DOMAIN/speedtest-<random token>/ to measure the
# connection between a device and this server (the photos themselves travel device <-> bucket, not through here).
# A small local server streams random data and swallows uploads; Caddy gets the route through its admin API, so the
# Caddyfile is untouched and the route is gone when the test ends (or at the next Caddy reload).
cmd_speedtest() {
  load_env
  local tok url port=8099
  command -v caddy >/dev/null || die "run install first"
  write_file /usr/local/bin/ente-speedtest 755 <<'EOF'
#!/usr/bin/env python3
# Managed by ente-setup.sh. GET .../down/<MB> streams random data; PUT/POST .../up reads and discards the body.
import os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
BLOCK = os.urandom(1 << 20)
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        try: mb = max(1, min(2000, int(self.path.rstrip("/").rsplit("/", 1)[1])))
        except ValueError: mb = 100
        self.send_response(200); self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(mb << 20)); self.send_header("Cache-Control", "no-store"); self.end_headers()
        for _ in range(mb): self.wfile.write(BLOCK)
    def do_PUT(self):
        n = int(self.headers.get("Content-Length") or 0); left = n
        while left > 0:
            d = self.rfile.read(min(left, 1 << 20))
            if not d: break
            left -= len(d)
        b = str(n - left).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    do_POST = do_PUT
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
  systemctl stop ente-speedtest.service >/dev/null 2>&1 || true
  systemctl reset-failed ente-speedtest.service >/dev/null 2>&1 || true
  curl -fsS -m 5 -o /dev/null --unix-socket "$CADDY_ADMIN_SOCK" -X DELETE http://localhost/id/ente-speedtest 2>/dev/null || true
  [[ -z $(ss -Htln "sport = :$port") ]] || die "port $port is in use"
  tok=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
  systemd-run --quiet --unit ente-speedtest --description "Ente speed test endpoint (temporary)" -p DynamicUser=yes -p RuntimeMaxSec=1800 \
    -p ExecStopPost="+/usr/bin/curl -fsS -m 5 -o /dev/null --unix-socket $CADDY_ADMIN_SOCK -X DELETE http://localhost/id/ente-speedtest" \
    /usr/local/bin/ente-speedtest "$port"
  # first in the route list: the Caddyfile's host routes are terminal
  curl -fsS -m 5 -o /dev/null --unix-socket "$CADDY_ADMIN_SOCK" -X PUT -H 'Content-Type: application/json' http://localhost/config/apps/http/servers/srv0/routes/0 -d @- <<EOF ||
{"@id": "ente-speedtest", "terminal": true,
 "match": [{"host": ["api.$DOMAIN"], "path": ["/speedtest-$tok/*"]}],
 "handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": "127.0.0.1:$port"}], "flush_interval": -1}]}
EOF
    { systemctl stop ente-speedtest.service; die "could not add the route to Caddy (admin API on $CADDY_ADMIN_SOCK)"; }
  url=https://api.$DOMAIN/speedtest-$tok
  url_ok "$url/down/1" 5 || { systemctl stop ente-speedtest.service; die "the test endpoint does not answer"; }
  cat <<EOF

Speed test endpoint is up for 30 minutes (stop earlier: systemctl stop ente-speedtest):
  $url

Linux/macOS:  curl -o /dev/null -w 'download: %{speed_download} bytes/s\\n' $url/down/100
              head -c 100000000 /dev/urandom > /tmp/up.bin && curl -o /dev/null -T /tmp/up.bin -w 'upload: %{speed_upload} bytes/s\\n' $url/up
EOF
}

# ---------------------------------------------------------------- alert-test
# alert-test: send a test message through the installed alert path.
cmd_alert_test() {
  load_env
  [[ -n $TG_CHAT_ID && -x /usr/local/bin/ente-alert ]] || die "alerts not set up: set TG_CHAT_ID, then run backup-setup"
  echo "Test from ente-setup on $(hostname) ($DOMAIN). Alerts arrive here when a backup or the daily check fails." |
    /usr/local/bin/ente-alert "🔔 Ente alert test" || die "sending failed: wrong TG_CHAT_ID, or nobody pressed Start in the bot / the bot is not in the group"
  log "test message sent"
}

# ---------------------------------------------------------------- main
OPS_COMMANDS="check verify alert-test speedtest"
ops_usage() { echo "usage: $0 {${OPS_COMMANDS// /|}}" >&2; exit 2; }

# sourced (tests): define the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  [[ $# -eq 1 && " $OPS_COMMANDS " == *" $1 "* ]] || ops_usage
  [[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $*)" >&2; exit 1; }
  touch "$LOG"; chmod 600 "$LOG"
  main "$@" 2>&1 | tee -a "$LOG"
fi
