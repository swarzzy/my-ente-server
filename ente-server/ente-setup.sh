#!/usr/bin/env bash
# ente-setup.sh - turn a fresh Debian 12/13 server into a backed-up Ente Photos server.
# Usage: ente-setup.sh <bootstrap|install|codes|lockdown|backup-setup|restore|check|update|syncthing>
# Config: ente-setup.env next to this script (or ENV_FILE=/path). See ente-setup.env.example.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE=${ENV_FILE:-$SCRIPT_DIR/ente-setup.env}
LOG=/var/log/ente-setup.log
ENTE_DIR=/opt/my-ente
DATA_MNT=/srv/ente-data
QUICKSTART_URL=https://raw.githubusercontent.com/ente/ente/main/server/quickstart.sh
BOX_KEY=/root/.ssh/storagebox
CADDY_ROOT=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
INT_BEGIN='# BEGIN ente-setup internal'
INT_END='# END ente-setup internal'
FAILS=0
CMD=

# ---------------------------------------------------------------- helpers
log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$CMD" "$*"; }
die()  { printf '%s [%s] ERROR: %s\n' "$(date '+%F %T')" "$CMD" "$*" >&2; exit 1; }
ok()   { printf '  OK    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '  WARN  %s\n' "$*"; }

dc() { (cd "$ENTE_DIR" && docker compose "$@"); }
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$@"; }
ensure_line() { grep -qxF -- "$2" "$1" 2>/dev/null || echo "$2" >>"$1"; }
version_ge() { [[ $(printf '%s\n%s\n' "$2" "${1#v}" | sort -V | head -1) == "$2" ]]; }
host_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'; }

# write_file FILE [MODE] < content: replaces FILE only if content differs.
write_file() {
  local f=$1 m=${2:-644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ -f $f ]] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
  install -m "$m" "$tmp" "$f"
  rm -f "$tmp"
  log "wrote $f"
}

# ask_secret VAR PROMPT [confirm]: silent read from stdin; never logged or stored in the config.
ask_secret() {
  local -n _out=$1
  local a b
  while :; do
    read -rsp "$2: " a; echo >&2
    [[ -n $a ]] || { echo "must not be empty" >&2; continue; }
    if [[ ${3:-} == confirm ]]; then
      read -rsp "$2 (again): " b; echo >&2
      [[ $a == "$b" ]] || { echo "did not match, retry" >&2; continue; }
    fi
    _out=$a
    return 0
  done
}

load_env() {
  [[ $EUID -eq 0 ]] || die "run as root"
  [[ -f $ENV_FILE ]] || die "config $ENV_FILE not found (copy ente-setup.env.example)"
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  MODE=${MODE:-production}; ADMIN_USER=${ADMIN_USER:-}; ADMIN_SSH_PUBKEY=${ADMIN_SSH_PUBKEY:-}
  DATA_DISK=${DATA_DISK:-}; LOW_RAM=${LOW_RAM:-auto}; BOX_HOST=${BOX_HOST:-}; BOX_USER=${BOX_USER:-}
  BOX_PORT=${BOX_PORT:-23}; HC_URL=${HC_URL:-}; FAIL2BAN=${FAIL2BAN:-yes}; SYNCTHING=${SYNCTHING:-no}
  FORCE_FORMAT=${FORCE_FORMAT:-no}; DOMAIN=${DOMAIN:-}
  [[ $DOMAIN =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z0-9-]+$ ]] || die "DOMAIN missing or invalid"
  case $MODE in
    production) [[ $DOMAIN != *.test && $DOMAIN != *example.com ]] || die "DOMAIN=$DOMAIN is a placeholder; set your real domain" ;;
    test) [[ $DOMAIN == *.test ]] || die "MODE=test requires DOMAIN ending in .test" ;;
    *) die "MODE must be production or test" ;;
  esac
  case $LOW_RAM in
    auto) if (($(awk '/^MemTotal/{print $2}' /proc/meminfo) < 1536 * 1024)); then LOW_RAM=yes; else LOW_RAM=no; fi ;;
    yes | no) ;;
    *) die "LOW_RAM must be auto, yes or no" ;;
  esac
  if [[ $MODE == test ]]; then
    printf '\n!!!!!!!!!! MODE=test: local CA certificates, /etc/hosts overrides, hardcoded test codes. NEVER use on a real server. !!!!!!!!!!\n\n'
  fi
}

need() { local v; for v in "$@"; do [[ -n ${!v} ]] || die "$v is not set in $ENV_FILE"; done; }

