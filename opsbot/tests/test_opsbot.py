"""Unit tests for opsbot.py: plugin validation, the registry, the root helper, the sudo rule, and the bot against a fake Telegram
Bot API with a fake action runner.

Run:  python3 -m unittest discover -s tests -v     (from opsbot/; stdlib only, changes nothing outside temp dirs)
"""
import copy
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import opsbot as ob  # noqa: E402

SETTINGS = (ob.PLUGINS_DIR, ob.REBOOT_FLAG)  # the module settings the bot tests change

TOKEN = "123456:TEST-token_abcdefghijklmnopqrstuvwxyz"
OWNER = 376193354
STRANGER = 555000111

# a plugin like a real service's: a status action, background actions, a command with arguments (one lock: one command)
DEMO = {
    "name": "demo",
    "exec": ["/bin/sh", "/nonexistent/demo.sh"],
    "commands": [
        {"command": "check", "description": "Full health check", "action": "check"},
        {"command": "backup", "description": "Back up now", "action": "backup"},
        {"command": "proxy", "description": "S3 proxy: state, /proxy on, /proxy off",
         "args": {"": "proxy-status", "status": "proxy-status", "on": "proxy-on", "off": "proxy-off"}},
        {"command": "size", "description": "Measure the buckets now", "action": "size"},
        {"command": "uptime", "description": "How long it runs", "action": "uptime"},
    ],
    "actions": {
        "status": {},
        "uptime": {"ok": "⏱ Uptime"},
        "check": {"started": "⏳ Checking...", "ok": "✅ Check passed", "fail": "❌ Check found problems"},
        "backup": {"started": "⏳ Backing up...", "ok": "✅ Backup done", "fail": "❌ Backup failed"},
        "proxy-status": {"started": "⏳ Checking the S3 proxy...", "ok": "🔀 S3 proxy", "fail": "❌ S3 proxy has problems"},
        "proxy-on": {"started": "⏳ Turning the S3 proxy on...", "ok": "✅ S3 proxy is on"},
        "proxy-off": {"started": "⏳ Turning the S3 proxy off...", "ok": "✅ S3 proxy is off"},
        "size": {"started": "⏳ Measuring the buckets..."},
    },
}


def write_plugin(d, doc, name=None):
    with open(os.path.join(d, (name or doc["name"]) + ".json"), "w") as f:
        json.dump(doc, f)


class FakeTelegram(BaseHTTPRequestHandler):
    """Implements the few Bot API methods the bot uses. State lives on the server object."""
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        srv = self.server
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        parts = self.path.split("/")
        if len(parts) != 3 or parts[1] != "bot" + TOKEN:
            return self._send(401, {"ok": False, "description": "Unauthorized"})
        method = parts[2]
        with srv.lock:
            srv.calls.append((method, body))
            if srv.fail_next:
                srv.fail_next -= 1
                return self._send(502, {"ok": False, "description": "Bad Gateway"})
        if method == "getUpdates":
            off = body.get("offset", 0)
            deadline = time.time() + min(float(body.get("timeout", 0)), 1.0)
            while True:
                with srv.lock:
                    ups = [u for u in srv.updates if u["update_id"] >= off]
                if ups or time.time() >= deadline:
                    break
                time.sleep(0.02)
            return self._send(200, {"ok": True, "result": ups})
        if method == "sendMessage":
            with srv.lock:
                srv.sent.append(body)
            return self._send(200, {"ok": True, "result": {"message_id": len(srv.sent)}})
        if method in ("setMyCommands", "deleteMyCommands", "getMe"):
            return self._send(200, {"ok": True, "result": True})
        return self._send(404, {"ok": False, "description": "Not Found"})

    def _send(self, status, doc):
        data = json.dumps(doc).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class FakeRunner:
    """Records (plugin, action); returns canned output. An action can be made to block until released."""
    def __init__(self):
        self.calls = []
        self.out = {}
        self.gates = {}
        self.timeouts = {}
        self.lock = threading.Lock()

    def __call__(self, plugin, action, timeout=ob.ACTION_TIMEOUT):
        key = action if plugin == "demo" else "%s:%s" % (plugin, action)  # other plugins' actions: "plugin:action"
        with self.lock:
            self.calls.append(key)
            self.timeouts[key] = timeout
        gate = self.gates.get(key)
        if gate:
            gate.wait(10)
        return self.out.get(key, (0, "output of " + key))


