#!/usr/bin/env bash
# ente-setup.sh - turn a fresh Debian 12/13 server into a backed-up Ente Photos server.
# Usage: ente-setup.sh <deploy|bootstrap|install|codes|lockdown|backup-setup|restore|check|update|syncthing>
# Config: ente-setup.env next to this script (or ENV_FILE=/path). See ente-setup.env.example.
# Secrets: prompted, or taken from the environment / ente-setup.secrets (mode 600, same variables, see the example).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE=${ENV_FILE:-$SCRIPT_DIR/ente-setup.env}
SECRETS_FILE=${SECRETS_FILE:-$SCRIPT_DIR/ente-setup.secrets}
LOG=/var/log/ente-setup.log
ENTE_DIR=/opt/my-ente
DATA_MNT=/srv/ente-data
QUICKSTART_URL=https://raw.githubusercontent.com/ente/ente/main/server/quickstart.sh
BOX_KEY=/root/.ssh/storagebox
CADDY_ROOT=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
INT_BEGIN='# BEGIN ente-setup internal'
INT_END='# END ente-setup internal'
FAILS=0
MUSEUM_CFG_CHANGED=0
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

# secret_var VAR PROMPT [confirm]: keep VAR if already set (environment / secrets file), else ask on a terminal.
secret_var() {
  [[ -z ${!1:-} ]] || return 0
  [[ -t 0 ]] || die "$1 is not set and there is no terminal to ask on (set it in the environment or $SECRETS_FILE)"
  ask_secret "$1" "$2" "${3:-}"
}

load_env() {
  [[ $EUID -eq 0 ]] || die "run as root"
  [[ -f $ENV_FILE ]] || die "config $ENV_FILE not found (copy ente-setup.env.example)"
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  if [[ -f $SECRETS_FILE ]]; then
    [[ $(stat -c %a "$SECRETS_FILE") =~ ^[46]00$ ]] || die "$SECRETS_FILE must be mode 600"
    # shellcheck source=/dev/null
    . "$SECRETS_FILE"
  fi
  MODE=${MODE:-production}; ADMIN_USER=${ADMIN_USER:-}; ADMIN_SSH_PUBKEY=${ADMIN_SSH_PUBKEY:-}
  DATA_DISK=${DATA_DISK:-}; LOW_RAM=${LOW_RAM:-auto}; BOX_HOST=${BOX_HOST:-}; BOX_USER=${BOX_USER:-}
  BOX_PORT=${BOX_PORT:-23}; HC_URL=${HC_URL:-}; FAIL2BAN=${FAIL2BAN:-yes}; SYNCTHING=${SYNCTHING:-no}
  FORCE_FORMAT=${FORCE_FORMAT:-no}; DOMAIN=${DOMAIN:-}
  BACKUP_TARGET=${BACKUP_TARGET:-sftp}; BACKUP_S3_PROVIDER=${BACKUP_S3_PROVIDER:-Other}
  BACKUP_S3_ENDPOINT=${BACKUP_S3_ENDPOINT:-}; BACKUP_S3_REGION=${BACKUP_S3_REGION:-}; BACKUP_S3_BUCKET=${BACKUP_S3_BUCKET:-}
  STORAGE=${STORAGE:-silo}; S3_PROVIDER=${S3_PROVIDER:-Other}; S3_ENDPOINT=${S3_ENDPOINT:-}; S3_REGION=${S3_REGION:-}
  S3_BUCKET=${S3_BUCKET:-}; S3_CORS_ORIGINS=${S3_CORS_ORIGINS:-https://web.$DOMAIN,https://albums.$DOMAIN}; RESTORE=${RESTORE:-no}
  S3_ACCESS_KEY=${S3_ACCESS_KEY:-}; S3_SECRET_KEY=${S3_SECRET_KEY:-}; BACKUP_S3_ACCESS_KEY=${BACKUP_S3_ACCESS_KEY:-}
  BACKUP_S3_SECRET_KEY=${BACKUP_S3_SECRET_KEY:-}; BACKUP_PASSPHRASE=${BACKUP_PASSPHRASE:-}
  LOCAL_CA=no; [[ $MODE == test && $STORAGE == silo ]] && LOCAL_CA=yes
  case $STORAGE in
    silo) SRC_BUCKET=b2-eu-cen ;;
    s3) SRC_BUCKET=$S3_BUCKET; [[ -z $DATA_DISK ]] || die "DATA_DISK is only for STORAGE=silo" ;;
    *) die "STORAGE must be silo or s3" ;;
  esac
  case $BACKUP_TARGET in
    sftp) BOX_ROOT=box: ;;
    s3) BOX_ROOT=box:$BACKUP_S3_BUCKET/ ;;
    *) die "BACKUP_TARGET must be sftp or s3" ;;
  esac
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