# ---------------------------------------------------------------- bootstrap
setup_data_disk() {
  [[ -n $DATA_DISK ]] || return 0
  [[ -b $DATA_DISK ]] || die "DATA_DISK=$DATA_DISK is not a block device"
  local uuid root_src root_disk
  if [[ $(blkid -s LABEL -o value "$DATA_DISK" 2>/dev/null || true) != ente-data ]]; then
    root_src=$(findmnt -no SOURCE /)
    root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)
    [[ -n $root_disk ]] || root_disk=$(basename "$root_src")
    [[ $(basename "$(readlink -f "$DATA_DISK")") != "$root_disk" ]] || die "DATA_DISK is the root disk"
    if [[ $FORCE_FORMAT != yes ]]; then
      [[ -z $(wipefs -n "$DATA_DISK") ]] || die "$DATA_DISK has a filesystem/signature; set FORCE_FORMAT=yes to erase it"
      (($(lsblk -nr -o NAME "$DATA_DISK" | wc -l) == 1)) || die "$DATA_DISK has partitions; set FORCE_FORMAT=yes to erase it"
    fi
    log "formatting $DATA_DISK as ext4 (label ente-data)"
    wipefs -a "$DATA_DISK" >/dev/null
    mkfs.ext4 -q -m 1 -L ente-data "$DATA_DISK"
    udevadm settle
  fi
  uuid=$(blkid -s UUID -o value "$DATA_DISK")
  [[ -n $uuid ]] || die "no UUID on $DATA_DISK"
  mkdir -p "$DATA_MNT"
  ensure_line /etc/fstab "UUID=$uuid $DATA_MNT ext4 defaults,nofail 0 2"
  systemctl daemon-reload
  mountpoint -q "$DATA_MNT" || mount "$DATA_MNT"
  mkdir -p "$DATA_MNT/silo"
  log "data disk mounted at $DATA_MNT (UUID=$uuid)"
}

setup_swap() {
  if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
    if [[ ! -f /swapfile ]]; then
      fallocate -l 2G /swapfile
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
    fi
    swapon /swapfile
  fi
  ensure_line /etc/fstab '/swapfile none swap sw 0 0'
  if [[ $LOW_RAM == yes ]]; then
    apt_install zram-tools
    write_file /etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
EOF
    systemctl enable zramswap >/dev/null 2>&1 || true
    systemctl restart zramswap
  fi
}

setup_ssh() {
  local home n
  id "$ADMIN_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos '' "$ADMIN_USER"
  usermod -aG sudo "$ADMIN_USER"
  # key-only user has no password, so sudo must not ask for one
  write_file "/etc/sudoers.d/90-$ADMIN_USER" 440 <<EOF
$ADMIN_USER ALL=(ALL) NOPASSWD:ALL
EOF
  visudo -cf "/etc/sudoers.d/90-$ADMIN_USER" >/dev/null
  home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  ensure_line "$home/.ssh/authorized_keys" "$ADMIN_SSH_PUBKEY"
  chown "$ADMIN_USER:$ADMIN_USER" "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"
  # only harden after the user and key are confirmed
  grep -qxF -- "$ADMIN_SSH_PUBKEY" "$home/.ssh/authorized_keys" || die "admin key not installed, refusing to harden sshd"
  [[ -d /etc/ssh/sshd_config.d ]] || die "/etc/ssh/sshd_config.d missing"
  write_file /etc/ssh/sshd_config.d/10-hardening.conf <<EOF
PasswordAuthentication no
PermitRootLogin no
AllowUsers $ADMIN_USER
MaxAuthTries 3
EOF
  sshd -t || die "sshd config invalid"
  n=$(sshd -T | grep -Ec '^(passwordauthentication no|permitrootlogin no|allowusers '"$ADMIN_USER"'|maxauthtries 3)$' || true)
  if ((n != 4)); then
    rm -f /etc/ssh/sshd_config.d/10-hardening.conf
    die "sshd -T does not show the hardening (no Include for sshd_config.d?); drop-in removed"
  fi
  systemctl reload ssh
  log "sshd hardened. TEST A SECOND LOGIN as $ADMIN_USER before closing this session!"
}

setup_ufw() {
  local sshport
  sshport=$(sshd -T | awk '$1 == "port" {print $2; exit}')
  ufw allow "${sshport:-22}/tcp" >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
}

cmd_bootstrap() {
  load_env; need ADMIN_USER ADMIN_SSH_PUBKEY
  [[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]*$ && $ADMIN_USER != root ]] || die "ADMIN_USER invalid"
  [[ $ADMIN_SSH_PUBKEY =~ ^ssh-(ed25519|rsa)\  || $ADMIN_SSH_PUBKEY =~ ^ecdsa- ]] || die "ADMIN_SSH_PUBKEY does not look like a public key"
  log "updating packages"
  apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confold upgrade
  apt_install sudo ufw curl ca-certificates gnupg unattended-upgrades python3-yaml unzip openssh-server
  setup_ssh
  setup_ufw
  write_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  write_file /etc/apt/apt.conf.d/52ente-unattended <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
EOF
  setup_swap
  if [[ $FAIL2BAN == yes ]]; then
    apt_install fail2ban python3-systemd
    write_file /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
backend = systemd
EOF
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
  fi
  setup_data_disk
  log "bootstrap done. Test a second login as $ADMIN_USER (ssh $ADMIN_USER@<ip>) before closing this session."
}

