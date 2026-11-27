#!/usr/bin/env bash
# ente-tg-bot.sh - optional add-on: Ente's Telegram commands as an opsbot plugin (/status lines, /check, /backup, /proxy,
# /size): install, uninstall, check, and `action NAME`, which opsbot's root helper runs. See README.md.
BOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) # the real path: it is in the plugin file
# shellcheck source=ente-setup.sh
. "$BOT_DIR/ente-setup.sh" # its helpers, config and opsbot_install; its own main does not run when sourced
OPSBOT_CLI=${OPSBOT_CLI:-/usr/local/sbin/opsbot}
PROXY_STATE=${PROXY_STATE:-/var/lib/ente-setup/s3-proxy} # ente-s3-proxy.sh's state file (on|off)
# the bot before opsbot (ente-tg-bot.service and its pieces; its token: LEGACY_BOT_TOKEN in ente-setup.sh): install removes it
LEGACY_UNIT=/etc/systemd/system/ente-tg-bot.service
LEGACY_FILES=("$LEGACY_UNIT" /etc/sudoers.d/ente-tg-bot /usr/local/sbin/ente-tg-action /usr/local/lib/ente-setup/ente_tg_bot.py)

# bot_load_env: ente-setup.sh's config plus TG_BOT_USER_ID (opsbot checks its form).
bot_load_env() {
  load_env
  TG_BOT_USER_ID=${TG_BOT_USER_ID:-}
  [[ -n $TG_BOT_USER_ID ]] || die "TG_BOT_USER_ID is not set in $ENV_FILE (your Telegram user id; for a private chat it equals TG_CHAT_ID)"
}

