#!/usr/bin/env bash
# Tests for ente-tg-bot.sh, Ente's plugin for opsbot, and ente-setup.sh's opsbot_install: config, where the token comes from,
# the plugin file (checked by opsbot's own validator, and the sudo rule opsbot makes of it), install/uninstall with opsbot and
# the older bot stubbed, the check, what each action replies, and the command line. Runs anywhere bash and python3 are; where
# visudo is installed (the server) the sudo rule is also validated. Changes nothing on the machine: when run as root, the
# command-line checks run as an unprivileged user on a copy. Run: bash tests/test_tg_bot_config.sh
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OPSBOT_PY=$HERE/../../opsbot/opsbot.py

TOKEN=123456789:AAH-test_token-abcdefghijklmnopqrstuv
base_env() {
  cat <<'X'
DOMAIN=photos.example.org
ADMIN_USER=ops
ADMIN_SSH_PUBKEY="ssh-ed25519 AAAA test"
S3_ENDPOINT=s3.eu-west-4.idrivee2.com
S3_REGION=eu-west-4
S3_BUCKET=ente-dev
BACKUP_S3_ENDPOINT=s3.us-east-005.backblazeb2.com
BACKUP_S3_REGION=us-east-005
BACKUP_S3_BUCKET=ente-backup
X
}
# in_bot ENV_EXTRA SECRETS CODE: source ente-tg-bot.sh with a config, a secrets file and every outside path in $T, run CODE
in_bot() {
  base_env >"$T/env"; printf '%s\n' "$1" >>"$T/env"
  printf '%s\n' "$2" >"$T/secrets"; chmod 600 "$T/secrets"
  ( ENV_FILE=$T/env SECRETS_FILE=$T/secrets OPSBOT_TOKEN_FILE=$T/opsbot-token OPSBOT_SH=$T/fake/opsbot.sh OPSBOT_CLI=$T/fake/opsbot CMD=test
    # shellcheck source=/dev/null
    . "$HERE/../ente-tg-bot.sh"
    ALERT_LEGACY=("$T/alert.env" "$T/alert-bin") LEGACY_BOT_TOKEN=$T/legacy/tok/token LEGACY_UNIT=$T/legacy/ente-tg-bot.service
    LEGACY_FILES=("$LEGACY_UNIT" "$T/legacy/sudoers" "$T/legacy/helper" "$T/legacy/ente_tg_bot.py")
    id() { [[ -n ${LEGACY_USER:-} ]]; }; userdel() { echo "userdel $*"; }; pkill() { return 1; }
    systemctl() { echo "systemctl $*" >>"$T/systemctl.log"; [[ $1 != cat || -e $LEGACY_UNIT ]]; }
    set +e
    eval "$3" )
}
U=TG_BOT_USER_ID=376193354
mkdir -p "$T/fake" "$T/plugins"
# a fake opsbot.sh (records how it was run) and installed opsbot CLI (records its arguments; plugin add/remove/list on $T/plugins)
printf '#!/bin/bash\n{ echo "args=$*"; echo "token=${OPSBOT_TOKEN-unset}"; echo "chat=${OPSBOT_CHAT_ID-unset}"; echo "user=${OPSBOT_USER_ID-unset}"; } >"%s"\nexit "${OPSBOT_FAILS:-0}"\n' \
  "$T/opsbot.log" >"$T/fake/opsbot.sh"
cat >"$T/fake/opsbot" <<X
#!/bin/bash
echo "cli \$*" >>"$T/cli.log"
case "\$1 \$2" in
  "plugin add") cp "\$3" "$T/plugins/ente.json" ;;
  "plugin remove") rm -f "$T/plugins/\$3.json" ;;
  "plugin list") ls "$T/plugins" | sed 's/\.json\$//' | paste -sd' ' ;;
  "check "*) printf '  OK    opsbot fine\n  FAIL  opsbot broken\n'; exit 1 ;;
esac
exit "\${CLI_FAILS:-0}"
X
chmod 755 "$T/fake/opsbot.sh" "$T/fake/opsbot"

echo "== config"
out=$(in_bot "$U" "" 'bot_load_env && echo "LOADED $TG_BOT_USER_ID"' 2>&1); check "a user id is needed" '[[ $out == *"LOADED 376193354"* ]]' "$out"
out=$(in_bot "TG_BOT_USER_ID=" "" 'bot_load_env && echo LOADED' 2>&1); check "without one: says so" '[[ $out != *LOADED* && $out == *"TG_BOT_USER_ID is not set"* ]]' "$out"

