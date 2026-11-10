# ente-server

One script, `ente-setup.sh`, turns a fresh Debian 12/13 VPS into a working, backed-up
[Ente Photos](https://ente.com) server:

- **Caddy** (Let's Encrypt TLS) is the only public service; Museum, the web apps and Postgres run in Docker on `127.0.0.1`.
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

Both copies are git-ignored. Anything missing from the secrets file is asked at a prompt (never echoed, logged or stored in the env file).

## Fresh install

1. **Buckets.** Create two buckets at two providers if you can. The key for the photo bucket needs read/write/delete and
   permission to set CORS (the script sets it; if the provider refuses it prints what to set by hand).
   Backup bucket: on versioned buckets (B2 keeps old versions by default) add a lifecycle rule "keep only the last version".
2. **DNS.** A (and AAAA) records for `api.`, `web.` and `albums.` under your domain → the VPS, TTL 300.
3. **Config.** Copy `ente-server/` to the VPS, create `ente-setup.env` and `ente-setup.secrets` from the examples.
   `BACKUP_PASSPHRASE` encrypts the config backup: keep it in a password manager, without it the backup is unreadable.
4. **As root:** `./ente-setup.sh deploy` = `bootstrap` + `install` + `backup-setup`. About 5 minutes.
   - `bootstrap`: updates, `ADMIN_USER` (sudo, key only), sshd hardening (no passwords, no root login), UFW 22/80/443,
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

## Backups

A run (`systemctl start --no-block ente-backup.service`, logs `journalctl -u ente-backup.service`):
dumps Postgres (verified, atomic), copies `museum.yaml`/`compose*.yaml`, syncs them to `<backup bucket>/config` (names and contents
encrypted with `BACKUP_PASSPHRASE`), mirrors the photo bucket to `<backup bucket>/objects`. Objects deleted from the photo bucket move to
`deleted/<date>/` and are purged after 60 days; a run that would delete more than 500 objects stops with an error.
`HC_URL` (optional) is pinged only after a fully successful run.

`backup-setup` refuses to touch a backup bucket that already holds another Ente instance's backup, one the passphrase cannot read, or one it cannot list.
The server holds keys that can delete backups: turn on bucket versioning or Object Lock at the backup provider if it supports it, and use a key limited to that bucket.
Two safety limits stop a run instead of deleting: more than 500 photo deletions, more than 20 dump deletions.

## Monthly: `sudo ./ente-setup.sh check`

OK/FAIL report: containers, restart policy, localhost-only ports, sshd, UFW, Caddy, HTTPS, photo bucket + CORS, backup timer and last
result, `rclone check` photo bucket vs backup, disk, OOM kills, pending reboot. Also look at both buckets' usage in the provider consoles.

## Updates

`sudo ./ente-setup.sh update`: runs a backup first (rollback point; aborts if it fails), pulls images, recreates changed containers, prunes.
Ente images are untagged `latest`; read Ente's release notes first. OS updates install themselves.

## Moving to a new VPS / disaster recovery (`restore`)

1. New VPS, point DNS later. Put the **same** `ente-setup.env` and secrets there (same `DOMAIN`, same buckets, same `BACKUP_PASSPHRASE`) and set `RESTORE=yes`.
2. `./ente-setup.sh deploy` (bootstrap, then `restore`, then `backup-setup`). `restore` fetches the encrypted config backup,
   puts back `museum.yaml`, restores the newest DB dump, and uses the photos already in the photo bucket
   and tops up any objects missing from the photo bucket from the backup (copy only, never deletes). About 2 minutes for a small library.
   If a restore is interrupted, just run it again: it cleans up and starts over.
3. Point DNS (`api.`, `web.`, `albums.`, TTL 300) at the new IP; certificates are issued once it resolves. Run `check`.

Apps keep working because the hostnames do not change. To restore into a *new* photo bucket, set the new `S3_*` values:
objects are copied from the backup bucket.

## Notes and limits

- Users in countries that throttle foreign hosts need to reach the photo bucket's endpoint directly; pick a provider that works for them.
- The installers (get.docker.com, Caddy repo key, rclone, Ente quickstart from `main`) are fetched at install time and run as root without pinning; the quickstart's output is asserted.
- The VPS downloads and re-uploads every photo for the backup (bucket → VPS → bucket). Fine for hundreds of GB, slow for the first run.
- Museum logs some request metadata (never photo plaintext); Docker log rotation bounds it (10 MB x 3).
