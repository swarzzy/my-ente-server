# Ente server: functions and tests

As of 2026-11-20.

Scripts in `ente-server/` turn a Debian VPS into a self-hosted Ente Photos server with photos in an S3 bucket, nightly encrypted backups to a second bucket, health checks, Telegram alerts and three optional add-ons. Telegram goes through `opsbot/`, a separate bot and notification service that Ente plugs into (its own [README](../opsbot/README.md)). Each section lists what a function does and what a tester must prove. The runbook is [`ente-server/README.md`](../ente-server/README.md); this is the overview.

## How it fits together

```
                      photos up and down, through links museum signs
      +-------------------------------------------------------------------------------+
      |                                                                               v
+-----------+        +------------- VPS (Debian, ente-setup.sh) ------+   +------------------+
| Ente apps |  API   | Caddy: HTTPS, certificates, security headers   |   | Photo bucket     |
| phone,    |------->|------------------------------------------------|   | encrypted photos |
| desktop,  |        | museum (Ente API)     | web (web and albums)   |   | + config copy    |
| web       |        |------------------------------------------------|   +------------------+
| (end-to-  |        | Postgres: users, file metadata, encrypted keys |            ^
| end       |        |------------------------------------------------|  config  |
| encrypted)|        | Timers: backup 03:00, check 09:00, verify      |----------+
+-----------+        |         monthly                                |---------------+
                     |------------------------------------------------|  nightly copy |
                     | Add-ons (optional): Telegram bot, S3 proxy,    |               v
                     | VPN                                            |   +---------------------+
                     +------------------------------------------------+   | Backup bucket       |
                                         |                                | copy of every photo |
                                         | alerts, bot                    | every dump,         |
                                         v                                | encrypted           |
                                    +----------+                          +---------------------+
                                    | Telegram |
                                    +----------+
```

The apps upload and download photos directly to the photo bucket; the server handles the API, the database and the nightly backup to the second bucket.

## Setup commands

`ente-setup.sh <command>`, run as root. Config comes from `ente-setup.env`, keys from `ente-setup.secrets`. Every command can be re-run safely.

| Command | What it does | What to test |
| --- | --- | --- |
| `bootstrap` | Upgrades packages; creates the admin user (key only, passwordless sudo); moves SSH to `SSH_PORT`, turns off root and password login; enables ufw (SSH, 80, 443), fail2ban, turns LLMNR/mDNS off in `systemd-resolved` if it runs (port 5355), unattended upgrades with automatic reboot at 02:00 (Debian, plus the Docker, Caddy and AmneziaWG repositories; `install` and `ente-vpn.sh install` write it too), 2 GB swap. | Admin can log in on the new port; root and passwords are refused; `sshd -T` shows the settings; ufw active; nothing on port 5355. |
| `install` | Installs Docker and Caddy; fetches Ente's quickstart and edits it: ports on 127.0.0.1 only, the domain's URLs, the external photo bucket; pins the Ente images by digest; writes the Caddyfile (TLS, security headers) with `web.`, `albums.` and any `WEB_APPS` (`auth.`, `locker.`); sets CORS on the bucket (the web apps and `ente://app`, the desktop apps); starts the containers. | `https://api.<domain>/ping` answers; ports 8080/3000/3002 local only; images pinned; a changed quickstart layout is refused. |
| `codes` | Prints sign-up verification codes from the last 24 h of museum logs (no mail server). | A sign-up's code shows up. |
| `lockdown` | After a yes, makes the oldest user the admin and closes sign-ups; restarts museum. | Only after `y`; deleted accounts skipped; re-run changes nothing; new sign-ups refused. |
| `backup-setup` | Creates the rclone remotes, refuses a bucket holding another instance's backup, installs the backup and verify timers, Telegram alerts (installs or updates opsbot with the config's token and chat, sends a test message, removes the alerts from before opsbot), starts a first backup. Backup bucket keys in the secrets file replace the remote's (rotation); the passphrase is never replaced. | Foreign or unreadable backup refused; script folder writable by others refused; test message arrives; new keys applied, none given keeps the old. |
| `restore` | On a fresh server: takes config and database from whichever bucket has the newer dump, restores the newest dump, copies missing photos back from the backup bucket. Resumes if interrupted. | Restore from each bucket alone; wrong passphrase refused; interrupted at each stage, then re-run. |
| `update` | Backs up first, moves the image pins to Ente's latest builds, recreates what changed, keeps the old pins in `image-pins.prev`. | Failed download or failed backup changes nothing; museum not answering points to `image-pins.prev`. |
| `deploy` | `bootstrap` + `install` (or `restore` with `RESTORE=yes`) + `backup-setup` in one go. | A clean VPS ends with `check` passing. |

## Backup and restore

