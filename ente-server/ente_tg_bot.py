#!/usr/bin/env python3
"""ente-tg-bot: a Telegram bot that lets ONE person run a few fixed server actions. Python stdlib only.

It long-polls the Bot API (no open port), accepts only private messages from --user-id, drops messages older than a minute,
and maps each command to one fixed action name; no text from Telegram ever reaches a shell. Actions run through
--action-cmd (installed as `sudo -n /usr/local/sbin/ente-tg-action`, which allows exactly these names).

  /status          a short summary                       -> status
  /check           the full health check                 -> check
  /backup          run a backup now, report the result   -> backup
  /proxy [on|off]  the S3 proxy: state, or switch it      -> proxy-status | proxy-on | proxy-off

Usage: ente-tg-bot --user-id ID --state-dir DIR --action-cmd "sudo -n /usr/local/sbin/ente-tg-action"
       [--token-file FILE (default: $CREDENTIALS_DIRECTORY/token)] [--api-base https://api.telegram.org]
"""
import argparse
import http.client
import json
import os
import shlex
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

ACTIONS = ("status", "check", "backup", "proxy-on", "proxy-off", "proxy-status")
COMMANDS = [("status", "Quick overview"), ("check", "Full health check"),
            ("backup", "Back up now"), ("proxy", "S3 proxy: state, /proxy on, /proxy off")]
HELP = ("Available actions:\n/status – quick overview\n/check – full health check (about 30 s)\n/backup – back up now\n"
        "/proxy – S3 proxy state; /proxy on or /proxy off to switch it")
# the first line of a finished action's reply: (when it worked, when it did not)
TITLES = {"backup": ("✅ Backup done", "❌ Backup failed"),
          "check": ("✅ Check passed", "❌ Check found problems"),
          "proxy-on": ("✅ S3 proxy is on", "❌ Could not turn the S3 proxy on"),
          "proxy-off": ("✅ S3 proxy is off", "❌ Could not turn the S3 proxy off"),
          "proxy-status": ("🔀 S3 proxy", "❌ S3 proxy has problems")}
STARTED = {"backup": "⏳ Backing up...",
           "check": "⏳ Checking (about 30 s)...",
           "proxy-on": "⏳ Turning the S3 proxy on...",
           "proxy-off": "⏳ Turning the S3 proxy off...",
           "proxy-status": "⏳ Checking the S3 proxy..."}
BUSY = {"backup": "⏳ A backup is already running.",
        "check": "⏳ A check is already running.",
        "proxy": "⏳ Busy: the last /proxy command hasn't finished yet."}
MAX_TEXT = 4000      # Telegram allows 4096 characters
MAX_AGE = 60         # seconds; older commands are not run (e.g. queued while the bot was down)
NOTICE_EVERY = 3600  # at most one notice per stranger per hour


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
    """Runs PREFIX + [action]; only the known action names are accepted."""
    def __init__(self, prefix, timeout=6 * 3600):
        self.prefix, self.timeout = list(prefix), timeout

    def __call__(self, action):
        if action not in ACTIONS:
            raise ValueError("unknown action %r" % action)
        try:
            p = subprocess.run(self.prefix + [action], capture_output=True, text=True, timeout=self.timeout,
                               stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return 124, "timed out after %d s" % self.timeout
        except OSError as e:
            return 127, "could not run the action: %s" % e
        return p.returncode, (p.stdout + p.stderr).strip()


def fit(text):
    """Cut long output to fit one message, keeping the end (verdicts are last)."""
    text = text.strip() or "(no output)"
    return text if len(text) <= MAX_TEXT else "…(cut)\n" + text[-(MAX_TEXT - 8):]


class Bot:
    def __init__(self, api, user_id, runner, state_dir, log=sys.stdout, max_age=MAX_AGE):
        self.api, self.user_id, self.runner, self.max_age, self._log = api, int(user_id), runner, max_age, log
        self.offset_file = os.path.join(state_dir, "offset")
        try:
            with open(self.offset_file) as f:
                self.offset = int(f.read().strip())
        except (OSError, ValueError):
            self.offset = 0
        self.locks = {k: threading.Lock() for k in ("check", "backup", "proxy")}
        self.noticed = {}

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

    def register_commands(self):
        self.api.call("setMyCommands", commands=[{"command": c, "description": d} for c, d in COMMANDS],
                      scope={"type": "chat", "chat_id": self.user_id})

    def run_once(self):
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
            self.send(HELP)
            return
        cmd, args = words[0][1:].split("@", 1)[0].lower(), [a.lower() for a in words[1:]]
        if cmd not in ("status", "check", "backup", "proxy"):  # also /start and /help
            self.send(HELP)
            return
        if cmd == "proxy":
            if len(args) > 1 or (args and args[0] not in ("on", "off", "status")):
                self.send("Send /proxy, /proxy on or /proxy off.")
                return
            action = "proxy-" + (args[0] if args else "status")
        else:
            if args:
                self.send("/%s takes nothing after it. Just send /%s." % (cmd, cmd))
                return
            action = cmd
        self.log("accepted /%s%s" % (cmd, " " + " ".join(args) if args else ""))
        if action == "status":
            rc, out = self.runner(action)
            self.send(out if rc == 0 else "❌ Could not get the status:\n%s" % out)
            return
        group = action.split("-")[0]
        lock = self.locks[group]
        if not lock.acquire(blocking=False):
            self.send(BUSY[group])
            return
        self.send(STARTED[action])
        threading.Thread(target=self._run_async, args=(action, lock), daemon=True).start()

    def _run_async(self, action, lock):
        try:
            rc, out = self.runner(action)
            self.send("%s\n%s" % (TITLES[action][rc != 0], out) if out else TITLES[action][rc != 0])
            self.log("%s finished, exit %d" % (action, rc))
        finally:
            lock.release()


def main(argv=None):
    p = argparse.ArgumentParser(prog="ente-tg-bot")
    p.add_argument("--user-id", type=int, required=True)
    p.add_argument("--state-dir", required=True)
    p.add_argument("--action-cmd", required=True, help="command prefix; the action name is appended")
    p.add_argument("--token-file", default=os.path.join(os.environ.get("CREDENTIALS_DIRECTORY", "/nonexistent"), "token"))
    p.add_argument("--api-base", default="https://api.telegram.org")
    p.add_argument("--poll-timeout", type=int, default=50)
    a = p.parse_args(argv)
    if a.user_id <= 0:
        p.error("--user-id must be a person's id (a positive number)")
    with open(a.token_file) as f:
        token = f.read().strip()
    bot = Bot(TelegramAPI(a.api_base, token, a.poll_timeout), a.user_id, CommandRunner(shlex.split(a.action_cmd)), a.state_dir)
    bot.log("ente-tg-bot started for user %d" % a.user_id)
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


if __name__ == "__main__":
    main()