need_storage() {
  [[ $STORAGE == s3 ]] || return 0
  need S3_ENDPOINT S3_REGION S3_BUCKET
  [[ $S3_ENDPOINT != *://* ]] || die "S3_ENDPOINT must be a bare hostname, without https://"
}
need() { local v; for v in "$@"; do [[ -n ${!v} ]] || die "$v is not set in $ENV_FILE"; done; }
need_backup() {
  if [[ $BACKUP_TARGET == s3 ]]; then need BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_BUCKET; else need BOX_HOST BOX_USER; fi
}

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
  for p in 8080 3000 3002 $([[ $STORAGE == silo ]] && echo 3200); do
    sed -Ei "s/^( *- )(127\.0\.0\.1:)?$p:$p( |\$)/\1127.0.0.1:$p:$p\3/" "$c"
    grep -Eq "^ *- 127\.0\.0\.1:$p:$p( |\$)" "$c" || die "compose.yaml: port line for $p not found"
  done
  grep -q '^ *ENTE_API_ORIGIN:' "$c" || die "compose.yaml: ENTE_API_ORIGIN not found"
  sed -Ei "s|^( *ENTE_API_ORIGIN:).*|\1 https://api.$DOMAIN|" "$c"
  grep -qE "^ *ENTE_API_ORIGIN: https://api\.${DOMAIN//./\\.}\$" "$c" || die "compose.yaml: ENTE_API_ORIGIN edit failed"

  if [[ $STORAGE == silo ]]; then
    sed -Ei 's/^( *are_local_buckets:) *(true|false)/\1 false/' "$m"
    [[ $(grep -Ec '^ *are_local_buckets: false' "$m") == 1 && $(grep -Ec '^ *are_local_buckets: true' "$m") == 0 ]] || die "museum.yaml: are_local_buckets edit failed"
    sed -Ei "s|^( *endpoint:).*|\1 s3.$DOMAIN|" "$m"
    n=$(grep -Fc "endpoint: s3.$DOMAIN" "$m")
    [[ $n == 3 ]] || die "museum.yaml: expected 3 bucket endpoints, got $n"
  else
    edit_museum_s3 "$m"
  fi
  sed -Ei "s|^( *public-albums:).*|\1 https://albums.$DOMAIN|" "$m"
  grep -Fq "public-albums: https://albums.$DOMAIN" "$m" || die "museum.yaml: public-albums edit failed"
  python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$c" || die "compose.yaml invalid after edits"
  python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$m" || die "museum.yaml invalid after edits"
}

# STORAGE=s3: point the b2-eu-cen bucket at the external bucket and drop the two unused Silo buckets (idempotent).
edit_museum_s3() {
  secret_var S3_ACCESS_KEY "S3 access key ID (primary bucket)"
  secret_var S3_SECRET_KEY "S3 secret access key (primary bucket)"
  S3_ENDPOINT=$S3_ENDPOINT S3_REGION=$S3_REGION S3_BUCKET=$S3_BUCKET S3_ACCESS_KEY=$S3_ACCESS_KEY S3_SECRET_KEY=$S3_SECRET_KEY \
    python3 - "$1" <<'PY' || die "museum.yaml: S3 edit failed (quickstart layout changed?)"
import json, os, re, sys, yaml
path = sys.argv[1]; e = os.environ
vals = {"key": e["S3_ACCESS_KEY"], "secret": e["S3_SECRET_KEY"], "endpoint": e["S3_ENDPOINT"],
        "region": e["S3_REGION"], "bucket": e["S3_BUCKET"]}
out = []; blk = None
for ln in open(path).read().split("\n"):
    m = re.match(r"^( *)([A-Za-z0-9_-]+):\s*$", ln)
    ind = len(ln) - len(ln.lstrip())
    if blk and ln.strip() and ind <= blk[0]: blk = None
    if blk and blk[1] == "drop": continue
    if m and ind == 6 and m.group(2) in ("b2-eu-cen", "wasabi-eu-central-2-v3", "scw-eu-fr-v3"):
        blk = (ind, "keep" if m.group(2) == "b2-eu-cen" else "drop")
        if blk[1] == "drop": continue
    elif blk:
        k = re.match(r"^( +)(key|secret|endpoint|region|bucket):", ln)
        if k: ln = "%s%s: %s" % (k.group(1), k.group(2), json.dumps(vals[k.group(2)]))
    if re.match(r"^ *are_local_buckets:", ln): ln = re.sub(r":.*", ": false", ln)
    out.append(ln)
open(path, "w").write("\n".join(out))
d = yaml.safe_load(open(path))["s3"]
assert d["are_local_buckets"] is False and d["use_path_style_urls"] is True
assert [k for k in d if isinstance(d[k], dict)] == ["b2-eu-cen"], list(d)
assert {k: d["b2-eu-cen"][k] for k in vals} == vals
PY
}

# museum_val FIELD: key|secret|endpoint|region|bucket of the primary bucket in museum.yaml
museum_val() {
  python3 - "$ENTE_DIR/museum.yaml" "$1" <<'PY'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))["s3"]["b2-eu-cen"][sys.argv[2]])