echo "== the token opsbot_install gives opsbot"
# tok SECRETS: the token opsbot_install passes (from the fake opsbot's record), or its error
tok() { rm -f "$T/opsbot.log"; in_bot "$U" "$1" 'load_env; opsbot_install 376193354' >/dev/null 2>"$T/tok.err"; sed -n 's/^token=//p' "$T/opsbot.log" 2>/dev/null || cat "$T/tok.err"; }
out=$(tok "TG_BOT_TOKEN=$TOKEN"); check "the secrets file's" '[[ $out == "$TOKEN" ]]' "$out"
printf "TG_BOT_TOKEN='%s'\nTG_CHAT_ID='1'\n" "$TOKEN" >"$T/alert.env"
out=$(tok ""); check "else the alerts' from before opsbot" '[[ $out == "$TOKEN" ]]' "$out"
rm "$T/alert.env"; mkdir -p "$T/legacy/tok"; echo "$TOKEN" >"$T/legacy/tok/token"
out=$(tok ""); check "else the older bot's" '[[ $out == "$TOKEN" ]]' "$out"
rm -r "$T/legacy"; echo "$TOKEN" >"$T/opsbot-token"
out=$(tok ""); check "else none, when opsbot has one (it keeps it)" '[[ -z $out ]]' "$out"
rm "$T/opsbot-token"
out=$(tok ""); check "none anywhere: asks for TG_BOT_TOKEN" '[[ $out == *"TG_BOT_TOKEN is not set"* ]]' "$out"
in_bot "$U
TG_CHAT_ID=-1001234567" "TG_BOT_TOKEN=$TOKEN" 'load_env; opsbot_install' >/dev/null 2>&1
check "without a user id: the alert chat, and the bot left as it is (no user id passed)" \
  '[[ $(cat "$T/opsbot.log") == "$(printf "args=install\ntoken=%s\nchat=-1001234567\nuser=unset" "$TOKEN")" ]]' "$(cat "$T/opsbot.log")"

echo "== the plugin file"
mkdir -p "$T/pj"
in_bot "$U" "" 'bot_load_env; plugin_json' >"$T/pj/ente.json" 2>"$T/pj.err"
out=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import opsbot; print(opsbot.read_plugin(sys.argv[2])["name"])' \
  "$(dirname "$OPSBOT_PY")" "$T/pj/ente.json" 2>&1)
check "opsbot's plugin checks accept it" '[[ $out == ente ]]' "$out $(cat "$T/pj.err")"
if [[ $EUID -eq 0 ]]; then # the full validator also wants what it runs to be root's alone: only true as root
  out=$(python3 -I "$OPSBOT_PY" validate "$T/pj/ente.json" --plugins "$T/none" 2>&1)
  check "... and so does opsbot's validator, which also checks the files it runs are root's alone" '[[ $out == ente ]]' "$out"
fi
pj() { python3 -I -c "import json, sys; d = json.load(open(sys.argv[1])); print($1)" "$T/pj/ente.json"; }
D=$(realpath "$HERE/..")
check "the helper runs this script's action command, with the config and secrets files this install used" \
  '[[ $(pj "\" \".join(d[\"exec\"])") == "/usr/bin/env ENV_FILE=$(realpath "$T/env") SECRETS_FILE=$(realpath "$T/secrets") /bin/bash $D/ente-tg-bot.sh action" ]]' "$(pj 'd["exec"]')"
check "the scripts it sources and runs, the link rewriter and the config are root_files: checked before each action" \
  '[[ $(pj "\" \".join(d[\"root_files\"])") == "$D/ente-setup.sh $D/ente-ops.sh $D/ente-s3-proxy.sh $D/ente_s3_rewrite.py $(realpath "$T/env") $(realpath "$T/secrets")" ]]' "$(pj 'd["root_files"]')"
check "commands: /check /backup /proxy /size, and a status action for /status" \
  '[[ $(pj "\" \".join(c[\"command\"] for c in d[\"commands\"]), \"status\" in d[\"actions\"]") == "check backup proxy size True" ]]' "$(pj 'd["commands"]')"