# ---------------------------------------------------------------- install helpers
install_docker() {
  local v
  if ! command -v docker >/dev/null; then
    log "installing Docker via get.docker.com"
    curl -fsSL https://get.docker.com | sh
  fi
  if [[ ! -f /etc/docker/daemon.json ]]; then
    write_file /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
EOF
    systemctl restart docker
  fi
  systemctl enable --now docker >/dev/null 2>&1
  v=$(docker compose version --short 2>/dev/null) || die "docker compose plugin missing"
  version_ge "$v" 2.30 || die "Docker Compose $v is older than 2.30"
}

install_caddy() {
  command -v caddy >/dev/null && return 0
  log "installing Caddy from its apt repository"
  apt_install debian-keyring debian-archive-keyring apt-transport-https curl gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt >/etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q
  apt_install caddy
}

run_quickstart() {
  [[ -d $ENTE_DIR ]] && { log "$ENTE_DIR exists, skipping quickstart"; return 0; }
  log "running Ente quickstart (answering n)"
  (cd /opt && printf 'n\n' | sh -c "$(curl -fsSL "$QUICKSTART_URL")") >/dev/null || die "quickstart failed"
  [[ -f $ENTE_DIR/compose.yaml && -f $ENTE_DIR/museum.yaml ]] || die "quickstart did not create compose.yaml/museum.yaml"
}

# Edit the quickstart output and assert every edit; fail loudly if its format changed.
apply_edits() {
  local c=$ENTE_DIR/compose.yaml m=$ENTE_DIR/museum.yaml p n
  chmod 700 "$ENTE_DIR"
  python3 - "$c" "$m" <<'PY' || die "quickstart output no longer matches the expected layout; not patching blindly"
import sys, yaml
c = yaml.safe_load(open(sys.argv[1])); m = yaml.safe_load(open(sys.argv[2]))
s = c["services"]
assert set(s) == {"museum", "socat", "web", "postgres", "minio"}, set(s)
assert s["minio"]["image"] == "pgsty/silo" and s["postgres"]["image"] == "postgres:15"
assert s["museum"]["image"] == "ghcr.io/ente/server" and s["web"]["image"] == "ghcr.io/ente/web"
assert s["socat"]["network_mode"] == "service:museum"
b = m["s3"]["b2-eu-cen"]
for k in ("key", "secret", "endpoint", "region", "bucket"):
    assert b[k], k
assert m["db"]["host"] == "postgres" and m["db"]["port"] == 5432
assert "public-albums" in m["apps"] and "key" in m and "jwt" in m
PY
  for p in 8080 3000 3002 3200; do
    sed -Ei "s/^( *- )(127\.0\.0\.1:)?$p:$p( |\$)/\1127.0.0.1:$p:$p\3/" "$c"
    grep -Eq "^ *- 127\.0\.0\.1:$p:$p( |\$)" "$c" || die "compose.yaml: port line for $p not found"
  done
  grep -q '^ *ENTE_API_ORIGIN:' "$c" || die "compose.yaml: ENTE_API_ORIGIN not found"
  sed -Ei "s|^( *ENTE_API_ORIGIN:).*|\1 https://api.$DOMAIN|" "$c"
  grep -qE "^ *ENTE_API_ORIGIN: https://api\.${DOMAIN//./\\.}\$" "$c" || die "compose.yaml: ENTE_API_ORIGIN edit failed"

  sed -Ei 's/^( *are_local_buckets:) *(true|false)/\1 false/' "$m"
  [[ $(grep -Ec '^ *are_local_buckets: false' "$m") == 1 && $(grep -Ec '^ *are_local_buckets: true' "$m") == 0 ]] || die "museum.yaml: are_local_buckets edit failed"
  sed -Ei "s|^( *endpoint:).*|\1 s3.$DOMAIN|" "$m"
  n=$(grep -Fc "endpoint: s3.$DOMAIN" "$m")
  [[ $n == 3 ]] || die "museum.yaml: expected 3 bucket endpoints, got $n"
  sed -Ei "s|^( *public-albums:).*|\1 https://albums.$DOMAIN|" "$m"
  grep -Fq "public-albums: https://albums.$DOMAIN" "$m" || die "museum.yaml: public-albums edit failed"
  python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$c" || die "compose.yaml invalid after edits"
  python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$m" || die "museum.yaml invalid after edits"
}

internal_admin() { sed -n 's/^  admins: \[\(.*\)\]$/\1/p' "$ENTE_DIR/museum.yaml"; }
internal_locked() { grep -qx '  disable-registration: true' "$ENTE_DIR/museum.yaml"; }

