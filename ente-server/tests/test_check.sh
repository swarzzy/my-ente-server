#!/usr/bin/env bash
# Tests for `ente-ops.sh check` outside its backup part (that is in test_backup_checks.sh): services and image age, web and
# certificates, open ports, sshd/UFW, disk, OOM kills, a pending reboot. docker, ss, sshd, ufw, curl, df, journalctl and
# `openssl s_client` are stubbed, so each section sees a server in a chosen state. Each fault must give exactly one FAIL (or the
# expected WARN), a healthy server none. Changes nothing outside a temp dir. Needs bash and openssl. Run: bash tests/test_check.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/        /' | head -20; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }

printf '%s\n' DOMAIN=photos.example.org S3_ENDPOINT=s3.example.net S3_REGION=r1 S3_BUCKET=photo BACKUP_S3_ENDPOINT=b2.example.net \
  BACKUP_S3_REGION=r2 BACKUP_S3_BUCKET=bk SSH_PORT=42876 ADMIN_USER=ops >"$T/env"
mkdir -p "$T/ente"
printf 'internal:\n  admins: [1580559962386439]\n  disable-registration: true\n' >"$T/ente/museum.yaml"
# run SECTION: one check section with the stubs below, output in $T/out, its FAIL count in $T/fails
run() {
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-ops.sh"
    ENTE_DIR=$T/ente REBOOT_FLAG=$T/reboot-required
    set +e
    load_env
    sleep() { :; }
    systemctl() { case "$*" in "is-active --quiet caddy") [[ -z ${CADDY_DOWN:-} ]] ;; esac; }
    dc() { [[ $1 == ps && " ${SVC_DOWN:-} " != *" $3 "* ]] && echo "cid-$3"; return 0; }
    docker() {
      case "$*" in
        "image inspect -f {{.Created}} img-"*) date -u -d "${IMG_AGE:-5} days ago" +%FT%T.123456789Z ;;
        "inspect -f {{.Image}} cid-"*) echo "img-${4#cid-}" ;;
        "inspect -f "*State*" cid-"*)
          local s=${4#cid-}
          if [[ " ${SVC_BAD:-} " == *" $s "* ]]; then echo unhealthy; elif [[ $s == web ]]; then echo running; else echo healthy; fi ;;
      esac
    }
    curl() { local u=${*: -1}; [[ " ${URL_DOWN:-} " != *" $u "* ]]; }
    openssl() {
      if [[ $1 == s_client ]]; then local h=${*: -1}; cat "$T/cert-${h%%.*}.pem" 2>/dev/null; else command openssl "$@"; fi
    }
    ss() { if [[ $1 == -Htlnp ]]; then cat "$T/ss"; elif [[ -z ${SSHD_DOWN:-} ]]; then echo "LISTEN 0 128 0.0.0.0:42876 0.0.0.0:*"; fi; }
    sshd() { cat "$T/sshd"; }
    ufw() { cat "$T/ufw"; }
    df() { printf 'Use%%  Used  Size\n %s%%  5.7G   24G\n' "${PCT:-26}"; }
    journalctl() { local i; for ((i = 0; i < ${OOM:-0}; i++)); do echo "Out of memory: Killed process 1 (x)"; done; }
    eval "$1" ) >"$T/out" 2>&1
  grep -c '^  FAIL' "$T/out" >"$T/fails"
}
fails() { cat "$T/fails"; }
one_fail() { [[ $(fails) -eq 1 ]] && grep -q "^  FAIL.*$1" "$T/out"; }
cert() { command openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout /dev/null -subj /CN=x -days "$2" -out "$T/cert-$1.pem" 2>/dev/null; }
healthy() {
  for h in api web albums; do cert $h 89; done
  cat >"$T/ss" <<'X'
LISTEN 0      4096   127.0.0.1:8080  0.0.0.0:* users:(("docker-proxy",pid=1348,fd=8))
LISTEN 0      1024   127.0.0.1:8081  0.0.0.0:* users:(("python3",pid=170089,fd=3))
LISTEN 0      4096   127.0.0.1:3000  0.0.0.0:* users:(("docker-proxy",pid=1311,fd=8))
LISTEN 0      4096   127.0.0.53%lo:53  0.0.0.0:* users:(("systemd-resolve",pid=1,fd=8))
LISTEN 0      4096   [::1]:631  [::]:* users:(("cupsd",pid=2,fd=8))
LISTEN 0      128      0.0.0.0:42876 0.0.0.0:* users:(("sshd",pid=758,fd=6))
LISTEN 0      128         [::]:42876    [::]:* users:(("sshd",pid=758,fd=7))
LISTEN 0      4096           *:80          *:* users:(("caddy",pid=740,fd=14))
LISTEN 0      4096           *:443         *:* users:(("caddy",pid=740,fd=12))
X
  printf '%s\n' "port 42876" "passwordauthentication no" "permitrootlogin no" "maxauthtries 3" "allowusers ops" >"$T/sshd"
  printf '%s\n' "Status: active" "" "To                         Action      From" "42876/tcp                  ALLOW       Anywhere" >"$T/ufw"
  rm -f "$T/reboot-required"
}
healthy

