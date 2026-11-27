#!/usr/bin/env python3
"""opsbot: a Telegram bot through which ONE person runs the fixed actions that services register as plugins. Stdlib only.

It long-polls the Bot API (no open port), accepts only private messages from --user-id, drops messages older than a minute,
and maps each command to one fixed (plugin, action) pair; no text from Telegram ever reaches a shell. Actions run through
--action-cmd (installed as `sudo -n /usr/local/sbin/opsbot-action`, which the sudo rule allows for exactly the registered
pairs, and which checks the pair again against the root-owned plugin files).

A plugin is a JSON file in /etc/opsbot/plugins.d/NAME.json (see README.md):
  {"name": "demo", "exec": ["/bin/bash", "/opt/demo/bot.sh"], "env": {"K": "V"}, "status": "status",
   "commands": [{"command": "backup", "description": "Back up now", "action": "backup"},
                {"command": "proxy", "description": "Proxy state; /proxy on|off", "args": {"": "p-status", "on": "p-on", "off": "p-off"},
                 "usage": "Send /proxy, /proxy on or /proxy off."}],
   "actions": {"status": {}, "backup": {"started": "⏳ Backing up...", "ok": "✅ Backup done", "fail": "❌ Backup failed"}, ...}}
The action name is appended to "exec". An action with "started" runs in the background (one at a time per "lock", default the
action itself); one without is quick: its output is the reply. "status" names a quick action whose output /status shows.

Modes:
  opsbot.py bot --user-id ID --state-dir DIR [--plugins DIR] [--action-cmd CMD] [--token-file FILE] [--api-base URL]
  opsbot.py action PLUGIN ACTION        as root (the sudo helper): run one registered action
  opsbot.py validate FILE [--plugins DIR]   check a plugin file, and that its commands are not taken; prints its name
  opsbot.py sudoers USER HELPER [--plugins DIR]   the sudo rule for every registered action
  opsbot.py list | actions | paths [--plugins DIR]   plugins and commands | "PLUGIN ACTION" lines | the files actions run
"""
import argparse
import http.client
import json
import math
import os
import re
import shlex
import signal
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

PLUGINS_DIR = "/etc/opsbot/plugins.d"
# how the helper starts an action: as a transient unit of its own, so it gets a clean environment and working directory
# (nothing of the bot user's reaches root), survives a restart of the bot, and is stopped after 6 hours
RUN = ["systemd-run", "--quiet", "--wait", "--pipe", "--collect", "-p", "RuntimeMaxSec=21600"]
REBOOT_FLAG = "/var/run/reboot-required"
MAX_TEXT = 4000      # Telegram allows 4096 characters
MAX_AGE = 60         # seconds; older commands are not run (e.g. queued while the bot was down)
NOTICE_EVERY = 3600  # at most one notice per stranger per hour
QUICK_TIMEOUT = 120  # seconds for a quick action (no "started"): /status waits for them
SLOW_TIMEOUT = 6 * 3600

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")    # plugin and action names
CMD_RE = re.compile(r"^[a-z][a-z0-9_]{0,31}$")     # Telegram command names
ARG_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
ENV_RE = re.compile(r"^[A-Z_][A-Z0-9_]{0,63}$")
RESERVED = {"start", "help", "status"}
PLUGIN_KEYS = {"name", "exec", "env", "status", "commands", "actions"}
COMMAND_KEYS = {"command", "description", "action", "args", "usage"}
ACTION_KEYS = {"started", "ok", "fail", "busy", "lock"}


# ---------------------------------------------------------------- plugins
class PluginError(ValueError):
    pass


def _line(v):
    return isinstance(v, str) and v.strip() != "" and "\0" not in v