check "the seven actions, exactly those the script answers" \
  '[[ $(pj "\" \".join(sorted(d[\"actions\"]))") == "backup check proxy-off proxy-on proxy-status size status" ]] &&
   [[ $(sed -n "/^bot_cmd_action()/,/^}/p" "$HERE/../ente-tg-bot.sh" | grep -oE "^    [a-z-]+\)" | tr -d " )" | sort | paste -sd" ") == "backup check proxy-off proxy-on proxy-status size status" ]]'
check "every long action says it started, and how it ended" \
  '[[ $(pj "all({\"started\", \"ok\", \"fail\"} <= set(a) for n, a in d[\"actions\"].items() if n != \"status\")") == True ]]'
python3 -I "$OPSBOT_PY" sudoers opsbot /usr/local/sbin/opsbot-action --plugins "$T/pj" >"$T/sudoers"
check "opsbot's sudo rule for it: exactly the seven actions, as root, for the bot user only" \
  '[[ $(grep -c "^opsbot ALL=(root) NOPASSWD:" "$T/sudoers") == 1 && $(grep -o "/usr/local/sbin/opsbot-action ente [a-z-]*" "$T/sudoers" | sort | sed "s|.* ||" | paste -sd" ") == "backup check proxy-off proxy-on proxy-status size status" ]]' "$(cat "$T/sudoers")"
check "no wildcard and no other command" '! grep -qE "\*|ALL$|ALL,|/bin/|/usr/bin/" <(grep -v "^#" "$T/sudoers")' "$(cat "$T/sudoers")"
if command -v visudo >/dev/null; then
  out=$(visudo -cf "$T/sudoers" 2>&1); rc=$?; check "visudo accepts the rule" '[[ $rc -eq 0 ]]' "$out"
else
  echo "  skip  visudo not installed here (run on the server)"
fi

echo "== install and uninstall"
out=$(in_bot "$U" "TG_BOT_TOKEN=$TOKEN" "bot_cmd_install" 2>&1)
check "install: opsbot with the token and the user; no chat when TG_CHAT_ID is empty (opsbot keeps its own, else the user)" \
  '[[ $(cat "$T/opsbot.log") == "$(printf "args=install\ntoken=%s\nchat=\nuser=376193354" "$TOKEN")" ]]' "$(cat "$T/opsbot.log"; echo "$out")"
