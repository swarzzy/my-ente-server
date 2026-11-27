"""End-to-end tests of the S3 proxy site against the real bucket, with real pre-signed links (as museum hands them out).

Run on the server, as root, with the proxy site installed (S3_PROXY_HOST set, `install` run):
    python3 tests/proxy_e2e_s3.py -v
Uses the bucket keys from /opt/my-ente/museum.yaml. Creates objects under e2e-proxy-test/ and deletes them.
The proxy state (on/off) does not matter here: the proxy site serves links in both states.
"""
import hashlib
import os
import re
import subprocess
import time
import unittest
import urllib.error
import urllib.request

import boto3
import yaml
from botocore.config import Config

M = yaml.safe_load(open("/opt/my-ente/museum.yaml"))["s3"]["b2-eu-cen"]
ENV = dict(re.findall(r"^([A-Z0-9_]+)=(\S*)", open(os.environ.get("ENV_FILE", "/root/ente-server/ente-setup.env")).read(), re.M))
PROXY, REAL, BUCKET = ENV["S3_PROXY_HOST"], M["endpoint"], M["bucket"]
DOMAIN = ENV["DOMAIN"]
PREFIX = "e2e-proxy-test/%d/" % int(time.time())
s3 = boto3.client("s3", endpoint_url="https://" + REAL, region_name=M["region"], aws_access_key_id=M["key"],
                  aws_secret_access_key=M["secret"], config=Config(s3={"addressing_style": "path"}, signature_version="s3v4"))


def via_proxy(u):
    assert u.startswith("https://%s/%s/" % (REAL, BUCKET)), u
    return u.replace("https://%s/" % REAL, "https://%s/" % PROXY, 1)


def presign(op, expires=600, **params):
    return via_proxy(s3.generate_presigned_url(op, Params=dict(Bucket=BUCKET, **params), ExpiresIn=expires))