class BotTest(unittest.TestCase):
    def setUp(self):
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeTelegram)
        self.srv.lock = threading.Lock()
        self.srv.calls, self.srv.sent, self.srv.updates, self.srv.fail_next = [], [], [], 0
        # a short poll interval: shutdown() waits up to one interval (the default 0.5 s, paid by every test)
        threading.Thread(target=self.srv.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
        self.state = tempfile.mkdtemp()
        self.plugins = tempfile.mkdtemp()
        write_plugin(self.plugins, DEMO)
        self.runner = FakeRunner()
        self.log = io.StringIO()
        self.bot = self.make_bot()
        self.next_id = 100

    def tearDown(self):
        ob.PLUGINS_DIR, ob.REBOOT_FLAG = SETTINGS
        self.srv.shutdown()
        self.srv.server_close()
        shutil.rmtree(self.state)
        shutil.rmtree(self.plugins)

    def make_bot(self):
        # a short long-poll: a poll with nothing queued waits this long
        api = ob.TelegramAPI("http://127.0.0.1:%d" % self.srv.server_address[1], TOKEN, poll_timeout=0.1)
        ob.PLUGINS_DIR, ob.REBOOT_FLAG = self.plugins, os.path.join(self.state, "no-reboot")  # restored in tearDown
        return ob.Bot(api, OWNER, self.runner, self.state, log=self.log)

    def msg(self, text, sender=OWNER, chat=None, chat_type="private", age=0, is_bot=False, edited=False):
        self.next_id += 1
        m = {"message_id": self.next_id, "date": int(time.time() - age), "text": text,
             "from": {"id": sender, "is_bot": is_bot, "first_name": "Someone", "username": "someone"},
             "chat": {"id": OWNER if chat is None and sender == OWNER else (chat or sender), "type": chat_type}}
        u = {"update_id": self.next_id, ("edited_message" if edited else "message"): m}
        with self.srv.lock:
            self.srv.updates.append(u)
        return u

    def poll(self, n=1):
        for _ in range(n):
            self.bot.run_once()

    def sent(self):
        with self.srv.lock:
            return list(self.srv.sent)

    def texts(self, chat=OWNER):
        return [s["text"] for s in self.sent() if s["chat_id"] == chat]

    def wait_sent(self, n, timeout=5):
        end = time.time() + timeout
        while len(self.sent()) < n and time.time() < end:
            time.sleep(0.02)
        return self.sent()

    # ---- who may use it
    def test_owner_private_message_runs_the_action_and_gets_the_reply(self):
        self.msg("/status")
        self.poll()
        self.wait_sent(1)
        self.assertEqual(self.runner.calls, ["status"])
        self.assertEqual(self.texts()[0].splitlines()[0], "output of status")

    def test_someone_else_is_ignored_and_nothing_is_sent(self):
        self.msg("/backup", sender=STRANGER)
        self.msg("/proxy on", sender=STRANGER)
        self.poll()
        self.assertEqual(self.runner.calls, [])
        self.assertEqual(self.sent(), [])  # no answer to the stranger, no message to the owner

    def test_owner_in_a_group_is_ignored(self):
        self.msg("/backup", sender=OWNER, chat=-100123, chat_type="group")
        self.poll()
        self.assertEqual(self.runner.calls, [])
        self.assertEqual(self.sent(), [])

    def test_a_private_chat_that_is_not_the_owners_is_ignored(self):
        # from.id spoofing is not possible on Telegram, but both ids must match anyway
        self.msg("/backup", sender=OWNER, chat=STRANGER)
        self.poll()
        self.assertEqual(self.runner.calls, [])

    def test_messages_from_bots_and_edited_messages_are_ignored(self):
        self.msg("/backup", is_bot=True)
        self.msg("/backup", edited=True)
        self.poll()
        self.assertEqual(self.runner.calls, [])

    def test_old_messages_are_dropped(self):
        self.msg("/backup", age=120)
        self.poll()
        self.assertEqual(self.runner.calls, [])
        self.assertEqual(len(self.texts()), 1)
        self.assertTrue(self.texts()[0].startswith("⏰ Skipped /backup"), self.texts())

    # ---- commands from the plugins
    def test_help_and_unknown_commands_list_the_plugin_commands(self):
        for text in ("/start", "/help", "/nonsense", "hello"):
            self.msg(text)
        self.poll()
        self.assertEqual(self.runner.calls, [])
        replies = self.texts()
        self.assertEqual(len(replies), 4)
        for r in replies:
            for c in ("/status – Quick overview", "/check – Full health check", "/backup", "/proxy", "/size", "/uptime"):
                self.assertIn(c, r)

    def test_proxy_arguments_map_to_their_actions(self):
        # one at a time: proxy commands share a lock (see test_actions_sharing_a_lock_are_serialised)
        for i, text in enumerate(("/proxy", "/proxy on", "/proxy   OFF", "/proxy@ente_test_bot status"), 1):
            self.msg(text)
            self.poll()
            self.wait_sent(2 * i)  # acknowledgement + result
            time.sleep(0.05)
        self.assertEqual(self.runner.calls, ["proxy-status", "proxy-on", "proxy-off", "proxy-status"])

    def test_bad_arguments_are_refused_without_running_anything(self):
        for text in ("/proxy maybe", "/proxy on; rm -rf /", "/proxy on off", "/status now", "/backup please", "/check `id`",
                     "/size now"):
            self.msg(text)
        self.poll()
        time.sleep(0.2)
        self.assertEqual(self.runner.calls, [])
        t = self.texts()
        self.assertEqual(len(t), 7)
        self.assertEqual(t[0], "Send /proxy, /proxy status, /proxy on, /proxy off.")
        self.assertEqual(t[3], "Send /status.")
        self.assertEqual(t[4], "Send /backup.")

    def test_bot_name_suffix_is_accepted(self):
        self.msg("/check@ente_test_bot")
        self.poll()
        self.wait_sent(2)
        self.assertEqual(self.runner.calls, ["check"])

    def test_an_action_without_texts_says_it_started_then_its_title_and_output(self):
        self.msg("/uptime")
        self.poll()
        self.wait_sent(2)
        self.assertEqual(self.texts(), ["⏳ /uptime...", "⏱ Uptime\noutput of uptime"])
        self.runner.out["uptime"] = (1, "broken")
        self.msg("/uptime")
        self.poll()
        self.wait_sent(4)
        self.assertEqual(self.texts()[-1], "❌ /uptime failed\nbroken")

    # ---- /status
    def test_status_is_each_plugins_status_then_the_system_line(self):
        other = {"name": "other", "exec": ["/bin/true"], "actions": {"status": {}}}
        write_plugin(self.plugins, other)
        self.bot.load_plugins()
        self.runner.out["status"] = (0, "✅ Demo is up\n💾 Backup: fine")
        self.msg("/status")
        self.poll()
        self.wait_sent(1)
        lines = self.texts()[0].splitlines()
        self.assertEqual(lines[:3], ["✅ Demo is up", "💾 Backup: fine", "output of other:status"])
        self.assertTrue(lines[3].startswith("🖥 Disk ") and " used (" in lines[3] and "MB free · up " in lines[3], lines)
        self.assertNotIn("reboot pending", lines[3])
        self.assertEqual(self.runner.calls, ["status", "other:status"])
        self.assertEqual(self.runner.timeouts["status"], ob.STATUS_TIMEOUT)

    def test_status_says_when_a_plugin_has_none_and_still_shows_the_rest(self):
        self.runner.out["status"] = (1, "some noise\nERROR: database down")
        open(os.path.join(self.state, "no-reboot"), "w").close()
        self.msg("/status")
        self.poll()
        self.wait_sent(1)
        lines = self.texts()[0].splitlines()
        self.assertEqual(lines[0], "❌ demo: no status (ERROR: database down)")
        self.assertTrue(lines[1].startswith("🖥 ") and lines[1].endswith(" · reboot pending"), lines)

    def test_status_without_plugins_is_the_system_line(self):
        os.unlink(os.path.join(self.plugins, "demo.json"))
        self.bot.load_plugins()
        self.msg("/status")
        self.poll()
        self.wait_sent(1)
        self.assertEqual(len(self.texts()[0].splitlines()), 1)
        self.assertEqual(self.runner.calls, [])

    def test_a_slow_status_does_not_hold_up_other_commands(self):
        self.runner.gates["status"] = threading.Event()
        self.msg("/status")
        self.msg("/uptime")
        self.poll()
        self.wait_sent(2)
        self.assertEqual(self.texts(), ["⏳ /uptime...", "⏱ Uptime\noutput of uptime"])  # answered while /status waits
        self.runner.gates["status"].set()
        self.wait_sent(3)
        self.assertTrue(self.texts()[2].startswith("output of status"), self.texts())

    # ---- long actions
    def test_backup_replies_at_once_then_with_the_result(self):
        self.runner.gates["backup"] = threading.Event()
        self.runner.out["backup"] = (0, "backup ok")
        self.msg("/backup")
        self.poll()
        self.wait_sent(1)
        self.assertEqual(self.texts()[0], "⏳ Backing up...")
        self.msg("/status")  # the bot keeps answering while the backup runs
        self.poll()
        self.wait_sent(2)
        self.assertEqual(self.texts()[1].splitlines()[0], "output of status")
        self.runner.gates["backup"].set()
        self.wait_sent(3)
        self.assertEqual(self.texts()[2], "✅ Backup done\nbackup ok")
        self.assertEqual(self.runner.timeouts["backup"], ob.ACTION_TIMEOUT)

    def test_a_second_backup_while_one_runs_is_refused(self):
        self.runner.gates["backup"] = threading.Event()
        self.msg("/backup")
        self.msg("/backup")
        self.poll()
        self.wait_sent(2)
        self.assertEqual(self.runner.calls.count("backup"), 1)
        self.assertIn("⏳ /backup is already running.", self.texts())
        self.runner.gates["backup"].set()
        self.wait_sent(3)

    def test_one_command_runs_one_at_a_time_whatever_its_argument(self):
        self.runner.gates["proxy-on"] = threading.Event()
        self.msg("/proxy on")
        self.msg("/proxy off")
        self.poll()
        self.wait_sent(2)
        self.assertEqual(self.runner.calls, ["proxy-on"])
        self.assertIn("⏳ /proxy is already running.", self.texts())
        self.runner.gates["proxy-on"].set()
        self.wait_sent(3)

    def test_different_actions_run_side_by_side(self):
        self.runner.gates["backup"] = threading.Event()
        self.msg("/backup")
        self.msg("/check")
        self.poll()
        self.wait_sent(3)  # backup started, check started, check done
        self.assertEqual(sorted(self.runner.calls), ["backup", "check"])
        self.runner.gates["backup"].set()
        self.wait_sent(4)

    def test_failed_action_is_reported_as_failed(self):
        self.runner.out["check"] = (1, "  FAIL  something broke\n1 check(s) FAILED")
        self.msg("/check")
        self.poll()
        self.wait_sent(2)
        final = self.texts()[-1]
        self.assertTrue(final.startswith("❌ Check found problems\n"), final)
        self.assertIn("something broke", final)
        self.assertNotIn("exit", final)  # no exit codes in replies

    def test_default_titles_when_a_plugin_gives_none(self):
        self.runner.out["size"] = (0, "")
        self.msg("/size")
        self.poll()
        self.wait_sent(2)
        self.assertEqual(self.texts(), ["⏳ Measuring the buckets...", "✅ /size done"])
        self.runner.out["size"] = (2, "no bucket")
        self.msg("/size")
        self.poll()
        self.wait_sent(4)
        self.assertEqual(self.texts()[-1], "❌ /size failed\nno bucket")

    def test_an_action_without_output_gets_only_its_title(self):
        self.runner.out["proxy-off"] = (0, "")
        self.msg("/proxy off")
        self.poll()
        self.wait_sent(2)
        self.assertEqual(self.texts()[-1], "✅ S3 proxy is off")

    def test_long_output_is_cut_to_fit_a_message(self):
        self.runner.out["uptime"] = (0, "x" * 10000 + "THE END")
        self.msg("/uptime")
        self.poll()
        self.wait_sent(2)
        t = self.texts()[1]
        self.assertLessEqual(len(t), 4096)
        self.assertTrue(t.endswith("THE END"))

    # ---- plugins coming and going
    def test_a_reload_picks_up_new_and_removed_plugins_and_updates_the_menu(self):
        write_plugin(self.plugins, {"name": "drive", "exec": ["/bin/true"], "commands": [
            {"command": "drive", "description": "Drive backup", "action": "sync"}], "actions": {"sync": {"started": "⏳"}}})
        os.unlink(os.path.join(self.plugins, "demo.json"))
        self.msg("/drive")
        self.poll()  # not reloaded yet: unknown command
        self.assertEqual(self.runner.calls, [])
        ob.RELOAD.set()  # what SIGHUP does
        self.msg("/drive")
        self.poll()
        self.wait_sent(3)
        self.assertEqual(self.runner.calls, ["drive:sync"])
        menus = [b for m, b in self.srv.calls if m == "setMyCommands"]
        self.assertEqual([c["command"] for c in menus[-1]["commands"]], ["status", "drive"])
        self.msg("/backup")
        self.poll()
        self.assertTrue(self.texts()[-1].startswith("Available actions:"))

    def test_a_broken_plugin_is_skipped_and_the_rest_still_works(self):
        with open(os.path.join(self.plugins, "broken.json"), "w") as f:
            f.write("{not json")
        write_plugin(self.plugins, {"name": "thief", "exec": ["/bin/true"], "commands": [
            {"command": "backup", "description": "steals /backup", "action": "x"}], "actions": {"x": {}}})
        self.bot.load_plugins()
        self.assertIn("skipped plugin broken.json", self.log.getvalue())
        self.assertIn("skipped plugin thief.json: /backup is already demo's", self.log.getvalue())
        self.msg("/backup")
        self.poll()
        self.wait_sent(2)
        self.assertEqual(self.runner.calls, ["backup"])

    # ---- robustness
    def test_offset_is_persisted_so_nothing_runs_twice_after_a_restart(self):
        self.msg("/uptime")
        self.poll()
        self.wait_sent(2)
        self.bot = self.make_bot()  # restart
        self.poll()
        self.assertEqual(self.runner.calls, ["uptime"])

    def test_api_errors_do_not_crash_and_do_not_leak_the_token(self):
        self.srv.fail_next = 3
        self.msg("/uptime")
        for _ in range(4):
            try:
                self.bot.run_once()
            except ob.ApiError:
                pass
        self.wait_sent(2)
        self.assertEqual(self.runner.calls, ["uptime"])
        self.assertNotIn(TOKEN, self.log.getvalue())
        self.assertNotIn(TOKEN.split(":")[1], self.log.getvalue())

    def test_unreachable_api_raises_a_clean_error_without_the_token(self):
        api = ob.TelegramAPI("http://127.0.0.1:9", TOKEN, poll_timeout=1)
        with self.assertRaises(ob.ApiError) as cm:
            api.call("getMe")
        self.assertNotIn(TOKEN.split(":")[1], str(cm.exception))

    def test_a_cut_off_response_is_an_api_error_not_a_crash(self):
        import http.client
        from unittest import mock
        with mock.patch("urllib.request.urlopen", side_effect=http.client.IncompleteRead(b"{")):
            with self.assertRaises(ob.ApiError):
                self.bot.api.call("getUpdates")

    def test_the_command_menu_is_registered_for_the_owner_only_and_retried_until_it_works(self):
        self.srv.fail_next = 1  # the first setMyCommands fails
        self.poll(2)
        calls = [b for m, b in self.srv.calls if m == "setMyCommands"][1:]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["scope"], {"type": "chat", "chat_id": OWNER})
        self.assertEqual([c["command"] for c in calls[0]["commands"]], ["status", "check", "backup", "proxy", "size", "uptime"])

    def test_accepted_and_ignored_commands_are_logged(self):
        self.msg("/uptime")
        self.msg("/backup", sender=STRANGER)
        self.poll()
        log = self.log.getvalue()
        self.assertIn("accepted /uptime", log)
        self.assertIn("ignored", log)
        self.assertIn(str(STRANGER), log)