check "... then registers the plugin" '[[ $(cat "$T/cli.log") == "cli plugin add "*"/ente.json" && -s $T/plugins/ente.json ]] && grep -q "telegram bot ready" <<<"$out"' "$out"
out=$(in_bot "$U
TG_CHAT_ID=-1001234567" "TG_BOT_TOKEN=$TOKEN" "bot_cmd_install" 2>&1)
check "... alerts to TG_CHAT_ID when it is set" 'grep -qx "chat=-1001234567" "$T/opsbot.log"' "$(cat "$T/opsbot.log")"
rm -f "$T/cli.log"
out=$(OPSBOT_FAILS=1 in_bot "$U" "TG_BOT_TOKEN=$TOKEN" "bot_cmd_install" 2>&1)
check "a failed opsbot install stops it: nothing registered" '[[ $out == *"opsbot could not be set up for Ente"* && ! -e $T/cli.log ]]' "$out"
mkdir -p "$T/legacy/tok"; touch "$T/legacy/ente-tg-bot.service" "$T/legacy/sudoers" "$T/legacy/helper" "$T/legacy/ente_tg_bot.py"
echo "$TOKEN" >"$T/legacy/tok/token"
rm -f "$T/systemctl.log" "$T/opsbot.log"
out=$(LEGACY_USER=1 OPSBOT_FAILS=1 in_bot "$U" "" "bot_cmd_install" 2>&1)
check "opsbot's install fails while moving from the older bot: opsbot's bot stopped, the older one runs again, its token and files stay" \
  '[[ $out == *"the older bot runs again"* && $(cat "$T/systemctl.log") == *"stop ente-tg-bot.service"*"disable --now opsbot.service"*"start ente-tg-bot.service"* && -f $T/legacy/tok/token && -f $T/legacy/ente-tg-bot.service ]]' "$out $(cat "$T/systemctl.log")"
check "... (the older bot's token was offered to opsbot)" 'grep -qx "token=$TOKEN" "$T/opsbot.log"' "$(cat "$T/opsbot.log")"
rm -f "$T/systemctl.log"
out=$(CLI_FAILS=1 LEGACY_USER=1 in_bot "$U" "" "bot_cmd_install" 2>&1)
check "... the same when opsbot refuses Ente's plugin" \
  '[[ $out == *"the older bot runs again"* && $(cat "$T/systemctl.log") == *"start ente-tg-bot.service"* && -f $T/legacy/tok/token ]]' "$out"
rm -f "$T/systemctl.log"
out=$(LEGACY_USER=1 in_bot "$U" "" "bot_cmd_install" 2>&1)
check "the bot from before opsbot is stopped (whatever its state) before opsbot polls the same token" \
  '[[ $(head -1 "$T/systemctl.log") == "systemctl cat ente-tg-bot.service" && $(sed -n 2p "$T/systemctl.log") == "systemctl stop ente-tg-bot.service" ]]' "$(cat "$T/systemctl.log")"
check "... and removed once opsbot serves Ente: service, files, token, user" \
  '[[ -z $(find "$T/legacy" -type f) && $(cat "$T/systemctl.log") == *"disable --now ente-tg-bot.service"* && $out == *"userdel ente-tg-bot"* && $out == *"opsbot takes over"* && $out == *"telegram bot ready"* ]]' "$out"
rm -f "$T/cli.log"
out=$(in_bot "$U" "" 'bot_cmd_uninstall' 2>&1)
check "uninstall: unregisters the plugin, opsbot stays" '[[ $(cat "$T/cli.log") == "cli plugin remove ente" && ! -e $T/plugins/ente.json && $out == *"opsbot stays"* ]]' "$out"

echo "== check"
out=$(in_bot "$U" "" 'bot_cmd_check; echo "rc=$? FAILS=$FAILS"' 2>&1)
check "not registered: a FAIL; opsbot's own lines shown, its failing check counted" \
  '[[ $out == *"FAIL  Ente is not registered with opsbot"* && $out == *"OK    opsbot fine"* && $out == *"FAIL  opsbot broken"* && $out == *"rc=1 FAILS=2" ]]' "$out"
touch "$T/plugins/ente.json"; mkdir -p "$T/legacy"; touch "$T/legacy/ente-tg-bot.service"
out=$(in_bot "$U" "" 'bot_cmd_check; echo "rc=$? FAILS=$FAILS"' 2>&1)
check "registered, but the older bot still there: says to move it" '[[ $out == *"OK    registered with opsbot"* && $out == *"FAIL  the older ente-tg-bot service is still installed"* && $out == *"FAILS=2" ]]' "$out"
rm -r "$T/legacy"
out=$(in_bot "$U" "" 'OPSBOT_CLI=$T/none; bot_cmd_check; echo "rc=$?"' 2>&1)
check "opsbot not installed: a FAIL" '[[ $out == *"FAIL  opsbot is not installed"* && $out == *"rc=1" ]]' "$out"

echo "== failing actions still report"
if [[ $EUID -ne 0 ]]; then # here ente-ops.sh check fails with "run as root": the reply must carry that, not be empty
  out=$(in_bot "$U" "" 'bot_load_env; act_check; echo "rc=$?"' 2>&1)
  check "a failing check returns its output and exit code" '[[ $out == *"run as root"* && $out == *"rc=1"* ]]' "$out"
fi
out=$(in_bot "$U" "" 'bot_cmd_action rm; echo "rc=$?"' 2>&1)
check "an action it does not know is a usage error" '[[ $out == *usage* && $out != *"rc=0"* ]]' "$out"

echo "== what the actions reply"
# act CODE: run CODE (act_* calls) with the server stubbed: three containers (DOWN / EXITED), systemd (BRES, BTS: the last
# backup run; CRES, CTS: the last daily check; BRC: what starting a backup returns), the journal ($T/journal), and
# fake ente-ops.sh / ente-s3-proxy.sh in $T/fake (their output in $T/fake.out, exit code in FAKE_RC)
mkdir -p "$T/fake" "$T/st" "$T/sites"
for f in ente-ops.sh ente-s3-proxy.sh; do printf '#!/bin/bash\ncat "%s"\nexit "${FAKE_RC:-0}"\n' "$T/fake.out" >"$T/fake/$f"; done
# the bot shows timer times in the server's zone: pin it, so "03:00 CET" reads 03:00 on a server in any zone
act() {
  TZ=Europe/Berlin in_bot "$U" "" '
    BOT_DIR=$T/fake BACKUP_STATE=$T/st PROXY_STATE=$T/proxy-state CADDY_SITES=$T/sites
    bot_load_env
    dc() { # docker compose ps --all --format "SERVICE STATE": DOWN not there at all, EXITED exited, web without a health check
      local s; [[ $1 == ps ]] || return 0
      for s in museum web postgres; do
        if [[ " ${DOWN:-} " == *" $s "* ]]; then continue; elif [[ " ${EXITED:-} " == *" $s "* ]]; then echo "$s exited"
        elif [[ $s == web ]]; then echo "$s running"; else echo "$s healthy"; fi
      done; }
    systemctl() {
      case "$*" in
        "start ente-backup.service") return "${BRC:-0}" ;;
        *"ente-backup.service -p Result "*) echo "${BRES:-success}" ;;
        *"ente-backup.service -p ExecMainExitTimestamp "*) echo "${BTS-Mon 2026-11-16 03:05:00 CET}" ;;
        *"ente-backup.service -p InvocationID "*) echo abc ;;
        *"ente-backup.timer -p NextElapseUSecRealtime "*) echo "Tue 2026-11-17 03:00:00 CET" ;;
        *"ente-check.service -p ExecMainExitTimestamp "*) echo "${CTS-$(date -d "5 hours ago")}" ;;
        *"ente-check.service -p Result "*) echo "${CRES:-success}" ;;
      esac
    }
    journalctl() { cat "$T/journal"; }
    '"$1" 2>&1
}
stamps() { date -Is -d "$1 ago" >"$T/st/last-ok-s3"; date -Is -d "${2:-$1} ago" >"$T/st/last-ok-photo-config"; date -Is -d "3 days ago" >"$T/st/verify-ok"; }
out=$(act 'dur 45; dur 600; dur 7200; dur 200000' | tr '\n' '|'); check "dur: s, min, h, days" '[[ $out == "45 s|10 min|2 h|2 days|" ]]' "$out"
stamps "2 hours"; rm -f "$T/st/hc-fail"
printf 'date %s\nphoto 886046720 360\nbackup 2684354560 371\n' "$(date -Is -d "3 hours ago")" >"$T/st/usage"
out=$(act act_status)
check "status, all well: Ente's four lines (opsbot adds the system line), no warnings" '[[ $(wc -l <<<"$out") -eq 4 && $out != *"⚠️"* && $out != *"❌"* && $out != *"Disk"* ]]' "$out"
check "... services" '[[ $(sed -n 1p <<<"$out") == "✅ Ente is up (museum, web, postgres)" ]]' "$out"
check "... backup: last good and next run" '[[ $(sed -n 2p <<<"$out") == "💾 Backup: last good 2 h ago · next Tue 03:00" ]]' "$out"
check "... check and verify" '[[ $(sed -n 3p <<<"$out") == "🩺 Check: passed 5 h ago · verify: passed 3 days ago" ]]' "$out"
check "... both buckets as last measured (verify or /size)" \
  '[[ $(sed -n 4p <<<"$out") == "🪣 Buckets: photos 845.0MiB, 360 files · backup 2.5GiB, 371 files · measured 3 h ago" ]]' "$out"
