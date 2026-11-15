#!/usr/bin/env bash
# ente-setup.sh - turn a fresh Debian 12/13 VPS into a backed-up Ente Photos server.
# Photos live in an external S3 bucket (no local storage needed); a second S3 bucket holds the backup.
# Usage: ente-setup.sh <deploy|bootstrap|install|codes|lockdown|backup-setup|restore|check|verify|update|alert-test|speedtest|vpn>
# Config:  ente-setup.env next to this script (or ENV_FILE=/path). See ente-setup.env.example.
# Secrets: prompted, or from the environment / ente-setup.secrets (mode 600). See ente-setup.secrets.example.
set -euo pipefail
# apt keyrings, source lists and unit files must be world-readable even when root's shell has a strict umask (apt verifies
# signatures as the unprivileged _apt user). Everything secret is created with an explicit mode.
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE=${ENV_FILE:-$SCRIPT_DIR/ente-setup.env}
SECRETS_FILE=${SECRETS_FILE:-$SCRIPT_DIR/ente-setup.secrets}
LOG=/var/log/ente-setup.log
ENTE_DIR=/opt/my-ente
PINS=$ENTE_DIR/image-pins
QUICKSTART_URL=https://raw.githubusercontent.com/ente/ente/main/server/quickstart.sh
INT_BEGIN='# BEGIN ente-setup internal'
INT_END='# END ente-setup internal'
# the backup service uses this path; do not depend on sudo's HOME
export RCLONE_CONFIG=/root/.config/rclone/rclone.conf
FAILS=0
MUSEUM_CFG_CHANGED=0
CMD=
SECRET_VARS='S3_ACCESS_KEY S3_SECRET_KEY BACKUP_S3_ACCESS_KEY BACKUP_S3_SECRET_KEY BACKUP_PASSPHRASE YANDEX_TOKEN YANDEX_CLIENT_SECRET TG_BOT_TOKEN'