class PluginTest(unittest.TestCase):
    def bad(self, change, msg):
        doc = copy.deepcopy(DEMO)
        change(doc)
        with self.assertRaises(ob.PluginError) as cm:
            ob.check_plugin(doc, "demo")
        self.assertIn(msg, str(cm.exception))

    def test_the_demo_plugin_is_valid(self):
        self.assertIs(ob.check_plugin(copy.deepcopy(DEMO), "demo")["name"], "demo")

    def test_bad_plugins_are_refused_with_the_reason(self):
        self.bad(lambda d: d.update(name="Demo"), "name:")
        self.bad(lambda d: d.update(name="other"), "does not match the file name")
        self.bad(lambda d: d.update(extra=1), "unknown keys: extra")
        self.bad(lambda d: d.update(exec=["bash", "x"]), "absolute path")
        self.bad(lambda d: d.update(exec=["/bin/sh", "a\nb"]), "exec:")
        self.bad(lambda d: d.update(exec=[]), "exec:")
        self.bad(lambda d: d.update(env={"OK": "x"}), "unknown keys: env")
        self.bad(lambda d: d.update(actions={}), "actions:")
        self.bad(lambda d: d["actions"].update({"Bad Name": {}}), "action 'Bad Name'")
        self.bad(lambda d: d["actions"].update({"x": {"title": "?"}}), "action x: only")
        self.bad(lambda d: d["actions"].update({"x": {"lock": "l"}}), "action x: only")
        self.bad(lambda d: d["actions"].update({"x": {"started": ""}}), "one non-empty line")
        self.bad(lambda d: d["actions"].update({"x": {"ok": "a\nb"}}), "one non-empty line")
        self.bad(lambda d: d["commands"].append({"command": "Up", "description": "x", "action": "status"}), "command 'Up'")
        self.bad(lambda d: d["commands"].append({"command": "help", "description": "x", "action": "status"}), "/help is the bot's own")
        self.bad(lambda d: d["commands"].append({"command": "status", "description": "x", "action": "status"}), "/status is the bot's own")
        self.bad(lambda d: d["commands"].append(dict(d["commands"][0])), "/check is listed twice")
        self.bad(lambda d: d["commands"].append({"command": "x", "description": "", "action": "status"}), "/x: description")
        self.bad(lambda d: d["commands"].append({"command": "x", "description": "a\nb", "action": "status"}), "/x: description")
        self.bad(lambda d: d["commands"].append({"command": "x", "description": "x"}), "either action or args")
        self.bad(lambda d: d["commands"].append({"command": "x", "description": "x", "action": "status", "args": {"": "status"}}),
                 "either action or args")
        self.bad(lambda d: d["commands"].append({"command": "x", "description": "x", "action": "rm"}), "'rm' is not one of its actions")
        self.bad(lambda d: d["commands"].append({"command": "x", "description": "x", "args": {"a b": "status"}}), "argument 'a b'")
        self.bad(lambda d: (d.update(commands=[]), d["actions"].pop("status")), "needs commands or a status")
        # a trailing newline must not pass (it would break the sudo rule)
        self.bad(lambda d: d.update(name="demo\n"), "name:")
        self.bad(lambda d: d["actions"].update({"x\n": {}}), "action 'x\\n'")
        self.bad(lambda d: d["commands"].append({"command": "x\n", "description": "x", "action": "status"}), "command 'x\\n'")
        self.bad(lambda d: d.update(exec=["/bin/sh", "${HOME}/x.sh"]), "no $")
        self.bad(lambda d: d.update(exec=["/bin/sh", "/opt/link/../x.sh"]), "without ..")
        self.bad(lambda d: d.update(exec=["/bin//sh"]), "without ..")
        self.bad(lambda d: d.update(root_files=["relative.sh"]), "root_files:")
        self.bad(lambda d: d.update(root_files=["/opt/x/../y"]), "without ..")

    def test_registry_refuses_a_command_two_plugins_want(self):
        d = tempfile.mkdtemp()
        try:
            write_plugin(d, DEMO)
            write_plugin(d, {"name": "zz", "exec": ["/bin/true"], "commands": [
                {"command": "check", "description": "x", "action": "a"}], "actions": {"a": {}}})
            skipped = []
            self.assertEqual([x["name"] for x in ob.load_registry(d, skipped.append)], ["demo"])
            self.assertIn("/check is already demo's", skipped[0])
        finally:
            shutil.rmtree(d)

    def test_cli_validate_sudoers_root_only(self):
        d, src = tempfile.mkdtemp(), tempfile.mkdtemp()
        py = [sys.executable, "-I", os.path.join(HERE, "..", "opsbot.py")]
        try:
            write_plugin(src, DEMO)  # /nonexistent/demo.sh: validate refuses a program that is not there
            out = subprocess.run(py + ["validate", os.path.join(src, "demo.json"), "--plugins", d], capture_output=True, text=True)
            self.assertEqual(out.returncode, 1)
            self.assertIn("not found: /nonexistent", out.stderr)
            write_plugin(src, dict(DEMO, exec=["/bin/true"]))
            out = subprocess.run(py + ["validate", os.path.join(src, "demo.json"), "--plugins", d], capture_output=True, text=True)
            self.assertEqual((out.returncode, out.stdout), (0, "demo\n"))
            write_plugin(d, dict(DEMO, name="other", exec=["/bin/true"]), "other")
            out = subprocess.run(py + ["validate", os.path.join(src, "demo.json"), "--plugins", d], capture_output=True, text=True)
            self.assertEqual(out.returncode, 1)
            self.assertIn("/check is already other's", out.stderr)
            os.unlink(os.path.join(d, "other.json"))
            out = subprocess.run(py + ["sudoers", "opsbot", "/usr/local/sbin/opsbot-action", "--plugins", d], capture_output=True, text=True)
            self.assertEqual(out.stdout.strip().splitlines()[1:], [])  # nothing registered: a comment only
            write_plugin(d, DEMO)
            out = subprocess.run(py + ["sudoers", "opsbot", "/usr/local/sbin/opsbot-action", "--plugins", d], capture_output=True, text=True)
            rule = out.stdout.strip().splitlines()[1]
            self.assertTrue(rule.startswith("opsbot ALL=(root) NOPASSWD: /usr/local/sbin/opsbot-action demo status, "), rule)
            self.assertEqual(rule.count("/usr/local/sbin/opsbot-action demo "), len(DEMO["actions"]))
            with open(os.path.join(d, "broken.json"), "w") as f:
                f.write("{")
            out = subprocess.run(py + ["sudoers", "opsbot", "/h", "--plugins", d], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0)  # a broken plugin is left out of the rule, not fatal for the others
            self.assertIn("/h demo status", out.stdout)
            self.assertNotIn("broken", out.stdout)
            self.assertIn("skipped plugin broken.json", out.stderr)
            out = subprocess.run(py + ["root-only", "--plugins", d], capture_output=True, text=True)
            self.assertEqual(out.returncode, 1)  # a broken plugin fails it (and here: these files are not root's)
            self.assertIn("skipped plugin broken.json", out.stderr)
            os.unlink(os.path.join(d, "broken.json"))
            with open(os.path.join(d, "demo.json"), "w") as f:
                f.write('{"name": "demo", "old_key": 1}')  # the registered copy is broken: re-adding a good one must work
            demo = dict(DEMO, exec=["/bin/true"])
            write_plugin(src, demo)
            out = subprocess.run(py + ["validate", os.path.join(src, "demo.json"), "--plugins", d], capture_output=True, text=True)
            self.assertEqual((out.returncode, out.stdout), (0, "demo\n"), out.stderr)
        finally:
            shutil.rmtree(d)
            shutil.rmtree(src)