touch "$T/sites/s3-proxy.caddy"; echo on >"$T/proxy-state"; date >"$T/st/hc-fail"
out=$(EXITED=web DOWN=postgres BRES=exit-code CRES=exit-code act act_status)
check "status, problems: a container exited, one missing" '[[ $(sed -n 1p <<<"$out") == "❌ Down: web (exited), postgres (not running)" ]]' "$out"
check "... a failed last run and a failed heartbeat ping" '[[ $(sed -n 2p <<<"$out") == "💾 Backup: last good 2 h ago, the last run failed · next Tue 03:00 · heartbeat ping failed" ]]' "$out"
check "... a check that found problems" '[[ $(sed -n 3p <<<"$out") == "⚠️ Check: found problems 5 h ago (/check)"* ]]' "$out"
check "... and the proxy last" '[[ $(sed -n 5p <<<"$out") == "🔀 S3 proxy: on" ]]' "$out"
rm -f "$T/sites/s3-proxy.caddy" "$T/st/hc-fail"
stamps "2 hours" "40 hours"; out=$(act act_status | sed -n 2p)
check "status: the older part of the backup counts, over 36 h is a warning" '[[ $out == "⚠️ Backup: last good 40 h ago · next Tue 03:00" ]]' "$out"
stamps "40 hours" "2 hours"; out=$(act act_status | sed -n 2p)
check "... whichever part it is" '[[ $out == "⚠️ Backup: last good 40 h ago · next Tue 03:00" ]]' "$out"
rm "$T/st/last-ok-photo-config" "$T/st/verify-ok" "$T/st/usage"; out=$(BTS= CTS= act act_status)
check "status after a fresh install: no good backup yet, nothing run, buckets not measured" \
  '[[ $(sed -n 2p <<<"$out") == "⚠️ Backup: no good backup yet · next Tue 03:00" && $(sed -n 3p <<<"$out") == "🩺 Check: not run since boot · verify: not passed yet" &&
     $(sed -n 4p <<<"$out") == "🪣 Buckets: not measured yet (/size)" ]]' "$out"