echo "== services"
run check_services
check "all healthy: no FAIL, no WARN, build dates shown" \
  '[[ $(fails) -eq 0 ]] && ! grep -q WARN "$T/out" && grep -q "OK    museum healthy (image built " "$T/out" && grep -q "sign-ups closed" "$T/out"' "$(cat "$T/out")"
SVC_DOWN=web run check_services
check "web not running: one FAIL" 'one_fail "web not running"' "$(cat "$T/out")"
SVC_BAD=museum run check_services
check "museum unhealthy: one FAIL" 'one_fail "museum unhealthy"' "$(cat "$T/out")"
IMG_AGE=90 run check_services
check "images 90 days old: a WARN for museum and for web (not postgres), no FAIL" \
  '[[ $(fails) -eq 0 && $(grep -c "WARN.*image is 90 days old" "$T/out") -eq 2 ]]' "$(cat "$T/out")"
IMG_AGE=59 run check_services
check "images 59 days old: no WARN" '! grep -q WARN "$T/out"' "$(cat "$T/out")"

echo "== web"
run check_web
check "all answer, certificates fresh: no FAIL" '[[ $(fails) -eq 0 ]] && grep -q "certificates valid for 8[89]+ days" "$T/out"' "$(cat "$T/out")"
CADDY_DOWN=1 run check_web
check "caddy down: one FAIL, not one per site" 'one_fail "caddy is not running"' "$(cat "$T/out")"
URL_DOWN=https://web.photos.example.org/ run check_web
check "web does not answer: one FAIL" 'one_fail "https://web.photos.example.org/ does not answer"' "$(cat "$T/out")"
URL_DOWN=https://albums.photos.example.org/ run check_web
check "albums does not answer: one FAIL" 'one_fail "https://albums.photos.example.org/ does not answer"' "$(cat "$T/out")"
cert albums 10; run check_web
check "a certificate with 10 days left: one FAIL (renewal failing)" 'one_fail "certificate of albums.photos.example.org expires in [0-9]* days"' "$(cat "$T/out")"
cert albums 25; run check_web
check "a certificate with 25 days left: no FAIL" '[[ $(fails) -eq 0 ]] && grep -q "valid for 2[45]+ days" "$T/out"' "$(cat "$T/out")"
rm "$T/cert-api.pem"; run check_web
check "no certificate served: one FAIL" 'one_fail "no certificate served for api.photos.example.org"' "$(cat "$T/out")"
healthy