class HelperTest(unittest.TestCase):
    """The root helper, with this user standing in for root and no systemd-run (the action runs directly)."""
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.plugins = os.path.join(self.d, "plugins.d")
        os.mkdir(self.plugins)
        self.script = os.path.join(self.d, "plugin.sh")
        with open(self.script, "w") as f:
            f.write('#!/bin/sh\necho "args:$#:$1 env:${GREETING:-none} cwd:$(pwd)"\n')
        os.chmod(self.script, 0o755)
        # only the script: /bin/sh is root's, and this test stands in for root with its own user
        write_plugin(self.plugins, {"name": "t", "exec": [self.script], "actions": {"status": {}, "run": {"started": "⏳"}}})

    def tearDown(self):
        shutil.rmtree(self.d)

    def helper(self, *args, trusted=None, run="[]"):
        """Run the helper in a python of its own with this user trusted like root (TRUSTED) and the action run directly
        (RUN). GREETING comes from the caller and must not reach the action."""
        code = ("import sys; sys.path.insert(0, %r); import opsbot; opsbot.TRUSTED_UIDS = %r; opsbot.PLUGINS_DIR = %r; "
                "opsbot.RUN = %s; sys.exit(opsbot.helper(%r))"
                % (os.path.join(HERE, ".."), trusted or {0, os.getuid()}, self.plugins, run, list(args)))
        p = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True, text=True, cwd=self.d,
                           env=dict(os.environ, GREETING="leak"))
        return p.returncode, (p.stdout + p.stderr).strip()

    def test_a_registered_action_runs_in_the_root_directory(self):
        self.assertEqual(self.helper("t", "status")[1].split(" cwd:")[1], "/")
        self.assertTrue(self.helper("t", "status")[1].startswith("args:1:status "))

    def test_unknown_or_malformed_requests_are_refused(self):
        self.assertEqual(self.helper("t", "rm"), (2, "unknown action"))
        self.assertEqual(self.helper("nope", "status"), (1, "refused: not found: %s" % os.path.join(self.plugins, "nope.json")))
        for args in (("t",), ("t", "status", "x"), ("../t", "status"), ("t", "status; id"), ()):
            self.assertEqual(self.helper(*args)[0], 2, args)

    def test_files_others_can_write_are_refused(self):
        os.chmod(self.script, 0o777)
        rc, out = self.helper("t", "status")
        self.assertEqual(rc, 1)
        self.assertIn("refused: group/world-writable: %s" % self.script, out)
        os.chmod(self.script, 0o755)
        os.chmod(os.path.join(self.plugins, "t.json"), 0o666)
        rc, out = self.helper("t", "status")
        self.assertEqual(rc, 1)
        self.assertIn("refused: group/world-writable", out)

    def test_files_of_another_owner_are_refused(self):
        rc, out = self.helper("t", "status", trusted={os.getuid() + 1})
        self.assertEqual(rc, 1)
        self.assertIn("not owned by root", out)

    def test_a_symlink_root_alone_controls_runs_as_written(self):
        # e.g. a virtualenv's python: it must keep its own path (run by its target it would lose the venv)
        real = os.path.join(self.d, "real.sh")
        with open(real, "w") as f:
            f.write('#!/bin/sh\necho "ran:$0"\n')
        os.chmod(real, 0o755)
        link = os.path.join(self.d, "link.sh")
        os.symlink(real, link)
        write_plugin(self.plugins, {"name": "t", "exec": [link], "actions": {"status": {}}})
        self.assertEqual(self.helper("t", "status"), (0, "ran:%s" % link))

    def test_a_symlink_in_a_directory_others_can_write_is_refused(self):
        # its target is fine, but someone could point the link elsewhere between the check and the run
        real = os.path.join(self.d, "real.sh")
        with open(real, "w") as f:
            f.write('#!/bin/sh\necho ran\n')
        os.chmod(real, 0o755)
        shared = os.path.join(self.d, "shared")
        os.mkdir(shared)
        os.chmod(shared, 0o777)
        os.symlink(real, os.path.join(shared, "link.sh"))
        write_plugin(self.plugins, {"name": "t", "exec": [os.path.join(shared, "link.sh")], "actions": {"status": {}}})
        rc, out = self.helper("t", "status")
        self.assertEqual(rc, 1)
        self.assertIn("refused: group/world-writable: %s" % shared, out)

    def test_root_files_are_checked_too_and_a_missing_one_through_its_folder(self):
        conf = os.path.join(self.d, "app.conf")
        open(conf, "w").close()
        write_plugin(self.plugins, {"name": "t", "exec": [self.script], "root_files": [conf, os.path.join(self.d, "gone.env")],
                                    "actions": {"status": {}}})
        self.assertEqual(self.helper("t", "status")[0], 0)  # gone.env: its folder is the user's alone, as root's would be
        os.chmod(conf, 0o666)
        rc, out = self.helper("t", "status")
        self.assertEqual(rc, 1)
        self.assertIn("refused: group/world-writable: %s" % conf, out)
        os.chmod(conf, 0o644)
        os.chmod(self.d, 0o777)  # anyone could now create gone.env
        rc, out = self.helper("t", "status")
        os.chmod(self.d, 0o700)
        self.assertEqual(rc, 1)
        self.assertIn("refused: group/world-writable: %s" % self.d, out)

    def test_a_program_that_is_not_there_is_refused(self):
        write_plugin(self.plugins, {"name": "t", "exec": [os.path.join(self.d, "gone.sh")], "actions": {"status": {}}})
        rc, out = self.helper("t", "status")
        self.assertEqual(rc, 1)
        self.assertIn("refused: not found: %s" % os.path.join(self.d, "gone.sh"), out)

    def test_with_systemd_run_the_action_follows_its_options(self):
        log = os.path.join(self.d, "argv")
        fake = os.path.join(self.d, "systemd-run")
        with open(fake, "w") as f:
            f.write('#!/bin/sh\nfor a; do echo "$a"; done > %s\n' % log)
        os.chmod(fake, 0o755)
        self.assertEqual(self.helper("t", "run", run=repr([fake, "--wait", "--"]))[0], 0)
        with open(log) as f:
            self.assertEqual(f.read().splitlines(), ["--wait", "--", self.script, "run"])