def http(method, url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return r.status, r.headers, r.read()  # header lookups are case-insensitive (Caddy sends "Etag")
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def code(body):
    m = re.search(rb"<Code>([^<]+)</Code>", body)
    return m.group(1).decode() if m else None


class ProxyE2E(unittest.TestCase):
    @classmethod
    def tearDownClass(cls):
        keys = [o["Key"] for o in s3.list_objects_v2(Bucket=BUCKET, Prefix=PREFIX).get("Contents", [])]
        for k in keys:
            s3.delete_object(Bucket=BUCKET, Key=k)
        left = s3.list_objects_v2(Bucket=BUCKET, Prefix=PREFIX).get("KeyCount", 0)
        assert left == 0, "test objects left behind under " + PREFIX

    def test_upload_download_head_and_range(self):
        data = os.urandom(1 << 20)
        st, h, _ = http("PUT", presign("put_object", Key=PREFIX + "a.bin"), data)
        self.assertEqual(st, 200)
        st, h, got = http("GET", presign("get_object", Key=PREFIX + "a.bin"))
        self.assertEqual((st, got), (200, data))
        st, h, got = http("HEAD", presign("head_object", Key=PREFIX + "a.bin"))
        self.assertEqual((st, int(h["Content-Length"])), (200, len(data)))
        st, h, got = http("GET", presign("get_object", Key=PREFIX + "a.bin"), headers={"Range": "bytes=1000-1999"})
        self.assertEqual((st, got), (206, data[1000:2000]))
        # and the object really is in the bucket, byte for byte
        self.assertEqual(s3.get_object(Bucket=BUCKET, Key=PREFIX + "a.bin")["Body"].read(), data)

    def test_multipart_upload_like_the_apps(self):
        # museum creates the upload and signs the part and complete links; the app PUTs the parts and POSTs the completion
        key = PREFIX + "multi.bin"
        parts = [os.urandom(5 << 20), os.urandom(5 << 20), os.urandom(1 << 20)]
        up = s3.create_multipart_upload(Bucket=BUCKET, Key=key)["UploadId"]
        etags = []
        for i, p in enumerate(parts, 1):
            st, h, _ = http("PUT", presign("upload_part", Key=key, UploadId=up, PartNumber=i), p)
            self.assertEqual(st, 200, "part %d" % i)
            etags.append(h["ETag"])
        xml = "<CompleteMultipartUpload>%s</CompleteMultipartUpload>" % "".join(
            "<Part><PartNumber>%d</PartNumber><ETag>%s</ETag></Part>" % (i, e) for i, e in enumerate(etags, 1))
        st, h, body = http("POST", presign("complete_multipart_upload", Key=key, UploadId=up), xml.encode(),
                           {"Content-Type": "text/xml"})
        self.assertEqual(st, 200, body[:300])
        st, h, got = http("GET", presign("get_object", Key=key))
        self.assertEqual((st, hashlib.sha256(got).hexdigest()), (200, hashlib.sha256(b"".join(parts)).hexdigest()))

    def test_large_transfer_streams_both_ways(self):
        data = os.urandom(50 << 20)
        t0 = time.time()
        st, _, _ = http("PUT", presign("put_object", Key=PREFIX + "big.bin"), data)
        t1 = time.time()
        st2, _, got = http("GET", presign("get_object", Key=PREFIX + "big.bin"))
        t2 = time.time()
        self.assertEqual((st, st2), (200, 200))
        self.assertEqual(hashlib.sha256(got).digest(), hashlib.sha256(data).digest())
        print("\n    50 MB through the proxy: upload %.1f MB/s, download %.1f MB/s" % (50 / (t1 - t0), 50 / (t2 - t1)), end=" ")

    def test_proxy_does_not_weaken_authentication(self):
        u = presign("get_object", Key=PREFIX + "a.bin")
        st, _, body = http("GET", re.sub(r"X-Amz-Signature=[0-9a-f]+", "X-Amz-Signature=" + "0" * 64, u))
        self.assertEqual((st, code(body)), (403, "SignatureDoesNotMatch"))
        st, _, body = http("GET", "https://%s/%s/%sa.bin" % (PROXY, BUCKET, PREFIX))
        self.assertEqual(st, 403)
        expired = presign("get_object", expires=1, Key=PREFIX + "a.bin")
        time.sleep(3)
        st, _, body = http("GET", expired)
        self.assertEqual(st, 403)

    def test_only_the_photo_bucket_and_app_methods_are_forwarded(self):
        for path in ("/", "/other-bucket/x", "/%s-other/x" % BUCKET, "/%s" % BUCKET):
            st, _, _ = http("GET", "https://%s%s" % (PROXY, path))
            self.assertEqual(st, 404, path)
        st, _, _ = http("DELETE", presign("delete_object", Key=PREFIX + "a.bin"))
        self.assertEqual(st, 404)  # never reaches the provider

    def test_cors_preflight_answers_exactly_like_the_provider(self):
        # the proxy must not change CORS: the web app's origin is allowed, and any other origin gets the provider's own
        # answer (IDrive allows every origin on preflight, whatever the bucket rule says)
        cors = ("Access-Control-Allow-Origin", "Access-Control-Allow-Methods", "Access-Control-Allow-Headers",
                "Access-Control-Max-Age", "Access-Control-Allow-Credentials")
        for origin in ("https://web." + DOMAIN, "https://albums." + DOMAIN, "https://evil.example"):
            hdr = {"Origin": origin, "Access-Control-Request-Method": "PUT", "Access-Control-Request-Headers": "content-type"}
            _, hp, _ = http("OPTIONS", "https://%s/%s/%sx" % (PROXY, BUCKET, PREFIX), headers=hdr)
            _, hd, _ = http("OPTIONS", "https://%s/%s/%sx" % (REAL, BUCKET, PREFIX), headers=hdr)
            self.assertEqual({k: hp.get(k) for k in cors}, {k: hd.get(k) for k in cors}, origin)
        _, hp, _ = http("OPTIONS", "https://%s/%s/%sx" % (PROXY, BUCKET, PREFIX),
                        headers={"Origin": "https://web." + DOMAIN, "Access-Control-Request-Method": "PUT"})
        self.assertEqual(hp.get("Access-Control-Allow-Origin"), "https://web." + DOMAIN)

    def test_response_headers_the_apps_need_are_passed_on(self):
        # multipart uploads read the ETag of each part; downloads need length and ranges
        _, h, _ = http("PUT", presign("put_object", Key=PREFIX + "h.bin"), b"x" * 100,
                       headers={"Origin": "https://web." + DOMAIN})
        self.assertTrue(h.get("ETag"))
        direct = urllib.request.urlopen(urllib.request.Request(
            s3.generate_presigned_url("put_object", Params={"Bucket": BUCKET, "Key": PREFIX + "h2.bin"}, ExpiresIn=600),
            data=b"x" * 100, method="PUT", headers={"Origin": "https://web." + DOMAIN}), timeout=60).headers
        for k in ("Access-Control-Allow-Origin", "Access-Control-Expose-Headers"):
            self.assertEqual(h.get(k), direct.get(k), k)
        _, h, _ = http("GET", presign("get_object", Key=PREFIX + "h.bin"), headers={"Range": "bytes=0-9"})
        self.assertEqual((h.get("Content-Range"), h.get("Content-Length")), ("bytes 0-9/100", "10"))

    def test_tls_certificate_is_valid_for_the_proxy_host(self):
        out = subprocess.run(["curl", "-sS", "-o", "/dev/null", "-w", "%{ssl_verify_result}", "https://%s/" % PROXY],
                             capture_output=True, text=True)
        self.assertEqual(out.stdout, "0", out.stderr)


if __name__ == "__main__":
    unittest.main()