echo "== security"
run check_security
check "SSH, 80, 443 public, the rest on loopback: no FAIL" '[[ $(fails) -eq 0 ]] && grep -q "only SSH (42876), 80 and 443" "$T/out"' "$(cat "$T/out")"
echo 'LISTEN 0 4096 0.0.0.0:5432 0.0.0.0:* users:(("docker-proxy",pid=9,fd=8))' >>"$T/ss"; run check_security
check "Postgres published on all addresses: one FAIL naming it" 'one_fail "listening beyond localhost: 0.0.0.0:5432 (docker-proxy)"' "$(cat "$T/out")"
healthy; echo 'LISTEN 0 4096 [::]:3000 [::]:* users:(("docker-proxy",pid=9,fd=8))' >>"$T/ss"
echo 'LISTEN 0 4096 10.89.37.1:8080 0.0.0.0:* users:(("museum",pid=9,fd=8))' >>"$T/ss"; run check_security
check "IPv6 and a non-loopback address: one FAIL naming both" \
  'one_fail "\[::\]:3000 (docker-proxy) 10.89.37.1:8080 (museum)"' "$(cat "$T/out")"
healthy; sed -i '/permitrootlogin/d' "$T/sshd"; run check_security
check "root login allowed: one FAIL" 'one_fail "sshd expected: permitrootlogin no"' "$(cat "$T/out")"
healthy; sed -i 's/allowusers ops/allowusers ops eve/' "$T/sshd"; run check_security
check "another user allowed in: one FAIL" 'one_fail "sshd expected: allowusers ops"' "$(cat "$T/out")"
healthy; SSHD_DOWN=1 run check_security
check "sshd not listening: one FAIL" 'one_fail "sshd not listening on 42876"' "$(cat "$T/out")"
echo "Status: inactive" >"$T/ufw"; run check_security
check "ufw inactive: one FAIL" 'one_fail "ufw inactive"' "$(cat "$T/out")"
healthy; sed -i '/42876/d' "$T/ufw"; run check_security
check "ufw without the SSH rule: one FAIL" 'one_fail "ufw does not allow 42876/tcp"' "$(cat "$T/out")"
healthy

echo "== system"
run check_system
check "26% disk, no OOM, no reboot: no FAIL, no WARN" \
  '[[ $(fails) -eq 0 ]] && ! grep -q WARN "$T/out" && grep -q "disk / 26% used (5.7G of 24G)" "$T/out"' "$(cat "$T/out")"
PCT=79 run check_system; check "79%: OK" '[[ $(fails) -eq 0 ]] && ! grep -q WARN "$T/out"' "$(cat "$T/out")"
PCT=80 run check_system; check "80%: WARN" '[[ $(fails) -eq 0 ]] && grep -q "WARN  disk / is 80% full" "$T/out"' "$(cat "$T/out")"
PCT=90 run check_system; check "90%: one FAIL" 'one_fail "disk / is 90% full"' "$(cat "$T/out")"
OOM=2 run check_system; check "OOM kills in 24 h: one FAIL" 'one_fail "2 OOM kernel messages in 24 h"' "$(cat "$T/out")"
touch "$T/reboot-required"; run check_system
check "a fresh reboot flag: OK (automatic at 02:00)" '[[ $(fails) -eq 0 ]] && grep -q "OK    reboot pending: automatic" "$T/out"' "$(cat "$T/out")"
touch -d '30 hours ago' "$T/reboot-required"; run check_system
check "a reboot pending for 30 h: WARN" '[[ $(fails) -eq 0 ]] && grep -q "WARN  reboot pending for over a day" "$T/out"' "$(cat "$T/out")"
rm "$T/reboot-required"

echo "== check runs every section and fails on any FAIL"
run 'for f in check_services check_web check_security check_bucket check_addons check_backup check_system; do eval "$f() { echo $f; }"; done
  check_web() { echo check_web; bad x; }; cmd_check'
check "all seven sections, in order; one FAIL makes it fail" \
  '[[ $(grep -c "^check_" "$T/out") -eq 7 ]] && grep -q "1 check(s) FAILED" "$T/out"' "$(cat "$T/out")"

echo; echo "$PASS passed, $FAIL failed"; ((FAIL == 0))
