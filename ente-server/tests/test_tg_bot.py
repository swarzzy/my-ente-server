"""Unit tests for ente_tg_bot.py against a fake Telegram Bot API and a fake action runner.

Run:  python3 -m unittest discover -s tests -v     (from ente-server/; stdlib only)
"""
import io
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import ente_tg_bot as tb  # noqa: E402

TOKEN = "123456:TEST-token_abcdefghijklmnopqrstuvwxyz"
OWNER = 376193354
STRANGER = 555000111


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
    """Records actions; returns canned output. An action can be made to block until released."""
    def __init__(self):
        self.calls = []
        self.out = {}
        self.gates = {}
        self.lock = threading.Lock()

    def __call__(self, action):
        with self.lock:
            self.calls.append(action)
        gate = self.gates.get(action)
        if gate:
            gate.wait(10)
        return self.out.get(action, (0, "output of " + action))


class BotTest(unittest.TestCase):
    def setUp(self):
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeTelegram)
        self.srv.lock = threading.Lock()
        self.srv.calls, self.srv.sent, self.srv.updates, self.srv.fail_next = [], [], [], 0
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.state = tempfile.mkdtemp()
        self.runner = FakeRunner()
        self.log = io.StringIO()
        self.bot = self.make_bot()
        self.next_id = 100

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        for f in os.listdir(self.state):
            os.unlink(os.path.join(self.state, f))
        os.rmdir(self.state)

    def make_bot(self):
        api = tb.TelegramAPI("http://127.0.0.1:%d" % self.srv.server_address[1], TOKEN, poll_timeout=1)
        return tb.Bot(api, OWNER, self.runner, self.state, log=self.log)

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
        self.assertEqual(self.runner.calls, ["status"])
        self.assertEqual(self.texts(), ["output of status"])

    def test_someone_else_is_ignored_and_the_owner_is_told_once(self):
        self.msg("/backup", sender=STRANGER)
        self.msg("/proxy on", sender=STRANGER)
        self.poll()
        self.assertEqual(self.runner.calls, [])
        self.assertEqual([s for s in self.sent() if s["chat_id"] == STRANGER], [])  # no answer to the stranger at all
        notices = self.texts()
        self.assertEqual(len(notices), 1)
        self.assertIn(str(STRANGER), notices[0])
        self.assertIn("/backup", notices[0])

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

    # ---- commands
    def test_help_and_unknown_commands_list_the_commands(self):
        for text in ("/start", "/help", "/nonsense", "hello"):
            self.msg(text)
        self.poll()
        self.assertEqual(self.runner.calls, [])
        replies = self.texts()
        self.assertEqual(len(replies), 4)
        for r in replies:
            for c in ("/status", "/check", "/backup", "/proxy"):
                self.assertIn(c, r)

    def test_proxy_arguments(self):
        # one at a time: proxy commands are serialised (see test_proxy_switches_are_serialised)
        for i, text in enumerate(("/proxy", "/proxy on", "/proxy   OFF", "/proxy@ente_test_bot status"), 1):
            self.msg(text)
            self.poll()
            self.wait_sent(2 * i)  # acknowledgement + result
            time.sleep(0.05)
        self.assertEqual(self.runner.calls, ["proxy-status", "proxy-on", "proxy-off", "proxy-status"])

    def test_bad_arguments_are_refused_without_running_anything(self):
        for text in ("/proxy maybe", "/proxy on; rm -rf /", "/proxy on off", "/status now", "/backup please", "/check `id`"):
            self.msg(text)
        self.poll()
        time.sleep(0.2)
        self.assertEqual(self.runner.calls, [])
        self.assertEqual(len(self.texts()), 6)

    def test_bot_name_suffix_is_accepted(self):
        self.msg("/status@ente_test_bot")
        self.poll()
        self.assertEqual(self.runner.calls, ["status"])

    # ---- long actions
    def test_backup_replies_at_once_then_with_the_result(self):
        self.runner.gates["backup"] = threading.Event()
        self.runner.out["backup"] = (0, "backup ok")
        self.msg("/backup")
        self.poll()
        self.wait_sent(1)
        self.assertTrue(self.texts()[0].startswith("⏳ Backing up"), self.texts())
        self.msg("/status")  # the bot keeps answering while the backup runs
        self.poll()
        self.wait_sent(2)
        self.assertEqual(self.texts()[1], "output of status")
        self.runner.gates["backup"].set()
        self.wait_sent(3)
        self.assertEqual(self.texts()[2], "✅ Backup done\nbackup ok")

    def test_a_second_backup_while_one_runs_is_refused(self):
        self.runner.gates["backup"] = threading.Event()
        self.msg("/backup")
        self.msg("/backup")
        self.poll()
        self.wait_sent(2)
        self.assertEqual(self.runner.calls.count("backup"), 1)
        self.assertTrue(any("already" in t.lower() for t in self.texts()))
        self.runner.gates["backup"].set()
        self.wait_sent(3)

    def test_proxy_switches_are_serialised(self):
        self.runner.gates["proxy-on"] = threading.Event()
        self.msg("/proxy on")
        self.msg("/proxy off")
        self.poll()
        self.wait_sent(2)
        self.assertEqual(self.runner.calls, ["proxy-on"])
        self.assertTrue(any("busy" in t.lower() or "already" in t.lower() for t in self.texts()))
        self.runner.gates["proxy-on"].set()
        self.wait_sent(3)

    def test_failed_action_is_reported_as_failed(self):
        self.runner.out["check"] = (1, "  FAIL  something broke\n1 check(s) FAILED")
        self.msg("/check")
        self.poll()
        self.wait_sent(2)
        final = self.texts()[-1]
        self.assertTrue(final.startswith("❌ Check found problems\n"), final)
        self.assertIn("something broke", final)
        self.assertNotIn("exit", final)  # no exit codes in replies

    def test_each_action_has_a_title_for_success_and_failure(self):
        self.assertEqual(set(tb.TITLES), set(tb.ACTIONS) - {"status"})
        self.assertEqual(set(tb.STARTED), set(tb.ACTIONS) - {"status"})
        for ok, bad in tb.TITLES.values():
            self.assertTrue(ok[0] in "✅🔀" and bad.startswith("❌"), (ok, bad))

    def test_an_action_without_output_gets_only_its_title(self):
        self.runner.out["proxy-off"] = (0, "")
        self.msg("/proxy off")
        self.poll()
        self.wait_sent(2)
        self.assertEqual(self.texts()[-1], "✅ S3 proxy is off")

    def test_a_stranger_notice_names_them(self):
        self.msg("hi there", sender=STRANGER)
        self.poll()
        self.assertEqual(self.texts(), ["🚫 Someone else wrote to me, I ignored it: Someone @someone (id %d): 'hi there'" % STRANGER])

    def test_long_output_is_cut_to_fit_a_message(self):
        self.runner.out["status"] = (0, "x" * 10000 + "THE END")
        self.msg("/status")
        self.poll()
        t = self.texts()[0]
        self.assertLessEqual(len(t), 4096)
        self.assertTrue(t.endswith("THE END"))

    # ---- robustness
    def test_offset_is_persisted_so_nothing_runs_twice_after_a_restart(self):
        self.msg("/status")
        self.poll()
        self.bot = self.make_bot()  # restart
        self.poll()
        self.assertEqual(self.runner.calls, ["status"])

    def test_api_errors_do_not_crash_and_do_not_leak_the_token(self):
        self.srv.fail_next = 3
        self.msg("/status")
        for _ in range(4):
            try:
                self.bot.run_once()
            except tb.ApiError:
                pass
        self.assertEqual(self.runner.calls, ["status"])
        self.assertNotIn(TOKEN, self.log.getvalue())
        self.assertNotIn(TOKEN.split(":")[1], self.log.getvalue())

    def test_unreachable_api_raises_a_clean_error_without_the_token(self):
        api = tb.TelegramAPI("http://127.0.0.1:9", TOKEN, poll_timeout=1)
        with self.assertRaises(tb.ApiError) as cm:
            api.call("getMe")
        self.assertNotIn(TOKEN.split(":")[1], str(cm.exception))

    def test_a_cut_off_response_is_an_api_error_not_a_crash(self):
        import http.client
        from unittest import mock
        with mock.patch("urllib.request.urlopen", side_effect=http.client.IncompleteRead(b"{")):
            with self.assertRaises(tb.ApiError):
                self.bot.api.call("getUpdates")

    def test_start_registers_the_command_menu_for_the_owner_only(self):
        self.bot.register_commands()
        calls = [b for m, b in self.srv.calls if m == "setMyCommands"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["scope"], {"type": "chat", "chat_id": OWNER})
        self.assertEqual({c["command"] for c in calls[0]["commands"]}, {"status", "check", "backup", "proxy"})

    def test_accepted_and_ignored_commands_are_logged(self):
        self.msg("/status")
        self.msg("/backup", sender=STRANGER)
        self.poll()
        log = self.log.getvalue()
        self.assertIn("accepted /status", log)
        self.assertIn("ignored", log)
        self.assertIn(str(STRANGER), log)


class RunnerTest(unittest.TestCase):
    def test_sudo_runner_passes_only_the_action_and_captures_output(self):
        d = tempfile.mkdtemp()
        helper = os.path.join(d, "helper")
        with open(helper, "w") as f:
            f.write("#!/bin/sh\necho \"args:$#:$1\"\nexit 3\n")
        os.chmod(helper, 0o755)
        rc, out = tb.CommandRunner([helper], timeout=10)("status")
        self.assertEqual((rc, out.strip()), (3, "args:1:status"))
        with self.assertRaises(ValueError):
            tb.CommandRunner([helper])("rm -rf /")
        os.unlink(helper)
        os.rmdir(d)

    def test_runner_timeout_is_reported(self):
        d = tempfile.mkdtemp()
        helper = os.path.join(d, "helper")
        with open(helper, "w") as f:
            f.write("#!/bin/sh\nsleep 5\n")
        os.chmod(helper, 0o755)
        rc, out = tb.CommandRunner([helper], timeout=1)("status")
        self.assertNotEqual(rc, 0)
        self.assertIn("timed out", out)
        os.unlink(helper)
        os.rmdir(d)


if __name__ == "__main__":
    unittest.main()
