"""A fake Telegram Bot API for the opsbot tests and the services' bot tests. Python stdlib only.

    python3 tests/fake_telegram.py PORT_FILE
Listens on 127.0.0.1 (free port, written to PORT_FILE) and implements getUpdates, sendMessage, setMyCommands, getMe for
any token, with JSON or form-encoded bodies. Test control (plain HTTP, also on 127.0.0.1):
    POST /control/message   {"text": ..., "from": ID, "chat": ID, "type": "private", "age": 0}  -> queues a message
    GET  /control/sent                                                                       -> the bot's messages so far
    GET  /control/tokens                                                                     -> sha256 of tokens seen
    GET  /control/commands                                                                   -> the last command menu set
"""
import hashlib
import json
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
UPDATES, SENT, TOKENS, MENU = [], [], set(), []
NEXT = [1000]


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, status, doc):
        data = json.dumps(doc).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        with LOCK:
            if self.path == "/control/sent":
                return self._send(200, SENT)
            if self.path == "/control/tokens":
                return self._send(200, sorted(TOKENS))
            if self.path == "/control/commands":
                return self._send(200, MENU)
        self._send(404, {})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.headers.get("Content-Type", "").startswith("application/x-www-form-urlencoded"):  # curl --data-urlencode
            body = {k: v[-1] for k, v in urllib.parse.parse_qs(raw.decode(), keep_blank_values=True).items()}
        else:
            body = json.loads(raw or b"{}")
        if self.path == "/control/message":
            with LOCK:
                NEXT[0] += 1
                sender = body.get("from")
                UPDATES.append({"update_id": NEXT[0], "message": {
                    "message_id": NEXT[0], "date": int(time.time() - body.get("age", 0)), "text": body["text"],
                    "from": {"id": sender, "is_bot": False, "first_name": "Test", "username": "e2e_%s" % sender},
                    "chat": {"id": body.get("chat", sender), "type": body.get("type", "private")}}})
            return self._send(200, {"ok": True})
        parts = self.path.split("/")
        if len(parts) != 3 or not parts[1].startswith("bot"):
            return self._send(404, {"ok": False})
        with LOCK:
            TOKENS.add(hashlib.sha256(parts[1][3:].encode()).hexdigest())
        method = parts[2]
        if method == "getUpdates":
            off, end = body.get("offset", 0), time.time() + min(float(body.get("timeout", 0)), 2)
            while True:
                with LOCK:
                    ups = [u for u in UPDATES if u["update_id"] >= off]
                if ups or time.time() >= end:
                    return self._send(200, {"ok": True, "result": ups})
                time.sleep(0.05)
        if method == "sendMessage":
            with LOCK:
                SENT.append({"chat_id": body.get("chat_id"), "text": body.get("text"), "t": time.time()})
            return self._send(200, {"ok": True, "result": {"message_id": len(SENT)}})
        if method == "setMyCommands":
            with LOCK:
                MENU[:] = [c.get("command") for c in body.get("commands", [])]
        if method in ("setMyCommands", "getMe", "deleteMyCommands"):
            return self._send(200, {"ok": True, "result": True})
        return self._send(404, {"ok": False, "description": "Not Found"})


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    with open(sys.argv[1], "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()
