# ente-server

One script, `ente-setup.sh`, turns a fresh Debian 12/13 VPS into a working, backed-up
[Ente Photos](https://ente.com) server:

- **Caddy** (Let's Encrypt TLS, security headers) is the only public service; Museum, the web apps and Postgres run in Docker on `127.0.0.1`.
- **Photos** are stored in an external S3 bucket (IDrive e2, Backblaze B2, Wasabi, ...). Apps upload and download
  straight to that bucket through links Museum signs, so the VPS needs almost no disk (25 GB is plenty).
- **Backups** go daily to a second S3 bucket: encrypted DB dump + `museum.yaml`, plus a copy of the photo bucket (nothing is ever deleted there). The same
  encrypted dump + config is also kept inside the photo bucket, so **either bucket alone + `BACKUP_PASSPHRASE` restores everything**.

Every subcommand is safe to re-run. Log: `/var/log/ente-setup.log` (no secrets).

## Files

| File | Purpose |
| --- | --- |
| `ente-setup.sh` | the script: sets up the server (deploy, install, backup-setup, restore, update, ...) |
| `ente-backup.sh` | one backup run, standalone (installed by `backup-setup` as `/usr/local/bin/ente-backup.sh`, run daily by `ente-backup.service`) |
| `ente-ops.sh` | running it: `check`, `verify` (needs `ente-setup.sh` next to it) |
| `ente-setup.env.example` | non-secret config → copy to `ente-setup.env` |
| `ente-setup.secrets.example` | bucket keys + backup passphrase → copy to `ente-setup.secrets`, `chmod 600` |
| `ente-s3-proxy.sh`, `ente_s3_rewrite.py` | optional add-on: route photo traffic through the server (see "S3 proxy") |
| `ente-vpn.sh` | optional, independent of Ente: an AmneziaWG VPN (see "AmneziaWG VPN") |
| `ente-tg-bot.sh`, `ente_tg_bot.py` | optional add-on: a Telegram bot for status, checks, backups and the proxy (see "Telegram bot") |
| `tests/` | tests; `run_all.sh` runs them (see "Tests") |
| `../docs/functions-and-tests.md` | overview for others: every function, what it does and what must be tested (not needed on the server) |

Both copies are git-ignored. The script reads secrets only from the secrets file (or the environment, if the file does not set
them) and stops naming any that a command needs but is missing; it never logs them or stores them in the env file.

## Fresh install

1. **Buckets.** Create two buckets at two providers if you can. The key for the photo bucket needs read/write/delete and
   permission to set CORS (the script sets it; if the provider refuses it prints what to set by hand).
   Backup bucket: the backup only adds to it, so its key needs read/write (no delete). It grows: clean it up by hand (see "Backups").
2. **DNS.** A (and AAAA) records for `api.`, `web.` and `albums.` under your domain → the VPS, TTL 300. For the Ente Auth and
   Locker web apps also `auth.` and `locker.`, with `WEB_APPS="auth locker"` in `ente-setup.env` (either one alone works too).
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
   - `backup-setup`: rclone remotes, the backup timer (03:00 daily, catches up if missed), the monthly `verify` timer,
     Telegram alerts and the daily `check` if `TG_CHAT_ID` is set; first run started.
5. Keep `BACKUP_PASSPHRASE` in your password manager: with it, either bucket restores the server. (Optionally also
   `/opt/my-ente/museum.yaml`: both buckets already carry it, encrypted.)
6. **Sign up the owner first** at `https://web.<domain>`, then family. No SMTP, so codes are in the log: `sudo ./ente-setup.sh codes`.
7. `sudo ./ente-setup.sh lockdown` shows users, makes the oldest the admin (after you confirm) and closes sign-ups.
8. Apps: on Android/Windows tap the welcome screen 7 times and enter `https://api.<domain>`.
9. Storage limit (10 GB by default) is lifted from your PC with the Ente CLI:
   `ente account login`, then `ente admin user update-subscription EMAIL --no-limit` (the login must be < 10 min old). See Ente's CLI docs for pointing it at a custom server.

Run steps separately instead of `deploy` if you prefer: `bootstrap`, `install`, `backup-setup`.

## Extra web apps: Ente Auth and Locker (`WEB_APPS`)

The Ente web image also holds the Auth (2FA codes) and Locker (documents) web apps. `WEB_APPS="auth locker"` in
`ente-setup.env` (and their DNS records) serves them at `https://auth.<domain>` and `https://locker.<domain>`: `install`
publishes their ports on 127.0.0.1 only (in `compose.override.yaml`), adds a Caddy site for each with the same headers, and
allows them in the photo bucket's CORS; `check` then checks their pages and certificates. Re-run `install` after changing it.
They use the same account and server as Photos; their data is end-to-end encrypted like the photos and in the same backup.

## Security headers

Caddy adds HSTS (1 year), `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, a `Permissions-Policy` that turns off
camera/microphone/geolocation, removes the `Server` header, and on the web apps (`web.`, `albums.`, `auth.`, `locker.`) sends `X-Frame-Options: DENY`.
The Caddyfile is rewritten by `install`/`restore`: change headers in `render_caddyfile()`, not in `/etc/caddy/Caddyfile`.
`CSP_REPORT_ONLY=yes` adds a Content-Security-Policy in report-only mode: use the web app (log in, upload, open a shared album) with the
browser console open and look for CSP reports before considering enforcing it. HSTS stays in browsers for a year: keep serving HTTPS.

## Backups

A run of `ente-backup.sh` (`systemctl start --no-block ente-backup.service`, logs `journalctl -u ente-backup.service`; config in
`/etc/ente-backup.env`, written by `backup-setup`):
dumps Postgres (verified, atomic; 7 days kept on the server), copies `museum.yaml`/`compose*.yaml`, copies them to `<backup bucket>/config`
(names and contents encrypted with `BACKUP_PASSPHRASE`), copies the photo bucket to `<backup bucket>/objects`, then syncs the same
encrypted config (the last 7 dumps) to `<photo bucket>/ente-backup-config/config` (excluded from the copy; museum never lists its
bucket, so it ignores the folder).
**The backup never deletes anything in the backup bucket**: photos Ente deletes and every daily dump stay there until you clean up
by hand. To see what is in the backup but no longer in the photo bucket, then remove it, and to drop dumps older than 90 days:

```
sudo rclone check ente-s3:<photo bucket> backup:<backup bucket>/objects --exclude '/ente-backup-config/**' --size-only --missing-on-src -
sudo rclone sync  ente-s3:<photo bucket> backup:<backup bucket>/objects --exclude '/ente-backup-config/**' --size-only --dry-run   # then without --dry-run
sudo rclone delete backup-crypt: --include 'ente_db-*.dump' --min-age 90d --dry-run
```
`HC_URL` (optional; any heartbeat URL: healthchecks.io, Better Stack, Cronitor, ...) is pinged only after a fully successful run, so the
service alerts you when a run fails, does not happen, or the server is down. A failed ping does not fail the backup (the service
alerts you about the missing ping; the bot's `/status` shows it).

`backup-setup` refuses to touch a backup bucket that already holds another Ente instance's backup, one the passphrase cannot read, or one it cannot list.
The backup never deletes, so give the backup bucket a key limited to that bucket without delete permission (B2: no `deleteFiles`): then
the server cannot destroy the backup. Do the clean-up above with a separate key, from your PC.

What survives what (you also need each provider's account to create new keys, and your Ente password to log in):

| Lost | Restore from |
| --- | --- |
| the server | either bucket |
| the backup bucket | the photo bucket (its photos + its config copy); set up a new backup bucket |
| the photo bucket | the backup bucket (config + `objects/`, copied into a new photo bucket) |
| `BACKUP_PASSPHRASE` | nothing: keep it in your password manager |

## Telegram alerts (optional)

With `TG_CHAT_ID` set, `backup-setup` installs alerts that need no other service:
- a failed backup sends "❌ Backup failed on <host>" with its ERROR lines (or the last 15 log lines);
- `check` runs daily at 09:00 (`ente-check.timer`) and sends "⚠️ Daily check found problems on <host>" with one ❌ line per
  problem (a stale backup, a container down, the disk nearly full, ...); the monthly `verify` does the same.

Nothing is sent while all is well. Not covered: the VPS itself being down (only an outside monitor such as `HC_URL` sees that).

1. In Telegram: @BotFather → `/newbot` → copy the token. Open your bot and press **Start** (for a group: add the bot to it).
2. Chat ID: open `https://api.telegram.org/bot<TOKEN>/getUpdates` after writing to the bot and read `"chat":{"id":...}`
   (groups start with `-`), or ask @userinfobot.
3. `TG_CHAT_ID=...` in `ente-setup.env`, `TG_BOT_TOKEN=...` in `ente-setup.secrets`, then
   `sudo ./ente-setup.sh backup-setup`. It sends a test message to the chat and stops with an error if that fails
   (re-run it to test again).

The daily check and the monthly verify run the scripts from where `backup-setup` was run, as root: keep the folder there (or
re-run `backup-setup` after moving it), owned by root and writable by root only (`backup-setup` refuses otherwise).
Config values that end up in generated files (domain, buckets, `HC_URL`, the Telegram ids and token) must not contain spaces,
quotes, `$`, backticks or backslashes; the scripts refuse them.
The token is stored only in `/etc/ente-alert.env` (mode 600) and passed to curl on stdin. To turn alerts off, empty `TG_CHAT_ID`
and re-run `backup-setup`.

### Telegram bot (optional add-on): commands from your phone

`ente-tg-bot.sh` adds a bot that takes commands from **one** Telegram account and from nobody else:

| Command | Does |
| --- | --- |
| `/status` | four or five lines: services, last good backup and the next one, last check and verify, disk/RAM/uptime, proxy |
| `/check` | runs `ente-ops.sh check`: "✅ Check passed" or "❌ Check found problems", then each problem and a count of the rest |
| `/backup` | runs a backup now; replies at once, then "✅ Backup done" (and how long it took) or "❌ Backup failed" with why |
| `/proxy`, `/proxy on`, `/proxy off` | the S3 proxy's state, or switch it (needs `ente-s3-proxy.sh install`) |

Lines that need a look start with ⚠️ or ❌. Alerts use the same style: "❌ Backup failed on <host>" or "⚠️ Daily check found
problems on <host>", followed only by the lines that say why.

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

## Daily, automatic: `check`

`sudo ./ente-ops.sh check`: an OK/WARN/FAIL report, run daily at 09:00 when Telegram alerts are on (a FAIL sends an alert).
Every FAIL is something that can break by itself and that nothing else reports:

- services: museum, web and postgres healthy; sign-ups closed (WARN until `lockdown`); a WARN when an Ente image is over 60 days old;
- web: Caddy running, `api./ping`, `web.`, `albums.` and any `WEB_APPS` answer, their certificates valid for at least 20 more days (Caddy renews at 30);
- security: nothing reachable over TCP from outside but SSH, 80 and 443 (Docker bypasses UFW, so this is what keeps Postgres
  private), sshd settings, UFW active and allowing SSH;
- photo bucket reachable, CORS for the web app (the bucket museum uses, from `museum.yaml`; a WARN if `ente-setup.env` names
  another one, i.e. `S3_*` was edited without re-running `install`); the add-ons' own checks while installed;
- backup: the last good backup and the config copy in the photo bucket under 36 h old, the last good `verify` under 45 days, no
  unfinished restore. A failed backup run alerts by itself, so `check` only looks at the age of the last success;
- system: disk of `/` (WARN at 80%, FAIL at 90%), OOM kills in the last 24 h, a reboot pending for over a day (unattended-upgrades
  reboots at 02:00).

## Monthly, automatic: `verify`

`check` proves that backups ran; `verify` proves the backup can be restored. `backup-setup` installs
`ente-verify.timer` (the 1st of each month, 04:30; a FAIL sends a Telegram alert if alerts are on). By hand: `sudo ./ente-ops.sh verify`.

- photo bucket against the backup by checksum (objects without a common checksum, e.g. multipart uploads, are compared by size; the
  OK line counts them). Photos uploaded since the last backup started are not expected in the backup;
- an INFO line on the backup bucket's growth: photos and their size, how many of them are no longer in the photo bucket (what the
  clean-up in "Backups" would remove), dumps and their size;
- the encrypted config backup and its copy in the photo bucket, downloaded, decrypted with the stored passphrase and compared byte for
  byte with the local copies (`museum.yaml` with the keys, compose files, image pins, dumps);
- the newest dump (proven equal to the backed-up one by the step before) restored into a scratch database (dropped afterwards):
  tables exist, and users/files are not empty when the live ones are not.

It changes neither the backup nor the live database, and waits for a running backup. It uses the passphrase and keys stored on the
server, so it cannot prove that your own copies of them work: that is what the yearly restore drill below is for.

## Updates

The Ente images (`ghcr.io/ente/server`, `ghcr.io/ente/web`) have no version tags, so the script pins the exact builds by digest in
`/opt/my-ente/image-pins` (written into `compose.override.yaml`, carried by the backup). Nothing changes version by itself; `install`
re-runs keep the pins, `restore` runs the builds that made the dump, and `check` shows their build dates (a WARN after 60 days).
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
3. Point DNS (`api.`, `web.`, `albums.`, plus `auth.` / `locker.` if in `WEB_APPS`; TTL 300) at the new IP; certificates are issued once it resolves. Run `check`.

Apps keep working because the hostnames do not change. To restore into a *new* photo bucket, set the new `S3_*` values:
objects are copied from the backup bucket. After restoring from the photo bucket alone, `backup-setup` fills the new backup bucket.

**Restore drill, once a year, from your PC** (read-only; the only test of the copies you keep off the server). `verify` uses the
passphrase and keys stored on the server; this proves that yours open the backup. Needs rclone. Use the values from your password
manager / offline `ente-setup.env` and `ente-setup.secrets`, not from the server:

```
export RCLONE_CONFIG_DRILL_TYPE=s3 RCLONE_CONFIG_DRILL_PROVIDER=<BACKUP_S3_PROVIDER, e.g. Other> RCLONE_CONFIG_DRILL_ENDPOINT=<BACKUP_S3_ENDPOINT> \
  RCLONE_CONFIG_DRILL_REGION=<BACKUP_S3_REGION> RCLONE_CONFIG_DRILL_ACCESS_KEY_ID=<key id> RCLONE_CONFIG_DRILL_SECRET_ACCESS_KEY=<secret>
export RCLONE_CONFIG_DRILLC_TYPE=crypt RCLONE_CONFIG_DRILLC_REMOTE=drill:<BACKUP_S3_BUCKET>/config
export RCLONE_CONFIG_DRILLC_PASSWORD=$(rclone obscure -)   # type BACKUP_PASSPHRASE, Enter, Ctrl-D (stays out of the shell history)
rclone lsf drillc:                                          # readable file names: key and passphrase are right
rclone copy drillc: drill/ --include museum.yaml --include "$(rclone lsf drillc: --include 'ente_db-*.dump' | sort | tail -1)"
rclone lsf -R --files-only drill:<BACKUP_S3_BUCKET>/objects | wc -l   # the photos
```
The dump and `museum.yaml` in `drill/` must decrypt (rclone checks every block) and the dump should be about the size of the
server's. Repeat `lsf` with the photo bucket's key. Then delete `drill/`: it holds the server's keys. A full restore needs the
same `DOMAIN`, so it is done for real only when moving servers (above).

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
server instead, uploads included, and back again on demand. Measure first: it only helps if devices reach the server clearly
faster than the bucket's endpoint.

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

`bash tests/run_all.sh` runs every suite that changes nothing (the two bucket suites only where rclone is) and prints one line
per suite, with its time; the suites that change nothing run side by side (about 15 s). On the live server
`sudo bash tests/run_all.sh --server` adds the VPN config test and the proxy and bot end-to-end tests (about 3.5 min);
`--browser` also runs the web app in a real browser (about 4.5 min more): after touching the proxy or the web apps, and
after an Ente update.
Each suite also runs on its own:

| Command | Where | What |
| --- | --- | --- |
| `python3 -m unittest discover -s tests -v` | anywhere (Python 3 stdlib) | the link rewriter against a fake museum (incl. chunked responses and a stalled client), the bot against a fake Telegram (every reply) |
| `bash tests/test_tg_bot_config.sh` | anywhere; on the server also validated by visudo (changes nothing there) | bot config, token source, unit, sudo rule, root helper, ownership check, every reply of `/status`, `/check`, `/backup`, `/proxy` (stubbed server), command lines |
| `bash tests/test_bucket_copies.sh` | anywhere with rclone (the server; changes nothing there) | the config copy in the photo bucket: the real backup script on local "buckets", the copy's exclusion, restore fetching only the newest dump, check/verify, ownership check, restore's choice of bucket incl. lost buckets and a wrong passphrase, restore interrupted at each stage, the atomic `rclone.conf` write |
| `bash tests/test_backup_checks.sh` | anywhere with rclone (the server; changes nothing there) | the backup never deletes in the backup bucket (photos or dumps gone from the server stay there), `verify` catching a bad dump, empty tables, a damaged photo or missing config files, its growth line, and every FAIL in the backup part of `check` |
| `bash tests/test_check.sh` | anywhere (system tools stubbed) | the rest of `check`: services and image age, web and certificates, open ports, sshd/UFW, the photo bucket and CORS, the add-ons' checks, disk, OOM, pending reboot; each FAIL once, nothing on a healthy server |
| `bash tests/test_cli.sh` | anywhere (as an unprivileged user when run as root) | the command lines of `ente-setup.sh`, `ente-ops.sh`, `ente-vpn.sh`; config values refused (quotes, `$`, spaces, bad ids, `AWG_PORT`); the in-place `museum.yaml` write on a full disk; `backup-setup` refusing a script folder others can write |
| `bash tests/test_quickstart.sh` | anywhere with network (fetches Ente's current quickstart; docker stubbed) | `install`'s edits against today's quickstart: ports on 127.0.0.1, URLs, the external bucket, keys kept, in place, idempotent; a changed layout is refused |
| `bash tests/test_lockdown.sh` | anywhere (Postgres stubbed) | `lockdown`: oldest user becomes admin only after `y`, re-runs change nothing, install keeps the block, a hand-made `internal:` is refused, edited in place |
| `bash tests/test_alerts.sh` | anywhere (Telegram faked on 127.0.0.1) | the real alert scripts: what a failed check, verify or backup sends, to which chat, the length limit, broken UTF-8, Telegram down; the test message of `backup-setup`; emptying `TG_CHAT_ID` removes every alert file |
| `sudo bash tests/test_vpn_config.sh` | the server, after `ente-vpn.sh install` | the VPN config generator: keys pair up, same obfuscation on both sides within AmneziaWG's rules, mode 600, never overwrites, refuses a busy port |
| `bash tests/test_update.sh` | anywhere (docker and systemd stubbed) | `update`: a failed download (museum, web, postgres) or a failed backup first changes nothing; a real update moves the pins and keeps the old ones in `image-pins.prev`; museum not answering afterwards points there; pinned builds gone from the registry are re-pinned to the running or latest ones |
| `bash tests/test_proxy_config.sh` | anywhere; on the server also validated by Caddy (changes nothing there) | config checks, the Caddyfile hooks, the add-on's files in each state, the bucket taken from `museum.yaml`, the rollback of a failed install or switch, unit, command lines |
| `sudo bash tests/proxy_e2e.sh` | the server, `S3_PROXY_HOST` set | `ente-s3-proxy.sh` end to end (install, on/off, fallback, rollback, uninstall), plus `tests/proxy_e2e_s3.py`: real signed links through the proxy |
| `sudo bash tests/tg_bot_e2e.sh` | the server, `TG_BOT_USER_ID` set | the real bot as its real user with the real sudo rule and actions, against a fake Telegram (`tests/fake_telegram.py`): every command, strangers, groups, old messages, privileges, uninstall; runs a real backup |
| `sudo bash tests/proxy_browser_e2e.sh` | the server, `S3_PROXY_HOST` set | the real web app in Chromium (Playwright container): sign-up, uploads incl. multipart, viewing, with the proxy on and off |

`proxy_e2e.sh` and `tg_bot_e2e.sh` leave their add-on as they found it (installed or not, on or off). The browser test opens registration for a throwaway account, deletes it
afterwards and closes registration again. Its first run builds a local image with Playwright (`ente-e2e-playwright`, about
5.5 GB on disk) and keeps it, so later runs skip the download; `KEEP_IMAGE=0` removes it afterwards (or
`docker rmi ente-e2e-playwright:1.49.0 && docker builder prune -af` any time). `TEST_TIMES=1` before any bash suite adds the seconds each check took.

## Notes and limits

- Users in countries that throttle foreign hosts need to reach the photo bucket's endpoint directly; pick a provider that works for
  them, or use the S3 proxy.
- IDrive e2 answers CORS preflights for any origin, whatever CORS rule the bucket holds: the signatures, not CORS, protect the bucket.
- The installers (get.docker.com, Caddy repo key, rclone, Ente quickstart from `main`) are fetched at install time and run as root without pinning; the quickstart's output is asserted.
- The VPS downloads and re-uploads every photo for the backup (bucket → VPS → bucket). Fine for hundreds of GB, slow for the first run.
- Museum logs some request metadata (never photo plaintext); Docker log rotation bounds it (10 MB x 3).