# plugin_json: Ente's plugin file for opsbot: its commands, what each action says, how the helper runs it (this script, with
# the config files this run reads, passed through env), and the other files that run as root: the scripts it sources and
# runs, the link rewriter /proxy on puts in front of the API (it sees every request) and the config. The helper checks them
# all before each action. /proxy's three actions are one command: only one of them runs at a time.
plugin_json() {
  local ce e s d=$BOT_DIR; ce=$(config_env) # plain paths only (checked), so they need no quoting in JSON
  e=${ce% *} s=${ce#* }
  cat <<EOF
{
  "name": "ente",
  "exec": ["/usr/bin/env", "$e", "$s", "/bin/bash", "$d/ente-tg-bot.sh", "action"],
  "root_files": ["$d/ente-setup.sh", "$d/ente-ops.sh", "$d/ente-s3-proxy.sh", "$d/ente_s3_rewrite.py",
                 "${e#ENV_FILE=}", "${s#SECRETS_FILE=}"],
  "commands": [
    {"command": "check", "description": "Full health check (about 30 s)", "action": "check"},
    {"command": "backup", "description": "Back up now", "action": "backup"},
    {"command": "proxy", "description": "S3 proxy: state, /proxy on, /proxy off",
     "args": {"": "proxy-status", "on": "proxy-on", "off": "proxy-off"}},
    {"command": "size", "description": "Measure both buckets now", "action": "size"}
  ],
  "actions": {
    "status": {},
    "check": {"started": "⏳ Checking (about 30 s)...", "ok": "✅ Check passed", "fail": "❌ Check found problems"},
    "backup": {"started": "⏳ Backing up...", "ok": "✅ Backup done", "fail": "❌ Backup failed"},
    "proxy-status": {"started": "⏳ Checking the S3 proxy...", "ok": "🔀 S3 proxy", "fail": "❌ S3 proxy has problems"},
    "proxy-on": {"started": "⏳ Turning the S3 proxy on...", "ok": "✅ S3 proxy is on", "fail": "❌ Could not turn the S3 proxy on"},
    "proxy-off": {"started": "⏳ Turning the S3 proxy off...", "ok": "✅ S3 proxy is off", "fail": "❌ Could not turn the S3 proxy off"},
    "size": {"started": "⏳ Measuring the buckets (lists every object: a minute for a big library)...",
             "ok": "🪣 Bucket usage", "fail": "❌ Could not measure the buckets"}
  }
}
EOF
}

# remove_legacy: the bot before opsbot (its service, user, sudo rule, helper and token). It polled the same token, which
# Telegram allows only once at a time.
remove_legacy() {
  local f found=no
  for f in "${LEGACY_FILES[@]}" "$LEGACY_BOT_TOKEN"; do [[ ! -e $f ]] || found=yes; done
  id ente-tg-bot >/dev/null 2>&1 && found=yes
  [[ $found == yes ]] || return 0
  if systemctl cat ente-tg-bot.service >/dev/null 2>&1; then systemctl disable --now ente-tg-bot.service >/dev/null 2>&1 || true; fi
  rm -f "${LEGACY_FILES[@]}"
  rm -rf "$(dirname "$LEGACY_BOT_TOKEN")" /var/lib/ente-tg-bot /var/lib/private/ente-tg-bot
  systemctl daemon-reload
  if id ente-tg-bot >/dev/null 2>&1; then
    pkill -TERM -u ente-tg-bot 2>/dev/null && sleep 2
    pkill -KILL -u ente-tg-bot 2>/dev/null && sleep 1
    userdel ente-tg-bot || die "could not remove the old bot's user ente-tg-bot (ps -u ente-tg-bot)"
  fi
  log "removed the older ente-tg-bot service: opsbot takes over"
}

# ---------------------------------------------------------------- actions (run as root by the helper)
# dur SECONDS: "45 s", "12 min", "5 h", "3 days". ago TIMESTAMP: the same, since then, plus " ago".
dur() {
  local s=$1
  if ((s < 120)); then echo "$s s"; elif ((s < 7200)); then echo "$((s / 60)) min"
  elif ((s < 172800)); then echo "$((s / 3600)) h"; else echo "$((s / 86400)) days"; fi
}
ago() { echo "$(dur $(($(date +%s) - $(date -d "$1" +%s 2>/dev/null || date +%s)))) ago"; }
# tidy: a script's log lines as a reply: without the timestamp and tag, errors and FAILs as ❌
tidy() { sed -E 's/^[0-9-]+ [0-9:]+ \[[^]]*\] //; s/^(ERROR: |  FAIL  )/❌ /'; }

# act_status: Ente's lines of /status (opsbot adds the system line): services, backup, checks, buckets, and the proxy when
# installed. ⚠️/❌ mark what needs a look.
act_status() {
  local s st ps down='' a b last line ts res nxt U_DATE U_PHOTO U_BACKUP
  load_env
  ps=$(dc ps --all --format '{{.Service}} {{if .Health}}{{.Health}}{{else}}{{.State}}{{end}}' 2>/dev/null || true)
  for s in museum web postgres; do
    st=$(awk -v s="$s" '$1 == s {print $2; exit}' <<<"$ps")
    [[ $st == healthy || $st == running ]] || down+="${down:+, }$s (${st:-not running})"
  done
  if [[ -z $down ]]; then echo "✅ Ente is up (museum, web, postgres)"; else echo "❌ Down: $down"; fi
  # the last fully good backup: the older of its two parts (backup bucket, config copy in the photo bucket)
  a=$(cat "$BACKUP_STATE/last-ok-s3" 2>/dev/null || true); b=$(cat "$BACKUP_STATE/last-ok-photo-config" 2>/dev/null || true)
  if [[ -z $a || -z $b ]]; then line="⚠️ Backup: no good backup yet"
  else
    last=$a; [[ $(date -d "$b" +%s) -ge $(date -d "$a" +%s) ]] || last=$b
    if (($(date +%s) - $(date -d "$last" +%s) > 36 * 3600)); then line="⚠️ Backup: last good $(ago "$last")"; else line="💾 Backup: last good $(ago "$last")"; fi
  fi
  res=$(systemctl show ente-backup.service -p Result --value 2>/dev/null || true)
  ts=$(systemctl show ente-backup.service -p ExecMainExitTimestamp --value 2>/dev/null || true)
  [[ -z $ts || $res == success ]] || line+=", the last run failed"
  nxt=$(systemctl show ente-backup.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
  [[ -z $nxt ]] || line+=" · next $(date -d "$nxt" '+%a %H:%M' 2>/dev/null || echo "$nxt")"
  [[ ! -e $BACKUP_STATE/hc-fail ]] || line+=" · heartbeat ping failed"
  echo "$line"
  ts=$(systemctl show ente-check.service -p ExecMainExitTimestamp --value 2>/dev/null || true)
  res=$(systemctl show ente-check.service -p Result --value 2>/dev/null || true)
  if [[ -z $ts ]]; then line="🩺 Check: not run since boot"
  elif [[ $res == success ]]; then line="🩺 Check: passed $(ago "$ts")"
  else line="⚠️ Check: found problems $(ago "$ts") (/check)"; fi
  if [[ -e $BACKUP_STATE/verify-ok ]]; then line+=" · verify: passed $(ago "$(cat "$BACKUP_STATE/verify-ok")")"; else line+=" · verify: not passed yet"; fi
  echo "$line"
  # the buckets as last measured (monthly verify, or /size)
  if usage_get "$BACKUP_STATE/usage"; then echo "🪣 Buckets: photos $U_PHOTO · backup $U_BACKUP · measured $(ago "$U_DATE")"
  else echo "🪣 Buckets: not measured yet (/size)"; fi
  [[ ! -e $CADDY_SITES/s3-proxy.caddy ]] || echo "🔀 S3 proxy: $([[ $(cat "$PROXY_STATE" 2>/dev/null) == on ]] && echo on || echo off)"
}

# act_size: measure both buckets now (ente-ops.sh size, which saves it for /status and check); on failure its last lines.
act_size() {
  local out rc U_DATE U_PHOTO U_BACKUP
  out=$(bash "$BOT_DIR/ente-ops.sh" size 2>&1) && rc=0 || rc=$?
  if ((rc == 0)) && usage_get "$BACKUP_STATE/usage"; then echo "📷 Photos: $U_PHOTO"; echo "💾 Backup: $U_BACKUP"
  else tidy <<<"$out" | tail -3; ((rc)) || rc=1; fi
  return "$rc"
}
# act_check: the check's problems as ❌/⚠️ lines and a count of the rest; the bot's title says passed or not.
act_check() {
  local out rc
  out=$(bash "$BOT_DIR/ente-ops.sh" check 2>&1) && rc=0 || rc=$?
  if ! grep -qE '^  (OK|FAIL|WARN)' <<<"$out"; then tail -3 <<<"$out"; return "$rc"; fi # it did not run
  sed -n 's/^  FAIL  /❌ /p' <<<"$out"   # failures first, then warnings
  sed -n 's/^  WARN  /⚠️ /p' <<<"$out"
  sed -n 's/^  INFO  buckets: /🪣 Buckets: /p' <<<"$out" # the last measurement, as check shows it
  echo "$(grep -c '^  OK' <<<"$out") checks OK"
  return "$rc"
}

# act_backup: run a backup and wait for it; the time it took, and on failure the lines that say why.
act_backup() {
  local t0 id why rc=0
  t0=$SECONDS
  systemctl start ente-backup.service || rc=$?
  id=$(systemctl show ente-backup.service -p InvocationID --value)
  if ((rc == 0)); then echo "Took $(dur $((SECONDS - t0)))."
  else
    echo "Stopped after $(dur $((SECONDS - t0))):"
    why=$([[ -z $id ]] || journalctl -q -o cat --no-pager "_SYSTEMD_INVOCATION_ID=$id")
    if grep -q ERROR <<<"$why"; then grep ERROR <<<"$why" | tail -10; else tail -5 <<<"$why"; fi
  fi
  [[ ! -e $BACKUP_STATE/hc-fail ]] || echo "⚠️ The heartbeat ping failed (the backup itself is fine)."
  return "$rc"
}

# act_proxy on|off|status: what ente-s3-proxy.sh says, without timestamps and with its OK lines counted.
act_proxy() {
  local out rc
  if [[ ! -f $BOT_DIR/ente-s3-proxy.sh || ! -e $CADDY_SITES/s3-proxy.caddy ]]; then
    echo "The S3 proxy is not installed (ente-s3-proxy.sh install)."; return 1
  fi
  out=$(bash "$BOT_DIR/ente-s3-proxy.sh" "$1" 2>&1) && rc=0 || rc=$?
  grep -vE '\] wrote |^\s*$|^  OK  ' <<<"$out" | tidy || true
  ! grep -q '^  OK  ' <<<"$out" || echo "$(grep -c '^  OK  ' <<<"$out") checks OK"
  return "$rc"
}

bot_cmd_action() {
  case $1 in
    status) act_status ;;
    check) act_check ;;
    backup) act_backup ;;
    proxy-on) act_proxy on ;;
    proxy-off) act_proxy off ;;
    proxy-status) act_proxy status ;;
    size) act_size ;;
    *) bot_usage ;;
  esac
}

