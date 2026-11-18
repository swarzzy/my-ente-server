#!/usr/bin/env bash
# run_all.sh - every test suite that can run here, one summary line each; exit 1 if any failed.
#   bash tests/run_all.sh            the suites that change nothing: anywhere (plus the two bucket suites where rclone is)
#   sudo bash tests/run_all.sh --server   on the live server: also the VPN config test and the end-to-end tests, which
#                                         install, switch and uninstall the add-ons for real and leave them as they found them
# Output of each suite: <tmp dir>/<suite>.out (the path is printed at the end).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
SERVER=no
case ${1:-} in
  "") ;;
  --server) SERVER=yes ;;
  *) echo "usage: $0 [--server]" >&2; exit 2 ;;
esac
if [[ $SERVER == yes && $EUID -ne 0 ]]; then echo "--server needs root (sudo $0 --server)" >&2; exit 1; fi
OUT=$(mktemp -d)
failed=0
# run NAME CMD...: run one suite, print its result line (the bash suites' "N passed, M failed", unittest's "Ran N tests")
run() {
  local name=$1 rc totals; shift
  timeout 3600 "$@" >"$OUT/$name.out" 2>&1; rc=$?
  ((rc == 0)) || failed=$((failed + 1))
  totals=$(grep -hE 'passed, [0-9]+ failed|^Ran [0-9]+ tests' "$OUT/$name.out" | tail -1)
  printf '%-24s %-6s %s\n' "$name" "$( ((rc == 0)) && echo ok || echo FAILED)" "$totals"
}
skip() { printf '%-24s %-6s %s\n' "$1" skip "$2"; }

for t in test_cli test_check test_alerts test_lockdown test_update test_proxy_config test_tg_bot_config test_quickstart; do
  run "$t" bash "tests/$t.sh"
done
run unittest python3 -m unittest discover -s tests
for t in test_backup_checks test_bucket_copies; do
  if command -v rclone >/dev/null; then run "$t" bash "tests/$t.sh"; else skip "$t" "needs rclone (run on the server)"; fi
done
if [[ $SERVER == yes ]]; then
  if [[ -e /etc/amnezia/amneziawg/awg0.conf ]]; then run test_vpn_config bash tests/test_vpn_config.sh; else skip test_vpn_config "VPN not installed"; fi
  run proxy_e2e bash tests/proxy_e2e.sh
  run tg_bot_e2e bash tests/tg_bot_e2e.sh
  run proxy_browser_e2e bash tests/proxy_browser_e2e.sh
else
  skip "server suites" "VPN config and end-to-end tests: sudo bash tests/run_all.sh --server on the server"
fi
echo
echo "$failed suite(s) failed; output in $OUT"
((failed == 0))