# sync_internal [ADMIN_ID] [yes|no]: rewrites our single managed internal: block, keeping unspecified values.
sync_internal() {
  local m=$ENTE_DIR/museum.yaml admin lock tmp
  admin=${1:-$(internal_admin)}
  if [[ -n ${2:-} ]]; then lock=$2; elif internal_locked; then lock=yes; else lock=no; fi
  tmp=$(mktemp)
  sed "/^$INT_BEGIN/,/^$INT_END/d" "$m" >"$tmp"
  grep -q '^internal:' "$tmp" && { rm -f "$tmp"; die "museum.yaml has its own internal: section; merge by hand"; }
  if [[ -n $admin || $lock == yes || $MODE == test ]]; then
    {
      echo "$INT_BEGIN"; echo "internal:"
      if [[ -n $admin ]]; then echo "  admins: [$admin]"; fi
      if [[ $lock == yes ]]; then echo "  disable-registration: true"; fi
      if [[ $MODE == test ]]; then
        echo "  hardcoded-ott:"; echo "    local-domain-suffix: \"@$DOMAIN\""; echo "    local-domain-value: 123456"
      fi
      echo "$INT_END"
    } >>"$tmp"
  fi
  if ! cmp -s "$tmp" "$m"; then cat "$tmp" >"$m"; log "updated internal block in museum.yaml"; fi # in place: keep inode for the bind mount
  rm -f "$tmp"
  python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$m" || die "museum.yaml invalid after internal edit"
}

gen_caddyfile() {
  local pair
  if [[ $MODE == test ]]; then printf '{\n\tlocal_certs\n}\n\n'; fi
  for pair in api:8080 web:3000 albums:3002 s3:3200; do
    printf '%s.%s {\n\treverse_proxy 127.0.0.1:%s\n}\n' "${pair%%:*}" "$DOMAIN" "${pair##*:}"
  done
}

gen_override() {
  echo "services:"
  echo "  museum:"
  echo "    restart: unless-stopped"
  echo "    oom_score_adj: -300"
  if [[ $MODE == test ]]; then echo "    extra_hosts: [\"s3.$DOMAIN:host-gateway\"]"; fi
  if [[ $LOW_RAM == yes || $MODE == test ]]; then
    echo "    environment:"
    if [[ $LOW_RAM == yes ]]; then echo "      GOMEMLIMIT: 150MiB"; fi
    if [[ $MODE == test ]]; then echo "      SSL_CERT_FILE: /etc/ssl/certs/ente-test-bundle.pem"; fi
  fi
  if [[ $MODE == test ]]; then
    echo "    volumes:"
    echo "      - $ENTE_DIR/test-ca-bundle.pem:/etc/ssl/certs/ente-test-bundle.pem:ro"
  fi
  echo "  web:"
  echo "    restart: unless-stopped"
  echo "  postgres:"
  echo "    restart: unless-stopped"
  echo "    oom_score_adj: -500"
  if [[ $LOW_RAM == yes ]]; then echo "    command: postgres -c shared_buffers=64MB -c maintenance_work_mem=32MB"; fi
  echo "  minio:"
  echo "    restart: unless-stopped"
  if [[ $LOW_RAM == yes ]]; then echo "    environment:"; echo "      GOMEMLIMIT: 200MiB"; fi
  if [[ -n $DATA_DISK ]]; then
    echo "    volumes:"
    echo "      - type: bind"
    echo "        source: $DATA_MNT/silo"
    echo "        target: /data"
    echo "        bind:"
    echo "          create_host_path: false"
  fi
  echo "  socat:"
  echo "    profiles: [\"off\"]"
}

setup_caddy_config() {
  write_file /etc/caddy/Caddyfile < <(gen_caddyfile)
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || die "Caddyfile invalid"
  systemctl enable caddy >/dev/null 2>&1
  systemctl reload-or-restart caddy # graceful and cheap when nothing changed
}

# test mode: hosts entries, trust Caddy's local root, CA bundle for museum
setup_test_env() {
  local i
  [[ $MODE == test ]] || return 0
  sed -i '/# ente-setup$/d' /etc/hosts
  echo "127.0.0.1 api.$DOMAIN web.$DOMAIN albums.$DOMAIN s3.$DOMAIN # ente-setup" >>/etc/hosts
  for i in $(seq 1 30); do [[ -f $CADDY_ROOT ]] && break; sleep 2; done
  [[ -f $CADDY_ROOT ]] || die "Caddy local root CA not found at $CADDY_ROOT"
  if ! cmp -s "$CADDY_ROOT" /usr/local/share/ca-certificates/ente-test-caddy-root.crt 2>/dev/null; then
    install -m 644 "$CADDY_ROOT" /usr/local/share/ca-certificates/ente-test-caddy-root.crt
    update-ca-certificates >/dev/null
  fi
  write_file "$ENTE_DIR/test-ca-bundle.pem" 644 < <(cat /etc/ssl/certs/ca-certificates.crt "$CADDY_ROOT")
}

configure_host() {
  apply_edits
  sync_internal
  setup_caddy_config
  setup_test_env
  write_file "$ENTE_DIR/compose.override.yaml" 600 < <(gen_override)
  dc config -q >/dev/null || die "docker compose config failed"
  if [[ -n $DATA_DISK ]]; then mountpoint -q "$DATA_MNT" || die "$DATA_MNT is not mounted (run bootstrap / attach the disk)"; fi
}

