#!/usr/bin/env python3
"""opsbot: a Telegram bot through which ONE person runs the actions services register as plugins. Stdlib only; see README.md.

  opsbot.py bot --user-id ID --state-dir DIR [--plugins DIR] [--action-cmd CMD] [--token-file FILE] [--api-base URL]
  opsbot.py action PLUGIN ACTION                  as root (the sudo helper): run one registered action
  opsbot.py validate FILE [--plugins DIR]         check a plugin file before it is registered; prints its name
  opsbot.py sudoers USER HELPER [--plugins DIR]   the sudo rule for every registered action
  opsbot.py root-only PATH... [--plugins DIR]     check the PATHs, the plugin files and what they run are root's alone
"""
import argparse
import http.client
import json
import math
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

# module settings, which the tests change
PLUGINS_DIR = "/etc/opsbot/plugins.d"
TRUSTED_UIDS = {0}        # who may own what root runs
ACTION_TIMEOUT = 6 * 3600
# the helper runs an action as a transient unit of its own: a clean environment and working directory (nothing of the bot
# user's reaches root), it outlives a restart of the bot, and it is stopped after ACTION_TIMEOUT
RUN = ["systemd-run", "--quiet", "--wait", "--pipe", "--collect", "-p", "RuntimeMaxSec=%d" % ACTION_TIMEOUT, "--"]
REBOOT_FLAG = "/var/run/reboot-required"
MAX_TEXT = 4000           # Telegram allows 4096 characters
MAX_AGE = 60              # seconds; older commands are not run (e.g. queued while the bot was down)
STATUS_TIMEOUT = 120      # seconds /status waits for each plugin's status action
RELOAD = threading.Event()  # set by SIGHUP (opsbot.sh plugin add/remove): re-read the plugins and the menu

# used with fullmatch (a ^...$ match would let a trailing newline through)
NAME_RE = re.compile(r"[a-z][a-z0-9-]{0,31}")    # plugin and action names
CMD_RE = re.compile(r"[a-z][a-z0-9_]{0,31}")     # Telegram command names
ARG_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,31}")
RESERVED = {"start", "help", "status"}
PLUGIN_KEYS = {"name", "exec", "root_files", "commands", "actions"}
COMMAND_KEYS = {"command", "description", "action", "args"}
ACTION_KEYS = {"started", "ok", "fail"}


# ---------------------------------------------------------------- plugins
class PluginError(ValueError):
    pass


def _line(v):
    return isinstance(v, str) and v.strip() != "" and "\0" not in v and "\n" not in v


