"""Browser end-to-end test of the S3 proxy with the real Ente web app (Playwright, Chromium).

Driven by tests/proxy_browser_e2e.sh on the server, which runs this in the official Playwright container with the
working directory mounted at /w, opens registration for the test, answers the hand-offs below and cleans up:
  /w/need_code      -> the runner writes the sign-up code to /w/code.txt
  /w/need_proxy_off -> the runner turns the proxy off and writes /w/proxy_off_done
Prints one JSON line per phase with the requests seen, and exits non-zero on any failed expectation.
"""
import json
import os
import struct
import sys
import time
import zlib
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright

WEB, PROXY, REAL = os.environ["WEB"], os.environ["PROXY"], os.environ["REAL"]
EMAIL, PW = os.environ["EMAIL"], os.environ.get("TEST_PASSWORD", "E2e-Proxy-Passw0rd-xyz!")
FAILS = []


def expect(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what, flush=True)
    if not cond:
        FAILS.append(what)


def png(path, w, h):
    raw = b"".join(b"\x00" + os.urandom(w * 3) for _ in range(h))  # noise: incompressible, so the file is ~w*h*3 bytes

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(raw, 1)) + chunk(b"IEND", b""))


def handoff(name, answer, timeout=180):
    open("/w/" + name, "w").write("1")
    for _ in range(timeout):
        if os.path.exists("/w/" + answer):
            return open("/w/" + answer).read().strip()
        time.sleep(1)
    raise RuntimeError("no answer to " + name)


class Net:
    """Records every request the browser context makes (pages and workers): method, host, path, query, the status of the
    response if one arrived, and the failure if any. Chromium reports some completed requests as aborted when the app
    does not read the body, so a response status counts as success even if a failure follows."""
    def __init__(self, ctx):
        self.log = []
        self.by_req = {}
        ctx.on("request", self.on_request)
        ctx.on("response", lambda r: self.by_req.get(id(r.request), {}).__setitem__("status", r.status))
        ctx.on("requestfailed", lambda r: self.by_req.get(id(r), {}).setdefault("failure", r.failure))

    def on_request(self, r):
        u = urlsplit(r.url)
        e = {"m": r.method, "host": u.hostname, "path": u.path, "q": u.query, "type": r.resource_type, "status": None}
        self.by_req[id(r)] = e
        self.log.append(e)

    def to(self, host, method=None):
        return [e for e in self.log if e["host"] == host and (method is None or e["m"] == method)]

    def reset(self):
        self.log = []
        self.by_req = {}

    def failed(self, host):
        return [e for e in self.to(host) if not (isinstance(e["status"], int) and e["status"] < 400) and e["m"] != "OPTIONS"]

    def summary(self, host):
        n = {}
        for e in self.to(host):
            k = "%s %s %s" % (e["m"], e["type"], e["status"] if e["status"] is not None else e.get("failure"))
            n[k] = n.get(k, 0) + 1
        return n


def gallery_count(pg):
    t = pg.inner_text("body")
    for n in range(0, 20):
        if ("%d memories" % n) in t or (n == 1 and "1 memory" in t):
            return n
    return -1


def login(pg):
    pg.goto("https://" + WEB + "/", wait_until="networkidle")
    pg.locator("input[name=email]").fill(EMAIL)
    pg.locator("button[type=submit]").first.click()
    pg.locator("input[type=password]").wait_for()
    pg.locator("input[type=password]").first.fill(PW)
    pg.keyboard.press("Enter")
    pg.get_by_text("Upload", exact=True).first.wait_for(timeout=120000)
    time.sleep(3)