PY
}

# STORAGE=s3: prove the primary bucket works (read, write, delete) and set CORS so the web app can upload straight to it.
s3_prepare() {
  [[ $STORAGE == s3 ]] || return 0
  dpkg -s python3-boto3 >/dev/null 2>&1 || apt_install python3-boto3
  S3_ENDPOINT=$(museum_val endpoint) S3_REGION=$(museum_val region) S3_BUCKET=$(museum_val bucket) \
    S3_ACCESS_KEY=$(museum_val key) S3_SECRET_KEY=$(museum_val secret) S3_CORS_ORIGINS=$S3_CORS_ORIGINS \
    python3 - <<'PY' || die "primary S3 bucket check failed"
import os, boto3
from botocore.config import Config
e = os.environ
try: cfg = Config(s3={"addressing_style": "path"}, request_checksum_calculation="when_required", response_checksum_validation="when_required")
except TypeError: cfg = Config(s3={"addressing_style": "path"})
c = boto3.client("s3", endpoint_url="https://" + e["S3_ENDPOINT"], region_name=e["S3_REGION"], aws_access_key_id=e["S3_ACCESS_KEY"],
                 aws_secret_access_key=e["S3_SECRET_KEY"], config=cfg)
b = e["S3_BUCKET"]
c.head_bucket(Bucket=b)
c.put_object(Bucket=b, Key="ente-setup-probe", Body=b"probe"); c.get_object(Bucket=b, Key="ente-setup-probe")["Body"].read(); c.delete_object(Bucket=b, Key="ente-setup-probe")
print("  OK    primary bucket %s: read/write/delete work" % b)
rule = {"AllowedOrigins": e["S3_CORS_ORIGINS"].split(","), "AllowedMethods": ["GET", "HEAD", "POST", "PUT", "DELETE"],
        "AllowedHeaders": ["*"], "ExposeHeaders": ["ETag"], "MaxAgeSeconds": 3000}
try:
    c.put_bucket_cors(Bucket=b, CORSConfiguration={"CORSRules": [rule]})
    print("  OK    CORS set for", e["S3_CORS_ORIGINS"])
except Exception as x:
    print("  WARN  could not set CORS (%s); set it by hand or web uploads fail: origins %s, methods GET/HEAD/POST/PUT/DELETE, headers *, expose ETag" % (type(x).__name__, e["S3_CORS_ORIGINS"]))
PY
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
  if ! cmp -s "$tmp" "$m"; then cat "$tmp" >"$m"; MUSEUM_CFG_CHANGED=1; log "updated internal block in museum.yaml"; fi # in place: keep inode for the bind mount
  rm -f "$tmp"
  python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$m" || die "museum.yaml invalid after internal edit"
}

gen_caddyfile() {
  local pair
  if [[ $MODE == test ]]; then printf '{\n\tlocal_certs\n}\n\n'; fi
  for pair in api:8080 web:3000 albums:3002 $([[ $STORAGE == silo ]] && echo s3:3200); do
    printf '%s.%s {\n\treverse_proxy 127.0.0.1:%s\n}\n' "${pair%%:*}" "$DOMAIN" "${pair##*:}"
  done
}

