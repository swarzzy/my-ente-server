# ente-server

One script, `ente-setup.sh`, turns a fresh Debian 12/13 KVM VPS into a working, backed-up
[Ente Photos](https://ente.com) server: Caddy (TLS) in front of Museum, the web apps and Silo (S3), all
containers on `127.0.0.1` only, daily encrypted backups to a Hetzner Storage Box.

Every subcommand is safe to re-run. Logs go to `/var/log/ente-setup.log` (no secrets).
Secrets (backup passphrase, Box password) are only ever typed at a prompt.

## Files

| File | Purpose |
| --- | --- |
| `ente-setup.sh` | the script |
| `ente-setup.env.example` | config template; copy to `ente-setup.env` (git-ignored) |

## Fresh production install

1. **DNS.** A/AAAA for `api.`, `web.`, `albums.`, `s3.` under your domain (or one wildcard), TTL 300, pointing at the server.
2. **Config.** Copy `ente-server/` to the server, `cp ente-setup.env.example ente-setup.env`, edit it
   (`DOMAIN`, `ADMIN_USER`, `ADMIN_SSH_PUBKEY`, `BOX_*`, `DATA_DISK` if you have a separate disk). Use `chmod 600`.
3. **As root:** `./ente-setup.sh bootstrap`
   - Creates `ADMIN_USER` (sudo, no password), hardens sshd (key only, no root login, `AllowUsers`), UFW (22/80/443),
     unattended-upgrades with reboot at 02:00 when needed, 2 GB swap, fail2ban, and formats/mounts `DATA_DISK` at `/srv/ente-data`.
   - **Before closing the root session, open a second terminal and log in as `ADMIN_USER`.**
4. **As `ADMIN_USER`:** `sudo ./ente-setup.sh install`
   - Installs Docker and Caddy, runs Ente's quickstart, edits its files (each edit is asserted), writes `compose.override.yaml` and the Caddyfile, starts everything.
   - Save `/opt/my-ente/museum.yaml` in your password manager. It holds the keys needed to read the database.
5. **Sign up the owner first** at `https://web.<domain>`, then family. Codes: `sudo ./ente-setup.sh codes` (no SMTP, so they are in the museum log).
6. `sudo ./ente-setup.sh lockdown` – shows users, makes the oldest the admin (after you confirm), closes sign-ups.
7. `sudo ./ente-setup.sh backup-setup` – see Backups.
8. Apps: on Android/Windows tap the welcome screen 7 times and enter `https://api.<domain>`.
9. Lift the storage limit from your PC with the Ente CLI:
   `ente account login --account home-server --app photos --host https://api.<domain>` then
   `ente admin user update-subscription EMAIL --no-limit --account home-server` (login must be < 10 min old).

## Backups

`backup-setup` needs `BOX_HOST`/`BOX_USER`. It creates `/root/.ssh/storagebox`, records the Box host keys
(**compare the fingerprints it prints with Hetzner's**), installs the key with `ssh-copy-id` (asks for the Box
password), asks twice for a **backup passphrase** (keep it in your password manager; without it the config backups are unreadable),
creates the rclone remotes `ente-s3`, `box`, `box-crypt`, and installs `ente-backup.timer` (03:00 daily, catches up if missed).

What a run does: dumps Postgres (verified, written atomically), copies `museum.yaml`/`compose*.yaml`, syncs these to `box-crypt:`
(= `box:config`, names and contents encrypted), then mirrors the bucket to `box:objects`. Objects deleted from the bucket
are moved to `box:deleted/<date>` and purged after 60 days; a run that would delete more than 500 objects stops with an error.
`HC_URL` (optional) is pinged only after a fully successful run.

**S3 instead of a Storage Box** (e.g. IDrive e2): set `BACKUP_TARGET=s3` plus `BACKUP_S3_PROVIDER/ENDPOINT/REGION/BUCKET`
(see the example file). `backup-setup` then asks for the S3 access key ID and secret (kept only in root's `rclone.conf`) instead of
installing an SSH key. The layout is the same under `<bucket>/`: `objects/`, `config/` (encrypted), `deleted/<date>/`. Use a key
limited to that bucket. If versioning is on, old versions stay in the bucket and count against its quota; if Object Lock is on,
moving files to `deleted/` may be refused (not tested). Changing the S3 settings later only needs `backup-setup` again.

Also set daily snapshots on the Box in the Hetzner Console; they are your protection against a bad sync.

Run now: `sudo systemctl start --no-block ente-backup.service`; logs: `journalctl -u ente-backup.service`.

## Monthly: `sudo ./ente-setup.sh check`

OK/FAIL report: containers, restart policy, localhost-only ports, sshd, UFW, Caddy, backup timer and last result,
`rclone check` bucket vs Box, disk, OOM kills, pending reboot. Also look at Box usage in the Hetzner Console.

## Updates

`sudo ./ente-setup.sh update` (pull images, recreate changed containers, prune). Ente images are untagged `latest`;
read Ente's release notes first if you can. OS updates install themselves; reboots happen at 02:00 only if required.

## Moving to another host (restore)

1. New VPS: `bootstrap` with the **same `DOMAIN`** and the same config (use a data disk if the old one had one).
2. `sudo ./ente-setup.sh restore` – asks for the Box password (new key) and the backup passphrase, fetches
   `box-crypt:`, restores `museum.yaml`, the newest DB dump and all objects, regenerates the override and Caddyfile for this host,
   starts everything and prints the DNS change.
3. Point DNS (A/AAAA of the four names, TTL 300) at the new IP; certificates are issued when DNS resolves.
4. `sudo ./ente-setup.sh backup-setup`, then `check`. Remove the old server once all is confirmed.

Apps keep working because the hostnames do not change.

## Data disk

`DATA_DISK=/dev/vdb` in `bootstrap`: refuses the root disk and any disk with a partition/filesystem/signature
(`FORCE_FORMAT=yes` overrides). It is formatted ext4 (label `ente-data`) and mounted by UUID with `nofail`.
Silo's objects live in `/srv/ente-data/silo`; Silo refuses to start (and the backup refuses to run) if the disk is not mounted.
If the disk was missing at boot, attach it, `mount /srv/ente-data`, then `cd /opt/my-ente && docker compose up -d`.

## Test mode (VM without public IP)

`MODE=test`, `DOMAIN=ente.test`. Prints a loud banner; never use on a real server. Same path as production except:
Caddy issues certificates from its own local CA (`local_certs`), hostnames are mapped to 127.0.0.1 in `/etc/hosts`,
the CA is trusted on the VM and mounted into museum, and `internal.hardcoded-ott` makes `anything@ente.test` use code `123456`.
`install` prints the hosts-file and certificate-import steps for your PC. To test backups without a Storage Box set
`BOX_HOST=127.0.0.1 BOX_USER=<local user> BOX_PORT=22` and authorize `/root/.ssh/storagebox.pub` for that user.
Phones do not trust the local CA, so phone tests need the real server.

## Syncthing (optional)

`SYNCTHING=yes`, then `sudo ./ente-setup.sh syncthing` and re-run `backup-setup`. UI on `127.0.0.1:8384`
(`ssh -L 8384:127.0.0.1:8384 user@server`), sync port 22000 public, data in `/srv/syncthing`.
