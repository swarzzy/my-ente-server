# lib.sh - the helpers every bash test shares (source it first): HERE (this folder), T (a temp dir, removed on exit unless the
# test sets its own trap, which must remove it too), pass/fail/check and summary.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
# fail NAME [DETAILS]: DETAILS (what was seen) is shown indented, at most 20 lines
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/        /' | head -20; }
# check NAME CONDITION [DETAILS]: CONDITION is evaluated (single-quoted by the caller, so it sees the current values)
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }
# summary: the totals; the test's exit status is 1 if anything failed
summary() { echo; echo "$PASS passed, $FAIL failed"; ((FAIL == 0)); }