def check_plugin(doc, name=None):
    """Validate one plugin document (NAME: the file's, which it must match); returns it. Raises PluginError."""
    def need(cond, msg):
        if not cond:
            raise PluginError(msg)
    need(isinstance(doc, dict), "not a JSON object")
    need(not set(doc) - PLUGIN_KEYS, "unknown keys: %s" % ", ".join(sorted(set(doc) - PLUGIN_KEYS)))
    n = doc.get("name")
    need(isinstance(n, str) and NAME_RE.fullmatch(n), "name: lowercase letters, digits and dashes, starting with a letter")
    need(name is None or n == name, "name %r does not match the file name %s.json" % (n, name))
    ex = doc.get("exec")
    need(isinstance(ex, list) and ex and all(_line(x) for x in ex), "exec: a list of one-line strings")
    need(ex[0].startswith("/"), "exec: the program must be an absolute path")
    # systemd-run would expand ${VAR}; a path with ".." resolves differently through a symlink than it reads: what runs must be
    # exactly what was checked
    need(not any("$" in x for x in ex), "exec: no $ (it would be expanded)")
    rf = doc.get("root_files", [])
    need(isinstance(rf, list) and all(_line(x) and x.startswith("/") for x in rf), "root_files: a list of absolute paths")
    need(all(os.path.normpath(x) == x for x in ex + rf if x.startswith("/")), "paths without .., // or a trailing /")
    actions = doc.get("actions")
    need(isinstance(actions, dict) and actions, "actions: a non-empty object")
    for a, spec in actions.items():
        need(NAME_RE.fullmatch(a), "action %r: lowercase letters, digits and dashes" % a)
        need(isinstance(spec, dict) and not set(spec) - ACTION_KEYS, "action %s: only %s" % (a, ", ".join(sorted(ACTION_KEYS))))
        need(all(_line(v) for v in spec.values()), "action %s: its texts must be one non-empty line" % a)
    cmds = doc.get("commands", [])
    need(isinstance(cmds, list), "commands: a list")
    seen = set()
    for c in cmds:
        need(isinstance(c, dict) and not set(c) - COMMAND_KEYS, "commands: objects with only %s" % ", ".join(sorted(COMMAND_KEYS)))
        cn = c.get("command")
        need(isinstance(cn, str) and CMD_RE.fullmatch(cn), "command %r: lowercase letters, digits and _" % cn)
        need(cn not in RESERVED, "/%s is the bot's own command" % cn)
        need(cn not in seen, "/%s is listed twice" % cn)
        seen.add(cn)
        need(_line(c.get("description")) and len(c["description"]) <= 256, "/%s: description: one line, at most 256 characters" % cn)
        need(("action" in c) != ("args" in c), "/%s: needs either action or args" % cn)
        args = command_args(c)
        need(isinstance(args, dict) and args, "/%s: args: an object of argument -> action" % cn)
        for k, v in args.items():
            need(k == "" or ARG_RE.fullmatch(k), "/%s: argument %r: lowercase letters, digits, _ and -" % (cn, k))
            need(isinstance(v, str) and v in actions, "/%s %s: %r is not one of its actions" % (cn, k, v))
    need(cmds or "status" in actions, "a plugin needs commands or a status action")
    return doc


def command_args(c):
    """A command's argument -> action map ("" = no argument)."""
    return {"": c["action"]} if "action" in c else c["args"]


def read_plugin(path):
    with open(path, encoding="utf-8") as f:
        return check_plugin(json.load(f), os.path.basename(path)[:-5])


def load_registry(d, log, extra=None):
    """The plugins in D (NAME.json, by name), then the file EXTRA in place of the registered one of its name. A broken file or
    a command an earlier plugin has is LOGged ("skipped plugin NAME.json: why") and left out: the others keep working."""
    plugins, owner = [], {}
    try:
        names = sorted(f for f in os.listdir(d) if f.endswith(".json") and not (extra and f == os.path.basename(extra)))
    except FileNotFoundError:
        names = []
    for path in [os.path.join(d, f) for f in names] + ([extra] if extra else []):
        fn = os.path.basename(path)
        try:
            p = read_plugin(path)
            for c in p.get("commands", []):
                if c["command"] in owner:
                    raise PluginError("/%s is already %s's" % (c["command"], owner[c["command"]]))
        except (OSError, ValueError) as e:  # PluginError and JSON errors are ValueErrors
            log("skipped plugin %s: %s" % (fn, e))
            continue
        owner.update((c["command"], p["name"]) for c in p.get("commands", []))
        plugins.append(p)
    return plugins


def root_only(path):
    """Raise PluginError unless only root can change what PATH runs: every component of the path as written (symlinks
    included, not followed) and of where it leads is owned by a TRUSTED_UID and not group/world-writable. A sticky directory
    above it, like /tmp, is fine: others cannot replace root's entries in it."""
    for p in (path, os.path.realpath(path)):
        d = p
        while True:
            try:
                st = os.lstat(d)
            except FileNotFoundError:
                raise PluginError("not found: %s" % d) from None
            if st.st_uid not in TRUSTED_UIDS:
                raise PluginError("not owned by root: %s" % d)
            if (not stat.S_ISLNK(st.st_mode) and st.st_mode & 0o022  # a link's own mode means nothing
                    and not (stat.S_ISDIR(st.st_mode) and st.st_mode & stat.S_ISVTX and d != p)):
                raise PluginError("group/world-writable: %s" % d)
            if d == "/":
                break
            d = os.path.dirname(d)