# ---------------------------------------------------------------- commands
bot_cmd_install() {
  local tmp legacy=no
  bot_load_env
  # The older bot polls the same token, which Telegram allows only once: stop it now (whatever state it is in) and remove it,
  # with its token, only once opsbot serves Ente. If anything fails before, opsbot's bot is stopped and the older one started
  # again. opsbot checks that every file the plugin runs as root is root's alone.
  if systemctl cat ente-tg-bot.service >/dev/null 2>&1; then systemctl stop ente-tg-bot.service; legacy=yes; fi
  tmp=$(mktemp -d)
  if ! opsbot_install "$TG_BOT_USER_ID" || ! plugin_json >"$tmp/ente.json" || ! "$OPSBOT_CLI" plugin add "$tmp/ente.json"; then
    rm -rf "$tmp"
    if [[ $legacy == yes ]]; then
      systemctl disable --now opsbot.service >/dev/null 2>&1 || true
      systemctl start ente-tg-bot.service || true
      die "opsbot could not take over (see above); the older bot runs again"
    fi
    die "opsbot could not be set up for Ente (see above)"
  fi
  rm -rf "$tmp"
  remove_legacy
  log "telegram bot ready: send /status to it from your Telegram account (user $TG_BOT_USER_ID)"
}

bot_cmd_uninstall() {
  load_env
  [[ ! -x $OPSBOT_CLI ]] || "$OPSBOT_CLI" plugin remove ente
  remove_legacy
  log "Ente's bot commands removed (opsbot stays for its notifications and other plugins: '$OPSBOT_CLI uninstall' removes it)"
}