printf 'date %s\nphoto 1 1\n' "$(date -Is)" >"$T/st/usage"; out=$(act act_status | sed -n 4p)
check "a usage file without the backup bucket counts as not measured" '[[ $out == "🪣 Buckets: not measured yet"* ]]' "$out"

printf '%s\n' "photo bucket p: 1.0KiB, 2 files" >"$T/fake.out"
out=$(act 'printf "date %s\nphoto 3221225472 1200\nbackup 4294967296 1300\n" "$(date -Is)" >"$T/st/usage"; act_size; echo "rc=$?"')
check "size: both buckets from the fresh measurement" '[[ $out == "$(printf "📷 Photos: 3.0GiB, 1200 files\n💾 Backup: 4.0GiB, 1300 files\nrc=0")" ]]' "$out"
printf '%s\n' "2026-11-24 10:00:00 [size] ERROR: cannot list the buckets (the last measurement stays)" >"$T/fake.out"
out=$(FAKE_RC=1 act 'act_size; echo "rc=$?"')
check "size that fails: why, without the timestamp, and a failure" '[[ $out == "$(printf "❌ cannot list the buckets (the last measurement stays)\nrc=1")" ]]' "$out"
printf '%s\n' "== a" "  OK    one" "  WARN  sign-ups are open" "  OK    two" "  FAIL  web exited" "  OK    three" "" "1 check(s) FAILED" >"$T/fake.out"
out=$(FAKE_RC=1 act 'act_check; echo "rc=$?"')
check "check: problems as ❌/⚠️ lines, the rest counted, exit code kept" '[[ $out == "$(printf "❌ web exited\n⚠️ sign-ups are open\n3 checks OK\nrc=1")" ]]' "$out"
printf '%s\n' "  OK    one" "  INFO  buckets: photos 1.0GiB, 9 files; backup 2.0GiB, 9 files (measured x)" >"$T/fake.out"
out=$(act 'act_check; echo "rc=$?"')
check "check: the last bucket measurement is shown too" '[[ $out == "$(printf "🪣 Buckets: photos 1.0GiB, 9 files; backup 2.0GiB, 9 files (measured x)\n1 checks OK\nrc=0")" ]]' "$out"
printf '%s\n' "something" "run as root (sudo x)" >"$T/fake.out"
out=$(FAKE_RC=1 act 'act_check; echo "rc=$?"'); check "check that did not run: its last lines" '[[ $out == *"run as root"* && $out == *"rc=1" ]]' "$out"

printf '%s\n' "== backup bucket" "x" "ERROR: backup to the S3 bucket failed" "y" >"$T/journal"
out=$(act 'act_backup; echo "rc=$?"'); check "backup that worked: how long it took" '[[ $out == "$(printf "Took 0 s.\nrc=0")" ]]' "$out"
out=$(BRC=3 act 'act_backup; echo "rc=$?"'); check "backup that failed: its ERROR lines" '[[ $out == "$(printf "Stopped after 0 s:\nERROR: backup to the S3 bucket failed\nrc=3")" ]]' "$out"
seq -f "line %g" 1 9 >"$T/journal"; date >"$T/st/hc-fail"
out=$(BRC=1 act act_backup); check "... without ERROR lines: the last five, and a failed heartbeat" '[[ $out == "$(printf "Stopped after 0 s:\nline 5\nline 6\nline 7\nline 8\nline 9\n⚠️ The heartbeat ping failed (the backup itself is fine).")" ]]' "$out"
rm -f "$T/st/hc-fail"

