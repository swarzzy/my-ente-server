# ente-server

One script, `ente-setup.sh`, turns a fresh Debian 12/13 VPS into a working, backed-up
[Ente Photos](https://ente.com) server:

- **Caddy** (Let's Encrypt TLS, security headers) is the only public service; Museum, the web apps and Postgres run in Docker on `127.0.0.1`.
- **Photos** are stored in an external S3 bucket (IDrive e2, Backblaze B2, Wasabi, ...). Apps upload and download
  straight to that bucket through links Museum signs, so the VPS needs almost no disk (25 GB is plenty).
- **Backups** go daily to a second S3 bucket: encrypted DB dump + `museum.yaml`, plus a mirror of the photo bucket. The same
  encrypted dump + config is also kept inside the photo bucket, so **either bucket alone + `BACKUP_PASSPHRASE` restores everything**.

Every subcommand is safe to re-run. Log: `/var/log/ente-setup.log` (no secrets).

## Files

| File | Purpose |
| --- | --- |
| `ente-setup.sh` | the script: sets up the server (deploy, install, backup-setup, restore, update, ...) |
| `ente-backup.sh` | one backup run, standalone (installed by `backup-setup` as `/usr/local/bin/ente-backup.sh`, run daily by `ente-backup.service`) |
| `ente-ops.sh` | running it: `check`, `verify`, `alert-test`, `speedtest` (needs `ente-setup.sh` next to it) |
| `ente-setup.env.example` | non-secret config → copy to `ente-setup.env` |
| `ente-setup.secrets.example` | bucket keys + backup passphrase → copy to `ente-setup.secrets`, `chmod 600` |
| `ente-s3-proxy.sh`, `ente_s3_rewrite.py` | optional add-on: route photo traffic through the server (see "S3 proxy") |
| `ente-vpn.sh` | optional, independent of Ente: an AmneziaWG VPN (see "AmneziaWG VPN") |
| `ente-tg-bot.sh`, `ente_tg_bot.py` | optional add-on: a Telegram bot for status, checks, backups and the proxy (see "Telegram bot") |
| `tests/` | tests (see "Tests") |

Both copies are git-ignored. The script reads secrets only from the secrets file (or the environment, if the file does not set
them) and stops naming any that a command needs but is missing; it never logs them or stores them in the env file.

## Fresh install

1. **Buckets.** Create two buckets at two providers if you can. The key for the photo bucket needs read/write/delete and
   permission to set CORS (the script sets it; if the provider refuses it prints what to set by hand).
   Backup bucket: it must keep old versions (versioning; B2 always does). `backup-setup` turns versioning on if needed and sets a
   lifecycle rule that removes old versions after `BACKUP_KEEP_DELETED_DAYS` (60); its key needs permission for both, or set them by hand.
2. **DNS.** A (and AAAA) records for `api.`, `web.` and `albums.` under your domain → the VPS, TTL 300.
3. **Config.** Copy `ente-server/` to the VPS, create `ente-setup.env` and `ente-setup.secrets` from the examples.
   `BACKUP_PASSPHRASE` encrypts the config backup: keep it in a password manager, without it the backup is unreadable.
4. **As root:** `./ente-setup.sh deploy` = `bootstrap` + `install` + `backup-setup`. About 5 minutes. Run it in `tmux` (or `nohup`):
   bootstrap moves sshd, and a dropped SSH session would stop it half-way (re-running it is safe).
   - `bootstrap`: updates, `ADMIN_USER` (sudo, key only), sshd hardening (no passwords, no root login, port `SSH_PORT`, default 22), UFW `SSH_PORT`/80/443,
     unattended upgrades (reboot 02:00 only when needed), 2 GB swap, fail2ban. A full upgrade: if it installs a new kernel it says so;
     reboot once deploy is done (`ente-vpn.sh` needs the running kernel's headers).
     The admin key is validated first (a placeholder or truncated key is refused, since it would lock you out).
     **Open a second terminal and log in as `ADMIN_USER` before closing the root session** (root login is now off).
     `MaxAuthTries 3`: if your ssh-agent holds many keys use `ssh -o IdentitiesOnly=yes -i KEY`.
   - `install`: Docker, Caddy, Ente's quickstart; edits its files (each edit asserted; fails loudly if the quickstart changed),
     checks the photo bucket (read/write/delete), sets CORS, starts everything.
   - `backup-setup`: rclone remotes, systemd timer (03:00 daily, catches up if missed), first run started.
5. Keep `BACKUP_PASSPHRASE` in your password manager: with it, either bucket restores the server. (Optionally also
   `/opt/my-ente/museum.yaml`: both buckets already carry it, encrypted.)
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

A run of `ente-backup.sh` (`systemctl start --no-block ente-backup.service`, logs `journalctl -u ente-backup.service`; config in
`/etc/ente-backup.env`, written by `backup-setup`):
dumps Postgres (verified, atomic), copies `museum.yaml`/`compose*.yaml`, syncs them to `<backup bucket>/config` (names and contents
encrypted with `BACKUP_PASSPHRASE`), mirrors the photo bucket to `<backup bucket>/objects`, then syncs the same encrypted config to
`<photo bucket>/ente-backup-config/config` (excluded from the mirror; museum never lists its bucket, so it ignores the folder).
Objects deleted from the photo bucket are deleted from the mirror too; the backup bucket keeps them as old versions for
`BACKUP_KEEP_DELETED_DAYS` (60), so `check` FAILs if it stops keeping versions. When more than `BACKUP_DELETE_WARN` (500) files
vanish between two backups, the backup still runs and sends a Telegram warning (and `check` WARNs for a week) with the command to
put them back as they were at the last backup: `rclone copy --s3-version-at '<time>' backup:<backup bucket>/objects ente-s3:<photo bucket>`.
After a cleanup in Ente that is expected (Ente removes a file from its bucket 45 days after it leaves the trash); otherwise act within the 60 days.
`HC_URL` (optional; any heartbeat URL: healthchecks.io, Better Stack, Cronitor, ...) is pinged only after a fully successful run, so the
service alerts you when a run fails, does not happen, or the server is down. A failed ping does not fail the backup; `check` reports it.

`backup-setup` refuses to touch a backup bucket that already holds another Ente instance's backup, one the passphrase cannot read, or one it cannot list.
The server holds keys that can delete backups: turn on bucket versioning or Object Lock at the backup provider if it supports it, and use a key limited to that bucket.
The dumps have no other history, so a run that would delete more than 20 of them stops instead, before deleting anything.

What survives what (you also need each provider's account to create new keys, and your Ente password to log in):

| Lost | Restore from |
| --- | --- |
| the server | either bucket |
| the backup bucket | the photo bucket (its photos + its config copy); set up a new backup bucket |
| the photo bucket | the backup bucket (config + `objects/`, copied into a new photo bucket) |
| `BACKUP_PASSPHRASE` | nothing: keep it in your password manager |

## Telegram alerts (optional)

With `TG_CHAT_ID` set, `backup-setup` installs alerts that need no other service:
- a failed backup sends "❌ ente-backup.service failed" with the last 30 log lines;
- `check` runs daily at 09:00 (`ente-check.timer`) and sends its FAIL lines if anything fails
  (stale or failed backup, a container down, missing headers, ...).

Nothing is sent while all is well. Not covered: the VPS itself being down (only an outside monitor such as `HC_URL` sees that).

1. In Telegram: @BotFather → `/newbot` → copy the token. Open your bot and press **Start** (for a group: add the bot to it).
2. Chat ID: open `https://api.telegram.org/bot<TOKEN>/getUpdates` after writing to the bot and read `"chat":{"id":...}`
   (groups start with `-`), or ask @userinfobot.
3. `TG_CHAT_ID=...` in `ente-setup.env`, `TG_BOT_TOKEN=...` in `ente-setup.secrets`, then
   `sudo ./ente-setup.sh backup-setup` and `sudo ./ente-ops.sh alert-test`.

The daily check runs the script from where `backup-setup` was run: keep the folder there (or re-run `backup-setup` after moving it).
The token is stored only in `/etc/ente-alert.env` (mode 600) and passed to curl on stdin. To turn alerts off, empty `TG_CHAT_ID`
and re-run `backup-setup`.

### Telegram bot (optional add-on): commands from your phone

`ente-tg-bot.sh` adds a bot that takes commands from **one** Telegram account and from nobody else:

| Command | Does |
| --- | --- |
| `/status` | short summary: containers, last backup, last check and verify, proxy, disk, uptime |
| `/check` | runs `ente-ops.sh check`, replies with the FAIL/WARN lines and the verdict |
| `/backup` | runs a backup now; replies at once, then with the result |
| `/proxy`, `/proxy on`, `/proxy off` | the S3 proxy's state, or switch it (needs `ente-s3-proxy.sh install`) |

1. `TG_BOT_USER_ID=<your Telegram user id>` in `ente-setup.env` (for a private chat it is the same number as `TG_CHAT_ID`).
   The bot uses the alert bot's token (`TG_BOT_TOKEN` in the secrets file, or the one `backup-setup` stored).
2. `sudo ./ente-tg-bot.sh install`, then send `/status` to the bot. `status`, `check` and `uninstall` as usual.

Security: the bot long-polls Telegram (no open port) as its own unprivileged user `ente-tg-bot`, acts only on private messages
from `TG_BOT_USER_ID` (others are ignored, and you get a notice at most once an hour per sender), does not run commands older
than a minute, and maps each command to a fixed action name: no text from Telegram reaches a shell. As root it may run exactly
`/usr/local/sbin/ente-tg-action <one of six names>` (`/etc/sudoers.d/ente-tg-bot`); that helper runs `ente-tg-bot.sh action <name>`,
so the script folder must be root's alone (`chown -R root: ente-server; chmod -R go-w ente-server`; `install` refuses otherwise).
The token reaches the bot as a systemd credential, never on a command line. Anyone who controls your Telegram account can use the
bot: turn on Telegram's two-step verification. `ente-ops.sh check` includes the bot's checks while it is installed.

## Monthly: `sudo ./ente-ops.sh check`

OK/FAIL report: containers, restart policy, localhost-only ports, sshd, UFW, Caddy, HTTPS, photo bucket + CORS, backup timer and last
result, `rclone check` photo bucket vs backup, the age of the config copy in the photo bucket, the last good `verify`, disk, OOM kills, pending reboot. Also look at both buckets' usage in the provider consoles.

## Monthly, automatic: `verify`

`check` proves that backups ran and that object sizes match; `verify` proves the S3 backup can be restored. `backup-setup` installs
`ente-verify.timer` (the 1st of each month, 04:30; a FAIL sends a Telegram alert if alerts are on). By hand: `sudo ./ente-ops.sh verify`.

- photo bucket against the backup by checksum (objects without a common checksum, e.g. multipart uploads, are compared by size and counted in a WARN);
- the encrypted config backup and its copy in the photo bucket, downloaded, decrypted with the stored passphrase and compared byte for
  byte with the local copies;
- the newest dump from the backup restored into a scratch database (dropped afterwards) and compared with the live one: same number of
  tables, and users/files not empty when the live ones are not;
- the keys in the backed-up `museum.yaml` equal the live ones.

It changes neither the backup nor the live database, and waits for a running backup. Photos uploaded since the last backup started are
not expected in the backup (same in `check`).
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

1. New VPS, point DNS later. Put `ente-setup.env` and secrets there: same `DOMAIN` and `BACKUP_PASSPHRASE`, the surviving bucket(s),
   and a new, empty bucket in place of a lost one (with its keys). Set `RESTORE=yes`.
2. `./ente-setup.sh deploy` (bootstrap, then `restore`, then `backup-setup`). `restore` reads the encrypted config from whichever
   bucket holds the newer dump (the log says which), puts back `museum.yaml`, restores that DB dump, uses the photos already in the
   photo bucket and tops up any objects missing there from the backup bucket (copy only, never deletes). About 2 minutes for a small library.
   If a restore is interrupted, just run it again. Stopped before the database was restored, it cleans up and starts over;
   after, it only finishes the remaining steps. It never wipes a restored database, and `check` FAILs until it finishes.
3. Point DNS (`api.`, `web.`, `albums.`, TTL 300) at the new IP; certificates are issued once it resolves. Run `check`.

Apps keep working because the hostnames do not change. To restore into a *new* photo bucket, set the new `S3_*` values:
objects are copied from the backup bucket. After restoring from the photo bucket alone, `backup-setup` fills the new backup bucket.

## AmneziaWG VPN (`ente-vpn.sh`, optional, independent of Ente)

Needs only `bootstrap` (and the reboot it asks for after a kernel update) and `AWG_PORT` (UDP, 1024-65535) in `ente-setup.env`; open that UDP port in your provider's firewall too.
`sudo ./ente-vpn.sh install` installs AmneziaWG 3.1 from Amnezia's PPA (pinned key, DKMS module), generates keys and random
obfuscation parameters, writes `/etc/amnezia/amneziawg/awg0.conf` and one shared client config `/root/awg-client.conf`
(one device at a time), allows the port and the tunnel's forwarding in UFW, NATs the tunnel (`nft` table `ip awg_nat`, set up and
removed by `awg-quick@awg0`), starts it at boot and runs a self-test from a network namespace on the server (handshake, DNS,
exit address, no IPv6 leak, 20 MB download). Tunnel `10.89.37.0/24`, MTU 1280, IPv4 only; no destination filtering.

Copy the client config to your device and import it in the AmneziaVPN app, then delete the server copy:
`ssh -p <SSH_PORT> <ADMIN_USER>@<ip> sudo cat /root/awg-client.conf > awg.conf`, then on the server `sudo shred -u /root/awg-client.conf`.

Re-running `install` keeps the keys (a new `AWG_PORT` is applied; update `Endpoint` in the client). New keys: move `awg0.conf` away, re-run.
The Amnezia packages are not covered by unattended upgrades (`apt list --upgradable` now and then); a kernel update needs the DKMS build to succeed.
`sudo ./ente-vpn.sh status` shows the service, the port and each peer's last handshake. `sudo ./ente-vpn.sh uninstall` removes it all
(service, keys and configs, UFW rules, NAT table, packages, the PPA); close the port in your provider's firewall yourself.
The Amnezia PPA's signing key is embedded in `ente-vpn.sh` and checked by fingerprint, so apt accepts only packages Amnezia signed.

## S3 proxy (optional add-on): photos through this server, toggled on demand

The apps upload and download photos directly to the photo bucket with links museum signs. Where devices reach the bucket's
endpoint badly (slow or blocked) but reach this server well, the add-on `ente-s3-proxy.sh` routes that traffic through the
server instead, uploads included, and back again on demand. Measure first: it only helps if the server is clearly faster.
`sudo ./ente-ops.sh speedtest` opens a test endpoint on the server for 30 minutes and prints `curl` lines for download and upload.

1. DNS: an A (and AAAA) record for the proxy host, e.g. `s3.<domain>`, pointing at the server.
2. `S3_PROXY_HOST=s3.<domain>` in `ente-setup.env`, then `sudo ./ente-s3-proxy.sh install`: the link rewriter service and the
   proxy site; the proxy stays **off**. (Needs `ente-setup.sh install` from this version: its Caddyfile has the hooks.)
3. `sudo ./ente-s3-proxy.sh on`, `off`, `status`. Toggling only reloads Caddy: no restart, no downtime, and it applies to every
   device at once. `on` runs a self-test first and stays off if it fails. `uninstall` removes it all.

How it works: while on, API traffic passes through `ente-s3-rewrite` (a small local service, `ente_s3_rewrite.py`), which replaces
`https://<bucket endpoint>/<bucket>/` with `https://<S3_PROXY_HOST>/<bucket>/` in museum's responses. Caddy forwards that host,
only the bucket's path and only the methods the apps use, to the real endpoint with its original host name, so the signed links stay
valid and the provider still checks every signature. Photo data streams through Caddy; the rewriter only sees API responses.

The add-on owns two files that `ente-setup.sh`'s Caddyfile imports: `/etc/caddy/ente.d/api-upstream.caddy` (where the API goes)
and `/etc/caddy/ente.d/sites/s3-proxy.caddy` (the proxy site). `ente-setup.sh install` never overwrites them, and
`ente-ops.sh check` includes the add-on's checks while it is installed (so the daily check alerts on it too).

- Links handed out while on keep working after `off` (the proxy site stays up while installed).
- If the rewriter dies, Caddy sends the API straight to museum (links point at the bucket again); `check` reports it.
- Every photo crosses the server twice while on: its bandwidth and monthly traffic become the limit.
- Backups and museum's own bucket access always go direct. After `restore` on a new server, run `ente-s3-proxy.sh install` again.
- After changing the photo bucket (`S3_ENDPOINT`/`S3_BUCKET`), run `ente-s3-proxy.sh install` again.

## Tests

| Command | Where | What |
| --- | --- | --- |
| `python3 -m unittest discover -s tests -v` | anywhere (Python 3 stdlib) | the link rewriter against a fake museum, the bot against a fake Telegram |
| `bash tests/test_tg_bot_config.sh` | anywhere; on the server also validated by visudo (changes nothing there) | bot config, token source, unit, sudo rule, root helper, ownership check, command lines |
| `bash tests/test_bucket_copies.sh` | anywhere with rclone (the server; changes nothing there) | the config copy in the photo bucket: the real backup script on local "buckets", the mirror's exclusion, check/verify, ownership check, restore's choice of bucket incl. lost buckets and a wrong passphrase, restore interrupted at each stage, the atomic `rclone.conf` write |
| `bash tests/test_backup_checks.sh` | anywhere with rclone (the server; changes nothing there) | the warning on a large photo deletion (Telegram, log, stamp; the backup still runs), the dumps' limit (over it nothing is deleted), `verify` catching a bad dump, empty tables, a damaged photo, other keys or missing config files, and every FAIL in the backup part of `check` |
| `bash tests/test_quickstart.sh` | anywhere with network (fetches Ente's current quickstart; docker stubbed) | `install`'s edits against today's quickstart: ports on 127.0.0.1, URLs, the external bucket, keys kept, in place, idempotent; a changed layout is refused |
| `bash tests/test_lockdown.sh` | anywhere (Postgres stubbed) | `lockdown`: oldest user becomes admin only after `y`, re-runs change nothing, install keeps the block, a hand-made `internal:` is refused, edited in place |
| `bash tests/test_alerts.sh` | anywhere (Telegram faked on 127.0.0.1) | the real alert scripts: what a failed check, verify or backup sends, to which chat, the length limit, broken UTF-8, Telegram down |
| `sudo bash tests/test_vpn_config.sh` | the server, after `ente-vpn.sh install` | the VPN config generator: keys pair up, same obfuscation on both sides within AmneziaWG's rules, mode 600, never overwrites, refuses a busy port |
| `sudo bash tests/backup_versions_e2e.sh` | the server, after `backup-setup` (uses a throwaway prefix in the real backup bucket, removed after) | the backup bucket keeps a file the mirror deletes as an old version, and the warning's `--s3-version-at` command brings it back |
| `bash tests/test_update.sh` | anywhere (docker and systemd stubbed) | `update`: a failed download (museum, web, postgres) changes nothing; a real update moves the pins and keeps the old ones in `image-pins.prev` |
| `bash tests/test_proxy_config.sh` | anywhere; on the server also validated by Caddy (changes nothing there) | config checks, the Caddyfile hooks, the add-on's files in each state, unit, command lines |
| `sudo bash tests/proxy_e2e.sh` | the server, `S3_PROXY_HOST` set | `ente-s3-proxy.sh` end to end (install, on/off, fallback, rollback, uninstall), plus `tests/proxy_e2e_s3.py`: real signed links through the proxy |
| `sudo bash tests/tg_bot_e2e.sh` | the server, `TG_BOT_USER_ID` set | the real bot as its real user with the real sudo rule and actions, against a fake Telegram (`tests/fake_telegram.py`): every command, strangers, groups, old messages, privileges, uninstall; runs a real backup |
| `sudo bash tests/proxy_browser_e2e.sh` | the server, `S3_PROXY_HOST` set | the real web app in Chromium (Playwright container): sign-up, uploads incl. multipart, viewing, with the proxy on and off |

`proxy_e2e.sh` and `tg_bot_e2e.sh` leave their add-on as they found it (installed or not, on or off). The browser test opens registration for a throwaway account, deletes it
afterwards, closes registration again and removes the Playwright image.

## Notes and limits

- Users in countries that throttle foreign hosts need to reach the photo bucket's endpoint directly; pick a provider that works for
  them, or use the S3 proxy.
- IDrive e2 answers CORS preflights for any origin, whatever CORS rule the bucket holds: the signatures, not CORS, protect the bucket.
- The installers (get.docker.com, Caddy repo key, rclone, Ente quickstart from `main`) are fetched at install time and run as root without pinning; the quickstart's output is asserted.
- The VPS downloads and re-uploads every photo for the backup (bucket → VPS → bucket). Fine for hundreds of GB, slow for the first run.
- Museum logs some request metadata (never photo plaintext); Docker log rotation bounds it (10 MB x 3).
