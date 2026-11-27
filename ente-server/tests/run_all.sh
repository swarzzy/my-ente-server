#!/usr/bin/env bash
# run_all.sh - every test suite that can run here, one summary line each; exit 1 if any failed.
#   bash tests/run_all.sh            the suites that change nothing, side by side (JOBS=4): anywhere (plus the two bucket suites
#                                    where rclone is)
#   sudo bash tests/run_all.sh --server   on the live server: also the VPN config test and the proxy and bot end-to-end
#                                         tests, which install, switch and uninstall the add-ons for real and leave them as
#                                         they found them (about 3.5 min in all)
#   sudo bash tests/run_all.sh --browser  --server plus the web app in a real browser (about 4.5 min more): it opens sign-ups
#                                         for a throwaway account and uploads 41 MB; run it after touching the proxy or the
#                                         web apps, and after an Ente update
# Output of each suite: <tmp dir>/<suite>.out (the path is printed at the end).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
SERVER=no BROWSER=no
case ${1:-} in
  "") ;;
  --server) SERVER=yes ;;
  --browser) SERVER=yes BROWSER=yes ;;
  *) echo "usage: $0 [--server | --browser]" >&2; exit 2 ;;
esac
if [[ $SERVER == yes && $EUID -ne 0 ]]; then echo "$1 needs root (sudo $0 $1)" >&2; exit 1; fi
OUT=$(mktemp -d)
failed=0
# report NAME RC SECONDS: one result line (the bash suites' "N passed, M failed", unittest's "Ran N tests")
report() {
  local totals
  (($2 == 0)) || failed=$((failed + 1))
  totals=$(grep -hE 'passed, [0-9]+ failed|^Ran [0-9]+ tests' "$OUT/$1.out" | tail -1)
  printf '%-24s %-6s %4ds  %s\n' "$1" "$( (($2 == 0)) && echo ok || echo FAILED)" "$3" "$totals"
}
# run NAME CMD...: run one suite now and report it
run() {
  local name=$1 rc t0=$SECONDS; shift
  timeout 3600 "$@" >"$OUT/$name.out" 2>&1; rc=$?
  report "$name" "$rc" $((SECONDS - t0))
}
skip() { printf '%-24s %-6s %5s  %s\n' "$1" skip "" "$2"; }

# The suites that change nothing each work in a temp dir of their own: they run side by side, JOBS at a time, and are
# reported in this order once all are done. The server suites below change the server and run one after another.
JOBS=${JOBS:-4}
quiet=(test_cli test_check test_alerts test_lockdown test_update test_proxy_config test_tg_bot_config test_quickstart unittest
  opsbot_unittest test_opsbot_cli)
if command -v rclone >/dev/null; then quiet+=(test_backup_checks test_bucket_copies); fi
for t in "${quiet[@]}"; do
  while (($(jobs -rp | wc -l) >= JOBS)); do wait -n; done
  ( t0=$SECONDS
    case $t in # opsbot (../opsbot) has its own suites: the Ente bot and alerts build on it
      unittest) timeout 3600 python3 -m unittest discover -s tests ;;
      opsbot_unittest) cd ../opsbot && timeout 3600 python3 -m unittest discover -s tests ;;
      test_opsbot_cli) timeout 3600 bash ../opsbot/tests/test_opsbot_cli.sh ;;
      *) timeout 3600 bash "tests/$t.sh" ;;
    esac >"$OUT/$t.out" 2>&1
    echo "$? $((SECONDS - t0))" >"$OUT/$t.rc" ) &
done
wait
for t in "${quiet[@]}"; do report "$t" $(cat "$OUT/$t.rc"); done
command -v rclone >/dev/null || for t in test_backup_checks test_bucket_copies; do skip "$t" "needs rclone (run on the server)"; done
if [[ $SERVER == yes ]]; then
  if [[ -e /etc/amnezia/amneziawg/awg0.conf ]]; then run test_vpn_config bash tests/test_vpn_config.sh; else skip test_vpn_config "VPN not installed"; fi
  run proxy_e2e bash tests/proxy_e2e.sh
  if [[ -f /etc/opsbot/opsbot.conf && -n $(sed -n 's/^USER_ID=//p' /etc/opsbot/opsbot.conf) ]]; then
    run opsbot_e2e bash ../opsbot/tests/opsbot_e2e.sh
  else skip opsbot_e2e "opsbot not installed with a bot"; fi
  run tg_bot_e2e bash tests/tg_bot_e2e.sh
  if [[ $BROWSER == yes ]]; then run proxy_browser_e2e bash tests/proxy_browser_e2e.sh
  else skip proxy_browser_e2e "the web app in a browser: --browser"; fi
else
  skip "server suites" "VPN config and end-to-end tests: sudo bash tests/run_all.sh --server on the server"
fi
echo
echo "$failed suite(s) failed in $((SECONDS / 60)) min $((SECONDS % 60)) s; output in $OUT"
((failed == 0))