# ---------------------------------------------------------------- helpers
# log MSG / die MSG: timestamped line tagged with the command; die prints to stderr and exits 1.
log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$CMD" "$*"; }
die()  { printf '%s [%s] ERROR: %s\n' "$(date '+%F %T')" "$CMD" "$*" >&2; exit 1; }
# ok/bad/warn MSG: check result lines; bad also counts the failure in FAILS.
ok()   { printf '  OK    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '  WARN  %s\n' "$*"; }

# dc ARGS: docker compose in the Ente directory.
dc() { (cd "$ENTE_DIR" && docker compose "$@"); }
# apt_get ARGS: non-interactive apt-get.
# fresh images run unattended-upgrades at first boot and hold the dpkg lock: wait for it
apt_get() { DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -q "$@"; }
# apt_install PKG...: install packages without recommends.
apt_install() { apt_get install -y --no-install-recommends "$@"; }
# Never `cmd | grep -q` under pipefail: grep exits at the first match, cmd may die of SIGPIPE and the test fails
# at random (seen with rclone listremotes). Use `grep ... >/dev/null`, which reads all input.
# ensure_line FILE LINE: append LINE to FILE unless already present verbatim.
ensure_line() { grep -qxF -- "$2" "$1" 2>/dev/null || echo "$2" >>"$1"; }
# version_ge VERSION MIN: true if VERSION (optional leading v) >= MIN.
version_ge() { [[ $(printf '%s\n%s\n' "$2" "${1#v}" | sort -V | head -1) == "$2" ]]; }
# host_ip: this server's outbound IPv4 address.
host_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'; }
# need VAR...: die unless every named config variable is non-empty.
need() { local v; for v in "$@"; do [[ -n ${!v} ]] || die "$v is not set in $ENV_FILE"; done; }
# url_ok URL [TRIES]: poll URL every 3s until it answers 2xx; false after TRIES (default 20).
url_ok() { local i; for i in $(seq 1 "${2:-20}"); do curl -fsS -m 5 "$1" >/dev/null 2>&1 && return 0; sleep 3; done; return 1; }
# yaml_ok FILE: die unless FILE parses as YAML.
yaml_ok() { python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$1" || die "$1 is not valid YAML"; }

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

# secret_var VAR PROMPT [confirm]: keep VAR if already set (environment / secrets file), else ask silently on a terminal.
# Secrets are never logged or written to the config file.
secret_var() {
  local -n _v=$1
  local a b
  [[ -z $_v ]] || return 0
  [[ -t 0 ]] || die "$1 is not set and there is no terminal to ask on (set it in the environment or $SECRETS_FILE)"
  while :; do
    read -rsp "$2: " a; echo >&2
    [[ -n $a ]] || { echo "must not be empty" >&2; continue; }
    if [[ ${3:-} == confirm ]]; then
      read -rsp "$2 (again): " b; echo >&2
      [[ $a == "$b" ]] || { echo "did not match, retry" >&2; continue; }
    fi
    _v=$a; return 0
  done
}

# Source the config and secrets files (environment wins over secrets file), apply defaults, validate.
load_env() {
  [[ -f $ENV_FILE ]] || die "config $ENV_FILE not found (copy ente-setup.env.example)"
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  if [[ -f $SECRETS_FILE ]]; then
    local v e
    [[ $(stat -c %a "$SECRETS_FILE") =~ ^[46]00$ ]] || die "$SECRETS_FILE must be mode 600"
    for v in $SECRET_VARS; do declare -g "_env_$v=${!v:-}"; done
    # shellcheck source=/dev/null
    . "$SECRETS_FILE"
    for v in $SECRET_VARS; do e=_env_$v; [[ -z ${!e} ]] || declare -g "$v=${!e}"; done # variables set in the environment win
  fi
  DOMAIN=${DOMAIN:-}; ADMIN_USER=${ADMIN_USER:-}; ADMIN_SSH_PUBKEY=${ADMIN_SSH_PUBKEY:-}; FAIL2BAN=${FAIL2BAN:-yes}
  SSH_PORT=${SSH_PORT:-22}; HC_URL=${HC_URL:-}; RESTORE=${RESTORE:-no}; CSP_REPORT_ONLY=${CSP_REPORT_ONLY:-no}
  S3_PROVIDER=${S3_PROVIDER:-Other}; S3_ENDPOINT=${S3_ENDPOINT:-}; S3_REGION=${S3_REGION:-}; S3_BUCKET=${S3_BUCKET:-}
  S3_CORS_ORIGINS=${S3_CORS_ORIGINS:-https://web.$DOMAIN,https://albums.$DOMAIN}
  BACKUP_S3_PROVIDER=${BACKUP_S3_PROVIDER:-Other}; BACKUP_S3_ENDPOINT=${BACKUP_S3_ENDPOINT:-}
  BACKUP_S3_REGION=${BACKUP_S3_REGION:-}; BACKUP_S3_BUCKET=${BACKUP_S3_BUCKET:-}
  AWG_PORT=${AWG_PORT:-}; YANDEX_DIR=${YANDEX_DIR:-}; YANDEX_CLIENT_ID=${YANDEX_CLIENT_ID:-}; RESTORE_FROM=${RESTORE_FROM:-s3}; TG_CHAT_ID=${TG_CHAT_ID:-}
  [[ ${1:-} != vpn ]] || return 0 # the VPN needs none of the Ente settings
  S3_ACCESS_KEY=${S3_ACCESS_KEY:-}; S3_SECRET_KEY=${S3_SECRET_KEY:-}
  BACKUP_S3_ACCESS_KEY=${BACKUP_S3_ACCESS_KEY:-}; BACKUP_S3_SECRET_KEY=${BACKUP_S3_SECRET_KEY:-}; BACKUP_PASSPHRASE=${BACKUP_PASSPHRASE:-}
  YANDEX_TOKEN=${YANDEX_TOKEN:-}; YANDEX_CLIENT_SECRET=${YANDEX_CLIENT_SECRET:-}; TG_BOT_TOKEN=${TG_BOT_TOKEN:-}
  need DOMAIN S3_ENDPOINT S3_REGION S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_BUCKET
  [[ $DOMAIN =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z0-9-]+$ && $DOMAIN != *example.com ]] || die "DOMAIN missing, invalid or a placeholder"
  [[ $SSH_PORT =~ ^[1-9][0-9]{0,4}$ ]] && ((SSH_PORT <= 65535)) && [[ ! $SSH_PORT =~ ^(80|443|3200|3201|5432)$ ]] ||
    die "SSH_PORT must be 1-65535 and not 80, 443, 3200, 3201 or 5432"
  [[ $S3_ENDPOINT != *://* &&$BACKUP_S3_ENDPOINT != *://* ]] || die "S3 endpoints must be bare hostnames, without https://"
  [[ $S3_ENDPOINT/$S3_BUCKET != "$BACKUP_S3_ENDPOINT/$BACKUP_S3_BUCKET" ]] || die "backup bucket must differ from the photo bucket"
  BACKUP_ROOT=backup:$BACKUP_S3_BUCKET/
  YANDEX_ROOT=
  if [[ -n $YANDEX_DIR ]]; then
    [[ $YANDEX_DIR =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || die "YANDEX_DIR must be a relative folder path like ente-backup (letters, digits, . _ -)"
    YANDEX_ROOT=yandex:$YANDEX_DIR/
  fi
  [[ -z $HC_URL || $HC_URL =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/?\&=%:+-]*)?$ ]] || die "HC_URL must be an https:// ping URL without spaces or quotes"
  [[ -z $TG_CHAT_ID || $TG_CHAT_ID =~ ^-?[0-9]+$ ]] || die "TG_CHAT_ID must be a number (a group's ID starts with -)"
  [[ $RESTORE_FROM == s3 || ($RESTORE_FROM == yandex && -n $YANDEX_DIR) ]] || die "RESTORE_FROM must be s3, or yandex with YANDEX_DIR set"
}

# ---------------------------------------------------------------- bootstrap
# Create the passwordless-sudo admin user with its key, then harden sshd (key-only, no root) and verify it took effect.
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
Port $SSH_PORT
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers $ADMIN_USER
MaxAuthTries 3
EOF
  sshd -t || die "sshd config invalid"
  n=$(sshd -T | grep -Ec '^(port '"$SSH_PORT"'|passwordauthentication no|kbdinteractiveauthentication no|permitrootlogin no|allowusers '"$ADMIN_USER"'|maxauthtries 3)$' || true)
  if ((n != 6)); then
    rm -f /etc/ssh/sshd_config.d/10-hardening.conf
    die "sshd -T does not show the hardening (no Include for sshd_config.d?); drop-in removed"
  fi
  if systemctl is-active --quiet ssh.socket; then
    # socket activation (Ubuntu 24.04+): a generator derives the listen port from sshd_config
    systemctl daemon-reload
    systemctl restart ssh.socket
  else
    systemctl reload ssh
  fi
  for n in $(seq 1 10); do
    [[ -z $(ss -Htln "sport = :$SSH_PORT") ]] || break
    ((n < 10)) || die "sshd is not listening on port $SSH_PORT"
    sleep 1
  done
  log "sshd hardened on port $SSH_PORT. TEST A SECOND LOGIN as $ADMIN_USER before closing this session!"
}

# bootstrap: upgrade packages, admin user + sshd hardening, ufw, unattended upgrades, swap, fail2ban.
cmd_bootstrap() {
  load_env; need ADMIN_USER ADMIN_SSH_PUBKEY
  [[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]*$ && $ADMIN_USER != root ]] || die "ADMIN_USER invalid"
  local kf; kf=$(mktemp); printf '%s\n' "$ADMIN_SSH_PUBKEY" >"$kf"
  ssh-keygen -l -f "$kf" >/dev/null 2>&1 || { rm -f "$kf"; die "ADMIN_SSH_PUBKEY is not a valid public key (placeholder or truncated?); refusing, it would lock you out"; }
  rm -f "$kf"
  # some images leave the hostname unresolvable: sudo then warns on every call and some tools wait for DNS
  getent hosts "$(hostname)" >/dev/null || { echo "127.0.1.1 $(hostname)" >>/etc/hosts; log "added $(hostname) to /etc/hosts"; }
  log "updating packages"
  apt_get update
  apt_get -y -o Dpkg::Options::=--force-confold upgrade
  apt_install sudo ufw curl ca-certificates gnupg unattended-upgrades python3-yaml unzip openssh-server
  local oldport
  oldport=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | head -1 || true)
  # open the new port before sshd moves to it, so an active firewall never locks us out
  ufw allow "$SSH_PORT/tcp" >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  setup_ssh
  if [[ -n $oldport && $oldport != "$SSH_PORT" ]]; then ufw delete allow "$oldport/tcp" >/dev/null || true; fi
  ufw --force enable >/dev/null
  write_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  write_file /etc/apt/apt.conf.d/52ente-unattended <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
EOF
  if ! swapon --show=NAME --noheadings | grep -x /swapfile >/dev/null; then
    if [[ ! -f /swapfile ]]; then fallocate -l 2G /swapfile; chmod 600 /swapfile; mkswap /swapfile >/dev/null; fi
    swapon /swapfile
  fi
  ensure_line /etc/fstab '/swapfile none swap sw 0 0'
  if [[ $FAIL2BAN == yes ]]; then
    apt_install fail2ban python3-systemd
    write_file /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
backend = systemd
port = $SSH_PORT
EOF
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
  fi
  log "bootstrap done. Test a second login as $ADMIN_USER (ssh -p $SSH_PORT $ADMIN_USER@<ip>) before closing this session."
  [[ $SSH_PORT == 22 ]] || log "if your provider has its own firewall (security group), allow TCP $SSH_PORT there too."
}

# ---------------------------------------------------------------- install helpers
# Install Docker if missing, cap container log size, and require Compose >= 2.30.
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

# Install Caddy from its apt repository if missing.
install_caddy() {
  command -v caddy >/dev/null && return 0
  log "installing Caddy from its apt repository"
  apt_install debian-keyring debian-archive-keyring apt-transport-https curl gpg
  local k; k=$(mktemp)
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o "$k"
  install -m 644 "$k" /usr/share/keyrings/caddy-stable-archive-keyring.gpg; rm -f "$k" # apt reads it as the _apt user
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt >/etc/apt/sources.list.d/caddy-stable.list
  chmod 644 /etc/apt/sources.list.d/caddy-stable.list
  apt_get update
  apt_install caddy
}

# Install rclone via its install script if missing.
install_rclone() {
  command -v rclone >/dev/null && return 0
  apt_install unzip curl ca-certificates
  curl -fsSL https://rclone.org/install.sh | bash >/dev/null
}

# Run Ente's quickstart into $ENTE_DIR (declining its auto-start) unless it already produced compose.yaml + museum.yaml.
run_quickstart() {
  if [[ -f $ENTE_DIR/compose.yaml && -f $ENTE_DIR/museum.yaml ]]; then log "$ENTE_DIR exists, skipping quickstart"; return 0; fi
  [[ ! -e $ENTE_DIR ]] || die "$ENTE_DIR exists but is incomplete (failed quickstart?); remove it and re-run"
  log "running Ente quickstart (answering n)"
  (cd /opt && printf 'n\n' | sh -c "$(curl -fsSL "$QUICKSTART_URL")") >/dev/null || die "quickstart failed"
  [[ -f $ENTE_DIR/compose.yaml && -f $ENTE_DIR/museum.yaml ]] || die "quickstart did not create compose.yaml/museum.yaml"
}

# Edit the quickstart output and assert every edit; fail loudly if its format changed. Idempotent.
apply_edits() {
  local c=$ENTE_DIR/compose.yaml m=$ENTE_DIR/museum.yaml p
  chmod 700 "$ENTE_DIR"
  python3 - "$c" "$m" <<'PY' || die "quickstart output no longer matches the expected layout; not patching blindly"
import sys, yaml
c = yaml.safe_load(open(sys.argv[1])); m = yaml.safe_load(open(sys.argv[2]))
s = c["services"]
assert set(s) == {"museum", "socat", "web", "postgres", "minio"}, set(s)
assert s["postgres"]["image"] == "postgres:15"
assert s["museum"]["image"] == "ghcr.io/ente/server" and s["web"]["image"] == "ghcr.io/ente/web"
b = m["s3"]["b2-eu-cen"]
for k in ("key", "secret", "endpoint", "region", "bucket"):
    assert b[k], k
assert m["db"]["host"] == "postgres" and m["db"]["port"] == 5432
assert "public-albums" in m["apps"] and "key" in m and "jwt" in m
PY
  for p in 8080 3000 3002; do
    sed -Ei "s/^( *- )(127\.0\.0\.1:)?$p:$p( |\$)/\1127.0.0.1:$p:$p\3/" "$c"
    grep -Eq "^ *- 127\.0\.0\.1:$p:$p( |\$)" "$c" || die "compose.yaml: port line for $p not found"
  done
  grep -q '^ *ENTE_API_ORIGIN:' "$c" || die "compose.yaml: ENTE_API_ORIGIN not found"
  sed -Ei "s|^( *ENTE_API_ORIGIN:).*|\1 https://api.$DOMAIN|" "$c"
  grep -qE "^ *ENTE_API_ORIGIN: https://api\.${DOMAIN//./\\.}\$" "$c" || die "compose.yaml: ENTE_API_ORIGIN edit failed"
  sed -E "s|^( *public-albums:).*|\1 https://albums.$DOMAIN|" "$m" >"$m.new"; cat "$m.new" >"$m"; rm -f "$m.new" # in place: keep the inode for the bind mount
  grep -Fq "public-albums: https://albums.$DOMAIN" "$m" || die "museum.yaml: public-albums edit failed"
  if [[ -z $S3_ACCESS_KEY || -z $S3_SECRET_KEY ]] && museum_s3_configured; then
    local M_KEY M_SECRET M_ENDPOINT M_REGION M_BUCKET
    eval "$(museum_s3)"; S3_ACCESS_KEY=$M_KEY; S3_SECRET_KEY=$M_SECRET # keep the keys already in museum.yaml
  fi
  secret_var S3_ACCESS_KEY "S3 access key ID (photo bucket)"
  secret_var S3_SECRET_KEY "S3 secret access key (photo bucket)"
  edit_museum_s3 "$m"
  yaml_ok "$c"; yaml_ok "$m"
}

# Point the b2-eu-cen bucket at the external photo bucket and drop the two unused buckets.
edit_museum_s3() {
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

# museum_s3: eval "$(museum_s3)" sets M_KEY M_SECRET M_ENDPOINT M_REGION M_BUCKET from museum.yaml (the source of truth after install).
museum_s3() {
  python3 - "$ENTE_DIR/museum.yaml" <<'PY'
import shlex, sys, yaml
b = yaml.safe_load(open(sys.argv[1]))["s3"]["b2-eu-cen"]
for k in ("key", "secret", "endpoint", "region", "bucket"): print("M_%s=%s" % (k.upper(), shlex.quote(str(b[k]))))
PY
}

# true when museum.yaml already points at the configured photo bucket (and is not the quickstart's local MinIO)
museum_s3_configured() {
  python3 - "$ENTE_DIR/museum.yaml" "$S3_ENDPOINT" "$S3_BUCKET" <<'PY'
import sys, yaml
b = yaml.safe_load(open(sys.argv[1]))["s3"]["b2-eu-cen"]
sys.exit(not (b["endpoint"] == sys.argv[2] and b["bucket"] == sys.argv[3] and not str(b["key"]).startswith("minio-user-")))
PY
}

# Prove the photo bucket works (read, write, delete) and set CORS so the web app can upload straight to it.
s3_prepare() {
  local M_KEY M_SECRET M_ENDPOINT M_REGION M_BUCKET
  eval "$(museum_s3)"
  dpkg -s python3-boto3 >/dev/null 2>&1 || apt_install python3-boto3
  S3_ENDPOINT=$M_ENDPOINT S3_REGION=$M_REGION S3_BUCKET=$M_BUCKET S3_ACCESS_KEY=$M_KEY S3_SECRET_KEY=$M_SECRET S3_CORS_ORIGINS=$S3_CORS_ORIGINS \
    python3 - <<'PY' || die "photo bucket check failed"
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
print("  OK    photo bucket %s: read/write/delete work" % b)
rule = {"AllowedOrigins": e["S3_CORS_ORIGINS"].split(","), "AllowedMethods": ["GET", "HEAD", "POST", "PUT", "DELETE"],
        "AllowedHeaders": ["*"], "ExposeHeaders": ["ETag"], "MaxAgeSeconds": 3000}
try:
    c.put_bucket_cors(Bucket=b, CORSConfiguration={"CORSRules": [rule]})
    print("  OK    CORS set for", e["S3_CORS_ORIGINS"])
except Exception as x:
    print("  WARN  could not set CORS (%s); set it by hand or web uploads fail: origins %s, methods GET/HEAD/POST/PUT/DELETE, headers *, expose ETag" % (type(x).__name__, e["S3_CORS_ORIGINS"]))
PY
}

# ---------------------------------------------------------------- image pins
# The quickstart's compose.yaml names the Ente images without a version (= latest). $PINS names the exact builds in use
# (one line per service: "museum ghcr.io/ente/server@sha256:..."); compose.override.yaml is written from it and the backup
# carries it, so a restore runs the builds that made the dump. Only `update` moves the pins. postgres stays on postgres:15.
repo_of() { case $1 in museum) echo ghcr.io/ente/server ;; web) echo ghcr.io/ente/web ;; esac; }
# pin_of SERVICE: the pinned image reference from $PINS, empty if none.
pin_of() { awk -v s="$1" '$1 == s {r = $2} END {print r}' "$PINS" 2>/dev/null || true; }
# image_digest IMAGE REPO: the REPO@sha256:... name of a local image (given by ID, tag or digest), empty if it has none.
image_digest() {
  docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$1" 2>/dev/null |
    awk -v r="$2@sha256:" 'index($0, r) == 1 && !f {print; f = 1}' || true
}

