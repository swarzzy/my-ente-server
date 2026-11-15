# ente-server

One script, `ente-setup.sh`, turns a fresh Debian 12/13 VPS into a working, backed-up
[Ente Photos](https://ente.com) server:

- **Caddy** (Let's Encrypt TLS, security headers) is the only public service; Museum, the web apps and Postgres run in Docker on `127.0.0.1`.
- **Photos** are stored in an external S3 bucket (IDrive e2, Backblaze B2, Wasabi, ...). Apps upload and download
  straight to that bucket through links Museum signs, so the VPS needs almost no disk (25 GB is plenty).
- **Backups** go daily to a second S3 bucket: encrypted DB dump + `museum.yaml`, plus a mirror of the photo bucket.

Every subcommand is safe to re-run. Log: `/var/log/ente-setup.log` (no secrets).
The full-featured previous version (local Silo storage, data disk, Storage Box, Syncthing, test mode) is git tag `full-featured-v1`.

## Files

| File | Purpose |
| --- | --- |
| `ente-setup.sh` | the script |
| `ente-setup.env.example` | non-secret config → copy to `ente-setup.env` |
| `ente-setup.secrets.example` | bucket keys + backup passphrase → copy to `ente-setup.secrets`, `chmod 600` |
| `s3-speedtest.sh`, `vps-speedtest.ps1` | optional speed tests from a PC (see "Measuring connection speed") |
| `ente_s3_rewrite.py` | the link rewriter of the optional S3 proxy (installed by the script) |
| `tests/` | tests (see "Tests") |

Both copies are git-ignored. Anything missing from the secrets file is asked at a prompt (never echoed, logged or stored in the env file).

## Fresh install

1. **Buckets.** Create two buckets at two providers if you can. The key for the photo bucket needs read/write/delete and
   permission to set CORS (the script sets it; if the provider refuses it prints what to set by hand).
   Backup bucket: on versioned buckets (B2 keeps old versions by default) add a lifecycle rule "keep only the last version".
2. **DNS.** A (and AAAA) records for `api.`, `web.` and `albums.` under your domain → the VPS, TTL 300.
3. **Config.** Copy `ente-server/` to the VPS, create `ente-setup.env` and `ente-setup.secrets` from the examples.
   `BACKUP_PASSPHRASE` encrypts the config backup: keep it in a password manager, without it the backup is unreadable.
4. **As root:** `./ente-setup.sh deploy` = `bootstrap` + `install` + `backup-setup`. About 5 minutes.
   - `bootstrap`: updates, `ADMIN_USER` (sudo, key only), sshd hardening (no passwords, no root login, port `SSH_PORT`, default 22), UFW `SSH_PORT`/80/443,
     unattended upgrades (reboot 02:00 only when needed), 2 GB swap, fail2ban.
     The admin key is validated first (a placeholder or truncated key is refused, since it would lock you out).
     **Open a second terminal and log in as `ADMIN_USER` before closing the root session** (root login is now off).
     `MaxAuthTries 3`: if your ssh-agent holds many keys use `ssh -o IdentitiesOnly=yes -i KEY`.
   - `install`: Docker, Caddy, Ente's quickstart; edits its files (each edit asserted; fails loudly if the quickstart changed),
     checks the photo bucket (read/write/delete), sets CORS, starts everything.
   - `backup-setup`: rclone remotes, systemd timer (03:00 daily, catches up if missed), first run started.
5. Save `/opt/my-ente/museum.yaml` in your password manager (it holds the keys the database needs).
6. **Sign up the owner first** at `https://web.<domain>`, then family. No SMTP, so codes are in the log: `sudo ./ente-setup.sh codes`.
7. `sudo ./ente-setup.sh lockdown` shows users, makes the oldest the admin (after you confirm) and closes sign-ups.
8. Apps: on Android/Windows tap the welcome screen 7 times and enter `https://api.<domain>`.
9. Storage limit (10 GB by default) is lifted from your PC with the Ente CLI:
   `ente account login`, then `ente admin user update-subscription EMAIL --no-limit` (the login must be < 10 min old). See Ente's CLI docs for pointing it at a custom server.

Run steps separately instead of `deploy` if you prefer: `bootstrap`, `install`, `backup-setup`.

## Security headers

Caddy adds HSTS (1 year), `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, a `Permissions-Policy` that turns off
camera/microphone/geolocation, removes the `Server` header, and on `web.`/`albums.` sends `X-Frame-Options: DENY`. `check` verifies them.
The Caddyfile is rewritten by `install`/`restore`: change headers in `configure_host()`, not in `/etc/caddy/Caddyfile`.
`CSP_REPORT_ONLY=yes` adds a Content-Security-Policy in report-only mode: use the web app (log in, upload, open a shared album) with the
browser console open and look for CSP reports before considering enforcing it. HSTS stays in browsers for a year: keep serving HTTPS.

## Backups

A run (`systemctl start --no-block ente-backup.service`, logs `journalctl -u ente-backup.service`):
dumps Postgres (verified, atomic), copies `museum.yaml`/`compose*.yaml`, syncs them to `<backup bucket>/config` (names and contents
encrypted with `BACKUP_PASSPHRASE`), mirrors the photo bucket to `<backup bucket>/objects`. Objects deleted from the photo bucket move to
`deleted/<date>/` and are purged after 60 days; a run that would delete more than 500 objects stops with an error.
`HC_URL` (optional; any heartbeat URL: healthchecks.io, Better Stack, Cronitor, ...) is pinged only after a fully successful run, so the
service alerts you when a run fails, does not happen, or the server is down. A failed ping does not fail the backup; `check` reports it.

`backup-setup` refuses to touch a backup bucket that already holds another Ente instance's backup, one the passphrase cannot read, or one it cannot list.
The server holds keys that can delete backups: turn on bucket versioning or Object Lock at the backup provider if it supports it, and use a key limited to that bucket.
Two safety limits stop a run instead of deleting: more than 500 photo deletions, more than 20 dump deletions.

### Second location: Yandex Disk (optional)

Set `YANDEX_DIR` (a folder on the Disk) and run `backup-setup`. Every run then also writes the same layout (`config/` encrypted
with the same `BACKUP_PASSPHRASE`, `objects/`, `deleted/`) to Yandex Disk through rclone's native `yandex` backend (Yandex's WebDAV
is throttled). The S3 backup always runs first; if Yandex fails the S3 backup is still done, the run fails and `HC_URL` is not pinged.

1. Use a separate Yandex account for this: the token can access the whole Disk.
2. Since October 2026 Yandex answers `410 Gone` to file requests made through rclone's built-in OAuth app (quota still works), so
   register your own: log in to that account, open <https://oauth.yandex.ru/client/new>, platform "Web services", redirect URI
   `http://127.0.0.1:53682/`, and under Yandex.Disk REST API allow reading all of Disk, writing anywhere on Disk and Disk info.
   Put its ID in `ente-setup.env` as `YANDEX_CLIENT_ID` and its secret in `ente-setup.secrets` as `YANDEX_CLIENT_SECRET`.
3. On a PC with a browser: `rclone authorize "yandex" CLIENT_ID CLIENT_SECRET`, log in, copy the JSON it prints into `ente-setup.secrets` as
   `YANDEX_TOKEN='{"access_token":...}'` (or paste it at the prompt). rclone refreshes it afterwards; it is never rewritten by the script.
   If the refresh token ever expires, `rclone config delete yandex` and re-run `backup-setup` with a fresh one.
4. `backup-setup` checks that it can list and upload (a token Yandex refuses stops it with the reason), creates the folder, refuses a
   folder holding another instance's backup, and starts a run. The first mirror is slow.

Deleted files go to the Yandex trash (some protection if the token is abused) and count against the quota, so empty it now and
then; `check` shows the quota. Files larger than your plan's per-file upload limit fail (the run fails and `check` reports it).
To restore from Yandex, set `RESTORE_FROM=yandex` (with `YANDEX_DIR` and a token) on the new server.

## Telegram alerts (optional)

With `TG_CHAT_ID` set, `backup-setup` installs alerts that need no other service:
- a failed backup sends "❌ ente-backup.service failed" with the last 30 log lines;
- `check` runs daily at 09:00 (`ente-check.timer`) and sends its FAIL lines if anything fails
  (stale or failed backup, Yandex token expired, a container down, missing headers, ...).

Nothing is sent while all is well. Not covered: the VPS itself being down (only an outside monitor such as `HC_URL` sees that).

1. In Telegram: @BotFather → `/newbot` → copy the token. Open your bot and press **Start** (for a group: add the bot to it).
2. Chat ID: open `https://api.telegram.org/bot<TOKEN>/getUpdates` after writing to the bot and read `"chat":{"id":...}`
   (groups start with `-`), or ask @userinfobot.
3. `TG_CHAT_ID=...` in `ente-setup.env`, `TG_BOT_TOKEN=...` in `ente-setup.secrets` (or paste it at the prompt), then
   `sudo ./ente-setup.sh backup-setup` and `sudo ./ente-setup.sh alert-test`.

The daily check runs the script from where `backup-setup` was run: keep the folder there (or re-run `backup-setup` after moving it).
The token is stored only in `/etc/ente-alert.env` (mode 600) and passed to curl on stdin. To turn alerts off, empty `TG_CHAT_ID`
and re-run `backup-setup`.

## Monthly: `sudo ./ente-setup.sh check`

OK/FAIL report: containers, restart policy, localhost-only ports, sshd, UFW, Caddy, HTTPS, photo bucket + CORS, backup timer and last
result, `rclone check` photo bucket vs backup (and Yandex Disk: reachable, last good run, `rclone check`, quota), the last good `verify`, disk, OOM kills, pending reboot. Also look at both buckets' usage in the provider consoles.

## Monthly, automatic: `verify`

`check` proves that backups ran and that object sizes match; `verify` proves the S3 backup can be restored. `backup-setup` installs
`ente-verify.timer` (the 1st of each month, 04:30; a FAIL sends a Telegram alert if alerts are on). By hand: `sudo ./ente-setup.sh verify`.

- photo bucket against the backup by checksum (objects without a common checksum, e.g. multipart uploads, are compared by size and counted in a WARN);
- the encrypted config backup, downloaded, decrypted with the stored passphrase and compared byte for byte with the local copies;
- the newest dump from the backup restored into a scratch database (dropped afterwards) and compared with the live one: same number of
  tables, and users/files not empty when the live ones are not;
- the keys in the backed-up `museum.yaml` equal the live ones.

It changes neither the backup nor the live database, and waits for a running backup. Photos uploaded since the last backup started are
not expected in the backup (same in `check`). The Yandex Disk copy is not verified here; `check` compares it by size daily.
A full disaster-recovery drill (restore on a fresh server) is still worth doing once by hand.

## Updates

The Ente images (`ghcr.io/ente/server`, `ghcr.io/ente/web`) have no version tags, so the script pins the exact builds by digest in
`/opt/my-ente/image-pins` (written into `compose.override.yaml`, carried by the backup). Nothing changes version by itself; `install`
re-runs keep the pins, `restore` runs the builds that made the dump, and `check` shows them with their build dates.
`postgres:15` is not pinned, so its minor fixes arrive with `update`.

`sudo ./ente-setup.sh update`: runs a backup first (rollback point; aborts if it fails), moves the pins to the current `latest`,
recreates the changed containers, prunes. Read Ente's release notes first. OS updates install themselves.

Going back after a bad update: the previous pins are in `/opt/my-ente/image-pins.prev`. Copy that file over `image-pins` and run
`install`. If the new server version already migrated the database, the old one may not start: then also restore the dump that
`update` made (`restore` on a fresh server, or `pg_restore` of `/var/backups/ente/ente_db-<date>.dump`).
If a pinned build is ever deleted from the registry, `install`/`restore` warn and pin the running or latest build instead.

## Moving to a new VPS / disaster recovery (`restore`)

1. New VPS, point DNS later. Put the **same** `ente-setup.env` and secrets there (same `DOMAIN`, same buckets, same `BACKUP_PASSPHRASE`) and set `RESTORE=yes`.
2. `./ente-setup.sh deploy` (bootstrap, then `restore`, then `backup-setup`). `restore` fetches the encrypted config backup,
   puts back `museum.yaml`, restores the newest DB dump, and uses the photos already in the photo bucket
   and tops up any objects missing from the photo bucket from the backup (copy only, never deletes). About 2 minutes for a small library.
   If a restore is interrupted, just run it again: it cleans up and starts over.
3. Point DNS (`api.`, `web.`, `albums.`, TTL 300) at the new IP; certificates are issued once it resolves. Run `check`.

Apps keep working because the hostnames do not change. To restore into a *new* photo bucket, set the new `S3_*` values:
objects are copied from the backup bucket.

## AmneziaWG VPN (`vpn`, optional, independent of Ente)

Needs only `bootstrap` and `AWG_PORT` (UDP, 1024-65535) in `ente-setup.env`; open that UDP port in your provider's firewall too.
`sudo ./ente-setup.sh vpn` installs AmneziaWG 3.1 from Amnezia's PPA (pinned key, DKMS module), generates keys and random
obfuscation parameters, writes `/etc/amnezia/amneziawg/awg0.conf` and one shared client config `/root/awg-client.conf`
(one device at a time), allows the port and the tunnel's forwarding in UFW, NATs the tunnel (`nft` table `ip awg_nat`, set up and
removed by `awg-quick@awg0`), starts it at boot and runs a self-test from a network namespace on the server (handshake, DNS,
exit address, no IPv6 leak, 20 MB download). Tunnel `10.89.37.0/24`, MTU 1280, IPv4 only; no destination filtering.

Copy the client config to your device and import it in the AmneziaVPN app, then delete the server copy:
`ssh -p <SSH_PORT> <ADMIN_USER>@<ip> sudo cat /root/awg-client.conf > awg.conf`, then on the server `sudo shred -u /root/awg-client.conf`.

Re-running `vpn` keeps the keys (a new `AWG_PORT` is applied; update `Endpoint` in the client). New keys: move `awg0.conf` away, re-run.
The Amnezia packages are not covered by unattended upgrades (`apt list --upgradable` now and then); a kernel update needs the DKMS build to succeed.
Remove: `systemctl disable --now awg-quick@awg0`, `ufw delete allow <AWG_PORT>/udp`, `ufw route delete allow in on awg0 out on <nic> from 10.89.37.0/24`,
`rm -rf /etc/amnezia /etc/sysctl.d/92-awg.conf`, `apt-get purge amneziawg amneziawg-tools amneziawg-dkms`.

## S3 proxy (optional): photos through this server, toggled on demand

The apps upload and download photos directly to the photo bucket with links museum signs. Where devices reach the bucket's
endpoint badly (slow or blocked) but reach this server well, `proxy on` routes that traffic through the server instead,
uploads included; `proxy off` returns to direct links. Measure first (next section): it only helps if the server is clearly faster.

1. DNS: an A (and AAAA) record for the proxy host, e.g. `s3.<domain>`, pointing at the server.
2. `S3_PROXY_HOST=s3.<domain>` in `ente-setup.env`, then `sudo ./ente-setup.sh install` (keeps everything else as it is).
   This adds the proxy site to Caddy and the link rewriter service; the proxy stays **off**.
3. `sudo ./ente-setup.sh proxy on`, `proxy off`, `proxy status`. Toggling only reloads Caddy: no restart, no downtime, and it
   applies to every device at once. `proxy on` runs a self-test first and stays off if it fails.

How it works: while on, API traffic passes through `ente-s3-rewrite` (a small local service, `ente_s3_rewrite.py`), which replaces
`https://<bucket endpoint>/<bucket>/` with `https://<S3_PROXY_HOST>/<bucket>/` in museum's responses. Caddy forwards that host,
only the bucket's path and only the methods the apps use, to the real endpoint with its original host name, so the signed links stay
valid and the provider still checks every signature. Photo data streams through Caddy; the rewriter only sees API responses.

- Links handed out while on keep working after `proxy off` (the proxy site stays up while `S3_PROXY_HOST` is set).
- If the rewriter dies, Caddy sends the API straight to museum (links point at the bucket again); `check` reports it.
- Every photo crosses the server twice while on: its bandwidth and monthly traffic become the limit.
- Backups and museum's own bucket access always go direct. After `restore` on a new server the proxy starts off.
- To remove it: empty `S3_PROXY_HOST` and run `install`.

## Measuring connection speed

Photos travel between a device and the photo bucket directly; only the API goes through the server. Two tests from a PC:

- **Device to bucket:** `s3-speedtest.sh` (Linux/macOS/WSL; needs rclone) uploads and downloads one random file in
  `<bucket>/speedtest/` and deletes it: `S3_BUCKET=... ./s3-speedtest.sh` (asks for the keys).
- **Device to server:** `sudo ./ente-setup.sh speedtest` opens a test endpoint under `https://api.<domain>/speedtest-<random token>/`
  for 30 minutes (a Caddy route added at runtime, not in the Caddyfile; `systemctl stop ente-speedtest` ends it early) and prints
  the URL. On Windows run `.\vps-speedtest.ps1 -Url <that URL>`; elsewhere use the two `curl` lines it prints.

Run each a few times: results vary a lot between runs.

## Tests

| Command | Where | What |
| --- | --- | --- |
| `python3 -m unittest discover -s tests -v` | anywhere (Python 3 stdlib) | the link rewriter against a fake museum |
| `bash tests/test_proxy_config.sh` | anywhere; on the server also validated by Caddy | config checks, generated Caddyfile in each proxy state, unit, command line |
| `sudo bash tests/proxy_e2e.sh` | the server, `S3_PROXY_HOST` set | the `proxy` command end to end, plus `tests/proxy_e2e_s3.py`: real signed links through the proxy |
| `sudo bash tests/proxy_browser_e2e.sh` | the server, `S3_PROXY_HOST` set | the real web app in Chromium (Playwright container): sign-up, uploads incl. multipart, viewing, with the proxy on and off |

The two server tests restore the proxy state they found. The browser test opens registration for a throwaway account, deletes it
afterwards, closes registration again and removes the Playwright image.

## Notes and limits

- Users in countries that throttle foreign hosts need to reach the photo bucket's endpoint directly; pick a provider that works for
  them, or use the S3 proxy.
- IDrive e2 answers CORS preflights for any origin, whatever CORS rule the bucket holds: the signatures, not CORS, protect the bucket.
- The installers (get.docker.com, Caddy repo key, rclone, Ente quickstart from `main`) are fetched at install time and run as root without pinning; the quickstart's output is asserted.
- The VPS downloads and re-uploads every photo for the backup (bucket → VPS → bucket). Fine for hundreds of GB, slow for the first run.
- Museum logs some request metadata (never photo plaintext); Docker log rotation bounds it (10 MB x 3).
