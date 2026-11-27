#!/usr/bin/env python3
"""ente-s3-rewrite: sits between Caddy and museum while the S3 proxy is on.

Museum hands out pre-signed links to the photo bucket (https://<real endpoint>/<bucket>/...) for every upload and download.
This forwards all API traffic to museum unchanged and, in JSON responses and redirect headers, replaces that prefix with
https://<proxy host>/<bucket>/, which Caddy forwards to the real endpoint with the original Host. The signature covers the
host, path and query only, so the links stay valid. Photo data never passes through here. Python stdlib only.

Usage: ente-s3-rewrite --listen 127.0.0.1:8081 --upstream 127.0.0.1:8080 --from-host s3.real.example --to-host s3.my.domain --bucket b
"""
import argparse
import http.client
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$")
BUCKET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
HOP = {"connection", "keep-alive", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade",
       "proxy-authorization", "proxy-authenticate"}
MAX_BODY = 16 << 20     # API request bodies are small JSON; photo data never comes through here
MAX_REWRITE = 64 << 20  # JSON responses that announce a larger Content-Length pass through unchanged. Museum (Go) sends
                        # anything over about 2 KB without one, chunked: those are always read whole; MemoryMax caps the service
CHUNK = 64 << 10


def make_rewriter(from_host, bucket, to_host):
    """bytes -> bytes: https://FROM/BUCKET/ (also JSON-escaped https:\\/\\/FROM\\/BUCKET\\/) becomes the TO host."""
    pairs = []
    for sep in ("/", "\\/"):
        pre = "https:" + sep + sep
        pairs.append(((pre + from_host + sep + bucket + sep).encode(), (pre + to_host + sep + bucket + sep).encode()))

    def rewrite(data):
        for a, b in pairs:
            data = data.replace(a, b)
        return data
    return rewrite


def _hostport(s):
    host, _, port = s.rpartition(":")
    if not host or not port.isdigit():
        raise ValueError("expected HOST:PORT, got %r" % s)
    return host, int(port)


class Config:
    def __init__(self, listen, upstream, from_host, to_host, bucket, quiet=False):
        for name, h in (("from_host", from_host), ("to_host", to_host)):
            if not isinstance(h, str) or not HOST_RE.match(h):
                raise ValueError("%s must be a bare host name, got %r" % (name, h))
        if not BUCKET_RE.match(bucket or ""):
            raise ValueError("bad bucket name %r" % bucket)
        if from_host == to_host:
            raise ValueError("from_host and to_host are the same")
        self.listen, self.upstream = tuple(listen), tuple(upstream)
        self.from_host, self.to_host, self.bucket = from_host, to_host, bucket
        self.quiet = quiet  # no error lines on stderr (tests)

    @classmethod
    def from_argv(cls, argv):
        p = argparse.ArgumentParser(prog="ente-s3-rewrite")
        p.add_argument("--listen", default="127.0.0.1:8081")
        p.add_argument("--upstream", default="127.0.0.1:8080")
        for a in ("--from-host", "--to-host", "--bucket"):
            p.add_argument(a, required=True)
        a = p.parse_args(argv)
        return cls(_hostport(a.listen), _hostport(a.upstream), a.from_host, a.to_host, a.bucket)