# ensure_pins: make $PINS name an available build of each Ente image. A pin is kept while its image is local or can be pulled.
# Without one (first install, a backup from before pinning) the running container's image is pinned, else the local latest,
# else a freshly pulled latest.
ensure_pins() {
  local svc repo ref cid new=''
  for svc in museum web; do
    repo=$(repo_of $svc); ref=$(pin_of $svc)
    if [[ -n $ref ]]; then
      [[ $ref =~ ^$repo@sha256:[0-9a-f]{64}$ ]] || die "$PINS: bad entry for $svc"
      if ! docker image inspect "$ref" >/dev/null 2>&1 && ! docker pull -q "$ref" >/dev/null 2>&1; then
        warn "the pinned $svc image ${ref##*@} can no longer be pulled; pinning the running or latest build instead"; ref=
      fi
    fi
    if [[ -z $ref ]]; then
      cid=$(dc ps -q $svc 2>/dev/null || true)
      [[ -z $cid ]] || ref=$(image_digest "$(docker inspect -f '{{.Image}}' "$cid")" "$repo")
      [[ -n $ref ]] || ref=$(image_digest "$repo:latest" "$repo")
      if [[ -z $ref ]]; then
        docker pull -q "$repo:latest" >/dev/null || die "cannot pull $repo:latest"
        ref=$(image_digest "$repo:latest" "$repo")
      fi
      [[ -n $ref ]] || die "cannot determine the digest of $repo"
      log "pinned $svc to $ref"
    fi
    new+="$svc $ref"$'\n'
  done
  printf '%s' "$new" | write_file "$PINS" 600
}

# write_override: compose.override.yaml with the pinned images, restart policies and OOM priorities.
# minio and socat only serve the quickstart's local storage; the photos are in the external bucket.
write_override() {
  write_file "$ENTE_DIR/compose.override.yaml" 600 <<EOF
services:
  museum:
    image: $(pin_of museum)
    restart: unless-stopped
    oom_score_adj: -300
  web:
    image: $(pin_of web)
    restart: unless-stopped
  postgres:
    restart: unless-stopped
    oom_score_adj: -500
  minio:
    profiles: ["off"]
  socat:
    profiles: ["off"]
EOF
  dc config -q >/dev/null || die "docker compose config failed"
}