class RunnerTest(unittest.TestCase):
    def test_runner_passes_plugin_and_action_only_and_captures_output(self):
        d = tempfile.mkdtemp()
        helper = os.path.join(d, "helper")
        with open(helper, "w") as f:
            f.write("#!/bin/sh\necho \"args:$#:$1:$2\"\nexit 3\n")
        os.chmod(helper, 0o755)
        rc, out = ob.CommandRunner([helper])("demo", "status", timeout=10)
        self.assertEqual((rc, out.strip()), (3, "args:2:demo:status"))
        shutil.rmtree(d)

    def test_runner_timeout_is_reported(self):
        d = tempfile.mkdtemp()
        helper = os.path.join(d, "helper")
        with open(helper, "w") as f:
            f.write("#!/bin/sh\nsleep 5\n")
        os.chmod(helper, 0o755)
        rc, out = ob.CommandRunner([helper])("demo", "status", timeout=0.3)
        self.assertNotEqual(rc, 0)
        self.assertIn("timed out", out)
        shutil.rmtree(d)


class FormatTest(unittest.TestCase):
    def test_durations_and_sizes(self):
        self.assertEqual([ob.dur(s) for s in (45, 720, 18000, 300000)], ["45 s", "12 min", "5 h", "3 days"])
        self.assertEqual([ob.human(n) for n in (17 * 2 ** 30, int(5.2 * 2 ** 30), 980 * 2 ** 20)], ["17G", "5.2G", "980M"])


if __name__ == "__main__":
    unittest.main()
