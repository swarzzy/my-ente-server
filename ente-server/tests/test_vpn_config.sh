#!/usr/bin/env bash
# Tests for ente-vpn.sh's config generator (awg_genconf): the server and client configs it writes into a temp dir (keys that
# pair up, the same obfuscation parameters on both sides and within AmneziaWG's rules, mode 600), that it never overwrites
# existing configs, and that it refuses a port already in use. It tries the parameters on a throwaway interface (awgtst0),
# so it needs root and AmneziaWG: the server after `ente-vpn.sh install`. The live tunnel and its files are not touched.
# Run: sudo bash tests/test_vpn_config.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $EUID -eq 0 ]] && command -v awg >/dev/null || { echo "needs root and AmneziaWG (run it on the server after ente-vpn.sh install)"; exit 1; }

port=27000; while [[ -n $(ss -Hlun "sport = :$port") ]]; do port=$((port + 1)); done
# gen DIR PORT: awg_genconf for 203.0.113.7 with its files in DIR
gen() {
  mkdir -p "$1"
  ( # shellcheck source=/dev/null
    . "$HERE/../ente-vpn.sh"
    AWG_CONF=$1/server.conf AWG_CLIENT=$1/client.conf AWG_NAT=$1/nat.nft AWG_PORT=$2
    awg_genconf 203.0.113.7 ) >"$1/out" 2>&1
}
# rules DIR: check the generated pair; prints what is wrong, nothing if all is right
rules() {
  python3 -I - "$1/server.conf" "$1/client.conf" "$port" <<'PY'
import subprocess, sys
def parse(path):
    secs, cur = [], None
    for l in open(path):
        l = l.strip()
        if l.startswith("["): cur = {}; secs.append((l, cur))
        elif "=" in l: k, v = l.split("=", 1); cur[k.strip()] = v.strip()
    return dict(secs)
def pub(k): return subprocess.run(["awg", "pubkey"], input=k, capture_output=True, text=True, check=True).stdout.strip()
s, c, port = parse(sys.argv[1]), parse(sys.argv[2]), sys.argv[3]
si, sp, ci, cp = s["[Interface]"], s["[Peer]"], c["[Interface]"], c["[Peer]"]
bad = []
if sp["PublicKey"] != pub(ci["PrivateKey"]): bad.append("server's peer key is not the client's")
if cp["PublicKey"] != pub(si["PrivateKey"]): bad.append("client's peer key is not the server's")
if sp["PresharedKey"] != cp["PresharedKey"]: bad.append("preshared keys differ")
if si["ListenPort"] != port or cp["Endpoint"] != "203.0.113.7:" + port: bad.append("port or endpoint wrong")
obf = ["Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "HeaderProtectionKey"]
if any(si.get(k) != ci.get(k) or not si.get(k) for k in obf): bad.append("obfuscation parameters differ or are missing")
jc, jmin, jmax, s1, s2, s3, s4 = (int(si[k]) for k in obf[:7])
if not 4 <= jc <= 8: bad.append("Jc %d" % jc)
if not (64 <= jmin and jmin + 200 <= jmax <= 900): bad.append("Jmin/Jmax %d/%d" % (jmin, jmax))
if s1 + 56 == s2 or len({148 + s1, 92 + s2, 64 + s3}) != 3: bad.append("S1-S3 make two message sizes equal")
hs = sorted(tuple(map(int, si[k].split("-"))) for k in ("H1", "H2", "H3", "H4"))
if hs[0][0] < 5 or any(b - a < 2**16 for a, b in hs) or any(hs[i][1] >= hs[i + 1][0] for i in range(3)):
    bad.append("H ranges overlap, are too narrow or hit WireGuard's types 1-4: %s" % hs)
if "AllowedIPs" not in cp or "0.0.0.0/0" not in cp["AllowedIPs"]: bad.append("client does not route everything")
print("\n".join(bad))
PY
}

echo "== generated configs"
for i in 1 2 3; do
  gen "$T/g$i" "$port"; RC=$?
  check "run $i: writes a server and a client config" '((RC == 0)) && [[ -s $T/g$i/server.conf && -s $T/g$i/client.conf ]]' "$(tail -3 "$T/g$i/out")"
  check "... both mode 600 (they hold private keys)" '[[ $(stat -c %a "$T/g$i/server.conf") == 600 && $(stat -c %a "$T/g$i/client.conf") == 600 ]]'
  out=$(rules "$T/g$i" 2>&1)
  check "... keys pair up, same parameters on both sides, within AmneziaWG's rules" '[[ -z $out ]]' "$out"
done
check "each run draws new keys and parameters" '! cmp -s "$T/g1/server.conf" "$T/g2/server.conf" && ! cmp -s "$T/g2/server.conf" "$T/g3/server.conf"'
check "no test interface is left behind" '! ip link show awgtst0 >/dev/null 2>&1'

echo "== never overwrites, refuses a busy port"
sha=$(sha256sum "$T/g1/server.conf" "$T/g1/client.conf")
gen "$T/g1" "$port"; RC=$?
check "configs already there: fails and leaves them as they were" '((RC != 0)) && [[ $(sha256sum "$T/g1/server.conf" "$T/g1/client.conf") == "$sha" ]]' "$(tail -2 "$T/g1/out")"
python3 -I -c 'import socket, sys, time; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", int(sys.argv[1]))); time.sleep(60)' "$port" &
busy=$!; sleep 0.5
gen "$T/busy" "$port"; RC=$?
kill "$busy" 2>/dev/null; wait "$busy" 2>/dev/null
check "a port already in use: refused, nothing written" \
  '((RC != 0)) && grep -q "already listens on UDP/$port" "$T/busy/out" && [[ ! -e $T/busy/server.conf && ! -e $T/busy/client.conf ]]' "$(tail -2 "$T/busy/out")"

summary