wait_healthy() { # service [timeout]
  local cid st t=${2:-360} i
  for ((i = 0; i < t; i += 3)); do
    cid=$(dc ps -q "$1" 2>/dev/null || true)
    if [[ -n $cid ]]; then
      st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")
      [[ $st == healthy || $st == running ]] && return 0
    fi
    sleep 3
  done
  die "$1 not healthy after ${t}s (docker compose logs $1)"
}

url_ok() { local i; for i in $(seq 1 "${2:-20}"); do curl -fsS -m 5 "$1" >/dev/null 2>&1 && return 0; sleep 3; done; return 1; }

print_test_steps() {
  [[ $MODE == test ]] || return 0
  cat <<EOF

Test mode - on the Windows PC (as admin / for your user):
  1. Hosts file C:\\Windows\\System32\\drivers\\etc\\hosts, add:
       $(host_ip) api.$DOMAIN web.$DOMAIN albums.$DOMAIN s3.$DOMAIN
  2. Copy the root cert:  scp $ADMIN_USER@$(host_ip):/usr/local/share/ca-certificates/ente-test-caddy-root.crt root.crt
     Import-Certificate -FilePath root.crt -CertStoreLocation Cert:\\CurrentUser\\Root
     (Edge/Chrome/Ente desktop use the Windows store; Firefox needs its own setting)
  3. Open https://web.$DOMAIN ; desktop app: 7 taps on the welcome screen, endpoint https://api.$DOMAIN
  Test sign-ups: any email ending @$DOMAIN uses code 123456; otherwise use '$0 codes'.
EOF
}

cmd_install() {
  load_env
  apt-get update -q; apt_install curl ca-certificates python3-yaml gnupg
  if [[ -n $DATA_DISK ]]; then mountpoint -q "$DATA_MNT" || die "$DATA_MNT not mounted; run bootstrap first"; fi
  install_docker
  install_caddy
  run_quickstart
  configure_host
  log "starting containers"
  dc up -d
  wait_healthy museum
  url_ok http://127.0.0.1:8080/ping 10 || die "museum /ping failed locally"
  if url_ok "https://api.$DOMAIN/ping" 20; then log "https://api.$DOMAIN/ping OK"
  elif [[ $MODE == test ]]; then die "https://api.$DOMAIN/ping failed in test mode"
  else warn "https://api.$DOMAIN/ping not reachable yet - point DNS A/AAAA (TTL 300) for api., web., albums., s3.$DOMAIN to this server"; fi
  cat <<EOF

Ente is up.
  1. Save $ENTE_DIR/museum.yaml in your password manager (secrets + encryption keys).
  2. Sign up the OWNER first at https://web.$DOMAIN, then the family. Codes: $0 codes
  3. Then: $0 lockdown   (makes the owner admin, closes sign-ups)
  4. Then: $0 backup-setup
EOF
  print_test_steps
}

# ---------------------------------------------------------------- codes / lockdown / update
cmd_codes() {
  load_env
  dc logs --no-log-prefix --since 24h museum 2>&1 | grep -ai 'verification code' | tail -n 20 || echo "no codes in the last 24h"
}

cmd_lockdown() {
  load_env
  local rows first id a
  if [[ -n $(internal_admin) ]] && internal_locked; then log "already locked down (admin $(internal_admin))"; return 0; fi
  wait_healthy museum 60
  rows=$(dc exec -T postgres psql -U pguser -d ente_db -At -F '|' -c "SELECT user_id, to_timestamp(creation_time/1000000) FROM users ORDER BY creation_time;" </dev/null)
  [[ -n $rows ]] || die "no users yet; sign up the owner first"
  echo "Users (oldest first):"; echo "user_id|created"; echo "$rows"
  first=${rows%%$'\n'*}; id=${first%%|*}
  [[ $id =~ ^[0-9]+$ ]] || die "unexpected user_id '$id'"
  read -rp "Make user_id $id (oldest) the admin and close sign-ups? [y/N] " a || die "no answer (stdin closed)"
  [[ $a == y || $a == Y ]] || die "aborted"
  sync_internal "$id" yes
  dc restart museum >/dev/null
  wait_healthy museum
  log "lockdown done: admin=$id, registration disabled"
}

cmd_update() {
  load_env
  dc pull && dc up -d && docker image prune -f >/dev/null
  log "updated"
}

# ---------------------------------------------------------------- backup
install_rclone() {
  command -v rclone >/dev/null && return 0
  apt_install unzip curl ca-certificates
  curl -fsSL https://rclone.org/install.sh | bash >/dev/null
}

