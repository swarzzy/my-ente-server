#!/usr/bin/env bash
# s3-speedtest.sh - measure upload and download speed between this machine and an S3 bucket (IDrive e2 by default).
# Needs rclone (https://rclone.org/downloads/). Uploads one random file to <bucket>/speedtest/, downloads it, deletes it.
# Usage: ./s3-speedtest.sh            (asks for the keys)
#        SIZE_MB=500 S3_BUCKET=my-bucket S3_ACCESS_KEY=... S3_SECRET_KEY=... ./s3-speedtest.sh
set -euo pipefail
ENDPOINT=${S3_ENDPOINT:-s3.eu-west-4.idrivee2.com}
REGION=${S3_REGION:-eu-west-4}
BUCKET=${S3_BUCKET:-ente-dev}
PROVIDER=${S3_PROVIDER:-IDrive}
SIZE_MB=${SIZE_MB:-100}
STREAMS=${STREAMS:-4}

command -v rclone >/dev/null || { echo "rclone not found: install it from https://rclone.org/downloads/" >&2; exit 1; }
KEY=${S3_ACCESS_KEY:-}; SECRET=${S3_SECRET_KEY:-}
[[ -n $KEY ]] || read -rp "Access key ID: " KEY
[[ -n $SECRET ]] || { read -rsp "Secret access key: " SECRET; echo; }

tmp=$(mktemp -d); : >"$tmp/rclone.conf"
# the remote exists only in this process's environment: nothing is written to your rclone config
export RCLONE_CONFIG="$tmp/rclone.conf" RCLONE_CONFIG_SPEED_TYPE=s3 RCLONE_CONFIG_SPEED_PROVIDER="$PROVIDER" \
  RCLONE_CONFIG_SPEED_ENDPOINT="$ENDPOINT" RCLONE_CONFIG_SPEED_REGION="$REGION" \
  RCLONE_CONFIG_SPEED_ACCESS_KEY_ID="$KEY" RCLONE_CONFIG_SPEED_SECRET_ACCESS_KEY="$SECRET" RCLONE_CONFIG_SPEED_NO_CHECK_BUCKET=true
obj="speed:$BUCKET/speedtest/$(date +%s)-$RANDOM.bin"
cleanup() { rclone deletefile "$obj" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

now() { if [[ -n ${EPOCHREALTIME:-} ]]; then echo "${EPOCHREALTIME/,/.}"; else date +%s; fi; }
rate() { awk -v s="$1" -v e="$2" -v mb="$SIZE_MB" 'BEGIN {t = e - s; if (t <= 0) t = 1; printf "%.1f s = %.1f MB/s (%.0f Mbit/s)", t, mb / t, mb * 8 / t}'; }

echo "endpoint $ENDPOINT, bucket $BUCKET, $SIZE_MB MB, $STREAMS parallel streams"
if command -v curl >/dev/null; then
  curl -s -o /dev/null -m 10 -w "latency:  connect %{time_connect}s, TLS %{time_appconnect}s, first byte %{time_starttransfer}s\n" "https://$ENDPOINT/" || echo "latency:  endpoint not reachable with curl"
fi
dd if=/dev/urandom of="$tmp/up.bin" bs=1048576 count="$SIZE_MB" 2>/dev/null
t0=$(now); rclone copyto "$tmp/up.bin" "$obj" --s3-upload-concurrency "$STREAMS"; t1=$(now)
echo "upload:   $(rate "$t0" "$t1")"
rclone copyto "$obj" "$tmp/down.bin" --multi-thread-streams "$STREAMS"; t2=$(now)
echo "download: $(rate "$t1" "$t2")"
cmp -s "$tmp/up.bin" "$tmp/down.bin" && echo "file intact; test object deleted" || echo "WARNING: the downloaded file differs"