The backup never deletes anything in the backup bucket; old photos and dumps are cleaned up by hand. Either bucket alone, plus `BACKUP_PASSPHRASE`, restores everything.

| Function | What it does | What to test |
| --- | --- | --- |
| Nightly backup (`ente-backup.sh`, 03:00) | Dumps Postgres (checked readable, written atomically), keeps 7 days of dumps locally with `museum.yaml`, compose files and image pins. | Empty or unreadable dump stops the run; old local dumps pruned after 7 days. |
| Copy to the backup bucket | Copies the encrypted config (`backup-crypt:`) and every photo object (`<bucket>/objects`). Copy only. | Photos deleted from the photo bucket, and dumps gone from the server, stay in the backup. |
| Config copy in the photo bucket | Syncs the same encrypted config into the photo bucket (`ente-backup-config/`, the last 7 dumps). | Follows the server's dumps; excluded from the photo copy. |
| Stamps and heartbeat | Each successful part leaves a stamp for `check`; a fully good run pings `HC_URL`. | A failed part leaves no stamp and exits 1; a failed ping does not fail the backup. |
| Bucket source | Bucket name and endpoint come from `museum.yaml` once install wrote them, else from `ente-setup.env`. | An edited `S3_BUCKET` without re-running install keeps the old bucket and `check` warns. Re-running install moves the backup to the new bucket too (env file, `ente-s3` and `photo-crypt` remotes, after the ownership check); `check` fails if the backup copies another bucket or endpoint than museum uses. |
| `restore` | See Setup commands. Restores only the newest dump; a server mid-restore is never wiped once its database is restored. | See Setup commands. |
| Manual clean-up | README commands: list and remove photos no longer in the photo bucket; delete dumps older than 90 days (`--dry-run` first). | Dry runs list what would go. |

Two things only a person can prove: that the offline copies of the keys and passphrase open the backup (yearly read-only drill from a PC, in the README), and a full restore, which needs the same domain and is done for real at a server move.

## Monitoring and alerts

Nothing is sent while all is well. Every FAIL is something that can break by itself and that nothing else reports; WARNs never alert.

| Function | What it does | What to test |
| --- | --- | --- |
| Daily check (`ente-ops.sh check`, 09:00) | Read-only report, exit 1 on any FAIL. Services: museum, web, postgres healthy; sign-ups closed after lockdown; Ente images under 60 days (WARN). Web: Caddy up, api/web/albums (and auth/locker when in `WEB_APPS`) answer, certificates valid 20+ days. Security: see that section. Photo bucket reachable, CORS allowed. Add-ons' own checks. Backup: last good backup and config copy under 36 h, verify under 45 days, no unfinished restore; an INFO line with the last bucket measurement. System: disk (WARN 80%, FAIL 90%), OOM kills in 24 h, reboot pending over a day (WARN). | Each fault gives exactly one FAIL; a healthy server none; a running first backup only WARNs. |
| Weekly Postgres update (`ente-ops.sh pg-update`, Sun 05:00) | Applies a newer `postgres:15` build (minor releases: security fixes): recreates postgres, restarts museum, checks `/ping`. Needs a good backup in the last 36 h; waits while a backup or verify runs. `check` fails if its timer is off. | Current build untouched; no recent backup refused (fails); running backup or verify postponed; failed download changes nothing. |
| Weekly rclone update (`ente-ops.sh rclone-update`, Sun 05:15) | `rclone selfupdate` of rclone.org's binary (apt does not update it); the new version must list both buckets, else the previous one goes back and it fails. Keeps `rclone.prev`. Skips a packaged rclone; waits while a backup or verify runs. `check` fails if its timer is off. | New release kept or rolled back; failed selfupdate changes nothing; packaged rclone untouched. |
| Monthly verify (`ente-ops.sh verify`, 1st, 04:30) | Photos match the backup by checksum (size where no common checksum); both encrypted config copies decrypt and equal the local files; the newest dump restores into a scratch database with tables, users and files present; an INFO line on the backup bucket's growth; measures both buckets (size, files) for `check`, `/status` and `/size`. Changes nothing but that measurement. | Corrupt dump, empty tables, damaged photo, missing config file each give one FAIL; a table added by an update is no false FAIL. |
| Alert: backup failed | `❌ Backup failed on <host>` with its ERROR lines (or the last 15 log lines). | Right title and lines; broken UTF-8 and long logs still send. |
| Alert: check or verify found problems | `⚠️ Daily check found problems on <host>` or `⚠️ Monthly backup verify found problems on <host>`, one ❌ line per problem. | Only FAIL lines, no OK, WARN or verdict noise. |
| Monthly news (`ente-ops.sh news`, 2nd, 10:00) | Compares the pinned museum and web builds with the registry's `latest` (no download) and, if one is newer, sends both build dates and the `update` hint to Telegram. Installed with the alerts; `check` fails if its timer is off while alerts are on. | Current: nothing sent; newer: listed; registry or Telegram down: fails. |
| Alert test message | Sent by every `backup-setup` run; a failure stops setup before anything is installed. | Wrong chat id stops setup. |
| Heartbeat (`HC_URL`) | Pinged after each fully good backup; the outside service alerts when a ping is missing (also covers the server being down). | A missed night is reported by the service. |
| Alerts off | Emptying `TG_CHAT_ID` and re-running `backup-setup` removes all alert files. | All six files gone. |