def make_handler(cfg):
    rewrite = make_rewriter(cfg.from_host, cfg.bucket, cfg.to_host)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        timeout = 120  # socket timeout: a stalled client cannot hold a thread (and its buffered body) for ever
        server_version = "ente-s3-rewrite"
        sys_version = ""

        def log_message(self, fmt, *args):  # errors only (journal); museum logs the requests
            pass

        def log_error(self, fmt, *args):
            if not cfg.quiet:
                sys.stderr.write("ente-s3-rewrite: " + (fmt % args) + "\n")

        def _request_body(self):
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                out, total = [], 0
                while True:
                    line = self.rfile.readline(1024)
                    size = int(line.split(b";")[0].strip() or b"0", 16)
                    if size == 0:
                        while self.rfile.readline(1024) not in (b"\r\n", b"\n", b""):
                            pass  # trailers
                        return b"".join(out)
                    total += size
                    if total > MAX_BODY:
                        raise OverflowError
                    out.append(self.rfile.read(size))
                    self.rfile.readline(1024)
            n = int(self.headers.get("Content-Length") or 0)
            if n > MAX_BODY:
                raise OverflowError
            return self.rfile.read(n) if n > 0 else None

        def _drop(self, headers):
            listed = {t.strip().lower() for t in headers.get("Connection", "").split(",") if t.strip()}
            return HOP | listed

        def _proxy(self):
            try:
                body = self._request_body()
            except OverflowError:  # not read: answer and drop the connection
                msg = b'{"code":"TOO_LARGE","message":"request body too large"}'
                self.close_connection = True
                self.send_response(413)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(msg)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(msg)
                return
            drop = self._drop(self.headers)
            fwd = {k: v for k, v in self.headers.items() if k.lower() not in drop and k.lower() not in ("accept-encoding", "content-length")}
            fwd["Accept-Encoding"] = "identity"
            if body is not None:
                fwd["Content-Length"] = str(len(body))
            try:
                up = http.client.HTTPConnection(*cfg.upstream, timeout=300)
                up.request(self.command, self.path, body=body, headers=fwd)
                r = up.getresponse()
            except OSError as e:
                self.log_error("upstream %s:%d: %s", cfg.upstream[0], cfg.upstream[1], e)
                msg = b'{"code":"BAD_GATEWAY","message":"museum unreachable"}'
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(msg)))
                self.send_header("X-Ente-Link-Rewrite", "on")
                self.end_headers()
                self.wfile.write(msg)
                return
            try:
                self._respond(r)
            finally:
                up.close()

        def _respond(self, r):
            drop = self._drop(r.headers)
            ctype = (r.getheader("Content-Type") or "").lower()
            clen = r.getheader("Content-Length")
            no_body = self.command == "HEAD" or r.status in (204, 304) or 100 <= r.status < 200
            # museum is asked for identity: a compressed body (never seen) passes untouched, its links then pointing at the bucket
            plain = (r.getheader("Content-Encoding") or "identity").lower() == "identity"
            rewritable = "json" in ctype and plain and not no_body and (clen is None or int(clen) <= MAX_REWRITE)
            headers = []
            for k, v in r.getheaders():
                kl = k.lower()
                if kl in drop or kl in ("server", "date"):
                    continue
                if kl == "location":
                    v = rewrite(v.encode("latin-1")).decode("latin-1")
                if rewritable and kl in ("content-length", "content-encoding"):
                    continue  # length recomputed; an identity encoding header is dropped
                headers.append((k, v))
            if rewritable:
                data = rewrite(r.read())
                headers.append(("Content-Length", str(len(data))))
            self.send_response(r.status, r.reason)
            for k, v in headers:
                self.send_header(k, v)
            self.send_header("X-Ente-Link-Rewrite", "on")
            if no_body:
                self.end_headers()
                r.read()
                return
            if rewritable:
                self.end_headers()
                self.wfile.write(data)
                return
            if clen is None:  # unknown length: stream chunked
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                while True:
                    part = r.read1(CHUNK)
                    if not part:
                        break
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
                self.wfile.write(b"0\r\n\r\n")
                return
            self.end_headers()
            while True:
                part = r.read(CHUNK)
                if not part:
                    break
                self.wfile.write(part)

        do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_OPTIONS = do_PATCH = _proxy

    return Handler


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 1024  # listen backlog; the default 5 resets connections when the app opens many at once


def make_server(cfg):
    return Server(cfg.listen, make_handler(cfg))


def main(argv=None):
    cfg = Config.from_argv(sys.argv[1:] if argv is None else argv)
    srv = make_server(cfg)
    print("ente-s3-rewrite: %s:%d -> %s:%d, https://%s/%s/ -> https://%s/%s/" % (
        cfg.listen + cfg.upstream + (cfg.from_host, cfg.bucket, cfg.to_host, cfg.bucket)), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