def signup(browser):
    ctx = browser.new_context()
    pg = ctx.new_page()
    pg.set_default_timeout(60000)
    pg.goto("https://" + WEB + "/", wait_until="networkidle")
    pg.get_by_text("Signup", exact=True).click()
    pg.locator("input[name=email]").fill(EMAIL)
    pws = pg.locator("input[type=password]")
    pws.nth(0).fill(PW)
    pws.nth(1).fill(PW)
    pg.locator("label").filter(has=pg.locator("input[name=acceptedTerms]")).click(position={"x": 10, "y": 10})
    pg.get_by_role("button", name="Create account").click()
    pg.wait_for_function("() => !document.querySelector('input[name=confirmPassword]')", timeout=240000)
    time.sleep(2)
    code = handoff("need_code", "code.txt")
    ins = pg.locator("input:visible")
    if ins.count() >= 6:
        for k, ch in enumerate(code):
            ins.nth(k).fill(ch)
    else:
        ins.first.fill(code)
    pg.keyboard.press("Enter")
    pg.get_by_text("recovery key", exact=False).first.wait_for(timeout=120000)
    ctx.close()


def upload(pg, files):
    pg.get_by_role("button", name="Upload").first.click()
    time.sleep(2)
    with pg.expect_file_chooser() as fc:
        pg.get_by_role("button", name="Files").click()
    fc.value.set_files(files)
    time.sleep(3)
    pg.get_by_text("New album", exact=True).last.click()
    time.sleep(2)
    pg.locator("input:visible").last.fill("proxy-e2e")
    pg.keyboard.press("Enter")
    time.sleep(3)
    start = pg.get_by_role("button", name="Start upload")  # shown for more than one file
    if start.count() and start.first.is_visible():
        start.first.click()
    for _ in range(120):
        time.sleep(3)
        t = pg.inner_text("body").lower()
        if "upload complete" in t or "%d uploaded" % len(files) in t:
            return True
        if "upload failed" in t or "failed" in t and "upload" in t:
            break
    pg.screenshot(path="/w/upload-failed.png")
    return False


def open_first_photo(pg):
    """Click the first thumbnail, wait for the full file to load, close the viewer."""
    pg.locator("img[src^='blob:']").first.click()
    time.sleep(12)
    pg.keyboard.press("Escape")
    time.sleep(2)


def thumbnails_rendered(pg):
    return pg.evaluate("() => [...document.querySelectorAll('img')].filter(i => i.src.startsWith('blob:') && i.naturalWidth > 0).length")


def delete_account(pg):
    pg.mouse.click(35, 677)  # settings (bottom left)
    time.sleep(3)
    pg.get_by_text("Delete account", exact=True).click()
    time.sleep(3)
    dlg = pg.get_by_role("dialog").filter(has_text="Why are you leaving").last
    dlg.locator("[role=combobox]").first.click()
    time.sleep(1)
    pg.locator("[role=option]").filter(has_text="My reason isn't listed").click()
    dlg.locator("textarea:visible").first.fill("automated proxy test account")
    dlg.get_by_role("button", name="Continue").click()
    bt = pg.get_by_role("button", name="Delete Ente account")
    bt.wait_for(state="visible")
    pg.get_by_text("I understand this deletes").click()
    bt.click()
    time.sleep(3)
    pg.get_by_role("dialog").last.locator("input[type=password]").fill(PW)
    pg.get_by_role("button", name="Authenticate").click()
    pg.locator("input[name=email]").wait_for(timeout=60000)  # back on the login page