ensure_box_key() {
  need BOX_HOST BOX_USER
  install -d -m 700 /root/.ssh
  [[ -f $BOX_KEY ]] || ssh-keygen -q -t ed25519 -N '' -C "ente-backup@$(hostname)" -f "$BOX_KEY"
  # Record every host key type once (trust on first use): rclone may negotiate a different type than ssh did.
  local hk=$BOX_HOST scan
  [[ $BOX_PORT == 22 ]] || hk="[$BOX_HOST]:$BOX_PORT"
  touch /root/.ssh/known_hosts
  if ! ssh-keygen -F "$hk" -f /root/.ssh/known_hosts >/dev/null 2>&1; then
    scan=$(ssh-keyscan -p "$BOX_PORT" "$BOX_HOST" 2>/dev/null) || true
    [[ -n $scan ]] || die "cannot reach $BOX_HOST:$BOX_PORT to read its host keys"
    echo "$scan" >>/root/.ssh/known_hosts
    log "host keys recorded for $BOX_HOST (compare with Hetzner's published fingerprints):"
    ssh-keygen -lf - <<<"$scan" | sed 's/^/    /'
  fi
  local sftp_opts=(-P "$BOX_PORT" -i "$BOX_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new)
  if ! echo pwd | sftp "${sftp_opts[@]}" -b - "$BOX_USER@$BOX_HOST" >/dev/null 2>&1; then
    log "installing backup key on $BOX_HOST:$BOX_PORT (enter the Storage Box password when asked)"
    ssh-copy-id -p "$BOX_PORT" -s -i "$BOX_KEY.pub" -o StrictHostKeyChecking=accept-new "$BOX_USER@$BOX_HOST"
    echo pwd | sftp "${sftp_opts[@]}" -b - "$BOX_USER@$BOX_HOST" >/dev/null 2>&1 || die "key login to the Box still fails"
  fi
  ok "Box key login works"
}

make_box_remotes() { # [confirm]
  local pass
  rclone config create box sftp host="$BOX_HOST" user="$BOX_USER" port="$BOX_PORT" \
    key_file="$BOX_KEY" known_hosts_file=/root/.ssh/known_hosts >/dev/null
  if rclone listremotes | grep -qx 'box-crypt:' && [[ ${1:-} != force ]]; then log "box-crypt remote exists, keeping passphrase"; return 0; fi
  ask_secret pass "Backup passphrase (keep it in your password manager; losing it loses the config backups)" "${1:-confirm}"
  rclone config create box-crypt crypt remote=box:config password="$pass" --obscure >/dev/null
}

make_s3_remote() {
  local kv
  kv=$(python3 - "$ENTE_DIR/museum.yaml" <<'PY'
import sys, yaml
b = yaml.safe_load(open(sys.argv[1]))["s3"]["b2-eu-cen"]
print(b["key"]); print(b["secret"]); print(b["region"])
PY
  )
  { read -r k; read -r s; read -r r; } <<<"$kv"
  rclone config create ente-s3 s3 provider=Minio endpoint=http://127.0.0.1:3200 \
    access_key_id="$k" secret_access_key="$s" region="$r" >/dev/null
}

install_backup_units() {
  write_file /etc/ente-backup.env 600 <<EOF
HC_URL="$HC_URL"
REQUIRE_MOUNT=$([[ -n $DATA_DISK ]] && echo yes || echo no)
LOW_RAM=$LOW_RAM
SYNCTHING=$SYNCTHING
EOF
  write_file /usr/local/bin/ente-backup.sh 755 <<'EOF'
#!/usr/bin/env bash
# Managed by ente-setup.sh. Config comes from /etc/ente-backup.env via systemd.
set -euo pipefail
umask 077
if [[ "${REQUIRE_MOUNT:-no}" == yes ]] && ! mountpoint -q /srv/ente-data; then
  echo "ERROR: /srv/ente-data is not mounted; refusing to back up an empty bucket" >&2; exit 1
fi
OPTS=(--checkers 4 --transfers 4)
if [[ "${LOW_RAM:-no}" == yes ]]; then OPTS=(--checkers 4 --transfers 2 --buffer-size 4M); fi
cd /opt/my-ente
DUMPS=/var/backups/ente; mkdir -p "$DUMPS"; chmod 700 "$DUMPS"
dump="$DUMPS/ente_db-$(date +%F).dump"
docker compose exec -T postgres pg_dump -U pguser -d ente_db -Fc > "$dump.tmp"
[[ -s "$dump.tmp" ]] || { echo "ERROR: empty database dump" >&2; rm -f "$dump.tmp"; exit 1; }
docker compose exec -T postgres pg_restore -l < "$dump.tmp" > /dev/null || { echo "ERROR: dump unreadable" >&2; rm -f "$dump.tmp"; exit 1; }
mv "$dump.tmp" "$dump"
find "$DUMPS" -name 'ente_db-*.dump' -mtime +6 -delete
cp museum.yaml compose.yaml compose.override.yaml "$DUMPS/"
rclone sync "$DUMPS" box-crypt: --checkers 4
rclone sync ente-s3:b2-eu-cen box:objects --size-only "${OPTS[@]}" \
  --max-delete 500 --backup-dir "box:deleted/$(date +%F)"
if [[ "${SYNCTHING:-no}" == yes ]]; then
  rclone sync /srv/syncthing box:syncthing --exclude '/config/**' --checkers 4
fi
cutoff=$(date -d '60 days ago' +%F)
for d in $(rclone lsf --dirs-only box:deleted 2>/dev/null || true); do
  if [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}/$ && "${d%/}" < "$cutoff" ]]; then rclone purge "box:deleted/${d%/}"; fi