gen_override() {
  echo "services:"
  echo "  museum:"
  echo "    restart: unless-stopped"
  echo "    oom_score_adj: -300"
  if [[ $LOCAL_CA == yes ]]; then echo "    extra_hosts: [\"s3.$DOMAIN:host-gateway\"]"; fi
  if [[ $LOW_RAM == yes || $LOCAL_CA == yes ]]; then
    echo "    environment:"
    if [[ $LOW_RAM == yes ]]; then echo "      GOMEMLIMIT: 150MiB"; fi
    if [[ $LOCAL_CA == yes ]]; then echo "      SSL_CERT_FILE: /etc/ssl/certs/ente-test-bundle.pem"; fi
  fi
  if [[ $LOCAL_CA == yes ]]; then
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
  if [[ $STORAGE == s3 ]]; then echo "    profiles: [\"off\"]"; else echo "    restart: unless-stopped"; fi
  if [[ $STORAGE == silo && $LOW_RAM == yes ]]; then echo "    environment:"; echo "      GOMEMLIMIT: 200MiB"; fi
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
  echo "127.0.0.1 api.$DOMAIN web.$DOMAIN albums.$DOMAIN s3.$DOMAIN # ente-setup" >>/etc/hosts # harmless extra name in s3 mode
  for i in $(seq 1 30); do [[ -f $CADDY_ROOT ]] && break; sleep 2; done
  [[ -f $CADDY_ROOT ]] || die "Caddy local root CA not found at $CADDY_ROOT"
  if ! cmp -s "$CADDY_ROOT" /usr/local/share/ca-certificates/ente-test-caddy-root.crt 2>/dev/null; then
    install -m 644 "$CADDY_ROOT" /usr/local/share/ca-certificates/ente-test-caddy-root.crt
    update-ca-certificates >/dev/null
  fi
  if [[ $LOCAL_CA == yes ]]; then write_file "$ENTE_DIR/test-ca-bundle.pem" 644 < <(cat /etc/ssl/certs/ca-certificates.crt "$CADDY_ROOT"); fi
}