def run_phases(b):
    signup(b)
    ctx = b.new_context()
    net = Net(ctx)
    pg = ctx.new_page()
    pg.set_default_timeout(60000)

    print("== proxy ON: upload", flush=True)
    login(pg)
    ok = upload(pg, ["/w/upload/small.png", "/w/upload/large.png"])
    expect(ok, "web app uploads a small and a 41 MB photo")
    print("    requests to the proxy: %s" % net.summary(PROXY), flush=True)
    puts = net.to(PROXY, "PUT")
    expect(len(puts) >= 2, "uploads went to the proxy (%d PUTs to %s)" % (len(puts), PROXY))
    parts = [e for e in puts if "partNumber" in e["q"]]
    expect(len(parts) >= 2, "the large photo was uploaded in parts through the proxy (%d part PUTs)" % len(parts))
    expect(len([e for e in net.to(PROXY, "POST") if "uploadId" in e["q"]]) >= 1, "the multipart upload was completed through the proxy")
    expect(not net.to(REAL), "nothing went to %s directly (%d requests)" % (REAL, len(net.to(REAL))))
    expect(not net.failed(PROXY), "every request to the proxy got a 2xx/3xx answer %s" % (net.failed(PROXY)[:2] or ""))
    open("/w/uploaded_keys", "w").write("\n".join(sorted({e["path"].split("/", 2)[2] for e in puts})))

    print("== proxy ON: view", flush=True)
    ctx.close()
    ctx = b.new_context()  # fresh profile: the app's own cache would otherwise serve everything
    net = Net(ctx)
    pg = ctx.new_page()
    pg.set_default_timeout(60000)
    login(pg)
    time.sleep(8)
    expect(gallery_count(pg) == 2, "gallery shows the 2 photos after a reload (%d)" % gallery_count(pg))
    expect(thumbnails_rendered(pg) >= 2, "thumbnails render (%d)" % thumbnails_rendered(pg))
    open_first_photo(pg)
    print("    requests to the proxy: %s" % net.summary(PROXY), flush=True)
    gets = net.to(PROXY, "GET")
    expect(len(gets) >= 2, "thumbnail and photo downloads came through the proxy (%d GETs)" % len(gets))
    expect(not net.failed(PROXY), "every download through the proxy succeeded %s" % (net.failed(PROXY)[:2] or ""))
    expect(not net.to(REAL), "nothing went to %s directly" % REAL)

    print("== proxy OFF: view", flush=True)
    handoff("need_proxy_off", "proxy_off_done")
    ctx.close()
    ctx = b.new_context()  # fresh cache: everything is fetched again
    net = Net(ctx)
    pg = ctx.new_page()
    pg.set_default_timeout(60000)
    login(pg)
    time.sleep(8)
    expect(thumbnails_rendered(pg) >= 2, "thumbnails render with the proxy off (%d)" % thumbnails_rendered(pg))
    open_first_photo(pg)
    print("    requests to %s: %s" % (REAL, net.summary(REAL)), flush=True)
    expect(len(net.to(REAL, "GET")) >= 2, "thumbnail and photo downloads came from %s directly (%d GETs)" % (REAL, len(net.to(REAL, "GET"))))
    expect(not net.failed(REAL), "every direct download succeeded")
    expect(not net.to(PROXY), "nothing went through the proxy (%d requests)" % len(net.to(PROXY)))
    ctx.close()


def cleanup(b):
    print("== cleanup", flush=True)
    ctx = b.new_context()
    pg = ctx.new_page()
    pg.set_default_timeout(60000)
    try:
        login(pg)
        if os.environ.get("MODE") != "delete":
            handoff("need_bucket_check", "bucket_checked")  # the runner checks the uploads before they are deleted
        delete_account(pg)
        expect(True, "test account deleted")
    except Exception as e:  # noqa: BLE001
        pg.screenshot(path="/w/cleanup-failed.png")
        expect(False, "test account deleted (%s: %s)" % (type(e).__name__, str(e).splitlines()[0][:120]))
    ctx.close()


def main():
    with sync_playwright() as p:
        b = p.chromium.launch()
        if os.environ.get("MODE") == "delete":
            cleanup(b)
        else:
            png("/w/upload/small.png", 300, 300)
            png("/w/upload/large.png", 3700, 3700)  # ~41 MB: uploaded in parts (multipart)
            try:
                run_phases(b)
            except Exception as e:  # noqa: BLE001 - reported, then the account is still cleaned up
                expect(False, "test ran to the end (%s: %s)" % (type(e).__name__, str(e).splitlines()[0][:160]))
            cleanup(b)
        b.close()
    print("RESULT %s" % ("PASS" if not FAILS else "FAIL: " + "; ".join(FAILS)), flush=True)
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