def check_plugin(doc, name=None):
    """Validate one plugin document (name: the file's, which it must match); returns it. Raises PluginError."""
    def need(cond, msg):
        if not cond:
            raise PluginError(msg)
    need(isinstance(doc, dict), "not a JSON object")
    need(not set(doc) - PLUGIN_KEYS, "unknown keys: %s" % ", ".join(sorted(set(doc) - PLUGIN_KEYS)))
    n = doc.get("name")
    need(isinstance(n, str) and NAME_RE.match(n), "name: lowercase letters, digits and dashes, starting with a letter")
    need(name is None or n == name, "name %r does not match the file name %s.json" % (n, name))
    ex = doc.get("exec")
    need(isinstance(ex, list) and ex and all(_line(x) and "\n" not in x for x in ex), "exec: a list of one-line strings")
    need(ex[0].startswith("/"), "exec: the program must be an absolute path")
    env = doc.get("env", {})
    need(isinstance(env, dict) and all(ENV_RE.match(k) and isinstance(v, str) and "\n" not in v and "\0" not in v
                                       for k, v in env.items()), "env: NAMES (A-Z, 0-9, _) to one-line strings")
    actions = doc.get("actions")
    need(isinstance(actions, dict) and actions, "actions: a non-empty object")
    for a, spec in actions.items():
        need(NAME_RE.match(a), "action %r: lowercase letters, digits and dashes" % a)
        need(isinstance(spec, dict) and not set(spec) - ACTION_KEYS, "action %s: only %s" % (a, ", ".join(sorted(ACTION_KEYS))))
        need(all(_line(v) for v in spec.values()), "action %s: its texts must not be empty" % a)
        need("started" in spec or not {"busy", "lock"} & set(spec), "action %s: busy and lock need started" % a)
        need("lock" not in spec or NAME_RE.match(spec["lock"]), "action %s: lock: lowercase letters, digits and dashes" % a)
    st = doc.get("status")
    need(st is None or (isinstance(st, str) and st in actions and "started" not in actions[st]),
         "status: the name of a quick action (one without started)")
    cmds = doc.get("commands", [])
    need(isinstance(cmds, list), "commands: a list")
    seen = set()
    for c in cmds:
        need(isinstance(c, dict) and not set(c) - COMMAND_KEYS, "commands: objects with only %s" % ", ".join(sorted(COMMAND_KEYS)))
        cn = c.get("command")
        need(isinstance(cn, str) and CMD_RE.match(cn), "command %r: lowercase letters, digits and _" % cn)
        need(cn not in RESERVED, "/%s is the bot's own command" % cn)
        need(cn not in seen, "/%s is listed twice" % cn)
        seen.add(cn)
        need(_line(c.get("description")) and len(c["description"]) <= 256 and "\n" not in c["description"],
             "/%s: description: one line, at most 256 characters" % cn)
        need(("action" in c) != ("args" in c), "/%s: needs either action or args" % cn)
        args = {"": c["action"]} if "action" in c else c["args"]
        need(isinstance(args, dict) and args, "/%s: args: an object of argument -> action" % cn)
        for k, v in args.items():
            need(k == "" or ARG_RE.match(k), "/%s: argument %r: lowercase letters, digits, _ and -" % (cn, k))
            need(isinstance(v, str) and v in actions, "/%s %s: %r is not one of its actions" % (cn, k, v))
        need("usage" not in c or _line(c["usage"]), "/%s: usage must not be empty" % cn)
    need(cmds or st, "a plugin needs commands or a status action")
    return doc


def command_args(c):
    """A command's argument -> action map ("" = no argument)."""
    return {"": c["action"]} if "action" in c else dict(c["args"])


def read_plugin(path):
    with open(path, encoding="utf-8") as f:
        return check_plugin(json.load(f), os.path.basename(path)[:-5])


def load_registry(d, log=None):
    """The plugins in D (NAME.json, by name). With LOG, a broken file or a taken command is logged and skipped (the bot keeps
    serving the rest); without, it raises PluginError."""
    plugins, owner = [], {}
    try:
        names = sorted(f for f in os.listdir(d) if f.endswith(".json"))
    except FileNotFoundError:
        names = []
    for fn in names:
        try:
            p = read_plugin(os.path.join(d, fn))
            for c in p.get("commands", []):
                if c["command"] in owner:
                    raise PluginError("/%s is already %s's" % (c["command"], owner[c["command"]]))
        except (OSError, ValueError) as e:  # PluginError and JSON errors are ValueErrors
            if log is None:
                raise PluginError("%s: %s" % (fn, e)) from None
            log("skipped plugin %s: %s" % (fn, e))
            continue
        for c in p.get("commands", []):
            owner[c["command"]] = p["name"]
        plugins.append(p)
    return plugins


