# Test report - small VPS + two S3 buckets

Environment: real VPS (Debian 13, 1 vCPU, 2 GB RAM, 25 GB disk, public IPv4), domain `swwz-storage.site` (A records for
`api.`/`web.`/`albums.`), photo bucket IDrive e2 (`s3.eu-west-4.idrivee2.com`), backup bucket Backblaze B2 (`us-east-005`, 10 GB test).
Browser tests: Playwright/Chromium on the owner's PC against the public hostnames (real Let's Encrypt certificates).
Earlier tests of the full-featured version (local Silo, data disk, test mode, low RAM, Syncthing) are in git tag `full-featured-v1`.

## Fresh install (`deploy`)
- [x] `bootstrap` + `install` + `backup-setup` finish; museum healthy; `check`: all OK (containers, restart policies, 8080/3000/3002 on 127.0.0.1 only, 3200/3201/5432 not listening, sshd, ufw, caddy, HTTPS, photo bucket, CORS preflight, backup, no OOM).
- [x] Museum runs with a single bucket entry (`b2-eu-cen` -> e2); the two unused quickstart buckets are removed. No Silo/socat started.
- [x] Real Let's Encrypt certificates for the three hostnames.
- [x] Web app (browser): sign-up, 12 photos uploaded directly to e2 (originals + thumbnails as separate objects), 25 s / 65 MB video uploaded multipart (2 parts + complete POST, all HTTP 200, no CORS errors), album created, thumbnails and viewer decrypt correctly.
- [x] `lockdown`: oldest user becomes admin, `disable-registration: true`; new sign-up -> HTTP 403.
- [ ] Not tested: Windows/Android apps, public album link in a private window (this run), Ente CLI `--no-limit`.

## Idempotency
- [x] Re-running `deploy`: sha256 of fstab, hosts, sshd drop-in, sudoers, authorized_keys, apt confs, fail2ban, Caddyfile, daemon.json, compose/museum/override, backup env/script/units, rclone.conf all unchanged; same container IDs and creation times; ufw rules unchanged.
- [x] Re-running `backup-setup` asks for nothing and keeps remotes.

## Backups (e2 -> B2)
- [x] First run ok; photo bucket and `objects/` equal: 26 objects, 75.1 MiB; `config/` names encrypted, `backup-crypt:` lists `ente_db-DATE.dump`, `museum.yaml`, `compose.yaml`, `compose.override.yaml`.
- [x] Guard: backup bucket holding a different instance's backup (changed `key.encryption`) -> refused. Wrong passphrase -> refused (found and fixed: `rclone cat` of an unreadable name exits 0 with empty output).
- [x] `check`'s `rclone check` ok after the run.
- Tested in the earlier version (backup code unchanged except remote names/creation): delete -> `deleted/DATE`, prune of old folders, `--max-delete` abort, `HC_URL` only after success, file modes 600/700, no secrets in log/journal.

## Restore (host move) on a freshly reset VPS
- [x] Clean Debian 13 -> `deploy` with `RESTORE=yes` (same domain, same bucket keys and passphrase): **restore step 84 s**; whole `deploy` about 4 min.
- [x] DB identical: 11 users / 13 files / 3 collections; `museum.yaml` byte-identical (sha256 equal), lockdown block preserved, temp directory with decrypted config removed.
- [x] Existing photos kept in e2 (bucket not empty -> nothing copied). Browser: existing user logs in with the original password on the restored server, sees 12 memories, viewer opens and decrypts the original; no HTTP errors.
- [x] `check` all OK on the restored host after `backup-setup`.

## Fresh install of the simplified script (second run, after emptying both dev buckets and removing the app)
- [x] `deploy` on the already-bootstrapped VPS: 29 s (packages cached), `check` all OK, CORS set, fresh quickstart secrets.
- [x] Browser: full batch of 12 photos + 65 MB video: 13/13 uploaded. The video's multipart upload finishes slowly when many files upload at once in headless Chromium (stuck at 12/13 for more than 4 minutes, done within 10); alone or with one photo it takes under 90 s. Server logs clean, every PUT to e2 returned 200.
- [x] Backup run: photo bucket and `objects/` equal, 66 objects / 157.9 MiB; `check` all OK. DB: 5 users, 33 files.

## Independent review and fixes (blind review by a second agent, then retested on the VPS)
Fixed: invalid/placeholder admin key now refused before sshd hardening; `KbdInteractiveAuthentication no` added and verified; backup-owner guard fails closed on listing errors; `update` no longer swallows failures and takes a backup first; restore is resumable and always tops up missing objects (copy only); any `museum.yaml` change restarts museum (in-place edit keeps the bind-mount inode); S3 keys are not demanded again when `museum.yaml` already holds them; `RCLONE_CONFIG` fixed independent of sudo's HOME; `sshd -T | awk` SIGPIPE race removed; `deploy` collects all secrets before changing anything; incomplete quickstart dir detected; environment wins over blank values in the secrets file; dump sync `--max-delete 20`; `check` flags a backup older than 36 h.
Not changed: `MaxAuthTries 3` (per brief, documented), unpinned installers (documented), OTP codes in the log from `codes`.
Retest on the VPS: bad key refused (root login untouched); `install` without secrets file OK; `update` (backup first) OK; `deploy` re-run changes only the sshd drop-in and backup script as expected; teardown + `restore` OK (5 users / 33 files, 20 s); simulated interrupted restore re-run cleans up and completes; `check` all OK.

## Deviations from the original brief
1. Storage is an external S3 bucket (`STORAGE` Silo mode, data disk, Storage Box, Syncthing, test mode and zram were removed to keep the script small; see git tag `full-featured-v1`).
2. Bucket keys and the backup passphrase may come from `ente-setup.secrets` or the environment (non-interactive `deploy`); they are prompted when missing.
3. rclone remotes are written to `rclone.conf` directly and the passphrase goes through `rclone obscure -` on stdin: no secret in any command line.
4. `ADMIN_USER` gets `NOPASSWD` sudo (key-only user). Caddy proxies to `127.0.0.1`. Docker log rotation. Backup dump written atomically and verified.
5. All `apt` calls wait up to 10 minutes for the dpkg lock (fresh images run unattended-upgrades at first boot; found on the reset VPS).
6. CORS is set on the photo bucket by the script (boto3 `put_bucket_cors`), origins `web.` and `albums.`.
7. Quickstart facts held (images, ports, `endpoint`, `public-albums`, no `internal:`). `museum.yaml` is created mode 644 (inside the root-only 700 dir); `apps:` lists more services than the brief names.

## Open issues and risks
- Museum accepts a single configured bucket; verified for uploads/downloads/multipart on e2. Replication to a second bucket is not configured (backup is the second copy).
- e2/B2 endpoints must be reachable by every user (incl. those in Russia); not testable from here.
- Backup traffic goes bucket -> VPS -> bucket; B2 keeps old file versions unless a lifecycle rule limits them.
- Multipart video upload in a large concurrent batch is slow in headless Chromium (see above); no error on the server or the bucket. Worth watching with the real apps.