# internal_admin: admin user_id from our internal block (empty if none). internal_locked: true if sign-ups are disabled.
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
  if [[ -n $admin || $lock == yes ]]; then
    {
      echo "$INT_BEGIN"; echo "internal:"
      if [[ -n $admin ]]; then echo "  admins: [$admin]"; fi
      if [[ $lock == yes ]]; then echo "  disable-registration: true"; fi
      echo "$INT_END"
    } >>"$tmp"
  fi
  if ! cmp -s "$tmp" "$m"; then cat "$tmp" >"$m"; MUSEUM_CFG_CHANGED=1; log "updated internal block in museum.yaml"; fi # in place: keep inode for the bind mount
  rm -f "$tmp"
  yaml_ok "$m"
}

# Shared by install and restore: patch the Ente config, verify the photo bucket, write the Caddyfile and compose override.
# Sets MUSEUM_CFG_CHANGED=1 when museum.yaml changed.
configure_host() {
  local h0; h0=$(sha256sum "$ENTE_DIR/museum.yaml")
  apply_edits
  s3_prepare
  sync_internal
  [[ $(sha256sum "$ENTE_DIR/museum.yaml") == "$h0" ]] || MUSEUM_CFG_CHANGED=1
  # Security headers. deferred, so they replace any the upstream sends. CSP only as Report-Only (CSP_REPORT_ONLY=yes):
  # violations show in the browser console, nothing is blocked. No CORS headers here: museum sets those itself.
  local csp=''
  if [[ $CSP_REPORT_ONLY == yes ]]; then
    csp="Content-Security-Policy-Report-Only \"default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline';"
    csp+=" img-src 'self' blob: data:; media-src 'self' blob:; font-src 'self' data:; worker-src 'self' blob:;"
    csp+=" connect-src 'self' https://api.$DOMAIN https://$S3_ENDPOINT https://$S3_BUCKET.$S3_ENDPOINT;"
    csp+=" object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'\""
  fi
  write_file /etc/caddy/Caddyfile <<EOF
(sec) {
	header {
		defer
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		Permissions-Policy "camera=(), microphone=(), geolocation=()"
		-Server
	}
}
(app) {
	header {
		defer
		X-Frame-Options "DENY"
		$csp
	}
}

api.$DOMAIN {
	import sec
	reverse_proxy 127.0.0.1:8080
}
web.$DOMAIN {
	import sec
	import app
	reverse_proxy 127.0.0.1:3000
}
albums.$DOMAIN {
	import sec
	import app
	reverse_proxy 127.0.0.1:3002
}
EOF
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || die "Caddyfile invalid"
  systemctl enable caddy >/dev/null 2>&1
  systemctl reload-or-restart caddy # graceful and cheap when nothing changed
  ensure_pins
  write_override
}

