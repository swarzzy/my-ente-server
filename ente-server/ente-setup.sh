#!/usr/bin/env bash
# ente-setup.sh - turn a fresh Debian 12/13 VPS into a backed-up Ente Photos server.
# Photos live in an external S3 bucket (no local storage needed); a second S3 bucket holds the backup.
# Usage: ente-setup.sh <deploy|bootstrap|install|codes|lockdown|backup-setup|restore|check|update>
# Config:  ente-setup.env next to this script (or ENV_FILE=/path). See ente-setup.env.example.
# Secrets: prompted, or from the environment / ente-setup.secrets (mode 600). See ente-setup.secrets.example.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE=${ENV_FILE:-$SCRIPT_DIR/ente-setup.env}
SECRETS_FILE=${SECRETS_FILE:-$SCRIPT_DIR/ente-setup.secrets}
LOG=/var/log/ente-setup.log
ENTE_DIR=/opt/my-ente
QUICKSTART_URL=https://raw.githubusercontent.com/ente/ente/main/server/quickstart.sh
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
# fresh images run unattended-upgrades at first boot and hold the dpkg lock: wait for it
apt_get() { DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -q "$@"; }
apt_install() { apt_get install -y --no-install-recommends "$@"; }
ensure_line() { grep -qxF -- "$2" "$1" 2>/dev/null || echo "$2" >>"$1"; }
version_ge() { [[ $(printf '%s\n%s\n' "$2" "${1#v}" | sort -V | head -1) == "$2" ]]; }
host_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'; }
need() { local v; for v in "$@"; do [[ -n ${!v} ]] || die "$v is not set in $ENV_FILE"; done; }
url_ok() { local i; for i in $(seq 1 "${2:-20}"); do curl -fsS -m 5 "$1" >/dev/null 2>&1 && return 0; sleep 3; done; return 1; }
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