def root_only(path, uid=0, top="/"):
    """Raise PluginError unless PATH and every directory above it (up to TOP; tests stop in their temp dir) are owned by UID
    and not group/world-writable (a sticky directory above it, like /tmp, is fine: others cannot replace root's entries)."""
    real = os.path.realpath(path)
    d = real
    while True:
        st = os.stat(d)
        if st.st_uid != uid:
            raise PluginError("not owned by root: %s" % d)
        if st.st_mode & 0o022 and not (stat.S_ISDIR(st.st_mode) and st.st_mode & stat.S_ISVTX and d != real):
            raise PluginError("group/world-writable: %s" % d)
        if d in ("/", top):
            return
        d = os.path.dirname(d)


def exec_paths(p):
    """The absolute paths in a plugin's exec that exist: the program and its script."""
    return [x for x in p["exec"] if x.startswith("/") and os.path.exists(x)]


# ---------------------------------------------------------------- the root helper
def helper(argv, plugins_dir=PLUGINS_DIR, run=None, uid=0, top="/", out=sys.stderr):
    """`opsbot-action PLUGIN ACTION`, as root: check the pair against the root-owned plugin file again (the sudo rule already
    allows only registered pairs), check that what it runs is root's alone, then run it as a transient unit."""
    run = RUN if run is None else run
    if len(argv) != 2 or not all(NAME_RE.match(a) for a in argv):
        out.write("usage: opsbot-action PLUGIN ACTION\n")
        return 2
    path = os.path.join(plugins_dir, argv[0] + ".json")
    if not os.path.isfile(path):
        out.write("unknown plugin\n")
        return 2
    try:
        root_only(path, uid, top)
        p = read_plugin(path)
        if argv[1] not in p["actions"]:
            out.write("unknown action\n")
            return 2
        for x in exec_paths(p):
            root_only(x, uid, top)
    except (OSError, ValueError) as e:
        out.write("refused: %s\n" % e)
        return 1
    cmd = list(run) + ["--setenv=%s=%s" % kv for kv in sorted(p.get("env", {}).items())] if run else []
    if run:
        cmd.append("--")
    cmd += p["exec"] + [argv[1]]
    if not run and p.get("env"):  # tests run without systemd-run
        os.environ.update(p["env"])
    os.chdir("/")
    os.execvp(cmd[0], cmd)


# ---------------------------------------------------------------- Telegram
class ApiError(Exception):
    pass


class TelegramAPI:
    def __init__(self, base, token, poll_timeout=50):
        self.base, self._token, self.poll_timeout = base.rstrip("/"), token, poll_timeout

    def call(self, method, http_timeout=30, **params):
        req = urllib.request.Request("%s/bot%s/%s" % (self.base, self._token, method), data=json.dumps(params).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=http_timeout) as r:
                doc = json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:  # never include the URL: it holds the token
            try:
                desc = json.loads(e.read() or b"{}").get("description", "")
            except ValueError:
                desc = ""
            raise ApiError("%s: HTTP %d %s" % (method, e.code, desc)) from None
        except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as e:  # incl. a cut-off response
            raise ApiError("%s: %s" % (method, getattr(e, "reason", None) or type(e).__name__)) from None
        if not doc.get("ok"):
            raise ApiError("%s: %s" % (method, doc.get("description", "not ok")))
        return doc.get("result")


