# opsbot

A Telegram bot through which **one** person runs fixed actions on a server, and notifications that any script or systemd
unit can send. It knows nothing about the services it serves: each one registers its commands as a **plugin**. Independent of
Ente; Ente's alerts and its bot commands (`../ente-server`) are built on it.

Needs: Debian with systemd, bash, python3 (stdlib only), sudo, curl. No open port: it long-polls Telegram.

| File | Purpose |
| --- | --- |
| `opsbot.sh` | install / uninstall / status / check, and `plugin add|remove|list` (installed as `/usr/local/sbin/opsbot`) |
| `opsbot.py` | the bot, the root helper and the plugin checks (installed in `/usr/local/lib/opsbot/`) |
| `tests/` | its tests (see "Tests") |

## Install

1. In Telegram: @BotFather → `/newbot` → copy the token. Open your bot and press **Start** (for a group: add the bot to it).
2. Your user id: ask @userinfobot. For a private chat the chat id is the same number.
3. As root:
   ```
   OPSBOT_TOKEN=123456:ABC... OPSBOT_USER_ID=<your id> ./opsbot.sh install
   ```
   - `OPSBOT_USER_ID`: the **one** person the bot obeys. Leave it out for notifications only (no bot).
   - `OPSBOT_CHAT_ID`: where notifications go (default: your user id; a group starts with `-100`).
   - A re-run keeps the stored values for those not given; `OPSBOT_USER_ID=` (empty) removes the bot, notifications stay.
   - It checks the token and, when the token or chat changes, sends a test message (and stops if that fails).

`sudo opsbot check` runs its checks (OK/FAIL lines; other services' checks include it). `sudo opsbot uninstall` removes
everything, registered plugins included.

## Notifications

- `opsbot-notify "Title" < body`: one message, the title and the end of the body (it fits Telegram's 4096 characters). Needs root
  (it reads the token). Exit status: whether Telegram took it.
- In any systemd unit, `OnFailure=opsbot-alert@%n.service`: when the unit fails, "❌ <unit> failed on <host>" with the lines of
  its log that say why (`ERROR` or `FAIL`; `  FAIL  x` is shown as `❌ x`), else the end of its log.
- `opsbot-notify-unit UNIT [TITLE] [PATTERN]`: the same with your own title and which lines say why (an extended regex). A
  service with its own titles wraps it in a template unit of its own (Ente's `ente-alert@` does).

## Plugins

A plugin is a JSON file. `sudo opsbot plugin add NAME.json` checks it, copies it to `/etc/opsbot/plugins.d/`, regenerates the
sudo rule and makes the bot reload its commands (within a minute). `plugin remove NAME` undoes it; `plugin list` names them. A
broken plugin file (say, edited by hand) is left out by the bot and the sudo rule, so the others keep working; `check` reports it.

```json
{
  "name": "demo",
  "exec": ["/usr/bin/env", "DEMO_CONFIG=/etc/demo.conf", "/bin/bash", "/opt/demo/bot-actions.sh"],
  "root_files": ["/opt/demo/lib.sh", "/etc/demo.conf"],
  "commands": [
    {"command": "backup", "description": "Back up now", "action": "backup"},
    {"command": "proxy", "description": "Proxy: state, /proxy on, /proxy off",
     "args": {"": "proxy-status", "on": "proxy-on", "off": "proxy-off"}}
  ],
  "actions": {
    "status": {},
    "backup": {"started": "⏳ Backing up...", "ok": "✅ Backup done", "fail": "❌ Backup failed"},
    "proxy-status": {"ok": "🔀 Proxy"},
    "proxy-on": {"ok": "✅ Proxy is on"},
    "proxy-off": {"ok": "✅ Proxy is off"}
  }
}
```

- `name`: the file name (`demo.json`); lowercase letters, digits and dashes.
- `exec`: what runs, as root, exactly as written, from `/` with a clean environment (pass variables with `/usr/bin/env` as
  above); the action name is appended. The program is an absolute path; no `$` and no `..` anywhere. Every absolute path in it
  must exist and be root's alone: the file, every folder above it and every symlink on the way (and where they lead) owned by
  root and not writable by others, so nobody else can change what runs. `plugin add` refuses otherwise, and the helper checks
  again before every action.
- `root_files` (optional): the other files the program sources or runs as root, checked the same way before every action.
  One that is missing (say, a secrets file deleted after setup) is fine if its folder is root's alone: nobody else can create it.
- `actions`: what each action says. A command's action runs in the background: the bot replies `started` at once (default
  "⏳ /cmd..."), then `ok` or `fail` (defaults "✅ /cmd done", "❌ /cmd failed") with its output. One command runs one at a
  time (whatever its argument). The action named `status`, if any, is the plugin's part of `/status`: its output, each
  plugin's in turn (at most 2 minutes each), then a system line ("🖥 Disk 26% used (17G free) · RAM 1408 MB free · up 5 days
  · reboot pending").
- `commands`: the Telegram commands (lowercase letters, digits, `_`), each with a `description` (the menu) and either one
  `action` or `args` (argument → action, `""` for none). Anything else after a command is refused, with what to send instead.
  `/status`, `/start` and `/help` are the bot's own; two plugins cannot have the same command.

## Security

- The bot runs as its own unprivileged user `opsbot`, acts only on private messages from the one user id (anything
  else is ignored and logged, never answered), does not run commands older than a minute (sent while it was down), and
  maps each command to a fixed plugin action: no text from Telegram reaches a shell.
- As root it may run exactly `/usr/local/sbin/opsbot-action PLUGIN ACTION` for the registered pairs (`/etc/sudoers.d/opsbot`
  lists each). The helper reads the root-owned plugin file again, refuses a pair it does not list or files others could
  change, and runs the action as a transient systemd unit: from `/`, with a clean environment, stopped after 6 hours, and it
  keeps running if the bot restarts.
- The token is in `/etc/opsbot/token` (mode 600): the bot gets it as a systemd credential, curl on stdin; never on a command line.
- Anyone who controls your Telegram account can use the bot: turn on Telegram's two-step verification.

## Tests

| Command | Where | What |
| --- | --- | --- |
| `python3 -m unittest discover -s tests -v` | anywhere (stdlib) | the bot against a fake Telegram with a demo plugin (every reply, strangers, locks, reloads), plugin validation, the registry, the root helper, the sudo rule |
| `bash tests/test_opsbot_cli.sh` | anywhere (all paths moved into a temp dir) | `install` (config checks, notifications only, the bot, re-runs), `plugin add/remove/list`, the checks, the notification scripts against a fake Telegram, the command line |
| `sudo bash tests/opsbot_e2e.sh` | a server with opsbot installed with a bot | a test plugin through the real sudo rule and helper, a second bot instance against a fake Telegram (every kind of reply, reloads, strangers), planted Python modules, files others could change, an action outliving the bot; leaves opsbot as it was |

`tests/fake_telegram.py` is a fake Bot API on 127.0.0.1 for these and for the tests of services that use opsbot.