def check_root_paths(p):
    """Raise PluginError unless what plugin P runs as root is root's alone: the absolute paths in its exec (which must exist)
    and its root_files, the files its program sources or runs (one that is missing, such as a deleted secrets file, is fine
    when its folder is root's alone: nobody else can create it)."""
    for x in p["exec"]:
        if x.startswith("/"):
            root_only(x)
    for x in p.get("root_files", []):
        root_only(x if os.path.lexists(x) else os.path.dirname(x))


# ---------------------------------------------------------------- the root helper
def helper(argv):
    """`opsbot-action PLUGIN ACTION`, as root: check the pair against the root-owned plugin file again (the sudo rule already
    allows only registered pairs) and that what it runs is root's alone (so nobody else can change it after the check), then
    run it, exactly as written, as a transient unit."""
    if len(argv) != 2 or not all(NAME_RE.fullmatch(a) for a in argv):
        sys.stderr.write("usage: opsbot-action PLUGIN ACTION\n")
        return 2
    path = os.path.join(PLUGINS_DIR, argv[0] + ".json")
    try:
        root_only(path)
        p = read_plugin(path)
        if argv[1] not in p["actions"]:
            sys.stderr.write("unknown action\n")
            return 2
        check_root_paths(p)
    except (OSError, ValueError) as e:
        sys.stderr.write("refused: %s\n" % e)
        return 1
    cmd = RUN + p["exec"] + [argv[1]]
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

    def __call__(self, plugin, action, timeout=ACTION_TIMEOUT):
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