load_env() {
  [[ -f $ENV_FILE ]] || die "config $ENV_FILE not found (copy ente-setup.env.example)"
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  if [[ -f $SECRETS_FILE ]]; then
    [[ $(stat -c %a "$SECRETS_FILE") =~ ^[46]00$ ]] || die "$SECRETS_FILE must be mode 600"
    # shellcheck source=/dev/null
    . "$SECRETS_FILE"
  fi
  DOMAIN=${DOMAIN:-}; ADMIN_USER=${ADMIN_USER:-}; ADMIN_SSH_PUBKEY=${ADMIN_SSH_PUBKEY:-}; FAIL2BAN=${FAIL2BAN:-yes}
  HC_URL=${HC_URL:-}; RESTORE=${RESTORE:-no}
  S3_PROVIDER=${S3_PROVIDER:-Other}; S3_ENDPOINT=${S3_ENDPOINT:-}; S3_REGION=${S3_REGION:-}; S3_BUCKET=${S3_BUCKET:-}
  S3_CORS_ORIGINS=${S3_CORS_ORIGINS:-https://web.$DOMAIN,https://albums.$DOMAIN}
  BACKUP_S3_PROVIDER=${BACKUP_S3_PROVIDER:-Other}; BACKUP_S3_ENDPOINT=${BACKUP_S3_ENDPOINT:-}
  BACKUP_S3_REGION=${BACKUP_S3_REGION:-}; BACKUP_S3_BUCKET=${BACKUP_S3_BUCKET:-}
  S3_ACCESS_KEY=${S3_ACCESS_KEY:-}; S3_SECRET_KEY=${S3_SECRET_KEY:-}
  BACKUP_S3_ACCESS_KEY=${BACKUP_S3_ACCESS_KEY:-}; BACKUP_S3_SECRET_KEY=${BACKUP_S3_SECRET_KEY:-}; BACKUP_PASSPHRASE=${BACKUP_PASSPHRASE:-}
  need DOMAIN S3_ENDPOINT S3_REGION S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_BUCKET
  [[ $DOMAIN =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z0-9-]+$ && $DOMAIN != *example.com ]] || die "DOMAIN missing, invalid or a placeholder"
  [[ $S3_ENDPOINT != *://* && $BACKUP_S3_ENDPOINT != *://* ]] || die "S3 endpoints must be bare hostnames, without https://"
  [[ $S3_ENDPOINT/$S3_BUCKET != "$BACKUP_S3_ENDPOINT/$BACKUP_S3_BUCKET" ]] || die "backup bucket must differ from the photo bucket"
  BACKUP_ROOT=backup:$BACKUP_S3_BUCKET/
}

# ---------------------------------------------------------------- bootstrap
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

cmd_bootstrap() {
  load_env; need ADMIN_USER ADMIN_SSH_PUBKEY
  [[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]*$ && $ADMIN_USER != root ]] || die "ADMIN_USER invalid"
  [[ $ADMIN_SSH_PUBKEY =~ ^(ssh-(ed25519|rsa)|ecdsa-) ]] || die "ADMIN_SSH_PUBKEY does not look like a public key"
  log "updating packages"
  apt_get update
  apt_get -y -o Dpkg::Options::=--force-confold upgrade
  apt_install sudo ufw curl ca-certificates gnupg unattended-upgrades python3-yaml unzip openssh-server
  setup_ssh
  local sshport
  sshport=$(sshd -T | awk '$1 == "port" {print $2; exit}')
  ufw allow "${sshport:-22}/tcp" >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
  write_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  write_file /etc/apt/apt.conf.d/52ente-unattended <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
EOF
  if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
    if [[ ! -f /swapfile ]]; then fallocate -l 2G /swapfile; chmod 600 /swapfile; mkswap /swapfile >/dev/null; fi
    swapon /swapfile
  fi
  ensure_line /etc/fstab '/swapfile none swap sw 0 0'
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
  apt_get update
  apt_install caddy
}

install_rclone() {
  command -v rclone >/dev/null && return 0
  apt_install unzip curl ca-certificates
  curl -fsSL https://rclone.org/install.sh | bash >/dev/null
}

run_quickstart() {
  [[ -d $ENTE_DIR ]] && { log "$ENTE_DIR exists, skipping quickstart"; return 0; }
  log "running Ente quickstart (answering n)"
  (cd /opt && printf 'n\n' | sh -c "$(curl -fsSL "$QUICKSTART_URL")") >/dev/null || die "quickstart failed"
  [[ -f $ENTE_DIR/compose.yaml && -f $ENTE_DIR/museum.yaml ]] || die "quickstart did not create compose.yaml/museum.yaml"
}

# Edit the quickstart output and assert every edit; fail loudly if its format changed. Idempotent.
apply_edits() {
  local c=$ENTE_DIR/compose.yaml m=$ENTE_DIR/museum.yaml p
  chmod 700 "$ENTE_DIR"
  secret_var S3_ACCESS_KEY "S3 access key ID (photo bucket)"
  secret_var S3_SECRET_KEY "S3 secret access key (photo bucket)"
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
  sed -Ei "s|^( *public-albums:).*|\1 https://albums.$DOMAIN|" "$m"
  grep -Fq "public-albums: https://albums.$DOMAIN" "$m" || die "museum.yaml: public-albums edit failed"
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

configure_host() {
  apply_edits
  s3_prepare
  sync_internal
  write_file /etc/caddy/Caddyfile <<EOF
api.$DOMAIN {
	reverse_proxy 127.0.0.1:8080
}
web.$DOMAIN {
	reverse_proxy 127.0.0.1:3000
}
albums.$DOMAIN {
	reverse_proxy 127.0.0.1:3002
}
EOF
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || die "Caddyfile invalid"
  systemctl enable caddy >/dev/null 2>&1
  systemctl reload-or-restart caddy # graceful and cheap when nothing changed
  # minio and socat only serve the quickstart's local storage; the photos are in the external bucket
  write_file "$ENTE_DIR/compose.override.yaml" 600 <<'EOF'
services:
  museum:
    restart: unless-stopped
    oom_score_adj: -300
  web:
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
  if ! rclone listremotes | grep -qx 'backup:'; then
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
  if rclone listremotes | grep -qx 'backup-crypt:'; then
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

# Refuse to sync over a backup that belongs to another Ente instance (a fresh install pointed at an old backup would wipe it).
check_backup_owner() {
  local theirs
  [[ -n $(rclone lsf "${BACKUP_ROOT}config" 2>/dev/null | head -1 || true) ]] || return 0
  theirs=$(mktemp); chmod 600 "$theirs"
  if ! rclone cat backup-crypt:museum.yaml >"$theirs" 2>/dev/null || [[ ! -s $theirs ]]; then
    rm -f "$theirs"; die "the backup bucket already holds a backup that this passphrase cannot read; refusing to overwrite it"
  fi
  if ! python3 - "$ENTE_DIR/museum.yaml" "$theirs" <<'PY'
import sys, yaml
a, b = (yaml.safe_load(open(f))["key"]["encryption"] for f in sys.argv[1:])
sys.exit(a != b)
PY
  then rm -f "$theirs"; die "the backup bucket holds the backup of a DIFFERENT Ente instance; refusing to overwrite it (use 'restore' on a fresh server, or an empty bucket)"; fi
  rm -f "$theirs"
}

install_backup_units() {
  write_file /etc/ente-backup.env 600 <<EOF
HC_URL="$HC_URL"
BACKUP_ROOT="$BACKUP_ROOT"
PHOTO_BUCKET="$S3_BUCKET"
EOF
  write_file /usr/local/bin/ente-backup.sh 755 <<'EOF'
#!/usr/bin/env bash
# Managed by ente-setup.sh. Config comes from /etc/ente-backup.env via systemd.
set -euo pipefail
umask 077
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
rclone sync "$DUMPS" backup-crypt: --checkers 4
rclone sync "ente-s3:$PHOTO_BUCKET" "${BACKUP_ROOT}objects" --size-only "${OPTS[@]}" \
  --max-delete 500 --backup-dir "${BACKUP_ROOT}deleted/$(date +%F)"
cutoff=$(date -d '60 days ago' +%F)
for d in $(rclone lsf --dirs-only "${BACKUP_ROOT}deleted" 2>/dev/null || true); do
  if [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}/$ && "${d%/}" < "$cutoff" ]]; then rclone purge "${BACKUP_ROOT}deleted/${d%/}"; fi
done
if [[ -n "${HC_URL:-}" ]]; then curl -fsS -m 10 --retry 3 "$HC_URL" > /dev/null; fi
EOF
  write_file /etc/systemd/system/ente-backup.service <<'EOF'
[Unit]
Description=Ente backup (database dump + photo objects to the backup bucket)
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
  load_env
  [[ -f $ENTE_DIR/museum.yaml ]] || die "run install first"
  install_rclone
  make_backup_remotes
  make_photo_remote
  check_backup_owner
  install_backup_units
  systemctl start --no-block ente-backup.service
  log "backup configured; first run started: journalctl -fu ente-backup.service"
}

# ---------------------------------------------------------------- restore
# Fresh server (after bootstrap), same DOMAIN: config + database come from the backup bucket,
# photos stay in the photo bucket (copied back from the backup only if that bucket is empty).
cmd_restore() {
  load_env
  local tmp dump t0=$SECONDS
  [[ ! -e $ENTE_DIR ]] || die "$ENTE_DIR already exists; restore is for a fresh server"
  apt_get update; apt_install curl ca-certificates python3-yaml gnupg
  install_docker; install_caddy; install_rclone
  rclone listremotes | grep -qx 'backup-crypt:' && rclone config delete backup-crypt
  make_backup_remotes once
  tmp=$(mktemp -d /root/ente-restore.XXXXXX)
  # shellcheck disable=SC2064 # expand now: $tmp is local to this function
  trap "rm -rf '$tmp'" EXIT
  log "fetching config backup"
  rclone copy backup-crypt: "$tmp" --checkers 4
  dump=$(find "$tmp" -maxdepth 1 -name 'ente_db-*.dump' | sort | tail -1)
  [[ -n $dump && -f $tmp/compose.yaml && -f $tmp/museum.yaml ]] || die "backup incomplete (wrong passphrase?): need ente_db-*.dump, compose.yaml, museum.yaml"
  install -d -m 700 "$ENTE_DIR"
  install -m 600 "$tmp/compose.yaml" "$ENTE_DIR/compose.yaml"
  install -m 644 "$tmp/museum.yaml" "$ENTE_DIR/museum.yaml"
  configure_host
  make_photo_remote
  log "starting postgres"
  dc up -d --wait postgres
  log "restoring database $(basename "$dump")"
  dc cp "$dump" postgres:/tmp/restore.dump
  dc exec -T postgres pg_restore -U pguser -d ente_db --clean --if-exists /tmp/restore.dump || die "pg_restore failed"
  dc exec -T postgres rm -f /tmp/restore.dump
  if [[ -n $(rclone lsf "ente-s3:$S3_BUCKET" --max-depth 1 2>/dev/null | head -1 || true) ]]; then
    log "photo bucket $S3_BUCKET already holds objects; keeping them (not copying from the backup)"
  else
    log "photo bucket is empty: copying objects back from the backup (this can take long)"
    rclone copy "${BACKUP_ROOT}objects" "ente-s3:$S3_BUCKET" --checkers 4 --transfers 4
  fi
  dc up -d
  wait_healthy museum
  url_ok http://127.0.0.1:8080/ping 10 || die "museum /ping failed locally"
  log "restore finished in $((SECONDS - t0))s"
  cat <<EOF

Restored. Next:
  1. DNS: point A/AAAA of api., web., albums.$DOMAIN to $(host_ip) (TTL 300). Certificates are issued once DNS resolves.
  2. $0 backup-setup   (installs the timer; remotes already exist)
  3. $0 check
EOF
}

# ---------------------------------------------------------------- check
cmd_check() {
  load_env
  local s cid st pol p addrs ts res out
  echo "== containers"
  for s in museum web postgres; do
    cid=$(dc ps -q "$s" 2>/dev/null || true)
    if [[ -z $cid ]]; then bad "$s not running"; continue; fi
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")
    pol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid")
    if [[ $st == healthy || $st == running ]]; then ok "$s $st"; else bad "$s $st"; fi
    if [[ $pol == unless-stopped ]]; then ok "$s restart=$pol"; else bad "$s restart=$pol"; fi
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
  if ufw status | grep -q '^Status: active'; then ok "ufw active"; else bad "ufw inactive"; fi
  if systemctl is-active --quiet caddy; then ok "caddy active"; else bad "caddy not active"; fi
  if curl -fsS -m 10 "https://api.$DOMAIN/ping" >/dev/null 2>&1; then ok "https://api.$DOMAIN/ping"; else bad "https://api.$DOMAIN/ping"; fi
  echo "== photo bucket"
  if out=$(rclone lsf "ente-s3:$S3_BUCKET" --max-depth 1 2>&1 >/dev/null); then ok "bucket $S3_BUCKET reachable"; else bad "bucket $S3_BUCKET: $out"; fi
  out=$(curl -sS -m 10 -o /dev/null -D - -X OPTIONS -H "Origin: https://web.$DOMAIN" -H "Access-Control-Request-Method: PUT" \
    "https://$S3_ENDPOINT/$S3_BUCKET/ente-check" 2>&1 || true)
  if grep -qi '^access-control-allow-origin:' <<<"$out"; then ok "CORS preflight from https://web.$DOMAIN allowed"; else bad "CORS preflight from https://web.$DOMAIN not allowed (web uploads will fail)"; fi
  echo "== backup"
  if systemctl is-enabled --quiet ente-backup.timer 2>/dev/null; then ok "timer enabled, next: $(systemctl show ente-backup.timer -p NextElapseUSecRealtime --value)"; else bad "ente-backup.timer not enabled"; fi
  ts=$(systemctl show ente-backup.service -p ExecMainExitTimestamp --value 2>/dev/null || true)
  res=$(systemctl show ente-backup.service -p Result --value 2>/dev/null || true)
  if [[ -z $ts ]]; then warn "backup has not run yet"
  elif [[ $res == success ]]; then ok "last backup finished $ts: $res"; else bad "last backup $ts: $res"; fi
  if out=$(rclone check "ente-s3:$S3_BUCKET" "${BACKUP_ROOT}objects" --one-way --size-only --checkers 4 2>&1); then ok "rclone check: photo bucket is in the backup"
  else bad "rclone check failed: $(echo "$out" | tail -3 | tr '\n' ' ')"; fi
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

# ---------------------------------------------------------------- deploy / main
# bootstrap + (install | restore) + backup-setup in one go, from the config and secrets given.
cmd_deploy() {
  cmd_bootstrap
  if [[ $RESTORE == yes ]]; then cmd_restore; else cmd_install; fi
  cmd_backup_setup
  log "deploy finished. Next: sign up the owner, then '$0 lockdown'."
}

usage() { echo "usage: $0 {deploy|bootstrap|install|codes|lockdown|backup-setup|restore|check|update}" >&2; exit 2; }

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
    *) usage ;;
  esac
}

[[ $# -eq 1 ]] || usage
[[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $1)" >&2; exit 1; }
touch "$LOG"; chmod 600 "$LOG"
main "$1" 2>&1 | tee -a "$LOG"