class CommandRunner:
    """Runs PREFIX + [plugin, action] and returns (exit code, output)."""
    def __init__(self, prefix):
        self.prefix = list(prefix)

    def __call__(self, plugin, action, timeout=SLOW_TIMEOUT):
        if not (NAME_RE.match(plugin) and NAME_RE.match(action)):
            raise ValueError("bad plugin or action name")
        try:
            p = subprocess.run(self.prefix + [plugin, action], capture_output=True, text=True, timeout=timeout,
                               stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return 124, "timed out after %d s" % timeout
        except OSError as e:
            return 127, "could not run the action: %s" % e
        return p.returncode, (p.stdout + p.stderr).strip()


def fit(text):
    """Cut long output to fit one message, keeping the end (verdicts are last)."""
    text = text.strip() or "(no output)"
    return text if len(text) <= MAX_TEXT else "…(cut)\n" + text[-(MAX_TEXT - 8):]


def dur(s):
    """45 s, 12 min, 5 h, 3 days."""
    s = int(s)
    if s < 120:
        return "%d s" % s
    if s < 7200:
        return "%d min" % (s // 60)
    if s < 172800:
        return "%d h" % (s // 3600)
    return "%d days" % (s // 86400)


def human(n):
    """Bytes the way df -h shows them: 17G, 5.2G, 980M."""
    for unit in "KMGTP":
        n /= 1024.0
        if n < 1024 or unit == "P":
            return ("%.1f%s" % (n, unit)) if n < 10 else ("%d%s" % (round(n), unit))


def system_line(reboot_flag=REBOOT_FLAG):
    """🖥 Disk 26% used (17G free) · RAM 1408 MB free · up 12 min[ · reboot pending]."""
    parts = []
    try:
        v = os.statvfs("/")
        used, avail = (v.f_blocks - v.f_bfree) * v.f_frsize, v.f_bavail * v.f_frsize
        parts.append("Disk %d%% used (%s free)" % (math.ceil(used * 100 / max(used + avail, 1)), human(avail)))
    except OSError:
        pass
    try:
        with open("/proc/meminfo") as f:
            kb = next(int(line.split()[1]) for line in f if line.startswith("MemAvailable:"))
        parts.append("RAM %d MB free" % (kb // 1024))
    except (OSError, StopIteration, ValueError):
        pass
    try:
        with open("/proc/uptime") as f:
            parts.append("up %s" % dur(float(f.read().split()[0])))
    except (OSError, ValueError, IndexError):
        pass
    if os.path.exists(reboot_flag):
        parts.append("reboot pending")
    return "🖥 " + " · ".join(parts)


# ---------------------------------------------------------------- the bot
class Bot:
    def __init__(self, api, user_id, runner, state_dir, plugins_dir=PLUGINS_DIR, log=sys.stdout, max_age=MAX_AGE,
                 reboot_flag=REBOOT_FLAG):
        self.api, self.user_id, self.runner, self.max_age, self._log = api, int(user_id), runner, max_age, log
        self.plugins_dir, self.reboot_flag = plugins_dir, reboot_flag
        self.offset_file = os.path.join(state_dir, "offset")
        try:
            with open(self.offset_file) as f:
                self.offset = int(f.read().strip())
        except (OSError, ValueError):
            self.offset = 0
        self._locks, self._locks_guard = {}, threading.Lock()
        self.noticed = {}
        self.reload_pending = False
        self.load_plugins()

    # ---- plumbing
    def log(self, msg):
        self._log.write("%s %s\n" % (time.strftime("%F %T"), msg))
        self._log.flush()

    def send(self, text, chat=None):
        try:
            self.api.call("sendMessage", chat_id=chat or self.user_id, text=fit(text), disable_web_page_preview=True)
        except ApiError as e:
            self.log("could not send a reply: %s" % e)

    def save_offset(self):
        tmp = self.offset_file + ".tmp"
        with open(tmp, "w") as f:
            f.write(str(self.offset))
        os.replace(tmp, self.offset_file)

    def lock(self, key):
        with self._locks_guard:
            return self._locks.setdefault(key, threading.Lock())

    def load_plugins(self):
        self.plugins = load_registry(self.plugins_dir, self.log)
        self.commands = {c["command"]: (p, c) for p in self.plugins for c in p.get("commands", [])}
        self.log("plugins: %s" % (", ".join(p["name"] for p in self.plugins) or "none"))

    def menu(self):
        return [("status", "Quick overview")] + [(n, c["description"]) for n, (_, c) in self.commands.items()]

    def help_text(self):
        return "Available actions:\n" + "\n".join("/%s – %s" % (n, d) for n, d in self.menu())

    def register_commands(self):
        self.api.call("setMyCommands", commands=[{"command": c, "description": d} for c, d in self.menu()],
                      scope={"type": "chat", "chat_id": self.user_id})

    def run_once(self):
        if self.reload_pending:
            self.reload_pending = False
            self.load_plugins()
            try:
                self.register_commands()
            except ApiError as e:
                self.log("could not register the command menu: %s" % e)
        updates = self.api.call("getUpdates", http_timeout=self.api.poll_timeout + 15, offset=self.offset,
                                timeout=self.api.poll_timeout, allowed_updates=["message"])
        for u in updates or []:
            self.offset = max(self.offset, u["update_id"] + 1)
            self.save_offset()  # before handling: a crash never makes a command run twice
            try:
                self.handle(u)
            except Exception as e:  # noqa: BLE001 - one bad update must not stop the bot
                self.log("error handling update %s: %s" % (u.get("update_id"), type(e).__name__))

    def serve_forever(self):
        delay = 1
        while True:
            try:
                self.run_once()
                delay = 1
            except ApiError as e:
                self.log("Telegram API: %s (retrying in %d s)" % (e, delay))
                time.sleep(delay)
                delay = min(delay * 2, 60)
            except Exception as e:  # noqa: BLE001 - never exit: a restart would lose replies of running actions
                self.log("unexpected %s (retrying in %d s)" % (type(e).__name__, delay))
                time.sleep(delay)
                delay = min(delay * 2, 60)

    # ---- one update
    def handle(self, u):
        m = u.get("message")
        if not m:
            self.log("ignored update %s (not a new message)" % u.get("update_id"))
            return
        sender, chat = m.get("from") or {}, m.get("chat") or {}
        text = (m.get("text") or "").strip()
        who = "id %s%s" % (sender.get("id"), " (@%s)" % sender["username"] if sender.get("username") else "")
        if (sender.get("is_bot") or sender.get("id") != self.user_id or chat.get("id") != self.user_id
                or chat.get("type") != "private"):
            self.log("ignored message from %s in %s chat %s: %r" % (who, chat.get("type"), chat.get("id"), text[:40]))
            self.notice(sender, text)
            return
        age = time.time() - int(m.get("date") or 0)
        if age > self.max_age:
            self.log("ignored %r: too old (%d s)" % (text[:40], age))
            self.send("⏰ Skipped %s: it was sent %d s ago, while offline. Send again."
                      % (text[:40] or "your message", age))
            return
        self.command(text)

    def notice(self, sender, text):
        sid = sender.get("id")
        if sid is None or sid == self.user_id or sender.get("is_bot"):
            return
        now = time.time()
        if now - self.noticed.get(sid, 0) < NOTICE_EVERY:
            return
        self.noticed[sid] = now
        name = " ".join(x for x in (sender.get("first_name"), sender.get("last_name")) if x)
        self.send("🚫 Someone else wrote, ignored: %s%s (id %s): %r" % (
            name or "no name", " @%s" % sender["username"] if sender.get("username") else "", sid, text[:60]))

    def command(self, text):
        words = text.split()
        if not words or not words[0].startswith("/"):
            self.send(self.help_text())
            return
        cmd, args = words[0][1:].split("@", 1)[0].lower(), [a.lower() for a in words[1:]]
        if cmd == "status":
            if args:
                self.send("/status takes nothing after it. Just send /status.")
                return
            self.log("accepted /status")
            self.send(self.status())
            return
        if cmd not in self.commands:  # also /start and /help
            self.send(self.help_text())
            return
        plugin, spec = self.commands[cmd]
        amap = command_args(spec)
        key = "" if not args else (args[0] if len(args) == 1 else None)
        if key not in amap:
            if spec.get("usage"):
                self.send(spec["usage"])
            elif list(amap) == [""]:
                self.send("/%s takes nothing after it. Just send /%s." % (cmd, cmd))
            else:
                self.send("Send " + ", ".join("/%s%s" % (cmd, " " + k if k else "") for k in amap) + ".")
            return
        action = amap[key]
        a = plugin["actions"][action]
        self.log("accepted /%s%s (%s %s)" % (cmd, " " + key if key else "", plugin["name"], action))
        if "started" not in a:
            rc, out = self.runner(plugin["name"], action, timeout=QUICK_TIMEOUT)
            title = a.get("ok") if rc == 0 else a.get("fail", "❌ /%s failed" % cmd)
            self.send("%s\n%s" % (title, out) if title and out else (title or out))
            return
        lock = self.lock("%s:%s" % (plugin["name"], a.get("lock", action)))
        if not lock.acquire(blocking=False):
            self.send(a.get("busy", "⏳ /%s is already running." % cmd))
            return
        self.send(a["started"])
        threading.Thread(target=self._run_async, args=(plugin["name"], action, a, cmd, lock), daemon=True).start()

    def _run_async(self, plugin, action, a, cmd, lock):
        try:
            rc, out = self.runner(plugin, action)
            title = a.get("ok", "✅ /%s done" % cmd) if rc == 0 else a.get("fail", "❌ /%s failed" % cmd)
            self.send("%s\n%s" % (title, out) if out else title)
            self.log("%s %s finished, exit %d" % (plugin, action, rc))
        finally:
            lock.release()

    def status(self):
        """Each plugin's status lines (in plugin order), then the system line."""
        lines = []
        for p in self.plugins:
            if not p.get("status"):
                continue
            rc, out = self.runner(p["name"], p["status"], timeout=QUICK_TIMEOUT)
            if rc == 0:
                lines.append(out)
            else:
                lines.append("❌ %s: no status (%s)" % (p["name"], (out.splitlines() or ["no output"])[-1][:200]))
        lines.append(system_line(self.reboot_flag))
        return "\n".join(x for x in lines if x)


# ---------------------------------------------------------------- command line
def main_bot(a):
    if a.user_id <= 0:
        sys.exit("--user-id must be a person's id (a positive number)")
    with open(a.token_file) as f:
        token = f.read().strip()
    bot = Bot(TelegramAPI(a.api_base, token, a.poll_timeout), a.user_id, CommandRunner(shlex.split(a.action_cmd)),
              a.state_dir, plugins_dir=a.plugins)
    bot.log("opsbot started for user %d" % a.user_id)
    signal.signal(signal.SIGHUP, lambda *_: setattr(bot, "reload_pending", True))  # opsbot.sh plugin add/remove

    def register():  # in the background: the bot must answer at once, whatever setMyCommands does
        for i in range(10):
            try:
                bot.register_commands()
                return
            except ApiError as e:
                bot.log("could not register the command menu: %s" % e)
                time.sleep(min(2 ** i, 60))
    threading.Thread(target=register, daemon=True).start()
    bot.serve_forever()


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["action"]:  # the root helper: no argparse (its messages), exact arguments only
        sys.exit(helper(argv[1:]))
    p = argparse.ArgumentParser(prog="opsbot")
    sub = p.add_subparsers(dest="mode", required=True)
    b = sub.add_parser("bot")
    b.add_argument("--user-id", type=int, required=True)
    b.add_argument("--state-dir", required=True)
    b.add_argument("--plugins", default=PLUGINS_DIR)
    b.add_argument("--action-cmd", default="sudo -n /usr/local/sbin/opsbot-action",
                   help="command prefix; the plugin and action names are appended")
    b.add_argument("--token-file", default=os.path.join(os.environ.get("CREDENTIALS_DIRECTORY", "/nonexistent"), "token"))
    b.add_argument("--api-base", default="https://api.telegram.org")
    b.add_argument("--poll-timeout", type=int, default=50)
    v = sub.add_parser("validate")
    v.add_argument("file")
    s = sub.add_parser("sudoers")
    s.add_argument("user")
    s.add_argument("helper")
    for name in ("list", "actions", "paths"):
        sub.add_parser(name)
    for x in (b, v, s) + tuple(sub.choices[n] for n in ("list", "actions", "paths")):
        if x is not b:
            x.add_argument("--plugins", default=PLUGINS_DIR)
    a = p.parse_args(argv)
    if a.mode == "bot":
        return main_bot(a)
    try:
        if a.mode == "validate":
            new = read_plugin(a.file) if a.file.endswith(".json") else None
            if new is None:
                raise PluginError("the file name must be NAME.json")
            others = [x for x in load_registry(a.plugins) if x["name"] != new["name"]]
            taken = {c["command"]: x["name"] for x in others for c in x.get("commands", [])}
            for c in new.get("commands", []):
                if c["command"] in taken:
                    raise PluginError("/%s is already %s's" % (c["command"], taken[c["command"]]))
            print(new["name"])
            return 0
        plugins = load_registry(a.plugins)
    except (OSError, ValueError) as e:
        print("opsbot: %s" % e, file=sys.stderr)
        return 1
    if a.mode == "sudoers":
        rules = ["%s %s %s" % (a.helper, x["name"], act) for x in plugins for act in x["actions"]]
        print("# Managed by opsbot.sh: the bot may run exactly these, as root, without a password.")
        if rules:
            print("%s ALL=(root) NOPASSWD: %s" % (a.user, ", ".join(rules)))
    elif a.mode == "actions":
        for x in plugins:
            for act in x["actions"]:
                print(x["name"], act)
    elif a.mode == "paths":
        for x in plugins:
            for path in exec_paths(x):
                print(path)
    else:
        for x in plugins:
            cmds = " ".join("/" + c["command"] for c in x.get("commands", []))
            print("%s: %s%s" % (x["name"], cmds, " (+ /status)" if x.get("status") else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
