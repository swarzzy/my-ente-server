#!/usr/bin/env bash
# Tests for `lockdown` and the managed internal: block in museum.yaml it writes (sync_internal): the oldest user becomes the
# admin and sign-ups close only after a yes, re-runs change nothing, install's re-run keeps the block, a museum.yaml with
# its own internal: section is refused, and the file is edited in place (museum bind-mounts it). Postgres and docker are
# stubs, so this runs anywhere bash and python3 with yaml are, and changes nothing outside a temp dir.
# Run: bash tests/test_lockdown.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/        /' | head -20; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }

printf '%s\n' DOMAIN=photos.example.org S3_ENDPOINT=s3.example.net S3_REGION=r1 S3_BUCKET=photos \
  BACKUP_S3_ENDPOINT=b2.example.net BACKUP_S3_REGION=r2 BACKUP_S3_BUCKET=bk >"$T/env"
M=$T/ente/museum.yaml
mkdir -p "$T/ente"
museum() { printf 'db:\n  host: postgres\napps:\n  public-albums: https://albums.photos.example.org\nkey:\n  encryption: K\n' >"$M"; }
# lockdown_run ANSWER: cmd_lockdown with the users in $T/users (user_id|created, oldest first), museum and Postgres stubbed
lockdown_run() {
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-setup.sh"
    ENTE_DIR=$T/ente
    set +e
    load_env
    wait_healthy() { :; }
    dc() { case "$*" in *"FROM users"*) cat "$T/users" ;; "restart museum") echo restarted >>"$T/restarts" ;; esac; }
    cmd_lockdown <<<"$1" ) >"$T/out" 2>&1
}
in_setup() {
  ( ENV_FILE=$T/env SECRETS_FILE=$T/none CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-setup.sh"
    ENTE_DIR=$T/ente
    set +e
    load_env
    eval "$1" ) >"$T/out" 2>&1
}
y() { python3 -I -c "import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print($1)" "$M" 2>&1; }
restarts() { cat "$T/restarts" 2>/dev/null | wc -l; }

echo "== lockdown"
museum; : >"$T/users"
lockdown_run y; RC=$?
check "no users yet: refused" '((RC != 0)) && grep -q "no users yet" "$T/out"' "$(tail -2 "$T/out")"
printf '%s\n' '1580559962386438|2026-11-16 08:00:00+00' '1580559962386440|2026-11-16 09:00:00+00' >"$T/users"
cp "$M" "$T/before"
lockdown_run n; RC=$?
check "answer n: aborted" '((RC != 0)) && grep -q aborted "$T/out"' "$(tail -2 "$T/out")"
check "... museum.yaml unchanged and museum not restarted" 'cmp -s "$M" "$T/before" && [[ $(restarts) -eq 0 ]]'
lockdown_run ""; RC=$?
check "no answer (closed stdin or Enter): aborted, unchanged" '((RC != 0)) && cmp -s "$M" "$T/before"' "$(tail -2 "$T/out")"
ino=$(stat -c %i "$M")
lockdown_run y; RC=$?
check "answer y: done" '((RC == 0)) && grep -q "lockdown done: admin=1580559962386438" "$T/out"' "$(tail -2 "$T/out")"
check "... the OLDEST user is the only admin" '[[ $(y "d[\"internal\"][\"admins\"]") == "[1580559962386438]" ]]' "$(cat "$M")"
check "... sign-ups are closed" '[[ $(y "d[\"internal\"][\"disable-registration\"]") == True ]]'
check "... the rest of museum.yaml is untouched" '[[ $(y "d[\"key\"][\"encryption\"], d[\"db\"][\"host\"], d[\"apps\"][\"public-albums\"]") == "K postgres https://albums.photos.example.org" ]]' "$(cat "$M")"
check "... edited in place (same inode: museum bind-mounts it)" '[[ $(stat -c %i "$M") == "$ino" ]]'
check "... museum restarted once" '[[ $(restarts) -eq 1 ]]'
sha=$(sha256sum "$M")
lockdown_run y; RC=$?
check "lockdown again: 'already locked down', nothing changes, no restart" \
  '((RC == 0)) && grep -q "already locked down" "$T/out" && [[ $(sha256sum "$M") == "$sha" && $(restarts) -eq 1 ]]' "$(tail -2 "$T/out")"

echo "== the managed block (sync_internal)"
in_setup 'sync_internal; echo "changed=$MUSEUM_CFG_CHANGED"'
check "install's re-run (no arguments) keeps admin and lock, changes nothing" \
  '[[ $(sha256sum "$M") == "$sha" ]] && grep -q "changed=0" "$T/out"' "$(cat "$T/out")"
in_setup 'sync_internal "" no; echo "changed=$MUSEUM_CFG_CHANGED"'
check "opening sign-ups again keeps the admin" \
  '[[ $(y "d[\"internal\"]") == "{'"'"'admins'"'"': [1580559962386438]}" ]] && grep -q "changed=1" "$T/out"' "$(cat "$M")"
check "check sees sign-ups open after lockdown (internal_locked false, admin set)" \
  '! in_setup internal_locked && [[ $(in_setup internal_admin; cat "$T/out") == 1580559962386438 ]]'
check "only one managed block, at most one internal: section" '[[ $(grep -c "^internal:" "$M") -eq 1 && $(grep -c "BEGIN ente-setup internal" "$M") -eq 1 ]]'
museum; printf 'internal:\n  admins: [5]\n' >>"$M"; cp "$M" "$T/before"
in_setup 'sync_internal 7 yes'; RC=$?
check "museum.yaml with its own internal: section: refused, unchanged" \
  '((RC != 0)) && grep -q "its own internal: section" "$T/out" && cmp -s "$M" "$T/before"' "$(cat "$T/out")"

echo
echo "$PASS passed, $FAIL failed"
((FAIL == 0))