configure_host() {
  need_storage
  apply_edits
  s3_prepare
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

dns_names() { if [[ $STORAGE == silo ]]; then echo "api., web., albums., s3.$DOMAIN"; else echo "api., web., albums.$DOMAIN"; fi; }

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
  local pre
  apt-get update -q; apt_install curl ca-certificates python3-yaml gnupg
  if [[ -n $DATA_DISK ]]; then mountpoint -q "$DATA_MNT" || die "$DATA_MNT not mounted; run bootstrap first"; fi
  install_docker
  install_caddy
  run_quickstart
  configure_host
  log "starting containers"
  pre=$(dc ps -q museum 2>/dev/null || true)
  dc up -d
  if [[ -n $pre && $MUSEUM_CFG_CHANGED == 1 ]]; then log "museum.yaml changed, restarting museum"; dc restart museum >/dev/null; fi
  wait_healthy museum
  url_ok http://127.0.0.1:8080/ping 10 || die "museum /ping failed locally"
  if url_ok "https://api.$DOMAIN/ping" 20; then log "https://api.$DOMAIN/ping OK"
  elif [[ $MODE == test ]]; then die "https://api.$DOMAIN/ping failed in test mode"
  else warn "https://api.$DOMAIN/ping not reachable yet - point DNS A/AAAA (TTL 300) for $(dns_names) to this server"; fi
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
  if [[ $BACKUP_TARGET == s3 ]]; then return 0; fi # S3 uses keys prompted in make_box_remotes, no SSH key
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

# rclone_set REMOTE < key=value lines: create/update a remote in rclone.conf directly, so secrets never appear in a command line
# and nothing contacts the endpoint (`rclone config create/update` does, and fails when it is unreachable).
rclone_set() {
  local conf
  conf=$(rclone config file | tail -1)
  mkdir -p "$(dirname "$conf")"
  (umask 077; python3 -c '
import configparser, sys
conf, remote = sys.argv[1:]
cp = configparser.RawConfigParser(); cp.optionxform = str; cp.read(conf)
if not cp.has_section(remote): cp.add_section(remote)
for line in sys.stdin.read().splitlines():
    if line:
        k, v = line.split("=", 1); cp.set(remote, k, v)
with open(conf, "w") as f: cp.write(f)
' "$conf" "$1")
}

make_box_remotes() { # [confirm|once]: confirm = new passphrase, once = existing one; prompts are skipped for remotes that exist
  local obs
  if [[ $BACKUP_TARGET == s3 ]]; then
    if rclone listremotes | grep -qx 'box:'; then
      rclone_set box <<EOF
provider=$BACKUP_S3_PROVIDER
endpoint=$BACKUP_S3_ENDPOINT
region=$BACKUP_S3_REGION
no_check_bucket=true
EOF
    else
      secret_var BACKUP_S3_ACCESS_KEY "Backup S3 access key ID"
      secret_var BACKUP_S3_SECRET_KEY "Backup S3 secret access key"
      rclone_set box <<EOF
type=s3
provider=$BACKUP_S3_PROVIDER
endpoint=$BACKUP_S3_ENDPOINT
region=$BACKUP_S3_REGION
access_key_id=$BACKUP_S3_ACCESS_KEY
secret_access_key=$BACKUP_S3_SECRET_KEY
no_check_bucket=true
EOF
    fi
  else
    rclone_set box <<EOF
type=sftp
host=$BOX_HOST
user=$BOX_USER
port=$BOX_PORT
key_file=$BOX_KEY
known_hosts_file=/root/.ssh/known_hosts
EOF
  fi
  if rclone listremotes | grep -qx 'box-crypt:'; then
    rclone_set box-crypt <<<"remote=${BOX_ROOT}config"
    log "box-crypt remote exists, keeping passphrase"; return 0
  fi
  secret_var BACKUP_PASSPHRASE "Backup passphrase (keep it in your password manager; losing it loses the config backups)" "${1:-confirm}"
  obs=$(rclone obscure - <<<"$BACKUP_PASSPHRASE")
  rclone_set box-crypt <<EOF
type=crypt
remote=${BOX_ROOT}config
password=$obs
EOF
}

# The primary bucket (what the backup reads): Silo on localhost, or the external S3 bucket from museum.yaml.
make_s3_remote() {
  if [[ $STORAGE == s3 ]]; then
    rclone_set ente-s3 <<EOF
type=s3
provider=$S3_PROVIDER
endpoint=$(museum_val endpoint)
region=$(museum_val region)
access_key_id=$(museum_val key)
secret_access_key=$(museum_val secret)
no_check_bucket=true
EOF
  else
    rclone_set ente-s3 <<EOF
type=s3
provider=Minio
endpoint=http://127.0.0.1:3200
region=$(museum_val region)
access_key_id=$(museum_val key)
secret_access_key=$(museum_val secret)
EOF
  fi
}

# Refuse to sync over a backup that belongs to another Ente instance (a fresh install pointed at an old backup would wipe it).
check_backup_owner() {
  local theirs
  [[ -n $(rclone lsf "${BOX_ROOT}config" 2>/dev/null | head -1 || true) ]] || return 0
  theirs=$(mktemp); chmod 600 "$theirs"
  if ! rclone cat box-crypt:museum.yaml >"$theirs" 2>/dev/null || [[ ! -s $theirs ]]; then
    rm -f "$theirs"; die "the backup target already holds a backup that this passphrase cannot read; refusing to overwrite it"
  fi
  if ! python3 - "$ENTE_DIR/museum.yaml" "$theirs" <<'PY'
import sys, yaml
a, b = (yaml.safe_load(open(f))["key"]["encryption"] for f in sys.argv[1:])
sys.exit(a != b)
PY
  then rm -f "$theirs"; die "the backup target holds the backup of a DIFFERENT Ente instance; refusing to overwrite it (use 'restore' on a fresh server, or a new bucket/folder)"; fi
  rm -f "$theirs"
}

install_backup_units() {
  write_file /etc/ente-backup.env 600 <<EOF
HC_URL="$HC_URL"
BOX_ROOT="$BOX_ROOT"
SRC_BUCKET="$SRC_BUCKET"
REQUIRE_MOUNT=$([[ -n $DATA_DISK ]] && echo yes || echo no)
LOW_RAM=$LOW_RAM
SYNCTHING=$SYNCTHING
EOF
  write_file /usr/local/bin/ente-backup.sh 755 <<'EOF'
#!/usr/bin/env bash
# Managed by ente-setup.sh. Config comes from /etc/ente-backup.env via systemd.
set -euo pipefail
umask 077
BOX_ROOT="${BOX_ROOT:-box:}"
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
rclone sync "ente-s3:${SRC_BUCKET:-b2-eu-cen}" "${BOX_ROOT}objects" --size-only "${OPTS[@]}" \
  --max-delete 500 --backup-dir "${BOX_ROOT}deleted/$(date +%F)"
if [[ "${SYNCTHING:-no}" == yes ]]; then
  rclone sync /srv/syncthing "${BOX_ROOT}syncthing" --exclude '/config/**' --checkers 4
fi
cutoff=$(date -d '60 days ago' +%F)
for d in $(rclone lsf --dirs-only "${BOX_ROOT}deleted" 2>/dev/null || true); do
  if [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}/$ && "${d%/}" < "$cutoff" ]]; then rclone purge "${BOX_ROOT}deleted/${d%/}"; fi
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
  load_env; need_backup; need_storage
  [[ -f $ENTE_DIR/museum.yaml ]] || die "run install first"
  install_rclone
  ensure_box_key
  make_box_remotes
  make_s3_remote
  check_backup_owner
  install_backup_units
  systemctl start --no-block ente-backup.service
  log "backup configured; first run started: journalctl -fu ente-backup.service"
}