done
if [[ -n "${HC_URL:-}" ]]; then curl -fsS -m 10 --retry 3 "$HC_URL" > /dev/null; fi
EOF
  write_file /etc/systemd/system/ente-backup.service <<'EOF'
[Unit]
Description=Ente backup (database dump + objects to Storage Box)
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
OOMScoreAdjust=500
TimeoutStartSec=infinity
Environment=RCLONE_CONFIG=/root/.config/rclone/rclone.conf
EnvironmentFile=/etc/ente-backup.env
ExecStart=/usr/local/bin/ente-backup.sh
EOF
  write_file /etc/systemd/system/ente-backup.timer <<'EOF'
[Unit]
Description=Daily Ente backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now ente-backup.timer >/dev/null 2>&1
}

cmd_backup_setup() {
  load_env; need BOX_HOST BOX_USER
  [[ -f $ENTE_DIR/museum.yaml ]] || die "run install first"
  install_rclone
  ensure_box_key
  make_box_remotes
  make_s3_remote
  install_backup_units
  systemctl start --no-block ente-backup.service
  log "backup configured; first run started: journalctl -fu ente-backup.service"
}

# ---------------------------------------------------------------- restore
cmd_restore() {
  load_env; need BOX_HOST BOX_USER
  local tmp dump t0=$SECONDS
  [[ ! -e $ENTE_DIR ]] || die "$ENTE_DIR already exists; restore is for a fresh server"
  if [[ -n $DATA_DISK ]]; then mountpoint -q "$DATA_MNT" || die "$DATA_MNT not mounted; run bootstrap first"; fi
  apt-get update -q; apt_install curl ca-certificates python3-yaml gnupg
  install_docker; install_caddy; install_rclone
  ensure_box_key
  rclone listremotes | grep -qx 'box-crypt:' && rclone config delete box-crypt
  make_box_remotes once
  tmp=$(mktemp -d /root/ente-restore.XXXXXX)
  trap 'rm -rf "$tmp"' EXIT
  log "fetching config backup"
  rclone copy box-crypt: "$tmp" --checkers 4
  dump=$(find "$tmp" -maxdepth 1 -name 'ente_db-*.dump' | sort | tail -1)
  [[ -n $dump && -f $tmp/compose.yaml && -f $tmp/museum.yaml ]] || die "backup incomplete (wrong passphrase?): need ente_db-*.dump, compose.yaml, museum.yaml"
  install -d -m 700 "$ENTE_DIR"
  install -m 600 "$tmp/compose.yaml" "$ENTE_DIR/compose.yaml"
  install -m 644 "$tmp/museum.yaml" "$ENTE_DIR/museum.yaml"
  configure_host
  make_s3_remote
  log "starting postgres and silo"
  dc up -d --wait postgres minio
  log "restoring database $(basename "$dump")"
  dc cp "$dump" postgres:/tmp/restore.dump
  dc exec -T postgres pg_restore -U pguser -d ente_db --clean --if-exists /tmp/restore.dump || die "pg_restore failed"
  dc exec -T postgres rm -f /tmp/restore.dump
  log "restoring objects (this can take long)"
  local opts=(--checkers 4 --transfers 4)
  [[ $LOW_RAM == yes ]] && opts=(--checkers 4 --transfers 2 --buffer-size 4M)
  rclone copy box:objects ente-s3:b2-eu-cen "${opts[@]}"
  dc up -d
  wait_healthy museum
  url_ok http://127.0.0.1:8080/ping 10 || die "museum /ping failed locally"
  log "restore finished in $((SECONDS - t0))s"
  cat <<EOF

Restored. Next:
  1. DNS: point A/AAAA of api., web., albums., s3.$DOMAIN to $(host_ip) (TTL 300). Certificates are issued once DNS resolves.
  2. $0 backup-setup   (installs the timer; remotes and key already exist)
  3. $0 check
EOF
  print_test_steps
}