def system_line():
    """🖥 Disk 26% used (17G free) · RAM 1408 MB free · up 12 min[ · reboot pending]; what cannot be read is left out."""
    parts = []
    try:
        d = shutil.disk_usage("/")
        parts.append("Disk %d%% used (%s free)" % (math.ceil(d.used * 100 / max(d.used + d.free, 1)), human(d.free)))
        with open("/proc/meminfo") as f:
            parts.append("RAM %d MB free" % (next(int(x.split()[1]) for x in f if x.startswith("MemAvailable:")) // 1024))
        with open("/proc/uptime") as f:
            parts.append("up " + dur(float(f.read().split()[0])))
    except (OSError, StopIteration, ValueError, IndexError):
        pass
    if os.path.exists(REBOOT_FLAG):
        parts.append("reboot pending")
    return "🖥 " + " · ".join(parts)


# ---------------------------------------------------------------- the bot
class Bot:
    def __init__(self, api, user_id, runner, state_dir, log=sys.stdout):
        self.api, self.user_id, self.runner, self._log = api, int(user_id), runner, log
        self.offset_file = os.path.join(state_dir, "offset")
        try:
            with open(self.offset_file) as f:
                self.offset = int(f.read().strip())
        except (OSError, ValueError):
            self.offset = 0
        self.busy = set()  # the commands running now: each runs one at a time
        self.load_plugins()

    # ---- plumbing
    def log(self, msg):
        self._log.write("%s %s\n" % (time.strftime("%F %T"), msg))
        self._log.flush()

    def send(self, text):
        try:
            self.api.call("sendMessage", chat_id=self.user_id, text=fit(text), disable_web_page_preview=True)
        except ApiError as e:
            self.log("could not send a reply: %s" % e)

    def save_offset(self):
        tmp = self.offset_file + ".tmp"
        with open(tmp, "w") as f:
            f.write(str(self.offset))
        os.replace(tmp, self.offset_file)

    def load_plugins(self):
        self.plugins = load_registry(PLUGINS_DIR, self.log)
        # /status is the bot's own: each plugin's status action, then the system line
        self.commands = {"status": (None, {"description": "Quick overview", "action": "status"})}
        self.commands.update((c["command"], (p, c)) for p in self.plugins for c in p.get("commands", []))
        self.menu_due = True  # the command menu follows (setMyCommands, retried each poll until it works)
        self.log("plugins: %s" % (", ".join(p["name"] for p in self.plugins) or "none"))

    def menu(self):
        return [(n, c["description"]) for n, (_, c) in self.commands.items()]

    def help_text(self):
        return "Available actions:\n" + "\n".join("/%s – %s" % (n, d) for n, d in self.menu())

    def register_commands(self):
        self.api.call("setMyCommands", commands=[{"command": c, "description": d} for c, d in self.menu()],
                      scope={"type": "chat", "chat_id": self.user_id})
        self.menu_due = False

    def run_once(self):
        if RELOAD.is_set():
            RELOAD.clear()
            self.load_plugins()
        if self.menu_due:
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
            except Exception as e:  # noqa: BLE001 - never exit: a restart would lose replies of running actions
                what = "Telegram API: %s" % e if isinstance(e, ApiError) else "unexpected " + type(e).__name__
                self.log("%s (retrying in %d s)" % (what, delay))
                time.sleep(delay)
                delay = min(delay * 2, 60)

    # ---- one update
    def handle(self, u):
        m = u.get("message") or {}
        sender, chat = m.get("from") or {}, m.get("chat") or {}
        text = (m.get("text") or "").strip()
        if (sender.get("is_bot") or sender.get("id") != self.user_id or chat.get("id") != self.user_id
                or chat.get("type") != "private"):
            self.log("ignored update %s from id %s in %s chat %s: %r" % (
                u.get("update_id"), sender.get("id"), chat.get("type"), chat.get("id"), text[:40]))
            return
        age = time.time() - int(m.get("date") or 0)
        if age > MAX_AGE:
            self.log("ignored %r: too old (%d s)" % (text[:40], age))
            self.send("⏰ Skipped %s: it was sent %d s ago, while offline. Send again." % (text[:40] or "your message", age))
            return
        self.command(text)

    def command(self, text):
        words = text.split()
        if not words or not words[0].startswith("/"):
            self.send(self.help_text())
            return
        cmd, key = words[0][1:].split("@", 1)[0].lower(), " ".join(words[1:]).lower()  # an argument never holds a space
        if cmd not in self.commands:  # also /start and /help
            self.send(self.help_text())
            return
        plugin, spec = self.commands[cmd]
        amap = command_args(spec)
        if key not in amap:
            self.send("Send " + ", ".join("/%s%s" % (cmd, " " + k if k else "") for k in amap) + ".")
            return
        self.log("accepted /%s%s" % (cmd, " " + key if key else ""))
        if cmd in self.busy:
            self.send("⏳ /%s is already running." % cmd)
            return
        self.busy.add(cmd)
        if plugin is None:
            work = self.status
        else:
            a = plugin["actions"][amap[key]]
            self.send(a.get("started", "⏳ /%s..." % cmd))
            work = lambda: self._result(plugin["name"], amap[key], a, cmd)  # noqa: E731
        threading.Thread(target=self._run, args=(cmd, work), daemon=True).start()

    def _run(self, cmd, work):
        try:
            self.send(work())
        finally:
            self.busy.discard(cmd)

    def _result(self, plugin, action, a, cmd):
        rc, out = self.runner(plugin, action)
        self.log("%s %s finished, exit %d" % (plugin, action, rc))
        title = a.get("ok", "✅ /%s done" % cmd) if rc == 0 else a.get("fail", "❌ /%s failed" % cmd)
        return "%s\n%s" % (title, out) if out else title

    def status(self):
        """Each plugin's status action's output (in plugin order), then the system line."""
        lines = []
        for p in self.plugins:
            if "status" not in p["actions"]:
                continue
            rc, out = self.runner(p["name"], "status", timeout=STATUS_TIMEOUT)
            lines.append(out if rc == 0 else "❌ %s: no status (%s)" % (p["name"], (out.splitlines() or ["no output"])[-1][:200]))
        lines.append(system_line())
        return "\n".join(x for x in lines if x)


# ---------------------------------------------------------------- command line
def main(argv=None):
    global PLUGINS_DIR  # --plugins sets it for the bot
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["action"]:  # the root helper: no argparse (its messages), exact arguments only
        sys.exit(helper(argv[1:]))
    signal.signal(signal.SIGHUP, lambda *_: RELOAD.set())  # first: a reload during startup must not kill the bot
    reg = argparse.ArgumentParser(add_help=False)
    reg.add_argument("--plugins", default=PLUGINS_DIR)
    p = argparse.ArgumentParser(prog="opsbot")
    sub = p.add_subparsers(dest="mode", required=True)
    b = sub.add_parser("bot", parents=[reg])
    b.add_argument("--user-id", type=int, required=True)
    b.add_argument("--state-dir", required=True)
    b.add_argument("--action-cmd", default="sudo -n /usr/local/sbin/opsbot-action",
                   help="command prefix; the plugin and action names are appended")
    b.add_argument("--token-file", default=os.path.join(os.environ.get("CREDENTIALS_DIRECTORY", "/nonexistent"), "token"))
    b.add_argument("--api-base", default="https://api.telegram.org")
    b.add_argument("--poll-timeout", type=int, default=50)
    sub.add_parser("validate", parents=[reg]).add_argument("file")
    s = sub.add_parser("sudoers", parents=[reg])
    s.add_argument("user")
    s.add_argument("helper")
    sub.add_parser("root-only", parents=[reg]).add_argument("paths", nargs="*")
    a = p.parse_args(argv)
    if a.mode == "bot":
        if a.user_id <= 0:
            sys.exit("--user-id must be a person's id (a positive number)")
        with open(a.token_file) as f:
            token = f.read().strip()
        PLUGINS_DIR = a.plugins
        bot = Bot(TelegramAPI(a.api_base, token, a.poll_timeout), a.user_id, CommandRunner(shlex.split(a.action_cmd)),
                  a.state_dir)
        bot.log("opsbot started for user %d" % a.user_id)
        bot.serve_forever()
    skipped = []
    if a.mode == "validate":  # as root, before a plugin is registered: loaded last, in place of the registered one
        name = os.path.basename(a.file)[:-5] if a.file.endswith(".json") else None
        plugins = load_registry(a.plugins, skipped.append, extra=a.file) if name else []
        new = next((x for x in plugins if x["name"] == name), None)
        try:
            if not new:  # its reason is the last one logged (other broken plugins are left out quietly: check reports them)
                raise PluginError(skipped[-1].split(": ", 1)[1] if name and skipped else "the file name must be NAME.json")
            check_root_paths(new)
        except (OSError, ValueError) as e:
            print("opsbot: %s" % e, file=sys.stderr)
            return 1
        print(name)
        return 0

    def warn(msg):
        skipped.append(msg)
        print("opsbot: %s" % msg, file=sys.stderr)
    plugins = load_registry(a.plugins, warn)
    if a.mode == "sudoers":
        rules = ["%s %s %s" % (a.helper, x["name"], act) for x in plugins for act in x["actions"]]
        print("# Managed by opsbot.sh: the bot may run exactly these, as root, without a password.")
        if rules:
            print("%s ALL=(root) NOPASSWD: %s" % (a.user, ", ".join(rules)))
        return 0
    # root-only, as root: what root runs for the bot, the registered plugin files and what they run (a broken plugin is
    # named on stderr and fails it too)
    bad = []
    for check, arg in ([(root_only, x) for x in a.paths + [os.path.join(a.plugins, x["name"] + ".json") for x in plugins]]
                       + [(check_root_paths, x) for x in plugins]):
        try:
            check(arg)
        except (OSError, ValueError) as e:
            bad.append(str(e))
    if bad:
        print("; ".join(sorted(set(bad))))
    return 1 if bad or skipped else 0


if __name__ == "__main__":
    sys.exit(main())
