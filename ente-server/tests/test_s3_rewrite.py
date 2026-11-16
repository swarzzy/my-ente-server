"""Unit tests for ente_s3_rewrite.py, the link rewriter between Caddy and museum.

Run:  python3 -m unittest discover -s tests -v     (from ente-server/; stdlib only)

Each test starts a fake museum (UPSTREAM) and the rewriter in threads on free local ports.
"""
import gzip
import http.client
import json
import os
import socket
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import ente_s3_rewrite as rw  # noqa: E402

REAL = "s3.eu-west-4.idrivee2.com"
PROXY = "s3.example.org"
BUCKET = "ente-dev"
SIGNED = "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=K%2F20261115%2Feu-west-4%2Fs3%2Faws4_request&X-Amz-Signature=abc"


def url(host=REAL, bucket=BUCKET, key="1580559962386439/uuid-1"):
    return "https://%s/%s/%s%s" % (host, bucket, key, SIGNED)


class FakeMuseum(BaseHTTPRequestHandler):
    """Answers according to the path; records what it received."""
    protocol_version = "HTTP/1.1"
    seen = []

    def log_message(self, *a):
        pass

    def _body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            data = b""
            while True:
                size = int(self.rfile.readline().strip(), 16)
                if size == 0:
                    self.rfile.readline()
                    break
                data += self.rfile.read(size)
                self.rfile.readline()
            return data
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _send(self, status, body=b"", ctype="application/json; charset=utf-8", extra=None):
        self.send_response(status)
        if ctype:
            self.send_header("Content-Type", ctype)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        if status not in (204, 304):
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and status not in (204, 304):
            self.wfile.write(body)

    def _handle(self):
        body = self._body()
        FakeMuseum.seen.append({"method": self.command, "path": self.path, "headers": dict(self.headers), "body": body})
        p = self.path.split("?")[0]
        if p == "/files/upload-url":
            # Go's encoding/json writes & as &
            self._send(200, json.dumps({"objectKey": "k", "url": url()}).replace("&", "\\u0026").encode())
        elif p == "/files/multipart-upload-urls":
            self._send(200, json.dumps({"urls": [{"objectKey": "k", "partURLs": [url(key="k?partNumber=%d" % i) for i in (1, 2, 3)],
                                                  "completeURL": url(key="k?uploadId=x")}]}).encode())
        elif p == "/files/download/v3/1":
            self._send(200, json.dumps({"url": url(), "other": url(bucket="someone-else"),
                                        "elsewhere": url(host="s3.other-provider.com")}).encode())
        elif p == "/escaped":
            self._send(200, b'{"url":"https:\\/\\/' + REAL.encode() + b'\\/' + BUCKET.encode() + b'\\/k?x=1"}')
        elif p == "/redirect":
            self._send(307, b"", ctype=None, extra={"Location": url()})
        elif p == "/gzip":
            self._send(200, gzip.compress(json.dumps({"url": url()}).encode()), extra={"Content-Encoding": "gzip"})
        elif p == "/binary":
            self._send(200, os.urandom(1) * 0 + bytes(range(256)) * 20000 + url().encode(), ctype="application/octet-stream")
        elif p == "/text":
            self._send(200, ("see " + url()).encode(), ctype="text/plain")
        elif p == "/error":
            self._send(401, json.dumps({"code": "UNAUTHORIZED", "hint": url()}).encode())
        elif p == "/nocontent":
            self._send(204, ctype=None)
        elif p == "/echo":
            self._send(200, json.dumps({"len": len(body), "body": body.decode("latin-1")}).encode())
        elif p == "/ping":
            self._send(200, b'{"message":"pong"}')
        else:
            self._send(404, b'{"code":"NOT_FOUND"}')

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_OPTIONS = do_PATCH = _handle


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class RewriterTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.museum = ThreadingHTTPServer(("127.0.0.1", 0), FakeMuseum)
        threading.Thread(target=cls.museum.serve_forever, daemon=True).start()
        cfg = rw.Config(listen=("127.0.0.1", 0), upstream=("127.0.0.1", cls.museum.server_address[1]),
                        from_host=REAL, to_host=PROXY, bucket=BUCKET)
        cls.proxy = rw.make_server(cfg)
        threading.Thread(target=cls.proxy.serve_forever, daemon=True).start()
        cls.port = cls.proxy.server_address[1]

    @classmethod
    def tearDownClass(cls):
        for srv in (cls.proxy, cls.museum):
            srv.shutdown()
            srv.server_close()

    def setUp(self):
        FakeMuseum.seen.clear()

    def req(self, method, path, body=None, headers=None, conn=None):
        c = conn or http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.request(method, path, body=body, headers=headers or {})
        r = c.getresponse()
        data = r.read()
        if conn is None:
            c.close()
        return r, data

    # ---- rewriting
    def test_json_upload_url_is_rewritten_and_length_matches(self):
        r, data = self.req("POST", "/files/upload-url", body=b"{}", headers={"Content-Type": "application/json"})
        self.assertEqual(r.status, 200)
        self.assertNotIn(REAL.encode(), data)
        doc = json.loads(data)
        self.assertEqual(doc["url"], url(host=PROXY))  # & decodes to & and the query string is untouched
        self.assertEqual(int(r.getheader("Content-Length")), len(data))

    def test_every_url_in_a_multipart_response_is_rewritten(self):
        r, data = self.req("POST", "/files/multipart-upload-urls", body=b"{}")
        u = json.loads(data)["urls"][0]
        self.assertEqual(u["partURLs"], [url(host=PROXY, key="k?partNumber=%d" % i) for i in (1, 2, 3)])
        self.assertEqual(u["completeURL"], url(host=PROXY, key="k?uploadId=x"))

    def test_only_our_bucket_on_the_real_endpoint_is_rewritten(self):
        r, data = self.req("GET", "/files/download/v3/1")
        doc = json.loads(data)
        self.assertEqual(doc["url"], url(host=PROXY))
        self.assertEqual(doc["other"], url(bucket="someone-else"))
        self.assertEqual(doc["elsewhere"], url(host="s3.other-provider.com"))

    def test_json_escaped_slashes_are_rewritten(self):
        r, data = self.req("GET", "/escaped")
        self.assertEqual(json.loads(data)["url"], "https://%s/%s/k?x=1" % (PROXY, BUCKET))

    def test_redirect_location_is_rewritten(self):
        r, data = self.req("GET", "/redirect")
        self.assertEqual(r.status, 307)
        self.assertEqual(r.getheader("Location"), url(host=PROXY))

    def test_compressed_json_passes_through_untouched(self):
        r, data = self.req("GET", "/gzip", headers={"Accept-Encoding": "gzip"})
        self.assertEqual(r.getheader("Content-Encoding"), "gzip")
        self.assertEqual(json.loads(gzip.decompress(data))["url"], url())

    def test_error_responses_are_rewritten_and_keep_their_status(self):
        r, data = self.req("GET", "/error")
        self.assertEqual(r.status, 401)
        self.assertEqual(json.loads(data)["hint"], url(host=PROXY))

    def test_non_json_bodies_pass_through_untouched(self):
        r, data = self.req("GET", "/binary")
        self.assertEqual(data, bytes(range(256)) * 20000 + url().encode())
        r, data = self.req("GET", "/text")
        self.assertEqual(data, ("see " + url()).encode())

    def test_responses_carry_a_marker_header(self):
        r, _ = self.req("GET", "/ping")
        self.assertEqual(r.getheader("X-Ente-Link-Rewrite"), "on")

    # ---- forwarding
    def test_method_path_query_body_and_headers_reach_museum(self):
        body = b'{"a":1}' * 1000
        r, data = self.req("PUT", "/echo?x=1&y=%2F", body=body,
                           headers={"X-Auth-Token": "tok", "X-Forwarded-For": "203.0.113.9", "Content-Type": "application/json",
                                    "Connection": "keep-alive, X-Secret-Hop", "X-Secret-Hop": "drop-me", "Keep-Alive": "timeout=5",
                                    "TE": "trailers", "Accept-Encoding": "gzip"})
        self.assertEqual(r.status, 200)
        seen = FakeMuseum.seen[-1]
        self.assertEqual((seen["method"], seen["path"], seen["body"]), ("PUT", "/echo?x=1&y=%2F", body))
        h = {k.lower(): v for k, v in seen["headers"].items()}
        self.assertEqual(h["x-auth-token"], "tok")
        self.assertEqual(h["x-forwarded-for"], "203.0.113.9")
        self.assertEqual(h["content-type"], "application/json")
        for hop in ("keep-alive", "te", "x-secret-hop"):
            self.assertNotIn(hop, h)
        self.assertEqual(h.get("accept-encoding"), "identity")  # so JSON comes back rewritable

    def test_chunked_request_bodies_are_forwarded(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.putrequest("POST", "/echo")
        c.putheader("Transfer-Encoding", "chunked")
        c.endheaders()
        for part in (b"hello ", b"chunked ", b"world"):
            c.send(b"%x\r\n%s\r\n" % (len(part), part))
        c.send(b"0\r\n\r\n")
        r = c.getresponse()
        self.assertEqual(json.loads(r.read())["body"], "hello chunked world")
        c.close()
        self.assertEqual(FakeMuseum.seen[-1]["body"], b"hello chunked world")

    def test_head_and_no_content_responses_have_no_body(self):
        r, data = self.req("HEAD", "/files/download/v3/1")
        self.assertEqual((r.status, data), (200, b""))
        r, data = self.req("DELETE", "/nocontent")
        self.assertEqual((r.status, data), (204, b""))

    def test_keep_alive_serves_several_requests_on_one_connection(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        for _ in range(3):
            r, data = self.req("GET", "/ping", conn=c)
            self.assertEqual(json.loads(data), {"message": "pong"})
        c.close()

    def test_oversized_request_bodies_are_refused_not_buffered(self):
        old, rw.MAX_BODY = rw.MAX_BODY, 1000
        try:
            r, data = self.req("POST", "/echo", body=b"x" * 2000)
            self.assertEqual(r.status, 413)
            self.assertEqual(FakeMuseum.seen, [])  # never forwarded
            c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
            c.putrequest("POST", "/echo")
            c.putheader("Transfer-Encoding", "chunked")
            c.endheaders()
            c.send(b"7d0\r\n" + b"x" * 2000 + b"\r\n0\r\n\r\n")
            self.assertEqual(c.getresponse().status, 413)
            c.close()
            r, data = self.req("POST", "/echo", body=b"x" * 900)
            self.assertEqual(r.status, 200)
        finally:
            rw.MAX_BODY = old

    def test_handler_has_a_socket_timeout(self):
        self.assertTrue(0 < rw.make_handler(self.proxy.RequestHandlerClass.__mro__ and rw.Config(("127.0.0.1", 0), ("127.0.0.1", 1), REAL, PROXY, BUCKET)).timeout <= 300)

    def test_parallel_requests(self):
        # a burst of simultaneous connections (the app loads many thumbnails at once) must not be refused
        n, results, errors = 100, [], []
        go = threading.Event()

        def one():
            go.wait()
            try:
                r, data = self.req("POST", "/files/upload-url", body=b"{}")
                results.append(json.loads(data)["url"] == url(host=PROXY))
            except Exception as e:  # noqa: BLE001 - collected and reported below
                errors.append(repr(e))
        ts = [threading.Thread(target=one) for _ in range(n)]
        [t.start() for t in ts]
        go.set()
        [t.join() for t in ts]
        self.assertEqual(errors, [])
        self.assertEqual(results, [True] * n)

    def test_listen_backlog_is_large(self):
        self.assertGreaterEqual(rw.Server.request_queue_size, 128)


class UpstreamDownTest(unittest.TestCase):
    def test_502_when_museum_is_unreachable(self):
        cfg = rw.Config(listen=("127.0.0.1", 0), upstream=("127.0.0.1", free_port()), from_host=REAL, to_host=PROXY, bucket=BUCKET)
        cfg.quiet = True
        srv = rw.make_server(cfg)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            c = http.client.HTTPConnection("127.0.0.1", srv.server_address[1], timeout=10)
            c.request("GET", "/ping")
            r = c.getresponse()
            self.assertEqual(r.status, 502)
            r.read()
            c.close()
        finally:
            srv.shutdown()
            srv.server_close()


class PureFunctionTest(unittest.TestCase):
    def test_rewrite_bytes(self):
        f = rw.make_rewriter(REAL, BUCKET, PROXY)
        self.assertEqual(f(b'["https://%s/%s/a"]' % (REAL.encode(), BUCKET.encode())), b'["https://%s/%s/a"]' % (PROXY.encode(), BUCKET.encode()))
        # a bucket whose name only starts with ours is someone else's
        self.assertEqual(f(b"https://%s/%s-old/a" % (REAL.encode(), BUCKET.encode())), b"https://%s/%s-old/a" % (REAL.encode(), BUCKET.encode()))
        self.assertEqual(f(b"http://%s/%s/a" % (REAL.encode(), BUCKET.encode())), b"http://%s/%s/a" % (REAL.encode(), BUCKET.encode()))

    def test_config_rejects_bad_values(self):
        for kw in ({"from_host": "https://x"}, {"to_host": "a b"}, {"bucket": "a/b"}, {"bucket": ""}, {"to_host": REAL}):
            args = dict(listen=("127.0.0.1", 0), upstream=("127.0.0.1", 1), from_host=REAL, to_host=PROXY, bucket=BUCKET)
            args.update(kw)
            with self.assertRaises(ValueError, msg=str(kw)):
                rw.Config(**args)

    def test_config_from_argv(self):
        c = rw.Config.from_argv(["--listen", "127.0.0.1:8081", "--upstream", "127.0.0.1:8080", "--from-host", REAL,
                                 "--to-host", PROXY, "--bucket", BUCKET])
        self.assertEqual((c.listen, c.upstream, c.to_host), (("127.0.0.1", 8081), ("127.0.0.1", 8080), PROXY))


if __name__ == "__main__":
    unittest.main()