# ---------------------------------------------------------------- check
cmd_check() {
  load_env
  local s cid st pol p addrs ts res n out
  echo "== containers"
  for s in museum web postgres minio; do
    cid=$(dc ps -q "$s" 2>/dev/null || true)
    if [[ -z $cid ]]; then bad "$s not running"; continue; fi
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")
    pol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid")
    if [[ $st == healthy || $st == running ]]; then ok "$s $st"; else bad "$s $st"; fi
    if [[ $pol == unless-stopped ]]; then ok "$s restart=$pol"; else bad "$s restart=$pol"; fi
  done
  if [[ -z $(dc ps -q socat 2>/dev/null || true) ]]; then ok "socat not running"; else bad "socat is running"; fi
  echo "== ports"
  for p in 8080 3000 3002 3200; do
    addrs=$(ss -Htln "sport = :$p" | awk '{print $4}')
    if [[ -z $addrs ]]; then bad "port $p not listening"
    elif grep -qvE '^127\.0\.0\.1:' <<<"$addrs"; then bad "port $p exposed beyond localhost: $(echo "$addrs" | tr '\n' ' ')"
    else ok "port $p on 127.0.0.1 only"; fi
  done
  for p in 3201 5432; do
    if [[ -z $(ss -Htln "sport = :$p") ]]; then ok "port $p not listening"; else bad "port $p is listening"; fi
  done
  echo "== ssh / firewall"
  out=$(sshd -T)
  for s in "passwordauthentication no" "permitrootlogin no" "maxauthtries 3"; do
    if grep -qx "$s" <<<"$out"; then ok "sshd $s"; else bad "sshd expected: $s"; fi
  done
  if [[ -n $ADMIN_USER ]] && grep -qx "allowusers $ADMIN_USER" <<<"$out"; then ok "sshd allowusers $ADMIN_USER"; else bad "sshd allowusers not set"; fi
  if ufw status | grep -q '^Status: active'; then ok "ufw active"; else bad "ufw inactive"; fi
  if systemctl is-active --quiet caddy; then ok "caddy active"; else bad "caddy not active"; fi
  if curl -fsS -m 10 "https://api.$DOMAIN/ping" >/dev/null 2>&1; then ok "https://api.$DOMAIN/ping"; else bad "https://api.$DOMAIN/ping"; fi
  if [[ -n $DATA_DISK ]]; then
    if mountpoint -q "$DATA_MNT"; then ok "$DATA_MNT mounted"; else bad "$DATA_MNT not mounted"; fi
  fi
  echo "== backup"
  if systemctl is-enabled --quiet ente-backup.timer 2>/dev/null; then ok "timer enabled, next: $(systemctl show ente-backup.timer -p NextElapseUSecRealtime --value)"; else bad "ente-backup.timer not enabled"; fi
  ts=$(systemctl show ente-backup.service -p ExecMainExitTimestamp --value 2>/dev/null || true)
  res=$(systemctl show ente-backup.service -p Result --value 2>/dev/null || true)
  if [[ -z $ts ]]; then warn "backup has not run yet"
  elif [[ $res == success ]]; then ok "last backup finished $ts: $res"; else bad "last backup $ts: $res"; fi
  if out=$(rclone check ente-s3:b2-eu-cen box:objects --one-way --size-only --checkers 4 2>&1); then ok "rclone check: bucket is on the Box"
  else bad "rclone check failed: $(echo "$out" | tail -3 | tr '\n' ' ')"; fi
  echo "== system"
  df -h / ${DATA_DISK:+"$DATA_MNT"} | sed 's/^/        /'
  warn "check Storage Box usage in the Hetzner Console"
  n=$(journalctl -k -q --since '30 days ago' 2>/dev/null | grep -ciE 'out of memory|oom-kill' || true)
  if [[ $n == 0 ]]; then ok "no OOM kills in 30 days"; else bad "$n OOM kernel messages (journalctl -k | grep -i oom)"; fi
  if [[ -e /var/run/reboot-required ]]; then warn "reboot required"; else ok "no reboot pending"; fi
  echo
  if ((FAILS)); then echo "$FAILS check(s) FAILED"; return 1; fi
  echo "all checks passed"
}

# ---------------------------------------------------------------- syncthing
cmd_syncthing() {
  load_env
  [[ $SYNCTHING == yes ]] || die "SYNCTHING=yes not set"
  install_docker
  install -d -m 700 /opt/syncthing
  install -d -m 750 -o 1000 -g 1000 /srv/syncthing
  write_file /opt/syncthing/compose.yaml 600 <<'EOF'
services:
  syncthing:
    image: syncthing/syncthing
    restart: unless-stopped
    environment:
      PUID: "1000"
      PGID: "1000"
    ports:
      - 127.0.0.1:8384:8384
      - 22000:22000/tcp
      - 22000:22000/udp
    volumes:
      - /srv/syncthing:/var/syncthing
EOF
  ufw allow 22000/tcp >/dev/null; ufw allow 22000/udp >/dev/null
  (cd /opt/syncthing && docker compose up -d)
  log "Syncthing UI on 127.0.0.1:8384 (use: ssh -L 8384:127.0.0.1:8384 $ADMIN_USER@<server>)"
}

# ---------------------------------------------------------------- main
usage() { echo "usage: $0 {bootstrap|install|codes|lockdown|backup-setup|restore|check|update|syncthing}" >&2; exit 2; }

main() {
  CMD=$1
  case $CMD in
    bootstrap) cmd_bootstrap ;;
    install) cmd_install ;;
    codes) cmd_codes ;;
    lockdown) cmd_lockdown ;;
    backup-setup) cmd_backup_setup ;;
    restore) cmd_restore ;;
    check) cmd_check ;;
    update) cmd_update ;;
    syncthing) cmd_syncthing ;;
    *) usage ;;
  esac
}

[[ $# -eq 1 ]] || usage
[[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $1)" >&2; exit 1; }
touch "$LOG"; chmod 600 "$LOG"
main "$1" 2>&1 | tee -a "$LOG"