# ---------------------------------------------------------------- restore
cmd_restore() {
  load_env; need_backup; need_storage
  local tmp dump t0=$SECONDS
  [[ ! -e $ENTE_DIR ]] || die "$ENTE_DIR already exists; restore is for a fresh server"
  if [[ -n $DATA_DISK ]]; then mountpoint -q "$DATA_MNT" || die "$DATA_MNT not mounted; run bootstrap first"; fi
  apt-get update -q; apt_install curl ca-certificates python3-yaml gnupg
  install_docker; install_caddy; install_rclone
  ensure_box_key
  rclone listremotes | grep -qx 'box-crypt:' && rclone config delete box-crypt
  make_box_remotes once
  tmp=$(mktemp -d /root/ente-restore.XXXXXX)
  # shellcheck disable=SC2064 # expand now: $tmp is local to this function
  trap "rm -rf '$tmp'" EXIT
  log "fetching config backup"
  rclone copy box-crypt: "$tmp" --checkers 4
  dump=$(find "$tmp" -maxdepth 1 -name 'ente_db-*.dump' | sort | tail -1)
  [[ -n $dump && -f $tmp/compose.yaml && -f $tmp/museum.yaml ]] || die "backup incomplete (wrong passphrase?): need ente_db-*.dump, compose.yaml, museum.yaml"
  install -d -m 700 "$ENTE_DIR"
  install -m 600 "$tmp/compose.yaml" "$ENTE_DIR/compose.yaml"
  install -m 644 "$tmp/museum.yaml" "$ENTE_DIR/museum.yaml"
  configure_host
  make_s3_remote
  log "starting postgres$([[ $STORAGE == silo ]] && echo ' and silo')"
  dc up -d --wait postgres $([[ $STORAGE == silo ]] && echo minio)
  log "restoring database $(basename "$dump")"
  dc cp "$dump" postgres:/tmp/restore.dump
  dc exec -T postgres pg_restore -U pguser -d ente_db --clean --if-exists /tmp/restore.dump || die "pg_restore failed"
  dc exec -T postgres rm -f /tmp/restore.dump
  log "restoring objects (this can take long)"
  local opts=(--checkers 4 --transfers 4)
  [[ $LOW_RAM == yes ]] && opts=(--checkers 4 --transfers 2 --buffer-size 4M)
  if [[ $STORAGE == s3 && -n $(rclone lsf "ente-s3:$SRC_BUCKET" --max-depth 1 2>/dev/null | head -1 || true) ]]; then
    log "primary bucket $SRC_BUCKET already holds objects; keeping them (not copying from the backup)"
  else
    rclone copy "${BOX_ROOT}objects" "ente-s3:$SRC_BUCKET" "${opts[@]}"
  fi
  dc up -d
  wait_healthy museum
  url_ok http://127.0.0.1:8080/ping 10 || die "museum /ping failed locally"
  log "restore finished in $((SECONDS - t0))s"
  cat <<EOF

Restored. Next:
  1. DNS: point A/AAAA of $(dns_names) to $(host_ip) (TTL 300). Certificates are issued once DNS resolves.
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
  for s in museum web postgres $([[ $STORAGE == silo ]] && echo minio); do
    cid=$(dc ps -q "$s" 2>/dev/null || true)
    if [[ -z $cid ]]; then bad "$s not running"; continue; fi
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")
    pol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid")
    if [[ $st == healthy || $st == running ]]; then ok "$s $st"; else bad "$s $st"; fi
    if [[ $pol == unless-stopped ]]; then ok "$s restart=$pol"; else bad "$s restart=$pol"; fi
  done
  if [[ -z $(dc ps -q socat 2>/dev/null || true) ]]; then ok "socat not running"; else bad "socat is running"; fi
  echo "== ports"
  for p in 8080 3000 3002 $([[ $STORAGE == silo ]] && echo 3200); do
    addrs=$(ss -Htln "sport = :$p" | awk '{print $4}')
    if [[ -z $addrs ]]; then bad "port $p not listening"
    elif grep -qvE '^127\.0\.0\.1:' <<<"$addrs"; then bad "port $p exposed beyond localhost: $(echo "$addrs" | tr '\n' ' ')"
    else ok "port $p on 127.0.0.1 only"; fi
  done
  for p in 3200 3201 5432; do
    [[ $p == 3200 && $STORAGE == silo ]] && continue
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
  if [[ $STORAGE == s3 ]]; then
    echo "== primary storage"
    if out=$(rclone lsf "ente-s3:$SRC_BUCKET" --max-depth 1 2>&1 >/dev/null); then ok "bucket $SRC_BUCKET reachable"; else bad "bucket $SRC_BUCKET: $out"; fi
    out=$(curl -sS -m 10 -o /dev/null -D - -X OPTIONS -H "Origin: https://web.$DOMAIN" -H "Access-Control-Request-Method: PUT"       "https://$(museum_val endpoint)/$SRC_BUCKET/ente-check" 2>&1 || true)
    if grep -qi '^access-control-allow-origin:' <<<"$out"; then ok "CORS preflight from https://web.$DOMAIN allowed"; else bad "CORS preflight from https://web.$DOMAIN not allowed (web uploads will fail)"; fi
  fi
  echo "== backup"
  if systemctl is-enabled --quiet ente-backup.timer 2>/dev/null; then ok "timer enabled, next: $(systemctl show ente-backup.timer -p NextElapseUSecRealtime --value)"; else bad "ente-backup.timer not enabled"; fi
  ts=$(systemctl show ente-backup.service -p ExecMainExitTimestamp --value 2>/dev/null || true)
  res=$(systemctl show ente-backup.service -p Result --value 2>/dev/null || true)
  if [[ -z $ts ]]; then warn "backup has not run yet"
  elif [[ $res == success ]]; then ok "last backup finished $ts: $res"; else bad "last backup $ts: $res"; fi
  if out=$(rclone check "ente-s3:$SRC_BUCKET" "${BOX_ROOT}objects" --one-way --size-only --checkers 4 2>&1); then ok "rclone check: bucket is on the backup target"
  else bad "rclone check failed: $(echo "$out" | tail -3 | tr '\n' ' ')"; fi
  echo "== system"
  df -h / ${DATA_DISK:+"$DATA_MNT"} | sed 's/^/        /'
  warn "check the backup target's usage in its console (Hetzner / S3 provider)"
  n=$(journalctl -k -q --since '30 days ago' 2>/dev/null | grep -ciE 'out of memory|oom-kill' || true)
  if [[ $n == 0 ]]; then ok "no OOM kills in 30 days"; else bad "$n OOM kernel messages (journalctl -k | grep -i oom)"; fi
  if [[ -e /var/run/reboot-required ]]; then warn "reboot required"; else ok "no reboot pending"; fi
  echo
  if ((FAILS)); then echo "$FAILS check(s) FAILED"; return 1; fi
  echo "all checks passed"
}

# ---------------------------------------------------------------- deploy
# bootstrap + (install | restore) + backup-setup in one go, from the config and secrets given.
cmd_deploy() {
  cmd_bootstrap
  if [[ $RESTORE == yes ]]; then cmd_restore; else cmd_install; fi
  cmd_backup_setup
  log "deploy finished. Next: sign up the owner, then '$0 lockdown'."
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
usage() { echo "usage: $0 {deploy|bootstrap|install|codes|lockdown|backup-setup|restore|check|update|syncthing}" >&2; exit 2; }

main() {
  CMD=$1
  case $CMD in
    deploy) load_env; cmd_deploy ;;
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