# check: OK/FAIL lines (for ente-ops.sh check): Ente registered, opsbot's own check, no older bot left; exit 1 on a FAIL
bot_cmd_check() {
  bot_load_env
  if [[ ! -x $OPSBOT_CLI ]]; then bad "opsbot is not installed ($0 install)"
  else
    if "$OPSBOT_CLI" plugin list | grep -qw ente; then ok "registered with opsbot (/check, /backup, /proxy, /size and /status lines)"
    else bad "Ente is not registered with opsbot ($0 install)"; fi
    "$OPSBOT_CLI" check || FAILS=$((FAILS + 1))
  fi
  [[ ! -e $LEGACY_UNIT ]] || bad "the older ente-tg-bot service is still installed ($0 install moves to opsbot)"
  ((FAILS == 0))
}

bot_usage() { echo "usage: $0 {install|uninstall|check}" >&2; exit 2; }

# sourced (tests): define the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "$#:${1:-}:${2:-}" in
    1:install: | 1:uninstall: | 1:check: | 2:action:*) ;; # actions: bot_cmd_action knows them (the helper only passes Ente's)
    *) bot_usage ;;
  esac
  [[ $EUID -eq 0 ]] || { echo "run as root (sudo $0 $*)" >&2; exit 1; }
  CMD="tg-bot $1"
  case $1 in
    check) bot_cmd_check; exit ;;           # quiet, not logged: run by ente-ops.sh check
    action) bot_cmd_action "$2"; exit ;;    # its output is the bot's reply
  esac
  touch "$LOG"; chmod 600 "$LOG"
  case $1 in
    install) bot_cmd_install ;;
    uninstall) bot_cmd_uninstall ;;
  esac 2>&1 | tee -a "$LOG"
  exit "${PIPESTATUS[0]}"
fi