out=$(act 'act_proxy status; echo "rc=$?"'); check "proxy not installed: says so" '[[ $out == "$(printf "The S3 proxy is not installed (ente-s3-proxy.sh install).\nrc=1")" ]]' "$out"
touch "$T/sites/s3-proxy.caddy"
printf '%s\n' "2026-11-16 10:00:00 [s3-proxy on] wrote /etc/caddy/x" "  OK    a" "  OK    b" "  FAIL  c broke" "" \
  "2026-11-16 10:00:01 [s3-proxy on] ERROR: S3 proxy not switched on (still off); everything is back as it was" >"$T/fake.out"
out=$(FAKE_RC=1 act 'act_proxy on; echo "rc=$?"')
check "proxy: no timestamps or file notes, problems as ❌, OK lines counted" \
  '[[ $out == "$(printf "❌ c broke\n❌ S3 proxy not switched on (still off); everything is back as it was\n2 checks OK\nrc=1")" ]]' "$out"
rm -f "$T/sites/s3-proxy.caddy"

echo "== ente-setup.sh's root-only check (the timers' scripts and config)"
mkdir -p "$T/own"; touch "$T/own/a"; chmod 755 "$T/own"; chmod 644 "$T/own/a"
out=$(in_bot "$U" "" "root_only_writable $T/own/a" 2>&1); rc=$?
if [[ $EUID -eq 0 ]]; then check "a root-owned, not group/world-writable file passes" '[[ $rc -eq 0 ]]' "$out"; fi
chmod 666 "$T/own/a"
out=$(in_bot "$U" "" "root_only_writable $T/own/a" 2>&1); rc=$?; check "a world-writable file is refused" '[[ $rc -ne 0 ]]' "$out"
chmod 644 "$T/own/a"; chmod 777 "$T/own"
out=$(in_bot "$U" "" "root_only_writable $T/own/a" 2>&1); rc=$?; check "a file in a world-writable directory is refused" '[[ $rc -ne 0 ]]' "$out"
if [[ $EUID -eq 0 ]]; then
  chmod 1777 "$T/own"
  out=$(in_bot "$U" "" "root_only_writable $T/own/a" 2>&1); rc=$?; check "a file in root's sticky world-writable directory (like /tmp) passes" '[[ $rc -eq 0 ]]' "$out"
  chmod 666 "$T/own/a"
  out=$(in_bot "$U" "" "root_only_writable $T/own/a" 2>&1); rc=$?; check "but a world-writable file in it is still refused" '[[ $rc -ne 0 ]]' "$out"
  chmod 644 "$T/own/a"
fi
chmod 755 "$T/own"
if [[ $EUID -ne 0 ]]; then out=$(in_bot "$U" "" "root_only_writable $T/own/a" 2>&1); rc=$?; check "a file not owned by root is refused" '[[ $rc -ne 0 ]]' "$out"; fi

echo "== command lines"
asuser() { "$@"; }
if [[ $EUID -eq 0 ]]; then
  mkdir -p "$T/bin"; cp "$HERE/../ente-setup.sh" "$HERE/../ente-ops.sh" "$HERE/../ente-tg-bot.sh" "$T/bin/"; chmod 755 "$T" "$T/bin" "$T/bin"/*
  asuser() { setpriv --reuid=65534 --regid=65534 --clear-groups "$@"; }
  CLI=$T/bin
else
  CLI=$HERE/..
fi
out=$(asuser bash "$CLI/ente-tg-bot.sh" maybe 2>&1); rc=$?; check "unknown command is a usage error" '[[ $rc -eq 2 && $out == *usage* ]]' "$out"
out=$(asuser bash "$CLI/ente-tg-bot.sh" 2>&1); rc=$?; check "no command is a usage error" '[[ $rc -eq 2 && $out == *usage* ]]' "$out"
out=$(asuser bash "$CLI/ente-tg-bot.sh" action 2>&1); rc=$?; check "action without a name is a usage error" '[[ $rc -eq 2 ]]' "$out"
for c in install uninstall check "action status"; do
  # shellcheck disable=SC2086
  out=$(asuser bash "$CLI/ente-tg-bot.sh" $c 2>&1); check "'$c' is a known command (asks for root here)" '[[ $out == *"run as root"* ]]' "$out"
done

summary