# wait_healthy SERVICE [TIMEOUT]: wait until the container is healthy (or running, without a healthcheck); die after TIMEOUT s (default 360).
wait_healthy() {
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

# install: Docker, Caddy, Ente quickstart, host config, start containers and check /ping locally and via the domain.
cmd_install() {
  load_env
  local pre
  apt_get update; apt_install curl ca-certificates python3-yaml gnupg
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
  else warn "https://api.$DOMAIN/ping not reachable yet - point DNS A/AAAA (TTL 300) of api., web., albums.$DOMAIN to this server"; fi
  cat <<EOF

Ente is up.
  1. Save $ENTE_DIR/museum.yaml in your password manager (secrets + encryption keys).
  2. Sign up the OWNER first at https://web.$DOMAIN, then the family. Codes: $0 codes
  3. Then: $0 lockdown   (makes the owner admin, closes sign-ups)
EOF
}

# ---------------------------------------------------------------- codes / lockdown / update
# codes: show sign-up verification codes from the last 24 h of museum logs (no mail server is configured).
cmd_codes() {
  load_env
  dc logs --no-log-prefix --since 24h museum 2>&1 | grep -ai 'verification code' | tail -n 20 || echo "no codes in the last 24h"
}

# lockdown: after confirmation, make the oldest user the admin, disable registration and restart museum.
cmd_lockdown() {
  load_env
  local rows first id a
  if [[ -n $(internal_admin) ]] && internal_locked; then log "already locked down (admin $(internal_admin))"; return 0; fi
  wait_healthy museum 60
  # deleted accounts keep their row with the email wiped: skip them
  rows=$(dc exec -T postgres psql -U pguser -d ente_db -At -F '|' -c "SELECT user_id, to_timestamp(creation_time/1000000) FROM users WHERE encrypted_email IS NOT NULL ORDER BY creation_time;" </dev/null)
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

# update: back up first (if configured), move the pins to the current latest Ente images, restart what changed, prune.
# The previous pins stay in $PINS.prev.
cmd_update() {
  load_env
  local svc repo ref old new='' changed=0
  if systemctl cat ente-backup.service >/dev/null 2>&1; then
    log "running a backup first (rollback point)"
    systemctl start ente-backup.service || die "backup failed; not updating"
  else
    warn "no backup configured yet; updating without a rollback point"
  fi
  ensure_pins
  cp -p "$PINS" "$PINS.prev"
  for svc in museum web; do
    repo=$(repo_of $svc); old=$(pin_of $svc)
    docker pull -q "$repo:latest" >/dev/null || die "cannot pull $repo:latest"
    ref=$(image_digest "$repo:latest" "$repo"); [[ -n $ref ]] || die "cannot determine the digest of $repo:latest"
    if [[ $ref != "$old" ]]; then changed=1; log "$svc: ${old##*@sha256:} -> ${ref##*@sha256:}"; fi
    new+="$svc $ref"$'\n'
  done
  printf '%s' "$new" | write_file "$PINS" 600
  write_override
  dc pull -q postgres
  dc up -d
  wait_healthy museum
  url_ok http://127.0.0.1:8080/ping 10 || die "museum /ping fails after the update; the previous versions are in $PINS.prev (README: Updates)"
  docker image prune -f >/dev/null
  if ((changed)); then log "updated; the previous versions are in $PINS.prev (README: Updates)"; else log "Ente images were already current"; fi
}

# ---------------------------------------------------------------- backup
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

# make_backup_remotes [confirm|once]: backup (S3 bucket) and backup-crypt (encrypted config/ folder in it).
# confirm = ask the passphrase twice, once = once (restore). Existing remotes keep their keys and passphrase.
make_backup_remotes() {
  local obs
  if ! rclone listremotes | grep -x 'backup:' >/dev/null; then
    secret_var BACKUP_S3_ACCESS_KEY "Backup bucket access key ID"
    secret_var BACKUP_S3_SECRET_KEY "Backup bucket secret access key"
    rclone_set backup <<EOF
type=s3
access_key_id=$BACKUP_S3_ACCESS_KEY
secret_access_key=$BACKUP_S3_SECRET_KEY
EOF
  fi
  rclone_set backup <<EOF
provider=$BACKUP_S3_PROVIDER
endpoint=$BACKUP_S3_ENDPOINT
region=$BACKUP_S3_REGION
no_check_bucket=true
EOF
  if rclone listremotes | grep -x 'backup-crypt:' >/dev/null; then
    rclone_set backup-crypt <<<"remote=${BACKUP_ROOT}config"
    log "backup-crypt remote exists, keeping passphrase"; return 0
  fi
  secret_var BACKUP_PASSPHRASE "Backup passphrase (keep it in your password manager; losing it loses the config backups)" "${1:-confirm}"
  obs=$(rclone obscure - <<<"$BACKUP_PASSPHRASE")
  rclone_set backup-crypt <<EOF
type=crypt
remote=${BACKUP_ROOT}config
password=$obs
EOF
}

# ente-s3: the photo bucket as the backup reads it (credentials from museum.yaml)
make_photo_remote() {
  local M_KEY M_SECRET M_ENDPOINT M_REGION M_BUCKET
  eval "$(museum_s3)"
  rclone_set ente-s3 <<EOF
type=s3
provider=$S3_PROVIDER
endpoint=$M_ENDPOINT
region=$M_REGION
access_key_id=$M_KEY
secret_access_key=$M_SECRET
no_check_bucket=true
EOF
}

# yandex (Yandex Disk, native API: its WebDAV is throttled) and yandex-crypt (encrypted config/ folder in YANDEX_DIR).
# The token is the JSON printed by `rclone authorize "yandex"` on a PC with a browser; rclone refreshes it in rclone.conf,
# so an existing remote is never rewritten. yandex-crypt reuses backup-crypt's passphrase (same BACKUP_PASSPHRASE).
# Deletes go to the Yandex trash (rclone default, no hard_delete): some protection if the token is abused; it uses quota.
make_yandex_remotes() {
  [[ -n $YANDEX_DIR ]] || return 0
  if ! rclone listremotes | grep -x 'yandex:' >/dev/null; then
    [[ -z $YANDEX_CLIENT_ID ]] || secret_var YANDEX_CLIENT_SECRET "Yandex OAuth app client secret"
    secret_var YANDEX_TOKEN "Yandex Disk token (the JSON from: rclone authorize \"yandex\" CLIENT_ID CLIENT_SECRET)"
    if [[ $YANDEX_TOKEN =~ ^y[0-9]_[A-Za-z0-9_-]+$ ]]; then
      # a bare OAuth token (no refresh token): rclone needs the JSON form and a refresh_token field, which it never uses
      # before the expiry. Yandex tokens last a year: renew it before then (a failed backup alerts you).
      YANDEX_TOKEN="{\"access_token\":\"$YANDEX_TOKEN\",\"token_type\":\"OAuth\",\"refresh_token\":\"none\",\"expiry\":\"$(date -u -d '+360 days' +%FT%TZ)\"}"
      warn "bare Yandex token: valid about a year, not renewed automatically (expires around $(date -d '+360 days' +%F))"
    fi
    [[ $YANDEX_TOKEN == *access_token* ]] || die "YANDEX_TOKEN does not look like the JSON from rclone authorize \"yandex\" (or a bare y0_... token)"
    rclone_set yandex <<EOF
type=yandex
token=$YANDEX_TOKEN
EOF
    # the token only refreshes through the app that issued it
    [[ -z $YANDEX_CLIENT_ID ]] || rclone_set yandex <<EOF
client_id=$YANDEX_CLIENT_ID
client_secret=$YANDEX_CLIENT_SECRET
EOF
    # mkdir and quota work even where file access is refused (rclone's built-in app gets 410 Gone since October 2026):
    # prove listing and upload. The probe goes to the Yandex trash.
    local err
    if ! err=$(rclone mkdir "yandex:$YANDEX_DIR" 2>&1 && rclone lsf "yandex:$YANDEX_DIR" 2>&1 >/dev/null &&
      echo probe | rclone rcat "yandex:$YANDEX_DIR/.ente-setup-probe" 2>&1 && rclone deletefile "yandex:$YANDEX_DIR/.ente-setup-probe" 2>&1); then
      rclone config delete yandex
      [[ $err != *410* ]] || err="410 Gone: Yandex refuses file access to this OAuth app; create your own app (README) and set YANDEX_CLIENT_ID"
      die "Yandex Disk test failed: $(tail -1 <<<"$err" | cut -c1-200); remote removed, re-run with a working token"
    fi
    log "yandex remote created (list and upload work)"
  fi
  local pw
  pw=$(python3 -c '
import configparser, sys
cp = configparser.RawConfigParser(); cp.read(sys.argv[1]); print(cp.get("backup-crypt", "password"))
' "$(rclone config file | tail -1)") && [[ -n $pw ]] || die "backup-crypt remote has no passphrase; run make_backup_remotes first"
  rclone_set yandex-crypt <<EOF
type=crypt
remote=${YANDEX_ROOT}config
password=$pw
EOF
}

# check_backup_owner [ROOT CRYPT NAME]: refuse to sync over a backup that belongs to another Ente instance
# (a fresh install pointed at an old backup would wipe it). Default: the S3 backup bucket.
check_backup_owner() {
  local root=${1:-$BACKUP_ROOT} crypt=${2:-backup-crypt} name=${3:-the backup bucket} theirs rc=0 listing
  listing=$(rclone lsf "${root}config" 2>/dev/null) || rc=$?
  ((rc == 0 || rc == 3)) || die "cannot list $name (rclone exit $rc); not touching it"
  [[ -n $listing ]] || return 0
  theirs=$(mktemp); chmod 600 "$theirs"
  if ! rclone cat "$crypt:museum.yaml" >"$theirs" 2>/dev/null || [[ ! -s $theirs ]]; then
    rm -f "$theirs"; die "$name already holds a backup that this passphrase cannot read; refusing to overwrite it"
  fi
  if ! python3 - "$ENTE_DIR/museum.yaml" "$theirs" <<'PY'
import sys, yaml
a, b = (yaml.safe_load(open(f))["key"]["encryption"] for f in sys.argv[1:])
sys.exit(a != b)
PY
  then rm -f "$theirs"; die "$name holds the backup of a DIFFERENT Ente instance; refusing to overwrite it (use 'restore' on a fresh server, or an empty bucket)"; fi
  rm -f "$theirs"
}

# Write the backup script (DB dump + config to backup-crypt, photo objects to the bucket, 60-day deleted retention)
# and its systemd service + daily 03:00 timer.
install_backup_units() {
  write_file /etc/ente-backup.env 600 <<EOF
HC_URL="$HC_URL"
BACKUP_ROOT="$BACKUP_ROOT"
PHOTO_BUCKET="$S3_BUCKET"
YANDEX_ROOT="$YANDEX_ROOT"
EOF
  write_file /usr/local/bin/ente-backup.sh 755 <<'EOF'
#!/usr/bin/env bash
# Managed by ente-setup.sh. Config comes from /etc/ente-backup.env via systemd.
set -euo pipefail
umask 077
START=$(date -Is)
OPTS=(--checkers 4 --transfers 4)
cd /opt/my-ente
DUMPS=/var/backups/ente; mkdir -p "$DUMPS"; chmod 700 "$DUMPS"
dump="$DUMPS/ente_db-$(date +%F).dump"
docker compose exec -T postgres pg_dump -U pguser -d ente_db -Fc > "$dump.tmp"
[[ -s "$dump.tmp" ]] || { echo "ERROR: empty database dump" >&2; rm -f "$dump.tmp"; exit 1; }
docker compose exec -T postgres pg_restore -l < "$dump.tmp" > /dev/null || { echo "ERROR: dump unreadable" >&2; rm -f "$dump.tmp"; exit 1; }
mv "$dump.tmp" "$dump"
find "$DUMPS" -name 'ente_db-*.dump' -mtime +6 -delete
cp museum.yaml compose.yaml compose.override.yaml "$DUMPS/"
[[ ! -f image-pins ]] || cp image-pins "$DUMPS/"
# target NAME CRYPT ROOT: config + dumps to CRYPT, photo objects to ROOT/objects, 60-day deleted/ retention.
# A failed target does not stop the next one; the run fails at the end. Success leaves a per-target stamp for `check`:
# the time the run STARTED, so that objects uploaded after it are not expected in the backup.
target() {
  local name=$1 crypt=$2 root=$3 cutoff d
  echo "== $name"
  rclone sync "$DUMPS" "$crypt:" --checkers 4 --max-delete 20 || return 1
  rclone sync "ente-s3:$PHOTO_BUCKET" "${root}objects" --size-only "${OPTS[@]}" \
    --max-delete 500 --backup-dir "${root}deleted/$(date +%F)" || return 1
  cutoff=$(date -d '60 days ago' +%F)
  for d in $(rclone lsf --dirs-only "${root}deleted" 2>/dev/null || true); do
    if [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}/$ && "${d%/}" < "$cutoff" ]]; then rclone purge "${root}deleted/${d%/}" || return 1; fi
  done
  mkdir -p /var/lib/ente-backup; echo "$START" > "/var/lib/ente-backup/last-ok-$name"
}
rc=0
target s3 backup-crypt "$BACKUP_ROOT" || { echo "ERROR: backup to the S3 bucket failed" >&2; rc=1; }
if [[ -n "${YANDEX_ROOT:-}" ]]; then
  target yandex yandex-crypt "$YANDEX_ROOT" || { echo "ERROR: backup to Yandex Disk failed" >&2; rc=1; }
fi
((rc == 0)) || exit 1
# heartbeat (healthchecks.io, Better Stack, ...): only after a fully good run. A failed ping does not fail the backup
# (that would send a false "backup failed"); `check` reports it instead.
if [[ -n "${HC_URL:-}" ]]; then
  if curl -fsS -m 15 --retry 3 --retry-all-errors -o /dev/null "$HC_URL"; then date -Is > /var/lib/ente-backup/hc-ok; rm -f /var/lib/ente-backup/hc-fail
  else echo "WARNING: heartbeat ping to HC_URL failed; the backup itself succeeded" >&2; date -Is > /var/lib/ente-backup/hc-fail; fi
fi
EOF
  write_file /etc/systemd/system/ente-backup.service <<EOF
[Unit]
Description=Ente backup (database dump + photo objects to the backup bucket, and Yandex Disk if set)
After=docker.service network-online.target
Wants=network-online.target
$ALERT_ONFAIL

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
  write_file /etc/systemd/system/ente-verify.service <<EOF
[Unit]
Description=Monthly deep check of the Ente backup (ente-setup.sh verify)
After=docker.service network-online.target
Wants=network-online.target
$ALERT_ONFAIL

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=/bin/bash "$SCRIPT_DIR/ente-setup.sh" verify
EOF
  write_file /etc/systemd/system/ente-verify.timer <<'EOF'
[Unit]
Description=Monthly deep check of the Ente backup

[Timer]
OnCalendar=*-*-01 04:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now ente-backup.timer ente-verify.timer >/dev/null 2>&1
}

# ---------------------------------------------------------------- telegram alerts
# setup_alerts: with TG_CHAT_ID set, install /usr/local/bin/ente-alert (send a message), ente-alert@.service (sends the log of a
# failed unit), and ente-check.timer (daily `check` at 09:00; a FAIL triggers an alert). Sets ALERT_ONFAIL for ente-backup.service.
# The bot token lives only in /etc/ente-alert.env (600) and is passed to curl on stdin, never on a command line.
# Without TG_CHAT_ID the alert units are removed.
ALERT_ONFAIL=
tg_api() { # tg_api METHOD [curl args...]: call the Bot API with TG_BOT_TOKEN
  local m=$1; shift
  curl -fsS -m 20 --retry 3 -o /dev/null -K - "$@" <<<"url = \"https://api.telegram.org/bot$TG_BOT_TOKEN/$m\""
}
setup_alerts() {
  if [[ -z $TG_CHAT_ID ]]; then
    ALERT_ONFAIL=
    if [[ -e /etc/systemd/system/ente-check.timer ]]; then
      systemctl disable --now ente-check.timer >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/ente-check.{timer,service} /etc/systemd/system/ente-alert@.service /etc/ente-alert.env
      systemctl daemon-reload; log "telegram alerts removed (TG_CHAT_ID empty)"
    fi
    return 0
  fi
  if [[ -z $TG_BOT_TOKEN && -f /etc/ente-alert.env ]]; then TG_BOT_TOKEN=$(. /etc/ente-alert.env; echo "$TG_BOT_TOKEN"); fi
  secret_var TG_BOT_TOKEN "Telegram bot token (from @BotFather)"
  [[ $TG_BOT_TOKEN =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "TG_BOT_TOKEN does not look like a bot token (123456:ABC...)"
  tg_api getMe 2>/dev/null || die "Telegram rejected the bot token, or api.telegram.org is unreachable"
  write_file /etc/ente-alert.env 600 <<EOF
TG_BOT_TOKEN='$TG_BOT_TOKEN'
TG_CHAT_ID='$TG_CHAT_ID'
EOF
  write_file /usr/local/bin/ente-alert 755 <<'EOF'
#!/usr/bin/env bash
# Managed by ente-setup.sh. ente-alert TITLE < BODY: send TITLE and the end of BODY (Telegram allows 4096 chars) as one message.
set -euo pipefail
. /etc/ente-alert.env
body=$(tail -c 3500 | iconv -c -f utf-8 -t utf-8 || true)
text="$1"
[[ -z $body ]] || text+=$'\n\n'"$body"
curl -fsS -m 20 --retry 3 -o /dev/null -K - --data-urlencode "chat_id=$TG_CHAT_ID" --data-urlencode "text=$text" \
  <<<"url = \"https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage\""
EOF
  write_file /usr/local/bin/ente-alert-unit 755 <<'EOF'
#!/usr/bin/env bash
# Managed by ente-setup.sh. ente-alert-unit UNIT: send the output of UNIT's last run (FAIL lines for the check) to Telegram.
set -euo pipefail
u=$1 h=$(hostname)
id=$(systemctl show -p InvocationID --value "$u" 2>/dev/null || true)
if [[ -n $id ]]; then out=$(journalctl -q -o cat --no-pager "_SYSTEMD_INVOCATION_ID=$id" || true)
else out=$(journalctl -q -o cat --no-pager -u "$u" -n 40 || true); fi
if [[ $u == ente-check.service || $u == ente-verify.service ]]; then
  n=${u#ente-}; title="⚠️ Ente ${n%.service} found problems on $h"
  out=$(grep -E 'FAIL|ERROR' <<<"$out" || tail -n 30 <<<"$out")
else
  title="❌ $u failed on $h"
  out=$(tail -n 30 <<<"$out")
fi
printf '%s\n' "$out" | /usr/local/bin/ente-alert "$title"
EOF
  write_file /etc/systemd/system/ente-alert@.service <<'EOF'
[Unit]
Description=Telegram alert for a failed %i

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ente-alert-unit %i
EOF
  write_file /etc/systemd/system/ente-check.service <<EOF
[Unit]
Description=Daily Ente health check (ente-setup.sh check), alerts on FAIL
After=docker.service network-online.target
Wants=network-online.target
OnFailure=ente-alert@%n.service

[Service]
Type=oneshot
ExecStart=/bin/bash "$SCRIPT_DIR/ente-setup.sh" check
EOF
  write_file /etc/systemd/system/ente-check.timer <<'EOF'
[Unit]
Description=Daily Ente health check

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now ente-check.timer >/dev/null 2>&1
  ALERT_ONFAIL='OnFailure=ente-alert@%n.service'
  log "telegram alerts on (failed backup, daily check at 09:00); test: $0 alert-test. The check runs $SCRIPT_DIR/ente-setup.sh: keep it there"
}

# alert-test: send a test message through the installed alert path.
cmd_alert_test() {
  load_env
  [[ -n $TG_CHAT_ID && -x /usr/local/bin/ente-alert ]] || die "alerts not set up: set TG_CHAT_ID, then run backup-setup"
  echo "Test from ente-setup on $(hostname) ($DOMAIN). Alerts arrive here when a backup or the daily check fails." |
    /usr/local/bin/ente-alert "🔔 Ente alert test" || die "sending failed: wrong TG_CHAT_ID, or nobody pressed Start in the bot / the bot is not in the group"
  log "test message sent"
}

# backup-setup: rclone remotes, refuse a foreign backup, install the timer and start a first backup.
cmd_backup_setup() {
  load_env
  [[ -f $ENTE_DIR/museum.yaml ]] || die "run install first"
  install_rclone
  make_backup_remotes
  make_photo_remote
  check_backup_owner
  if [[ -n $YANDEX_DIR ]]; then
    make_yandex_remotes
    check_backup_owner "$YANDEX_ROOT" yandex-crypt "Yandex Disk folder $YANDEX_DIR"
  fi
  setup_alerts
  install_backup_units
  systemctl start --no-block ente-backup.service
  log "backup configured; first run started: journalctl -fu ente-backup.service"
}

# ---------------------------------------------------------------- restore
# Fresh server (after bootstrap), same DOMAIN: config + database come from the backup bucket (RESTORE_FROM=s3, default)
# or Yandex Disk (RESTORE_FROM=yandex); photos stay in the photo bucket, objects missing there are copied back from the backup.
cmd_restore() {
  load_env
  local tmp dump t0=$SECONDS src_crypt=backup-crypt src_root
  if [[ -e $ENTE_DIR/.restore-incomplete ]]; then
    log "previous restore did not finish; cleaning up and starting over"
    dc down -v >/dev/null 2>&1 || true
    rm -rf "$ENTE_DIR"
  fi
  [[ ! -e $ENTE_DIR ]] || die "$ENTE_DIR already exists; restore is for a fresh server"
  apt_get update; apt_install curl ca-certificates python3-yaml gnupg
  install_docker; install_caddy; install_rclone
  rclone listremotes | grep -x 'backup-crypt:' >/dev/null && rclone config delete backup-crypt
  make_backup_remotes once
  make_yandex_remotes
  src_root=$BACKUP_ROOT
  if [[ $RESTORE_FROM == yandex ]]; then src_crypt=yandex-crypt; src_root=$YANDEX_ROOT; fi
  log "restoring from $RESTORE_FROM ($src_root)"
  tmp=$(mktemp -d /root/ente-restore.XXXXXX)
  # shellcheck disable=SC2064 # expand now: $tmp is local to this function
  trap "rm -rf '$tmp'" EXIT
  log "fetching config backup"
  rclone copy "$src_crypt:" "$tmp" --checkers 4
  dump=$(find "$tmp" -maxdepth 1 -name 'ente_db-*.dump' | sort | tail -1)
  [[ -n $dump && -f $tmp/compose.yaml && -f $tmp/museum.yaml ]] || die "backup incomplete (wrong passphrase?): need ente_db-*.dump, compose.yaml, museum.yaml"
  install -d -m 700 "$ENTE_DIR"; touch "$ENTE_DIR/.restore-incomplete"
  install -m 600 "$tmp/compose.yaml" "$ENTE_DIR/compose.yaml"
  install -m 644 "$tmp/museum.yaml" "$ENTE_DIR/museum.yaml"
  [[ ! -f $tmp/image-pins ]] || install -m 600 "$tmp/image-pins" "$PINS" # the builds that made the dump
  configure_host
  make_photo_remote
  log "starting postgres"
  dc up -d --wait postgres
  log "restoring database $(basename "$dump")"
  dc cp "$dump" postgres:/tmp/restore.dump
  dc exec -T postgres pg_restore -U pguser -d ente_db --clean --if-exists /tmp/restore.dump || die "pg_restore failed"
  dc exec -T postgres rm -f /tmp/restore.dump
  log "copying objects missing from the photo bucket back from the backup (never deletes; can take long on a new bucket)"
  rclone copy "${src_root}objects" "ente-s3:$S3_BUCKET" --size-only --checkers 4 --transfers 4
  dc up -d
  wait_healthy museum
  url_ok http://127.0.0.1:8080/ping 10 || die "museum /ping failed locally"
  rm -f "$ENTE_DIR/.restore-incomplete"
  log "restore finished in $((SECONDS - t0))s"
  cat <<EOF

Restored. Next:
  1. DNS: point A/AAAA of api., web., albums.$DOMAIN to $(host_ip) (TTL 300). Certificates are issued once DNS resolves.
  2. $0 backup-setup   (installs the timer; remotes already exist)
  3. $0 check
EOF
}

# new_uploads NAME: prints a temp file of rclone exclude rules naming the photo objects uploaded since the last good backup to
# NAME (s3|yandex) started. They are not in that backup yet, and that is not an error. The caller passes it as --exclude-from
# and removes it. One listing, no request per object. (An age filter instead would also hide freshly copied backup objects.)
new_uploads() {
  local s f; f=$(mktemp)
  if s=$(cat "/var/lib/ente-backup/last-ok-$1" 2>/dev/null); then
    rclone lsf -R --files-only --use-server-modtime --max-age "$(($(date +%s) - $(date -d "$s" +%s) + 60))s" "ente-s3:$S3_BUCKET" 2>/dev/null |
      sed 's/[][*?{}\\]/\\&/g; s|^|/|' >"$f" || true
  fi
  echo "$f"
}
# rc_err OUTPUT: the error lines of an rclone run, without timestamps, on one line.
rc_err() { grep -E 'ERROR|Failed to' <<<"$1" | sed -E 's|^[0-9/]+ [0-9:]+ ||' | head -3 | tr '\n' ' ' || true; }

# ---------------------------------------------------------------- check
# check: read-only health report (containers, ports, ssh/firewall/TLS, bucket + CORS, backup freshness, system); exit 1 on any FAIL.
cmd_check() {
  load_env
  local s cid st pol p addrs ts res out ex
  echo "== containers"
  for s in museum web postgres; do
    cid=$(dc ps -q "$s" 2>/dev/null || true)
    if [[ -z $cid ]]; then bad "$s not running"; continue; fi
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")
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
  echo "== backup"
  if systemctl is-enabled --quiet ente-backup.timer 2>/dev/null; then ok "timer enabled, next: $(systemctl show ente-backup.timer -p NextElapseUSecRealtime --value)"; else bad "ente-backup.timer not enabled"; fi
  ts=$(systemctl show ente-backup.service -p ExecMainExitTimestamp --value 2>/dev/null || true)
  res=$(systemctl show ente-backup.service -p Result --value 2>/dev/null || true)
  if [[ -z $ts ]]; then # systemd forgets the result at a reboot: fall back to the stamp the last good run left
    s=$(cat /var/lib/ente-backup/last-ok-s3 2>/dev/null || true)
    if [[ -z $s ]]; then warn "backup has not run yet"
    elif (($(date +%s) - $(date -d "$s" +%s) > 36 * 3600)); then bad "last good backup is older than 36 h ($s)"
    else ok "last good backup $s (no run since boot)"; fi
  elif [[ $res != success ]]; then bad "last backup run $ts: $res (journalctl -u ente-backup.service)"
    s=$(cat /var/lib/ente-backup/last-ok-s3 2>/dev/null || true)
    if [[ -n $s ]] && (($(date +%s) - $(date -d "$s" +%s) <= 36 * 3600)); then ok "S3 part of the backup succeeded $s"; fi
  elif (($(date +%s) - $(date -d "$ts" +%s) > 36 * 3600)); then bad "last backup is older than 36 h ($ts)"
  else ok "last backup finished $ts: $res"; fi
  ex=$(new_uploads s3)
  if out=$(rclone check "ente-s3:$S3_BUCKET" "${BACKUP_ROOT}objects" --one-way --size-only --checkers 4 --exclude-from "$ex" 2>&1); then ok "rclone check: photo bucket is in the backup"
  else bad "rclone check failed: $(echo "$out" | tail -3 | tr '\n' ' ')"; fi
  rm -f "$ex"
  s=$(cat /var/lib/ente-backup/verify-ok 2>/dev/null || true)
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
    s=$(cat /var/lib/ente-backup/hc-fail 2>/dev/null || true)
    if [[ -n $s ]]; then bad "heartbeat ping (HC_URL) failed after the backup of $s"
    elif s=$(cat /var/lib/ente-backup/hc-ok 2>/dev/null); then ok "heartbeat pinged $s (outside monitor)"
    else warn "heartbeat (HC_URL) not pinged yet: it is pinged after the next good backup"; fi
  fi
  if [[ -n $YANDEX_DIR ]]; then
    echo "== yandex disk"
    if out=$(rclone lsf "$YANDEX_ROOT" --max-depth 1 2>&1 >/dev/null); then ok "Yandex Disk folder $YANDEX_DIR reachable"; else bad "Yandex Disk: $out"; fi
    ts=$(cat /var/lib/ente-backup/last-ok-yandex 2>/dev/null || true)
    if [[ -z $ts ]]; then bad "no successful backup to Yandex Disk yet"
    elif (($(date +%s) - $(date -d "$ts" +%s) > 36 * 3600)); then bad "last good Yandex Disk backup is older than 36 h ($ts)"
    else ok "last good Yandex Disk backup $ts"; fi
    ex=$(new_uploads yandex)
    if out=$(rclone check "ente-s3:$S3_BUCKET" "${YANDEX_ROOT}objects" --one-way --size-only --checkers 4 --exclude-from "$ex" 2>&1); then ok "rclone check: photo bucket is on Yandex Disk"
    else bad "rclone check (Yandex) failed: $(echo "$out" | tail -3 | tr '\n' ' ')"; fi
    rm -f "$ex"
    out=$(rclone about yandex: 2>/dev/null | tr -s ' ' | tr '\n' ' ' || true)
    [[ -z $out ]] || warn "Yandex Disk quota: $out(the trash counts too; empty it now and then)"
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
# database. The Yandex Disk copy is not verified here (the daily check compares it by size).
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
    ok "photo bucket is in the backup with the same checksums (${n:-0 matching files}; $(wc -l <"$ex") uploaded around or after the last backup, not compared)"
    n=$(grep -oE '[0-9]+ hashes could not be checked' <<<"$out" | tail -1 || true)
    [[ -z $n ]] || warn "$n (no common checksum; compared by size)"
  else bad "photo objects differ from the backup: $(rc_err "$out")"; fi
  rm -f "$ex"

  echo "== config backup (decrypted, byte for byte)"
  if out=$(rclone check /var/backups/ente backup-crypt: --download --checkers 4 2>&1); then
    ok "config backup decrypts with the stored passphrase and equals the local copies ($(grep -oE '[0-9]+ matching files' <<<"$out" | tail -1))"
  else bad "config backup differs or cannot be decrypted: $(rc_err "$out")"; fi

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
    if python3 - "$ENTE_DIR/museum.yaml" "$VERIFY_TMP/museum.yaml" <<'PY' 2>/dev/null
import sys, yaml
a, b = (yaml.safe_load(open(f)) for f in sys.argv[1:])
sys.exit(not (a["key"] == b["key"] and a["jwt"] == b["jwt"]))
PY
    then ok "museum.yaml in the backup holds the live encryption keys"
    else bad "museum.yaml in the backup is missing or its keys differ from the live ones"; fi
  fi
  verify_cleanup; trap - EXIT
  [[ -z $YANDEX_DIR ]] || warn "the Yandex Disk copy is not verified here (check compares it by size)"
  echo
  if ((FAILS)); then echo "$FAILS verify check(s) FAILED"; return 1; fi
  mkdir -p /var/lib/ente-backup; date -Is >/var/lib/ente-backup/verify-ok
  echo "backup verified"
}

# ---------------------------------------------------------------- speedtest
# speedtest: for 30 minutes serve a download/upload test under https://api.$DOMAIN/speedtest-<random token>/ to measure the
# connection between a device and this server (the photos themselves travel device <-> bucket, not through here).
# A small local server streams random data and swallows uploads; Caddy gets the route through its admin API, so the
# Caddyfile is untouched and the route is gone when the test ends (or at the next Caddy reload). Client: s3-speedtest docs.
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
  curl -fsS -m 5 -o /dev/null -X DELETE http://localhost:2019/id/ente-speedtest 2>/dev/null || true
  [[ -z $(ss -Htln "sport = :$port") ]] || die "port $port is in use"
  tok=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
  systemd-run --quiet --unit ente-speedtest --description "Ente speed test endpoint (temporary)" -p DynamicUser=yes -p RuntimeMaxSec=1800 \
    -p ExecStopPost="/usr/bin/curl -fsS -m 5 -o /dev/null -X DELETE http://localhost:2019/id/ente-speedtest" \
    /usr/local/bin/ente-speedtest "$port"
  # first in the route list: the Caddyfile's host routes are terminal
  curl -fsS -m 5 -o /dev/null -X PUT -H 'Content-Type: application/json' http://localhost:2019/config/apps/http/servers/srv0/routes/0 -d @- <<EOF ||
{"@id": "ente-speedtest", "terminal": true,
 "match": [{"host": ["api.$DOMAIN"], "path": ["/speedtest-$tok/*"]}],
 "handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": "127.0.0.1:$port"}], "flush_interval": -1}]}
