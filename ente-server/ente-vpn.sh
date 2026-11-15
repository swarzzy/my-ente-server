#!/usr/bin/env bash
# ente-vpn.sh - optional, independent of Ente: an AmneziaWG 3.1 VPN on this server.
# Usage: ente-vpn.sh {install|status|uninstall}
#   install    AmneziaWG from Amnezia's PPA, keys, server config, ONE shared client config (/root/awg-client.conf), UFW and
#              NAT, start at boot, self-test. Re-runnable: keeps the keys, follows a changed AWG_PORT.
#   status     service, listening port, peers' last handshake (no keys printed)
#   uninstall  stop and remove it all: service, configs and keys, firewall rules, packages, the PPA
# Config: AWG_PORT in ente-setup.env. Needs only `ente-setup.sh bootstrap` (UFW) and ente-setup.sh next to it (its helpers).
VPN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ente-setup.sh
. "$VPN_DIR/ente-setup.sh" # its helpers and config; its own main does not run when sourced

AWG_CONF=/etc/amnezia/amneziawg/awg0.conf
AWG_NAT=/etc/amnezia/amneziawg/awg0-nat.nft
AWG_CLIENT=/root/awg-client.conf
AWG_SUBNET=10.89.37.0/24

# Amnezia's Launchpad PPA (suite focal: the project's own instructions for Debian), signing key pinned by fingerprint,
# then kernel headers, the DKMS module and the tools.
awg_install() {
  local fl pkgs
  [[ $(dpkg --print-architecture) == amd64 ]] || die "the Amnezia packages are amd64 only"
  if [[ $(uname -r) == *-cloud-amd64 ]]; then fl=cloud-amd64; else fl=amd64; fi
  install -d -m 755 /etc/apt/keyrings
  write_file /etc/apt/keyrings/amnezia.asc <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: Hockeypuck 2.2
Comment: Hostname: 

xsFNBGV0UhsBEAC33rMndHSN/k+u7gcZbh9/FjgYfGltQAtVe2QDxzn7UV+k/ChX
OrYRw6Izw/DrhaapkNCThK2jwJE64e0NjboLH7UrrmSJLXMfOlDFbyGJVRA+1sTB
lo7kKHY0xiZ1CHDzjKNV3czbesu80A9nuTZYyWHEn9ax6wsqKG3N8SvzQkUrIOVD
2wZjh0p273CCEGkBnax1ghAV3MF8OrsPU6FRJ+ZakzKbu54g68xoV+2813YECme0
JKsWfUUe/1uEJOXCvuACURSxnYr0sihJd8QI/jHSGlfeq72e5MflFEOrnu5xaDSJ
r2W5lvUetG7EGSxtNKd7Jm/KhUV04g7arA0qydRjRToW3QqyzG7VB2nXKz3AOBYN
earWAuBcTkfPvRVchxbjiYonKZA5tIlVrpawMZsdxKvYwl6LVnpBcccFWPhpudfy
4TpCqCxRoAanOCvSirI3/y7TcZMBw643SaxXi1ifGeg6eyMzrLtP3CeonKBHGzrt
1eeKGtEw/PFN4RmwpBePxi+uj0CoTD6zjCQa3c8EeB4Qz7tt6PnpibxdtZE8sBdd
51wSA/fPGi2tFph8IVAsws7oxcQxZYl8CyncKDLcoR4dxVHYdFEDDf1GjRjoQ3Ai
nD7fxD5qYzExe50DBVpuUbWcAiGICNxfvzQtUSRRtMoSHDcvzsy03KC6VwARAQAB
zR5MYXVuY2hwYWQgUFBBIGZvciBJdXJpaSBFZ29yb3bCwY4EEwEKADgWIQR1yd1y
x5mHDjEFQuJBZvLCVykIKAUCZXRSGwIbAwULCQgHAgYVCgkICwIEFgIDAQIeAQIX
gAAKCRBBZvLCVykIKBu5D/9akmHCHlUqm2RTTBeTMbLNGc0l6YugpPaCM6vz0O9k
BFP5PfRaNSRzyF7wHFHNY3JUHcor28my1fD8AE4+C3PwXz8tVYLh57UUsp4wjqHY
+MTl/1ngDViPGD3PRjB8ZlO+19yerfplZv1Jaw7FZZv2BZOAXb+ddqUG4EmlzOnC
EhcSDdFrzEBB3RGthjIb3QkKWKGbELDiMfogmsO9BE139Raiw23blagDrbnWsG4j
ReZeu3atjG6AW8eL7m+i7bKKshD2CYVMznI5cYGLMKo9w7sb33uylPj1Vx9O7joP
2GFf2rTpCY8wgzk7i1RqsipJ80u1/DY91Xdizv3f2BBe6UY7qHKoK00O11J0y8yU
is2Asycy33Wy51pf6rCFUBLQu+c1fEypHF6jqANmQwaH7pPBliy4gGWvrVggzV4m
xv7SnRiMi4PFyVwjKWm8dmuMxi/B9s++VG/ed+5aYgJYL58MohG3MUI/L58eitSC
DDcQ1iAnBmawnGMKPqzMgRFB3OU3wDwfh7LNVvQqWpQ4q7pr4Cq1CvZvGoggXWDo
1/vylPsRmiiuNetfsoVYmrkgtj1om07m5Xp1v4SyXJH11c3dc/xfMmn/4RlMWIpq
86IsOjpr3avsw3FVUNCgD5Wf5+rHG+7gNmM6Cm/F8MDfAnnRmsw4h6hgvcJNQT5D
ig==
=OY2W
-----END PGP PUBLIC KEY BLOCK-----
EOF
  [[ $(gpg --show-keys --with-colons /etc/apt/keyrings/amnezia.asc 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}') == 75C9DD72C799870E310542E24166F2C257290828 ]] ||
    die "Amnezia signing key fingerprint mismatch"
  write_file /etc/apt/sources.list.d/amnezia.sources <<'EOF'
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: focal
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/amnezia.asc
EOF
  apt_get update
  apt-cache show "linux-headers-$(uname -r)" >/dev/null 2>&1 || die "no headers for the running kernel $(uname -r); reboot into the newest kernel first"
  pkgs="linux-headers-$(uname -r) linux-headers-$fl dkms amneziawg amneziawg-tools nftables"
  # shellcheck disable=SC2086
  ! apt_get -s install --no-install-recommends $pkgs | grep '^Remv' >/dev/null || die "installing AmneziaWG would remove packages; refusing"
  # shellcheck disable=SC2086
  apt_install $pkgs
}

# awg_genconf IP: keys, random obfuscation parameters (tried on a throwaway interface first), the server config and ONE
# shared client config. Prints no secret.
awg_genconf() {
  python3 -I - "$1" "$AWG_PORT" "$AWG_CONF" "$AWG_CLIENT" "$AWG_NAT" <<'PY'
import os, random, subprocess, sys, tempfile

R = random.SystemRandom()
SERVER_IP, PORT, CONF, CLIENT, NAT = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
SERVER_ADDR, PEER_ADDR, MTU = "10.89.37.1/24", "10.89.37.2/32", 1280


def run(*a, inp=None):
    return subprocess.run(a, input=inp, capture_output=True, text=True, check=True).stdout.strip()


def pick_params():
    jc = R.randint(4, 8)
    jmin = R.randint(64, 128)
    jmax = R.randint(jmin + 200, 900)
    while True:  # message sizes: init 148+S1, response 92+S2, cookie 64+S3 must all differ; S1 + 56 != S2
        s1, s2, s3, s4 = R.randint(16, 150), R.randint(16, 150), R.randint(12, 60), R.randint(12, 32)
        if s1 + 56 != s2 and len({148 + s1, 92 + s2, 64 + s3}) == 3:
            break
    while True:  # four disjoint ranges above WireGuard's own type values 1-4
        v = sorted(R.sample(range(5, 2**32 - 1), 8))
        rs = [(v[0], v[1]), (v[2], v[3]), (v[4], v[5]), (v[6], v[7])]
        if all(b - a >= 2**16 for a, b in rs):
            break
    R.shuffle(rs)
    p = [("Jc", jc), ("Jmin", jmin), ("Jmax", jmax), ("S1", s1), ("S2", s2), ("S3", s3), ("S4", s4)]
    p += [(f"H{i + 1}", f"{a}-{b}") for i, (a, b) in enumerate(rs)]
    # no RandomTrailers: it loses 22-48 % of the packets; HeaderProtectionKey alone is clean
    p += [("HeaderProtectionKey", run("awg", "genpsk"))]
    return p


def gate(params):
    """Apply the parameters to a throwaway interface and read them back. Returns (ok, message without values)."""
    name = "awgtst0"
    text = "[Interface]\nPrivateKey = %s\n%s\n\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = 10.255.255.2/32\n" % (
        run("awg", "genkey"), "\n".join(f"{k} = {v}" for k, v in params),
        run("awg", "pubkey", inp=run("awg", "genkey")), run("awg", "genpsk"))
    with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
        f.write(text)
    run("ip", "link", "add", "dev", name, "type", "amneziawg")
    try:
        r = subprocess.run(["awg", "setconf", name, f.name], capture_output=True, text=True)
        if r.returncode:
            return False, "awg setconf rejected the parameters: " + (r.stderr.strip().splitlines() or ["?"])[0][:80]
        have = {l.split("=")[0].strip().lower() for l in run("awg", "showconf", name).splitlines() if "=" in l}
        missing = [k for k, _ in params if k.lower() not in have]
        return (False, "read back without: " + ", ".join(missing)) if missing else (True, "parameters accepted")
    finally:
        subprocess.run(["ip", "link", "del", "dev", name], capture_output=True)
        os.unlink(f.name)


for attempt in range(1, 6):
    params = pick_params()
    ok, msg = gate(params)
    print(f"gate attempt {attempt}: {msg}")
    if ok:
        break
else:
    sys.exit("no parameter set was accepted; nothing written")

if any(l.split()[3].rsplit(":", 1)[1] == str(PORT) for l in run("ss", "-ulnH").splitlines()):
    sys.exit(f"something already listens on UDP/{PORT}; nothing written")
skey, ckey = run("awg", "genkey"), run("awg", "genkey")
spub, cpub, psk = run("awg", "pubkey", inp=skey), run("awg", "pubkey", inp=ckey), run("awg", "genpsk")
obf = "\n".join(f"{k} = {v}" for k, v in params)

server = f"""[Interface]
Address = {SERVER_ADDR}
ListenPort = {PORT}
PrivateKey = {skey}
MTU = {MTU}
PostUp = nft -f {NAT}
PostDown = nft delete table ip awg_nat
{obf}

[Peer]
PublicKey = {cpub}
PresharedKey = {psk}
AllowedIPs = {PEER_ADDR}
"""
client = f"""[Interface]
PrivateKey = {ckey}
Address = {PEER_ADDR}
DNS = 1.1.1.1, 9.9.9.9
MTU = {MTU}
{obf}

[Peer]
PublicKey = {spub}
PresharedKey = {psk}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = {SERVER_IP}:{PORT}
PersistentKeepalive = 25
"""
for path, text in ((CONF, server), (CLIENT, client)):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
subprocess.run(["awg-quick", "strip", CONF], capture_output=True, check=True)  # the server file parses
PY
}

# awg_selftest IP: a temporary second peer in a network namespace on this server connects through the live tunnel and checks
# the handshake, DNS, the exit address, that IPv6 stays in, and a 20 MB download. Exercises forwarding, NAT and the ufw route
# rule, not the real network path to your device. Everything temporary is removed afterwards.
awg_selftest() {
  local ip=$1 ns=awgtest tmp ckey pub hs out
  ip netns del $ns 2>/dev/null || true; ip link del awgv0 2>/dev/null || true # leftovers of an interrupted run
  tmp=$(mktemp -d)
  ckey=$(awg genkey); pub=$(awg pubkey <<<"$ckey"); (umask 077; awg genpsk >"$tmp/psk")
  # shellcheck disable=SC2064
  trap "awg set awg0 peer '$pub' remove 2>/dev/null; ip netns del $ns 2>/dev/null; ip link del awgv0 2>/dev/null; rm -rf '$tmp' /etc/netns/$ns" EXIT
  awg set awg0 peer "$pub" preshared-key "$tmp/psk" allowed-ips 10.89.37.9/32
  {
    echo "[Interface]"; echo "PrivateKey = $ckey"
    grep -E '^(Jc|Jmin|Jmax|S[1-4]|H[1-4]|HeaderProtectionKey) *=' "$AWG_CONF"
    echo; echo "[Peer]"; echo "PublicKey = $(awg show awg0 public-key)"; echo "PresharedKey = $(cat "$tmp/psk")"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"; echo "Endpoint = $ip:$AWG_PORT"; echo "PersistentKeepalive = 5"
  } >"$tmp/client.conf"; chmod 600 "$tmp/client.conf"
  install -d "/etc/netns/$ns"; echo 'nameserver 1.1.1.1' >"/etc/netns/$ns/resolv.conf" # ip netns exec mounts it
  ip netns add $ns
  ip link add awgv0 type veth peer name awgv1; ip link set awgv1 netns $ns
  ip addr add 10.99.0.1/24 dev awgv0; ip link set awgv0 up
  ip -n $ns addr add 10.99.0.2/24 dev awgv1; ip -n $ns link set awgv1 up; ip -n $ns link set lo up
  ip -n $ns route add "$ip/32" via 10.99.0.1
  ip -n $ns link add awgc type amneziawg
  ip netns exec $ns awg setconf awgc "$tmp/client.conf"
  ip -n $ns addr add 10.89.37.9/32 dev awgc; ip -n $ns link set awgc mtu 1280 up
  ip -n $ns route add default dev awgc
  ip -n $ns -6 addr add fd00:89:37::9/128 dev awgc; ip -n $ns -6 route add default dev awgc

  echo "== vpn self-test"
  out=$(ip netns exec $ns curl -sS -m 12 https://one.one.one.one/cdn-cgi/trace 2>&1 | grep -E '^(ip|loc)=' | tr '\n' ' ' || true)
  hs=$(awg show awg0 latest-handshakes | awk -v k="$pub" '$1 == k {print $2}')
  if [[ ${hs:-0} -gt 0 ]]; then ok "handshake"; else bad "no handshake"; fi
  if [[ $out == *"ip=$ip "* ]]; then ok "DNS and exit address $ip through the tunnel ($out)"; else bad "unexpected exit: ${out:-no answer}"; fi
  if ip netns exec $ns curl -6 -sS -m 6 -o /dev/null "https://[2606:4700:4700::1111]/" 2>/dev/null; then bad "IPv6 left the tunnel"; else ok "IPv6 does not get out"; fi
  out=$(ip netns exec $ns curl -sS -m 25 -o /dev/null -w '%{size_download} %{speed_download}' "https://speed.cloudflare.com/__down?bytes=20000000" 2>/dev/null || true)
  if [[ ${out%% *} == 20000000 ]]; then ok "20 MB download through the tunnel ($(awk -v s="${out##* }" 'BEGIN {printf "%.1f", s / 1e6}') MB/s)"; else bad "20 MB download did not complete"; fi
  awg set awg0 peer "$pub" remove; ip netns del $ns; ip link del awgv0 2>/dev/null || true; rm -rf "$tmp" "/etc/netns/$ns"
  trap - EXIT
  ((FAILS == 0)) || die "vpn self-test: $FAILS check(s) failed"
}

# install: AmneziaWG on UDP AWG_PORT with one shared client (one device at a time). Re-runnable; keeps the keys, follows a changed AWG_PORT.
cmd_vpn_install() {
  load_env vpn; need AWG_PORT
  [[ $AWG_PORT =~ ^[1-9][0-9]{3,4}$ ]] && ((AWG_PORT >= 1024 && AWG_PORT <= 65535)) || die "AWG_PORT must be a UDP port 1024-65535"
  ufw status | grep '^Status: active' >/dev/null || die "ufw is not active; run bootstrap first"
  local ip wan old
  ip=$(host_ip)
  wan=$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  [[ -n $ip && -n $wan ]] || die "no default IPv4 route"
  dpkg -s amneziawg-tools >/dev/null 2>&1 || awg_install
  modprobe amneziawg || die "the amneziawg kernel module does not load (see: dkms status)"
  install -d -m 700 /etc/amnezia/amneziawg
  write_file "$AWG_NAT" 600 <<EOF
table ip awg_nat
delete table ip awg_nat
table ip awg_nat {
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		ip saddr $AWG_SUBNET oifname "$wan" masquerade
	}
}
EOF
  if [[ ! -f $AWG_CONF ]]; then
    log "generating keys and the server and client configs"
    awg_genconf "$ip"
  fi
  old=$(awk -F' *= *' '$1 == "ListenPort" {print $2}' "$AWG_CONF")
  if [[ $old != "$AWG_PORT" ]]; then
    sed -i "s/^ListenPort = .*/ListenPort = $AWG_PORT/" "$AWG_CONF"
    [[ ! -f $AWG_CLIENT ]] || sed -i "s/^Endpoint = .*/Endpoint = $ip:$AWG_PORT/" "$AWG_CLIENT"
    ufw delete allow "$old/udp" >/dev/null || true
    log "port changed from $old to $AWG_PORT: set Endpoint = $ip:$AWG_PORT in the client"
  fi
  write_file /etc/sysctl.d/92-awg.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  sysctl -q -p /etc/sysctl.d/92-awg.conf
  ufw allow "$AWG_PORT/udp" comment amneziawg >/dev/null
  # limited to the tunnel's IPv4 subnet: without `from`, ufw also adds an IPv6 forward rule
  ufw route allow in on awg0 out on "$wan" from "$AWG_SUBNET" comment amneziawg >/dev/null
  systemctl enable awg-quick@awg0 >/dev/null 2>&1
  systemctl restart awg-quick@awg0 || die "awg-quick@awg0 did not start (journalctl -u awg-quick@awg0)"
  [[ $(awg show awg0 listen-port) == "$AWG_PORT" ]] || die "awg0 does not listen on UDP $AWG_PORT"
  awg_selftest "$ip"
  if [[ -f $AWG_CLIENT ]]; then
    log "client config: $AWG_CLIENT (holds the client's private key). Import it in the AmneziaVPN app, e.g. fetch it with"
    log "  ssh -p <ssh port> <admin>@$ip sudo cat $AWG_CLIENT > awg.conf   then on the server: sudo shred -u $AWG_CLIENT"
  fi
  log "vpn ready on UDP $AWG_PORT. Allow it in your provider's firewall too, if it has one."
}

cmd_vpn_status() {
  local rc=0
  if systemctl is-active --quiet awg-quick@awg0; then echo "awg-quick@awg0: active"; else echo "awg-quick@awg0: NOT active"; rc=1; fi
  systemctl is-enabled --quiet awg-quick@awg0 2>/dev/null && echo "starts at boot: yes" || echo "starts at boot: no"
  if command -v awg >/dev/null && awg show awg0 >/dev/null 2>&1; then
    echo "listening on UDP $(awg show awg0 listen-port)"
    awg show awg0 latest-handshakes | while read -r pub ts; do
      if ((ts == 0)); then echo "peer ${pub:0:8}...: no handshake yet"
      else echo "peer ${pub:0:8}...: last handshake $(date -d "@$ts" '+%F %T') ($(($(date +%s) - ts)) s ago)"; fi
    done
  else rc=1; fi
  [[ ! -f $AWG_CLIENT ]] || echo "note: $AWG_CLIENT (client private key) is still on the server; shred it once imported"
  return $rc
}

# uninstall: everything install made. ip_forward is left as it is at runtime (Docker needs it); the sysctl file goes.
cmd_vpn_uninstall() {
  local port wan
  port=$(awk -F' *= *' '$1 == "ListenPort" {print $2}' "$AWG_CONF" 2>/dev/null || true)
  wan=$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  systemctl disable --now awg-quick@awg0 >/dev/null 2>&1 || true
  [[ -z $port ]] || ufw delete allow "$port/udp" >/dev/null 2>&1 || true
  [[ -z $wan ]] || ufw route delete allow in on awg0 out on "$wan" from "$AWG_SUBNET" >/dev/null 2>&1 || true
  nft delete table ip awg_nat 2>/dev/null || true
  ip link del awg0 2>/dev/null || true; rmmod amneziawg 2>/dev/null || true
  [[ ! -f $AWG_CLIENT ]] || shred -u "$AWG_CLIENT"
  find /etc/amnezia -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf /etc/amnezia /etc/sysctl.d/92-awg.conf
  if dpkg -s amneziawg-tools >/dev/null 2>&1 || dpkg -s amneziawg >/dev/null 2>&1; then
    apt_get purge -y amneziawg amneziawg-tools amneziawg-dkms || true
  fi
  rm -f /etc/apt/sources.list.d/amnezia.sources /etc/apt/keyrings/amnezia.asc
  log "vpn uninstalled"; [[ -z $port ]] || log "close UDP $port in the provider firewall too, if you opened it there"
}

vpn_usage() { echo "usage: $0 {install|status|uninstall}" >&2; exit 2; }

vpn_main() {
  case $1 in
    install) cmd_vpn_install ;;
    status) cmd_vpn_status ;;
    uninstall) cmd_vpn_uninstall ;;
    *) vpn_usage ;;
  esac
}

# sourced (tests): define the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  [[ $# -eq 1 && " install status uninstall " == *" $1 "* ]] || vpn_usage
  [[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $1)" >&2; exit 1; }
  CMD="vpn $1"
  if [[ $1 == status ]]; then vpn_main status; exit; fi # read-only, not logged
  touch "$LOG"; chmod 600 "$LOG"
  vpn_main "$1" 2>&1 | tee -a "$LOG"
fi
