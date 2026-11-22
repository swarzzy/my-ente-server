#!/usr/bin/env bash
# ente-setup.sh - turn a fresh Debian 12/13 VPS into a backed-up Ente Photos server.
# Photos live in an external S3 bucket (no local storage needed); a second S3 bucket holds the backup.
# Usage: ente-setup.sh <command> (see COMMANDS below)
# Config:  ente-setup.env next to this script (or ENV_FILE=/path). See ente-setup.env.example.
# Secrets: ente-setup.secrets next to it (or SECRETS_FILE=/path, or the environment). See ente-setup.secrets.example.
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
DUMP_DIR=/var/backups/ente # local DB dumps, synced to the config backup (the backup script hardcodes it)
BACKUP_ENV_FILE=/etc/ente-backup.env # the backup's config (where to, which photo bucket), written by backup-setup
BACKUP_STATE=/var/lib/ente-backup # stamps the backup script leaves; ente-ops.sh check/verify read them (tests point this elsewhere)
PHOTO_CFG_DIR=ente-backup-config # inside the photo bucket: the encrypted config copy (see make_photo_crypt)
CADDY_DIR=${CADDY_DIR:-/etc/caddy}
CADDYFILE=$CADDY_DIR/Caddyfile
# hooks for add-ons such as ente-s3-proxy.sh: the API's upstream (one reverse_proxy directive) and extra site blocks
CADDY_API_UPSTREAM=$CADDY_DIR/ente.d/api-upstream.caddy
CADDY_SITES=$CADDY_DIR/ente.d/sites
# Caddy's admin API on a socket only caddy and root can use (the default, localhost:2019, is open to every local user)
CADDY_ADMIN_SOCK=/run/caddy/admin.sock
QUICKSTART_URL=https://raw.githubusercontent.com/ente/ente/main/server/quickstart.sh
INT_BEGIN='# BEGIN ente-setup internal'
INT_END='# END ente-setup internal'
# the backup service uses this path; do not depend on sudo's HOME
export RCLONE_CONFIG=/root/.config/rclone/rclone.conf
FAILS=0
MUSEUM_CFG_CHANGED=0
CMD=

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
# url_ok URL [TRIES]: true once URL answers 2xx; gives up after about TRIES x 3 s (default 20). Polls every half second, so a
# service that comes up a moment later costs a moment, not a whole step.
url_ok() { local i; for ((i = 0; i < ${2:-20} * 6; i++)); do curl -fsS -m 5 "$1" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
# yaml_ok FILE: die unless FILE parses as YAML.
yaml_ok() { python3 -I -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$1" || die "$1 is not valid YAML"; }

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

# overwrite_in_place NEW FILE: put NEW's content into FILE without replacing the file itself (a bind mount keeps pointing at
# it), then remove NEW. If the write fails (disk full), die and keep NEW: the content is never lost.
overwrite_in_place() {
  { cat "$1" >"$2" && cmp -s "$1" "$2"; } || die "could not write $2 (disk full?): its new content is in $1"
  rm -f "$1"
}

# need_secret VAR...: die unless every named secret is set (secrets file or environment). Secrets are never logged.
need_secret() { local v; for v in "$@"; do [[ -n ${!v:-} ]] || die "$v is not set: put it in $SECRETS_FILE"; done; }

# Source the config and secrets files, apply defaults, validate.
load_env() {
  [[ -f $ENV_FILE ]] || die "config $ENV_FILE not found (copy ente-setup.env.example)"
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  if [[ -f $SECRETS_FILE ]]; then
    chmod 600 "$SECRETS_FILE" 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$SECRETS_FILE"
  fi
  DOMAIN=${DOMAIN:-}; ADMIN_USER=${ADMIN_USER:-}; ADMIN_SSH_PUBKEY=${ADMIN_SSH_PUBKEY:-}; FAIL2BAN=${FAIL2BAN:-yes}
  SSH_PORT=${SSH_PORT:-22}; HC_URL=${HC_URL:-}; RESTORE=${RESTORE:-no}; CSP_REPORT_ONLY=${CSP_REPORT_ONLY:-no}
  S3_PROVIDER=${S3_PROVIDER:-Other}; S3_ENDPOINT=${S3_ENDPOINT:-}; S3_REGION=${S3_REGION:-}; S3_BUCKET=${S3_BUCKET:-}
  WEB_APPS=${WEB_APPS:-}; web_apps_ok
  S3_CORS_ORIGINS=${S3_CORS_ORIGINS:-$(web_hosts | sed "s|^|https://|; s|\$|.$DOMAIN|" | paste -sd,)}
  BACKUP_S3_PROVIDER=${BACKUP_S3_PROVIDER:-Other}; BACKUP_S3_ENDPOINT=${BACKUP_S3_ENDPOINT:-}
  BACKUP_S3_REGION=${BACKUP_S3_REGION:-}; BACKUP_S3_BUCKET=${BACKUP_S3_BUCKET:-}
  AWG_PORT=${AWG_PORT:-}; S3_PROXY_HOST=${S3_PROXY_HOST:-}; TG_CHAT_ID=${TG_CHAT_ID:-}
  [[ ${1:-} != vpn ]] || return 0 # ente-vpn.sh needs none of the Ente settings
  S3_ACCESS_KEY=${S3_ACCESS_KEY:-}; S3_SECRET_KEY=${S3_SECRET_KEY:-}
  BACKUP_S3_ACCESS_KEY=${BACKUP_S3_ACCESS_KEY:-}; BACKUP_S3_SECRET_KEY=${BACKUP_S3_SECRET_KEY:-}; BACKUP_PASSPHRASE=${BACKUP_PASSPHRASE:-}
  TG_BOT_TOKEN=${TG_BOT_TOKEN:-}
  need DOMAIN S3_ENDPOINT S3_REGION S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_BUCKET
  plain_values DOMAIN S3_ENDPOINT S3_REGION S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_BUCKET HC_URL TG_CHAT_ID S3_PROXY_HOST
  [[ -z $TG_CHAT_ID || $TG_CHAT_ID =~ ^-?[0-9]+$ ]] || die "TG_CHAT_ID must be a number (a group's starts with -)"
  [[ -z $TG_BOT_TOKEN || $TG_BOT_TOKEN =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "TG_BOT_TOKEN does not look like a bot token (123456:ABC...)"
  [[ $S3_ENDPOINT != *://* && $BACKUP_S3_ENDPOINT != *://* ]] || die "S3 endpoints must be bare hostnames, without https://"
  [[ $S3_ENDPOINT/$S3_BUCKET != "$BACKUP_S3_ENDPOINT/$BACKUP_S3_BUCKET" ]] || die "backup bucket must differ from the photo bucket"
  BACKUP_ROOT=backup:$BACKUP_S3_BUCKET/
  photo_bucket
  PHOTO_CFG_ROOT=ente-s3:$PHOTO_BUCKET/$PHOTO_CFG_DIR/
}

# The Ente web apps this server serves, each at <name>.$DOMAIN: photos (web.) and public albums (albums.) always, the ones in
# WEB_APPS on request. The web container serves each app on its own port; only these are published (on 127.0.0.1).
WEB_APP_PORTS="web:3000 albums:3002 auth:3003 locker:3009"
# web_apps_ok: WEB_APPS names only apps this setup knows (auth, locker), space or comma separated
web_apps_ok() {
  local a
  for a in ${WEB_APPS//,/ }; do
    [[ $a == auth || $a == locker ]] || die "WEB_APPS: unknown app '$a' (known: auth, locker)"
  done
}
# web_hosts: the first label of each served web app's host name, one per line (web, albums, then WEB_APPS)
web_hosts() { printf '%s\n' web albums ${WEB_APPS//,/ }; }
# dns_names: the host names that need a DNS record, as "api., web., albums., ..."
dns_names() { { echo api; web_hosts; } | sed 's/$/./' | paste -sd, | sed 's/,/, /g'; }
# web_port NAME: the port the web container serves that app on
web_port() { local p; for p in $WEB_APP_PORTS; do [[ ${p%%:*} != "$1" ]] || { echo "${p#*:}"; return; }; done; return 1; }

# plain_values VAR...: die if a value holds a space, quote, $, backtick or backslash. These values are written into generated
# env files, unit lines and the Caddyfile, where such characters would break the file or run as code.
plain_values() {
  local v bad=$'[[:space:]"\'$`\\]'
  for v in "$@"; do [[ ! ${!v} =~ $bad ]] || die "$v must not contain spaces, quotes, \$, \` or backslashes"; done
}

# root_only_writable PATH...: true if each path and every directory above it is owned by root and not group/world-writable.
# Scripts that root runs from timers or through the bot's sudo rule: anyone who could change them could run anything as root.
root_only_writable() {
  local p real d
  for p in "$@"; do
    real=$(readlink -f "$p") || return 1
    d=$real
    while :; do
      [[ $(stat -c %u "$d") == 0 ]] || { echo "not owned by root: $d" >&2; return 1; }
      if (((8#$(stat -c %a "$d") & 8#022) != 0)) && ! sticky_dir "$d" "$real"; then
        echo "group/world-writable: $d" >&2; return 1
      fi
      [[ $d != / ]] || break
      d=$(dirname "$d")
    done
  done
}
# sticky_dir DIR TARGET: DIR is a sticky directory above TARGET (like /tmp): others cannot rename or replace root's entries in it
sticky_dir() { [[ -d $1 && -k $1 && $1 != "$2" ]]; }

# ---------------------------------------------------------------- bootstrap
# Create the passwordless-sudo admin user with its key, then harden sshd (key-only, no root) and verify it took effect.
setup_ssh() {
  local home n i
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
  for i in $(seq 1 10); do
    [[ -z $(ss -Htln "sport = :$SSH_PORT") ]] || break
    ((i < 10)) || die "sshd is not listening on port $SSH_PORT"
    sleep 1
  done
  log "sshd hardened on port $SSH_PORT. TEST A SECOND LOGIN as $ADMIN_USER before closing this session!"
}

# bootstrap: upgrade packages, admin user + sshd hardening, ufw, unattended upgrades, swap, fail2ban.
cmd_bootstrap() {
  load_env; need ADMIN_USER ADMIN_SSH_PUBKEY
  [[ $ADMIN_USER != root ]] || die "ADMIN_USER must not be root (bootstrap turns root login off: it would lock you out)"
  local kf; kf=$(mktemp); printf '%s\n' "$ADMIN_SSH_PUBKEY" >"$kf"
  ssh-keygen -l -f "$kf" >/dev/null 2>&1 || { rm -f "$kf"; die "ADMIN_SSH_PUBKEY is not a valid public key (placeholder or truncated?); refusing, it would lock you out"; }
  rm -f "$kf"
  # some images leave the hostname unresolvable: sudo then warns on every call and some tools wait for DNS
  getent hosts "$(hostname)" >/dev/null || { echo "127.0.1.1 $(hostname)" >>/etc/hosts; log "added $(hostname) to /etc/hosts"; }
  log "updating packages"
  apt_get update
  # full-upgrade: a kernel update is a new package, which plain upgrade holds back
  apt_get -y -o Dpkg::Options::=--force-confold full-upgrade
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
  local newest; newest=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sed 's/^vmlinuz-//' | sort -V | tail -1)
  [[ -z $newest || $newest == "$(uname -r)" ]] || log "kernel $newest was installed: reboot when deploy is done (ente-vpn.sh needs it)"
}

# ---------------------------------------------------------------- install helpers
# Install Docker if missing, cap container log size, and require Compose >= 2.30.
install_docker() {
  local v conf
  if ! command -v docker >/dev/null; then
    log "installing Docker via get.docker.com"
    # its apt-get does not wait for the dpkg lock (unattended-upgrades holds it right after bootstrap)
    conf=$(mktemp); echo 'DPkg::Lock::Timeout "600";' >"$conf"
    curl -fsSL https://get.docker.com | APT_CONFIG=$conf sh || { rm -f "$conf"; die "Docker install failed"; }
    rm -f "$conf"
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
  # the quickstart creates my-ente/ in the current directory
  (cd "$(dirname "$ENTE_DIR")" && printf 'n\n' | sh -c "$(curl -fsSL "$QUICKSTART_URL")") >/dev/null || die "quickstart failed"
  [[ -f $ENTE_DIR/compose.yaml && -f $ENTE_DIR/museum.yaml ]] || die "quickstart did not create compose.yaml/museum.yaml"
}

# Edit the quickstart output and assert every edit; fail loudly if its format changed. Idempotent.
apply_edits() {
  local c=$ENTE_DIR/compose.yaml m=$ENTE_DIR/museum.yaml p
  chmod 700 "$ENTE_DIR"
  python3 -I - "$c" "$m" <<'PY' || die "quickstart output no longer matches the expected layout; not patching blindly"
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
  sed -E "s|^( *public-albums:).*|\1 https://albums.$DOMAIN|" "$m" >"$m.new"; overwrite_in_place "$m.new" "$m"
  grep -Fq "public-albums: https://albums.$DOMAIN" "$m" || die "museum.yaml: public-albums edit failed"
  if [[ -z $S3_ACCESS_KEY || -z $S3_SECRET_KEY ]] && museum_s3_configured; then
    local M_KEY M_SECRET M_ENDPOINT M_REGION M_BUCKET
    eval "$(museum_s3)"; S3_ACCESS_KEY=$M_KEY; S3_SECRET_KEY=$M_SECRET # keep the keys already in museum.yaml
  fi
  need_secret S3_ACCESS_KEY S3_SECRET_KEY
  edit_museum_s3 "$m"
  yaml_ok "$c"; yaml_ok "$m"
}

# edit_museum_s3 FILE: point the b2-eu-cen bucket at the external photo bucket and drop the two unused buckets. The edit goes
# to FILE.new and is checked there; only then does overwrite_in_place put it into FILE, so a full disk never truncates FILE.
edit_museum_s3() {
  S3_ENDPOINT=$S3_ENDPOINT S3_REGION=$S3_REGION S3_BUCKET=$S3_BUCKET S3_ACCESS_KEY=$S3_ACCESS_KEY S3_SECRET_KEY=$S3_SECRET_KEY \
    python3 -I - "$1" "$1.new" <<'PY' || { rm -f "$1.new"; die "museum.yaml: S3 edit failed (quickstart layout changed, or disk full?); $1 is unchanged"; }
import json, os, re, sys, yaml
path, new = sys.argv[1:]; e = os.environ
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
with open(new, "w") as f:
    f.write("\n".join(out)); f.flush(); os.fsync(f.fileno())
d = yaml.safe_load(open(new))["s3"]
assert d["are_local_buckets"] is False and d["use_path_style_urls"] is True
assert [k for k in d if isinstance(d[k], dict)] == ["b2-eu-cen"], list(d)
assert {k: d["b2-eu-cen"][k] for k in vals} == vals
PY
  if cmp -s "$1.new" "$1"; then rm -f "$1.new"; else overwrite_in_place "$1.new" "$1"; fi
}

# photo_bucket: PHOTO_ENDPOINT and PHOTO_BUCKET, the photo bucket museum really uses: from museum.yaml once install has
# written it there (so a later edit of S3_ENDPOINT / S3_BUCKET without re-running install changes nothing), else from the
# env file (before install, and during restore until museum.yaml is back). The backup, check, verify and restore use these.
photo_bucket() {
  local out M_KEY M_SECRET M_ENDPOINT M_REGION M_BUCKET
  PHOTO_ENDPOINT=$S3_ENDPOINT PHOTO_BUCKET=$S3_BUCKET
  # no museum.yaml, or no bucket in it yet (grep first: it is cheaper than starting Python on every load_env)
  grep -qs '^ *b2-eu-cen:' "$ENTE_DIR/museum.yaml" && out=$(museum_s3 2>/dev/null) || return 0
  eval "$out"
  PHOTO_ENDPOINT=$M_ENDPOINT PHOTO_BUCKET=$M_BUCKET
}

# museum_s3: eval "$(museum_s3)" sets M_KEY M_SECRET M_ENDPOINT M_REGION M_BUCKET from museum.yaml (the source of truth after install).
museum_s3() {
  python3 -I - "$ENTE_DIR/museum.yaml" <<'PY'
import shlex, sys, yaml
b = yaml.safe_load(open(sys.argv[1]))["s3"]["b2-eu-cen"]
for k in ("key", "secret", "endpoint", "region", "bucket"): print("M_%s=%s" % (k.upper(), shlex.quote(str(b[k]))))
PY
}

# true when museum.yaml already points at the configured photo bucket (and is not the quickstart's local MinIO)
museum_s3_configured() {
  python3 -I - "$ENTE_DIR/museum.yaml" "$S3_ENDPOINT" "$S3_BUCKET" <<'PY'
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
    python3 -I - <<'PY' || die "photo bucket check failed"
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
# extra_ports: the compose ports lines that publish the WEB_APPS on 127.0.0.1 (the quickstart publishes web and albums)
extra_ports() {
  local a p
  [[ -n ${WEB_APPS//[ ,]/} ]] || return 0
  printf '\n    ports:'
  for a in ${WEB_APPS//,/ }; do p=$(web_port "$a"); printf '\n      - 127.0.0.1:%s:%s # %s web app' "$p" "$p" "$a"; done
}
write_override() {
  write_file "$ENTE_DIR/compose.override.yaml" 600 <<EOF
services:
  museum:
    image: $(pin_of museum)
    restart: unless-stopped
    oom_score_adj: -300
  web:
    image: $(pin_of web)
    restart: unless-stopped$(extra_ports)
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
  if ! cmp -s "$tmp" "$m"; then overwrite_in_place "$tmp" "$m"; MUSEUM_CFG_CHANGED=1; log "updated internal block in museum.yaml"
  else rm -f "$tmp"; fi
  yaml_ok "$m"
}

# render_caddyfile: print the Caddyfile (pure: writes nothing). The API's upstream and any extra sites come from the hook files
# (see ensure_caddy_hooks), which add-ons such as ente-s3-proxy.sh own.
render_caddyfile() {
  # Security headers. deferred, so they replace any the upstream sends. CSP only as Report-Only (CSP_REPORT_ONLY=yes):
  # violations show in the browser console, nothing is blocked. No CORS headers here: museum sets those itself.
  local csp='' sites='' a
  for a in ${WEB_APPS//,/ }; do # a site block per WEB_APPS app, like web. and albums.
    sites+="$a.$DOMAIN {"$'\n\t'"import sec"$'\n\t'"import app"$'\n\t'"reverse_proxy 127.0.0.1:$(web_port "$a")"$'\n}\n\n'
  done
  if [[ $CSP_REPORT_ONLY == yes ]]; then
    csp="Content-Security-Policy-Report-Only \"default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline';"
    csp+=" img-src 'self' blob: data:; media-src 'self' blob:; font-src 'self' data:; worker-src 'self' blob:;"
    csp+=" connect-src 'self' https://api.$DOMAIN https://$S3_ENDPOINT https://$S3_BUCKET.$S3_ENDPOINT${S3_PROXY_HOST:+ https://$S3_PROXY_HOST};"
    csp+=" object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'\""
  fi
  cat <<EOF
{
	admin unix/$CADDY_ADMIN_SOCK|0220
}

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
		X-Frame-Options "DENY"${csp:+
		$csp}
	}
}

api.$DOMAIN {
	import sec
	import $CADDY_API_UPSTREAM
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

${sites}import $CADDY_SITES/*.caddy
EOF
}

# ensure_caddy_hooks: the hook directory, and the default API upstream (museum) unless an add-on already wrote its own.
# The directory always holds a comment-only file: an import glob that matches nothing makes Caddy warn on every reload.
ensure_caddy_hooks() {
  install -d -m 755 "$CADDY_SITES"
  echo "# Site blocks of add-ons (ente-s3-proxy.sh, ...) are imported from this directory by the Caddyfile." |
    write_file "$CADDY_SITES/00-readme.caddy"
  [[ -e $CADDY_API_UPSTREAM ]] || echo "reverse_proxy 127.0.0.1:8080" | write_file "$CADDY_API_UPSTREAM"
}

# write_caddyfile: write $CADDYFILE from render_caddyfile, validate it and reload Caddy (graceful, cheap when unchanged).
write_caddyfile() {
  local tmp h0
  ensure_caddy_hooks
  tmp=$(mktemp); render_caddyfile >"$tmp"
  if ! caddy validate --config "$tmp" --adapter caddyfile >/dev/null 2>&1; then
    cp "$tmp" /root/Caddyfile.rejected; rm -f "$tmp"
    die "generated Caddyfile is invalid; the old one stays (see: caddy validate --config /root/Caddyfile.rejected --adapter caddyfile)"
  fi
  write_file "$CADDYFILE" <"$tmp"; rm -f "$tmp"
  h0=$(cat /etc/systemd/system/caddy.service.d/ente.conf 2>/dev/null || true)
  install -d -m 755 /etc/systemd/system/caddy.service.d
  printf '[Service]\nRuntimeDirectory=caddy\nRuntimeDirectoryMode=0755\n' | write_file /etc/systemd/system/caddy.service.d/ente.conf
  [[ $h0 == "$(cat /etc/systemd/system/caddy.service.d/ente.conf)" ]] || systemctl daemon-reload
  systemctl enable caddy >/dev/null 2>&1
  # reload talks to the admin API named in the new file: restart once when the running Caddy is not on the socket yet
  if [[ -S $CADDY_ADMIN_SOCK ]]; then systemctl reload-or-restart caddy; else systemctl restart caddy; fi
}

# Shared by install and restore: patch the Ente config, verify the photo bucket, write the Caddyfile and compose override.
# Sets MUSEUM_CFG_CHANGED=1 when museum.yaml changed.
configure_host() {
  local h0; h0=$(sha256sum "$ENTE_DIR/museum.yaml")
  apply_edits
  s3_prepare
  sync_internal
  [[ $(sha256sum "$ENTE_DIR/museum.yaml") == "$h0" ]] || MUSEUM_CFG_CHANGED=1
  write_caddyfile
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
  refresh_backup_source
  if url_ok "https://api.$DOMAIN/ping" 20; then log "https://api.$DOMAIN/ping OK"
  else warn "https://api.$DOMAIN/ping not reachable yet - point DNS A/AAAA (TTL 300) of $(dns_names) under $DOMAIN to this server"; fi
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
  for svc in museum web; do
    repo=$(repo_of $svc); old=$(pin_of $svc)
    docker pull -q "$repo:latest" >/dev/null || die "cannot pull $repo:latest"
    ref=$(image_digest "$repo:latest" "$repo"); [[ -n $ref ]] || die "cannot determine the digest of $repo:latest"
    if [[ $ref != "$old" ]]; then changed=1; log "$svc: ${old##*@sha256:} -> ${ref##*@sha256:}"; fi
    new+="$svc $ref"$'\n'
  done
  dc pull -q postgres || die "cannot pull postgres" # every download before anything changes
  if ((changed)); then cp -p "$PINS" "$PINS.prev"; fi # the rollback point: only replaced when a build really changes
  printf '%s' "$new" | write_file "$PINS" 600
  write_override
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
  # written to a temp file and renamed over the old one: an interrupted write (disk full, Ctrl-C, reboot) never leaves a
  # truncated config, which would lose every remote
  (umask 077; python3 -I -c '
import configparser, os, sys, tempfile
conf, remote = sys.argv[1:]
cp = configparser.RawConfigParser(); cp.optionxform = str; cp.read(conf)
if not cp.has_section(remote): cp.add_section(remote)
for line in sys.stdin.read().splitlines():
    if line:
        k, v = line.split("=", 1); cp.set(remote, k, v)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(conf), prefix=".rclone.conf.")
try:
    with os.fdopen(fd, "w") as f:
        cp.write(f); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, conf)
except BaseException:
    os.unlink(tmp); raise
' "$conf" "$1")
}

# make_backup_remotes: backup (S3 bucket) and backup-crypt (encrypted config/ folder in it).
# Existing remotes keep their keys and passphrase.
make_backup_remotes() {
  local obs
  if ! rclone listremotes | grep -x 'backup:' >/dev/null; then
    need_secret BACKUP_S3_ACCESS_KEY BACKUP_S3_SECRET_KEY
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
  need_secret BACKUP_PASSPHRASE
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

# make_photo_remote_env: the ente-s3 remote from S3_* and the keys (restore: museum.yaml does not exist yet).
make_photo_remote_env() {
  need_secret S3_ACCESS_KEY S3_SECRET_KEY
  rclone_set ente-s3 <<EOF
type=s3
provider=$S3_PROVIDER
endpoint=$S3_ENDPOINT
region=$S3_REGION
access_key_id=$S3_ACCESS_KEY
secret_access_key=$S3_SECRET_KEY
no_check_bucket=true
EOF
}

# make_photo_crypt: photo-crypt, a second encrypted copy of config/ (dumps, museum.yaml, compose files) inside the photo
# bucket under $PHOTO_CFG_DIR/, with backup-crypt's passphrase: either bucket alone + BACKUP_PASSPHRASE restores everything.
# Museum never lists its bucket (it only touches the object keys its database names), so the folder is invisible to it.
make_photo_crypt() {
  local pw
  pw=$(python3 -I -c '
import configparser, sys
cp = configparser.RawConfigParser(); cp.read(sys.argv[1]); print(cp.get("backup-crypt", "password"))
' "$(rclone config file | tail -1)") && [[ -n $pw ]] || die "backup-crypt remote has no passphrase; run make_backup_remotes first"
  rclone_set photo-crypt <<EOF
type=crypt
remote=${PHOTO_CFG_ROOT}config
password=$pw
EOF
}

# check_backup_owner [ROOT CRYPT NAME]: refuse to sync over a backup that belongs to another Ente instance
# (a fresh install pointed at an old backup would wipe it). Default: the backup bucket.
check_backup_owner() {
  local root=${1:-$BACKUP_ROOT} crypt=${2:-backup-crypt} name=${3:-the backup bucket} theirs rc=0 listing
  listing=$(rclone lsf "${root}config" 2>/dev/null) || rc=$?
  ((rc == 0 || rc == 3)) || die "cannot list $name (rclone exit $rc); not touching it"
  [[ -n $listing ]] || return 0
  theirs=$(mktemp); chmod 600 "$theirs"
  if ! rclone cat "$crypt:museum.yaml" >"$theirs" 2>/dev/null || [[ ! -s $theirs ]]; then
    rm -f "$theirs"; die "$name already holds a backup that this passphrase cannot read; refusing to overwrite it"
  fi
  if ! python3 -I - "$ENTE_DIR/museum.yaml" "$theirs" <<'PY'
import sys, yaml
a, b = (yaml.safe_load(open(f))["key"]["encryption"] for f in sys.argv[1:])
sys.exit(a != b)
PY
  then rm -f "$theirs"; die "$name holds the backup of a DIFFERENT Ente instance; refusing to overwrite it (use 'restore' on a fresh server, or an empty bucket)"; fi
  rm -f "$theirs"
}

# write_backup_env: the backup's config file: where it copies to, and which photo bucket it copies.
write_backup_env() {
  write_file "$BACKUP_ENV_FILE" 600 <<EOF
HC_URL="$HC_URL"
BACKUP_ROOT="$BACKUP_ROOT"
PHOTO_BUCKET="$PHOTO_BUCKET"
PHOTO_CFG_DIR="$PHOTO_CFG_DIR"
EOF
}
# backup_env_bucket: the photo bucket the backup copies (empty before backup-setup)
backup_env_bucket() { sed -n 's/^PHOTO_BUCKET="\(.*\)"$/\1/p' "$BACKUP_ENV_FILE" 2>/dev/null || true; }
# photo_remote_endpoint: the endpoint of the ente-s3 rclone remote, the backup's way into the photo bucket
photo_remote_endpoint() {
  awk -F' *= *' '/^\[/ {s = ($0 == "[ente-s3]")} s && $1 == "endpoint" {print $2}' "$RCLONE_CONFIG" 2>/dev/null || true
}

# refresh_backup_source: once backup-setup has run, point the backup at the photo bucket museum.yaml now names (bucket,
# endpoint, keys). Without it, install switching the bucket would leave the nightly backup copying the old one.
refresh_backup_source() {
  [[ -f $BACKUP_ENV_FILE ]] || return 0
  local was; was=$(photo_remote_endpoint)/$(backup_env_bucket)
  photo_bucket; PHOTO_CFG_ROOT=ente-s3:$PHOTO_BUCKET/$PHOTO_CFG_DIR/
  make_photo_remote
  make_photo_crypt
  if [[ $was != "$PHOTO_ENDPOINT/$PHOTO_BUCKET" ]]; then
    check_backup_owner "$PHOTO_CFG_ROOT" photo-crypt "the photo bucket's $PHOTO_CFG_DIR/"
    log "the backup now copies the photo bucket $PHOTO_ENDPOINT/$PHOTO_BUCKET (was $was)"
  fi
  write_backup_env
}

# Install the backup run (ente-backup.sh, its config $BACKUP_ENV_FILE), its systemd service + daily 03:00 timer, and the
# monthly verify.
install_backup_units() {
  write_backup_env
  # the backup run itself is ente-backup.sh (standalone; this only installs it)
  [[ -f $SCRIPT_DIR/ente-backup.sh ]] || die "ente-backup.sh is missing next to $0 (copy the whole ente-server folder)"
  write_file /usr/local/bin/ente-backup.sh 755 <"$SCRIPT_DIR/ente-backup.sh"
  write_file /etc/systemd/system/ente-backup.service <<EOF
[Unit]
Description=Ente backup (database dump + photo objects to the backup bucket)
After=docker.service network-online.target
Wants=network-online.target
$ALERT_ONFAIL

[Service]
Type=oneshot
OOMScoreAdjust=500
TimeoutStartSec=infinity
Environment=RCLONE_CONFIG=/root/.config/rclone/rclone.conf
EnvironmentFile=$BACKUP_ENV_FILE
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
Description=Monthly deep check of the Ente backup (ente-ops.sh verify)
After=docker.service network-online.target
Wants=network-online.target
$ALERT_ONFAIL

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=/bin/bash "$SCRIPT_DIR/ente-ops.sh" verify
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
# Each run first sends a test message, so a wrong token or chat id stops it here, not on the day a backup fails.
# The bot token lives only in /etc/ente-alert.env (600) and is passed to curl on stdin, never on a command line.
# Without TG_CHAT_ID the alert units are removed.
ALERT_ONFAIL=
tg_api() { # tg_api METHOD [curl args...]: call the Bot API with TG_BOT_TOKEN
  local m=$1; shift
  curl -fsS -m 20 --retry 3 -o /dev/null -K - "$@" <<<"url = \"https://api.telegram.org/bot$TG_BOT_TOKEN/$m\""
}
# the files setup_alerts installs, removed again when TG_CHAT_ID is emptied
ALERT_FILES=(/etc/systemd/system/ente-check.timer /etc/systemd/system/ente-check.service /etc/systemd/system/ente-alert@.service
  /etc/ente-alert.env /usr/local/bin/ente-alert /usr/local/bin/ente-alert-unit)
setup_alerts() {
  local f
  if [[ -z $TG_CHAT_ID ]]; then
    ALERT_ONFAIL=
    for f in "${ALERT_FILES[@]}"; do
      [[ -e $f ]] || continue
      systemctl disable --now ente-check.timer >/dev/null 2>&1 || true
      rm -f "${ALERT_FILES[@]}"
      systemctl daemon-reload; log "telegram alerts removed (TG_CHAT_ID empty)"
      break
    done
    return 0
  fi
  if [[ -z $TG_BOT_TOKEN && -f /etc/ente-alert.env ]]; then TG_BOT_TOKEN=$(. /etc/ente-alert.env; echo "$TG_BOT_TOKEN"); fi
  need_secret TG_BOT_TOKEN
  tg_api getMe 2>/dev/null || die "Telegram rejected the bot token, or api.telegram.org is unreachable"
  tg_api sendMessage --data-urlencode "chat_id=$TG_CHAT_ID" \
    --data-urlencode "text=🔔 Ente alerts on $(hostname) ($DOMAIN) are set up. Alerts arrive here when a backup or the daily check fails." 2>/dev/null ||
    die "could not send to TG_CHAT_ID: wrong chat id, or nobody pressed Start in the bot / the bot is not in the group"
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
# Managed by ente-setup.sh. ente-alert-unit UNIT: tell Telegram that UNIT's last run failed, with the lines that say why.
set -euo pipefail
u=$1 h=$(hostname)
id=$(systemctl show -p InvocationID --value "$u" 2>/dev/null || true)
if [[ -n $id ]]; then out=$(journalctl -q -o cat --no-pager "_SYSTEMD_INVOCATION_ID=$id" || true)
else out=$(journalctl -q -o cat --no-pager -u "$u" -n 40 || true); fi
case $u in
  ente-check.service) title="⚠️ Daily check found problems on $h"; why='^  FAIL|ERROR' ;;
  ente-verify.service) title="⚠️ Monthly backup verify found problems on $h"; why='^  FAIL|ERROR' ;;
  ente-backup.service) title="❌ Backup failed on $h"; why='ERROR|WARNING' ;;
  *) title="❌ $u failed on $h"; why='ERROR' ;;
esac
# the lines that say why (FAIL lines as "❌ ..."), else the end of the log. -a: a stray non-UTF-8 byte must not make it "binary"
if grep -aqE "$why" <<<"$out"; then out=$(grep -aE "$why" <<<"$out" | sed -E 's/^  FAIL  /❌ /' | tail -n 30)
else out=$(tail -n 15 <<<"$out"); fi
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
Description=Daily Ente health check (ente-ops.sh check), alerts on FAIL
After=docker.service network-online.target
Wants=network-online.target
OnFailure=ente-alert@%n.service

[Service]
Type=oneshot
ExecStart=/bin/bash "$SCRIPT_DIR/ente-ops.sh" check
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
  log "telegram alerts on (failed backup, daily check at 09:00), test message sent. The check runs $SCRIPT_DIR/ente-ops.sh: keep the folder there"
}

# backup-setup: rclone remotes, refuse a foreign backup, install the timer and start a first backup.
cmd_backup_setup() {
  load_env
  [[ -f $ENTE_DIR/museum.yaml ]] || die "run install first"
  # the verify timer (and the daily check, with alerts on) runs ente-ops.sh from this folder as root
  root_only_writable "$SCRIPT_DIR/ente-ops.sh" "$SCRIPT_DIR/ente-setup.sh" "$ENV_FILE" ||
    die "root's timers run the scripts in $SCRIPT_DIR: they must be root's alone (chown -R root: $SCRIPT_DIR; chmod -R go-w $SCRIPT_DIR)"
  install_rclone
  make_backup_remotes
  make_photo_remote
  make_photo_crypt
  check_backup_owner
  check_backup_owner "$PHOTO_CFG_ROOT" photo-crypt "the photo bucket's $PHOTO_CFG_DIR/"
  setup_alerts
  install_backup_units
  systemctl start --no-block ente-backup.service
  log "backup configured; first run started: journalctl -fu ente-backup.service"
}

# ---------------------------------------------------------------- restore
# Fresh server (after bootstrap), same DOMAIN. Config + database come from whichever bucket holds the newer dump: the backup
# bucket (config/) or the photo bucket ($PHOTO_CFG_DIR/config/); either alone is enough, with BACKUP_PASSPHRASE. Photos stay in
# the photo bucket; objects missing there (e.g. a new, empty photo bucket) are copied back from the backup bucket.
# restore_newest CRYPT: the newest dump's name in that config/ copy (empty if none or unreadable).
restore_newest() { rclone lsf "$1" --include 'ente_db-*.dump' 2>/dev/null | sort | tail -1 || true; }
# restore_source: backup-crypt: or photo-crypt:, whichever holds the newer dump (the backup bucket on a tie); fails if neither has one.
restore_source() {
  local b p
  b=$(restore_newest backup-crypt:); p=$(restore_newest photo-crypt:)
  [[ -n $b || -n $p ]] || return 1
  if [[ $p > $b ]]; then echo photo-crypt:; else echo backup-crypt:; fi
}
# An interrupted restore leaves one of two markers in $ENTE_DIR:
#   .restore-incomplete  the database is not restored yet and museum never ran on it: a re-run wipes it and starts over
#   .restore-finishing   the database is restored (it may be in use by now): a re-run only does the remaining steps,
#                        which never delete anything
# A server without a marker is never touched (restore is for a fresh server).
cmd_restore() {
  load_env
  local tmp dump src newest
  if [[ -e $ENTE_DIR/.restore-finishing ]]; then
    log "the database is already restored; doing the remaining steps (nothing is wiped)"
    restore_finish; return
  fi
  if [[ -e $ENTE_DIR/.restore-incomplete ]]; then
    [[ -z $(dc ps -q museum 2>/dev/null || true) ]] ||
      die "$ENTE_DIR/.restore-incomplete is there but museum is running: not wiping a database that may be in use (look first; delete the file if the restore did finish)"
    log "previous restore stopped before the database was restored; cleaning up and starting over"
    dc down -v >/dev/null 2>&1 || true
    rm -rf "$ENTE_DIR"
  fi
  [[ ! -e $ENTE_DIR ]] || die "$ENTE_DIR already exists; restore is for a fresh server"
  apt_get update; apt_install curl ca-certificates python3-yaml gnupg
  install_docker; install_caddy; install_rclone
  rclone listremotes | grep -x 'backup-crypt:' >/dev/null && rclone config delete backup-crypt
  make_backup_remotes
  make_photo_remote_env
  make_photo_crypt
  src=$(restore_source) || die "no readable backup in either bucket (wrong passphrase, wrong buckets or keys?)"
  newest=$(restore_newest "$src")
  log "restoring config and database from ${src%%:*} ($newest)"
  tmp=$(mktemp -d /root/ente-restore.XXXXXX)
  # shellcheck disable=SC2064 # expand now: $tmp is local to this function
  trap "rm -rf '$tmp'" EXIT
  log "fetching config backup"
  # only the newest dump: the backup bucket keeps every dump ever made
  rclone copy "$src" "$tmp" --checkers 4 --filter "+ $newest" --filter '- ente_db-*.dump'
  dump=$(find "$tmp" -maxdepth 1 -name 'ente_db-*.dump' | sort | tail -1)
  [[ -n $dump && -f $tmp/compose.yaml && -f $tmp/museum.yaml ]] || die "backup incomplete (wrong passphrase?): need ente_db-*.dump, compose.yaml, museum.yaml"
  install -d -m 700 "$DUMP_DIR"
  cp -p "$dump" "$DUMP_DIR/"
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
  mv "$ENTE_DIR/.restore-incomplete" "$ENTE_DIR/.restore-finishing" # from here on, never wipe
  restore_finish
}

# restore_finish: the steps after the database restore. They only copy and start, so an interrupted run resumes here.
restore_finish() {
  if [[ -n $(rclone lsf --max-depth 1 "${BACKUP_ROOT}objects" 2>/dev/null | head -1) ]]; then
    log "copying objects missing from the photo bucket back from the backup (never deletes; can take long on a new bucket)"
    rclone copy "${BACKUP_ROOT}objects" "ente-s3:$PHOTO_BUCKET" --size-only --checkers 4 --transfers 4
  else warn "no photo objects in the backup bucket: using the photo bucket as it is"; fi
  dc up -d
  wait_healthy museum
  url_ok http://127.0.0.1:8080/ping 10 || die "museum /ping failed locally"
  rm -f "$ENTE_DIR/.restore-finishing"
  log "restore finished"
  cat <<EOF

Restored. Next:
  1. DNS: point A/AAAA of $(dns_names) under $DOMAIN to $(host_ip) (TTL 300). Certificates are issued once DNS resolves.
  2. $0 backup-setup   (installs the timer; remotes already exist)
  3. $SCRIPT_DIR/ente-ops.sh check
EOF
}

# ---------------------------------------------------------------- deploy / main
# bootstrap + (install | restore) + backup-setup in one go, from the config and secrets given.
cmd_deploy() {
  load_env
  # fail now, not after a 10-minute bootstrap
  need ADMIN_USER ADMIN_SSH_PUBKEY
  need_secret S3_ACCESS_KEY S3_SECRET_KEY BACKUP_S3_ACCESS_KEY BACKUP_S3_SECRET_KEY BACKUP_PASSPHRASE
  [[ -z $TG_CHAT_ID || -f /etc/ente-alert.env ]] || need_secret TG_BOT_TOKEN
  cmd_bootstrap
  if [[ $RESTORE == yes ]]; then cmd_restore; else cmd_install; fi
  cmd_backup_setup
  log "deploy finished. Next: sign up the owner, then '$0 lockdown'."
}

# The commands: each runs cmd_<name> (dashes as underscores).
COMMANDS="deploy bootstrap install codes lockdown backup-setup restore update"
usage() {
  echo "usage: $0 {${COMMANDS// /|}}" >&2
  exit 2
}
main() { CMD=$1; "cmd_${CMD//-/_}"; }

# sourced (tests): define the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  [[ $# -eq 1 && " $COMMANDS " == *" $1 "* ]] || usage "$@"
  [[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $*)" >&2; exit 1; }
  touch "$LOG"; chmod 600 "$LOG"
  main "$@" 2>&1 | tee -a "$LOG"
fi