EOF
    { systemctl stop ente-speedtest.service; die "could not add the route to Caddy (admin API on localhost:2019)"; }
  url=https://api.$DOMAIN/speedtest-$tok
  url_ok "$url/down/1" 5 || { systemctl stop ente-speedtest.service; die "the test endpoint does not answer"; }
  cat <<EOF

Speed test endpoint is up for 30 minutes (stop earlier: systemctl stop ente-speedtest):
  $url

Windows:      .\\vps-speedtest.ps1 -Url $url
Linux/macOS:  curl -o /dev/null -w 'download: %{speed_download} bytes/s\\n' $url/down/100
              head -c 100000000 /dev/urandom > /tmp/up.bin && curl -o /dev/null -T /tmp/up.bin -w 'upload: %{speed_upload} bytes/s\\n' $url/up
EOF
}

# ---------------------------------------------------------------- deploy / main
# ---------------------------------------------------------------- vpn (AmneziaWG 3.1, independent of Ente)
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
  python3 - "$1" "$AWG_PORT" "$AWG_CONF" "$AWG_CLIENT" "$AWG_NAT" <<'PY'
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

# vpn: AmneziaWG on UDP AWG_PORT with one shared client (one device at a time). Re-runnable; keeps the keys, follows a changed AWG_PORT.
cmd_vpn() {
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

# bootstrap + (install | restore) + backup-setup in one go, from the config and secrets given.
cmd_deploy() {
  need ADMIN_USER ADMIN_SSH_PUBKEY
  secret_var S3_ACCESS_KEY "S3 access key ID (photo bucket)"
  secret_var S3_SECRET_KEY "S3 secret access key (photo bucket)"
  secret_var BACKUP_S3_ACCESS_KEY "Backup bucket access key ID"
  secret_var BACKUP_S3_SECRET_KEY "Backup bucket secret access key"
  secret_var BACKUP_PASSPHRASE "Backup passphrase (keep it in your password manager; losing it loses the config backups)" "$([[ $RESTORE == yes ]] && echo once || echo confirm)"
  if [[ -n $YANDEX_DIR ]] && ! { command -v rclone >/dev/null && rclone listremotes | grep -x 'yandex:' >/dev/null; }; then
    [[ -z $YANDEX_CLIENT_ID ]] || secret_var YANDEX_CLIENT_SECRET "Yandex OAuth app client secret"
    secret_var YANDEX_TOKEN "Yandex Disk token (the JSON from: rclone authorize \"yandex\" CLIENT_ID CLIENT_SECRET)"
  fi
  if [[ -n $TG_CHAT_ID && ! -f /etc/ente-alert.env ]]; then secret_var TG_BOT_TOKEN "Telegram bot token (from @BotFather)"; fi
  cmd_bootstrap
  if [[ $RESTORE == yes ]]; then cmd_restore; else cmd_install; fi
  cmd_backup_setup
  log "deploy finished. Next: sign up the owner, then '$0 lockdown'."
}

# usage: print the command list and exit 2. main CMD: dispatch to the cmd_* function.
usage() { echo "usage: $0 {deploy|bootstrap|install|codes|lockdown|backup-setup|restore|check|verify|update|alert-test|speedtest|vpn}" >&2; exit 2; }

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
    verify) cmd_verify ;;
    update) cmd_update ;;
    alert-test) cmd_alert_test ;;
    speedtest) cmd_speedtest ;;
    vpn) cmd_vpn ;;
    *) usage ;;
  esac
}

[[ $# -eq 1 ]] || usage
[[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $1)" >&2; exit 1; }
touch "$LOG"; chmod 600 "$LOG"
main "$1" 2>&1 | tee -a "$LOG"