## Security hardening

Photos stay end-to-end encrypted by the Ente apps; the server never sees plaintext. The rest protects the server and the keys.

| Function | What it does | What to test |
| --- | --- | --- |
| SSH | Key-only login for one admin user on a custom port; no root, no passwords, 3 tries; fail2ban. | Password and root logins refused; `check` FAILs if a setting changes. |
| Firewall and ports | ufw allows only SSH, 80, 443 (plus the VPN's UDP port). Docker bypasses ufw, so all Ente ports bind to 127.0.0.1. | `check` FAILs on any TCP port reachable from outside except SSH, 80, 443. |
| TLS and headers | Caddy gets Let's Encrypt certificates; HSTS, nosniff, no-referrer, frame denial; CSP in report-only mode if enabled. Caddy's admin API is a local socket only root and Caddy can write to. | Certificates valid; headers present; admin API closed to other users. |
| Pinned images | Ente images run by digest; nothing changes version unless `update` runs. | Pins survive `install` re-runs; `restore` runs the builds that made the dump. |
| Secrets | Keys live in `ente-setup.secrets` (600) and root-only files; the backup is encrypted with `BACKUP_PASSPHRASE`; tokens never on a command line. | Token appears in no other file and in no log. |
| Config values | Values written into generated files (domain, buckets, `HC_URL`, Telegram ids and token, proxy host, VPN port) are refused if they hold quotes, `$`, spaces or backslashes, or have the wrong shape. | Injection attempts refused. |
| Root-run folder | Root's timers and the bot run scripts from the script folder, so it must be root's alone; `backup-setup` and the bot install refuse otherwise. | A folder others can write is refused. |
| Config paths | The check and verify timers and the bot helper run with the `ENV_FILE`/`SECRETS_FILE` paths setup used (absolute), not only the defaults next to the scripts. | Units and helper carry the paths; a path a unit line would break on is refused. |
| Safe writes | `museum.yaml` (holds the master key) is rewritten in place and never left truncated on a full disk. | On a full disk, setup dies and keeps the new content; the bucket edit dies and leaves `museum.yaml` untouched. |

## Add-ons

All three are optional and installed separately; each has `install`, `uninstall` and `status`, and the first two feed their checks into the daily check.

| Add-on | What it does | What to test |
| --- | --- | --- |
| S3 proxy (`ente-s3-proxy.sh install / on / off`) | For devices that reach the bucket badly: a link rewriter in front of museum swaps the bucket host in its signed links for `S3_PROXY_HOST`; Caddy forwards only the bucket path and the apps' methods to the real endpoint with its own Host, so signatures stay valid. Bucket host and name come from `museum.yaml`. If the rewriter dies, Caddy falls back to museum. | `on` self-tests before going live; any failed step rolls everything back; links handed out while on keep working after off; uploads incl. multipart work both ways (browser test). |
| Telegram bot (`ente-tg-bot.sh install`) | Registers Ente as the opsbot plugin `ente` (installing or updating opsbot with the bot on, and removing the bot from before opsbot): `/status` lines (services, backup, checks, last bucket measurement, proxy), `/check`, `/backup`, `/proxy [on\|off]`, `/size`. opsbot may run as root only these seven actions, through its helper. `uninstall` unregisters them; opsbot stays. | The plugin passes opsbot's validator; the seven actions and nothing else are allowed; every reply; the older bot is gone before opsbot polls; `check` includes the bot. |
| AmneziaWG VPN (`ente-vpn.sh install`) | An obfuscated WireGuard VPN on `AWG_PORT` (UDP 1024–65535) with one shared client config; NAT, IPv4 only. Independent of Ente. | Self-test from a network namespace: handshake, exit address, no IPv6 leak, 20 MB download. |

## opsbot (`opsbot/`, independent of Ente)

| Part | What it does | What to test |
| --- | --- | --- |
| `opsbot.sh install` | Notifications (`opsbot-notify`, `opsbot-notify-unit`, `opsbot-alert@.service`) to `OPSBOT_CHAT_ID`, and with `OPSBOT_USER_ID` the bot service as the unprivileged user `opsbot`. Token in `/etc/opsbot/token` (600), a test message when token or chat change; re-runs keep stored values. | Bad token, ids or an unsendable test message stop it before anything is written; re-run changes nothing; emptying the user id removes the bot only. |
| `opsbot.sh plugin add/remove` | Validates a plugin file (names, commands not taken, files it runs root's alone), copies it to `/etc/opsbot/plugins.d`, regenerates the sudo rule (exactly the registered plugin-action pairs), reloads the bot. | Conflicts, broken files and writable scripts refused; the rule follows the registry. |
| The bot (`opsbot.py bot`) | Long-polls; only the owner's private messages; commands older than a minute skipped; strangers noticed at most hourly. Commands come from the plugins: quick actions reply with their output, long ones say they started, then the result, one at a time per lock. `/status`: each plugin's status, then a disk/RAM/uptime line. SIGHUP reloads the plugins and menu. | Every reply kind; injection refused; locks; a broken plugin skipped; reload; the token never logged. |
| The root helper (`opsbot-action PLUGIN ACTION`) | Re-reads the root-owned plugin file, refuses unknown pairs and files others could change, runs the action as a transient unit from `/` with a clean environment. | Refusals; planted Python modules not loaded; an action outlives the bot. |

## Tests

All suites live in `ente-server/tests/` and `opsbot/tests/` and must pass on the server before a commit; there is no CI. `bash tests/run_all.sh` runs every suite that can run where it is; `sudo bash tests/run_all.sh --server` on the server adds the VPN and the proxy, opsbot and bot end-to-end suites (about 4.5 min), and `--browser` also the browser test (about 4.5 min more; after proxy or web app changes and Ente updates). Counts are from the last full run on the server.

| Suite | Runs | Covers | Checks |
| --- | --- | --- | --- |
| `test_cli.sh` | anywhere | command lines, config value checks, `AWG_PORT`, safe `museum.yaml` write, photo bucket source, config paths, unattended-upgrade origins, the bucket CORS origins, LLMNR off | 63 (+3 on the server) |
| `test_check.sh` | anywhere (stubs) | every non-backup part of `check` | 39 |
| `test_backup_checks.sh` | server (rclone) | backup never deletes, `verify` faults, growth line and bucket measurement, `size`, backup part of `check`, the backup following a bucket switch | 44 |
| `test_bucket_copies.sh` | server (rclone) | the real backup script, config copies, restore from each bucket, interrupted restores, backup key rotation, timer units | 63 |
| `test_alerts.sh` | anywhere (fake Telegram) | alerts through opsbot: install, test message, the older alerts moved, every alert's text, alerts off, news unit | 25 |
| `test_update.sh` | anywhere (stubs) | `update` failures, rollback point, re-pinning; `pg-update`, `rclone-update`, `news` | 45 |
| `test_lockdown.sh` | anywhere (stubs) | `lockdown` | 16 |
| `test_quickstart.sh` | anywhere with network | `install`'s edits against Ente's current quickstart | 17 |
| `test_proxy_config.sh` | anywhere; Caddy-validated on the server | proxy config, Caddyfile hooks, rollback | 70 |
| `test_tg_bot_config.sh` | anywhere; visudo on the server | bot config, token sources, the plugin file and its sudo rule, install/uninstall and the move from the older bot, every reply (stubbed server) | 69 |
| `test_vpn_config.sh` | server, after VPN install | VPN key and obfuscation config | 13 |
| `python3 -m unittest discover -s tests` | anywhere | link rewriter | 23 |
| `proxy_e2e.sh` | server | the proxy end to end, real signed links | 42 |
| `tg_bot_e2e.sh` | server | Ente's plugin through the real opsbot; runs a real backup | 38 |
| `opsbot/tests`: unittest | anywhere | the bot against a fake Telegram, plugin checks, helper, sudo rule | 44 |
| `opsbot/tests/test_opsbot_cli.sh` | anywhere | install, plugins, checks, notification scripts, command line | 72 |
| `opsbot/tests/opsbot_e2e.sh` | server, opsbot with a bot | a test plugin through the real sudo rule and helper, a second bot against a fake Telegram | 50 |
| `proxy_browser_e2e.sh` | server | the web app in Chromium: sign-up, uploads incl. multipart, viewing, proxy on and off | 17 |

Still manual:

- [ ] After any change: `check` and `verify` pass on the live server.
- [ ] Yearly: the read-only restore drill from a PC with the offline keys (README).
- [ ] At a server move: a full `restore`, then sign in on a phone and open photos and videos.
- [ ] Telegram: send `/status` and `/check` to the real bot; confirm alerts reach the chat.
- [ ] VPN: import the client config on a device and browse through it.
