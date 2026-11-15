import sys, subprocess
import boto3, yaml
from botocore.config import Config
m = yaml.safe_load(open("/opt/my-ente/museum.yaml"))["s3"]["b2-eu-cen"]
c = boto3.client("s3", endpoint_url="https://" + m["endpoint"], region_name=m["region"], aws_access_key_id=m["key"],
                 aws_secret_access_key=m["secret"], config=Config(s3={"addressing_style": "path"}))
keys = [k for k in open(sys.argv[1]).read().split() if k]
sizes = {}
for k in keys:
    try:
        sizes[k] = c.head_object(Bucket=m["bucket"], Key=k)["ContentLength"]
    except Exception:
        sizes[k] = None
q = "select object_key, size from object_keys where object_key in (%s)" % ",".join("'%s'" % k.replace("'", "") for k in keys)
out = subprocess.run(["docker", "compose", "exec", "-T", "postgres", "psql", "-U", "pguser", "-d", "ente_db", "-At", "-F", " ", "-c", q],
                     cwd="/opt/my-ente", capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
db = {}
for line in out.splitlines():
    if line.strip():
        k, n = line.split()
        db[k] = int(n)
present = all(sizes[k] is not None for k in keys)
match = all(db.get(k) == sizes[k] for k in keys)
big = max([v for v in sizes.values() if v] or [0])
print("%s %d objects in the bucket (all present: %s), sizes equal museum's records: %s, largest %.1f MB" % (
    "PASS" if keys and present and match else "FAIL", len(keys), present, match, big / 1e6))
