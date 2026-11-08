# Test report (work in progress)

Environment: Debian 13 VM, 1.9 GB RAM, 40 GB system disk (14 GB root partition), second 20 GB disk `/dev/sdb`,
`MODE=test` (`DOMAIN=ente.test`), no public IP. Backup target: local SFTP on the VM (no Storage Box available).
Browser tests were driven with Playwright/Chromium from the owner's PC (Windows, hosts entry + test root CA trusted).

## T1 Fresh install (data disk attached)
- [x] `bootstrap` + `install` finish. `ops` second login works; `sshd -T`: `passwordauthentication no`, `permitrootlogin no`, `allowusers ops`, `maxauthtries 3`.
- [x] museum healthy; all containers `restart=unless-stopped`; socat not running.
- [x] `ss -tlnp`: 8080/3000/3002/3200 on 127.0.0.1 only; 3201 and 5432 not listening. From the PC, `VM_IP:3200`/`:8080` not tested (UFW allows only 22/80/443).
- [x] `curl https://api.ente.test/ping` OK without `-k` (VM and PC).
- [x] Data disk mounted at `/srv/ente-data` by UUID (`nofail`); objects land there (`/srv/ente-data/silo/b2-eu-cen/...`); Postgres volume stays on `/var/lib/docker` (system disk).
- [x] Web app: owner and family signed up; 50 photos (2.4 MB each) + 1 video (275 MB, 1:00) uploaded; video stored as 20 MB `part.N` objects (multipart); thumbnails render (36 in gallery), full-size viewer opens ("2 / 51"), album created, public link `albums.ente.test/?t=...` opens logged-out with 51 memories and thumbnails.
- [ ] Windows desktop app: not tested.
- [x] `lockdown`: owner (oldest user) set as admin, `disable-registration: true`; third sign-up -> HTTP 403, existing login -> 200; re-run is a no-op.
- [ ] Ente CLI `update-subscription --no-limit`: not tested. Left to the owner (running a downloaded CLI binary was not permitted in the test session). Unverified in the brief: whether `ente account login ... --host` exists in CLI v0.3.0 (the CLI may expect an `endpoint.api` entry in its `config.yaml` instead). The test server's local CA is regenerated on every fresh install, so import the CA of the server under test, or reach the API through `ssh -L 8080:127.0.0.1:8080 ops@<vm>` and point the CLI at `http://localhost:8080`.

## T2 Idempotency
- [x] Re-running `bootstrap`, `install` and `backup-setup`: no diff in any touched file (sha256 of fstab, hosts, sshd drop-in, sudoers, authorized_keys, apt confs, fail2ban, Caddyfile, daemon.json, compose/museum/override, ufw rules), no duplicated lines (1 swapfile line, 1 hosts line), containers not recreated (same Created timestamps).

## T3 Reboot and missing disk
- [x] After reboot: disk mounted, Ente reachable, timer scheduled, `check` all OK.
- [x] Disk unmounted: backup exits 1 ("not mounted"), Box unchanged (3 objects, no `deleted/`); `docker compose up minio` refused: `bind source path does not exist: /srv/ente-data/silo`.
- [x] Bogus UUID in fstab + reboot: VM boots (`nofail`), museum/postgres/web up, silo not running; `check` reports FAIL for minio, port 3200, mount. Recovered after restoring fstab.

## T4 Backups (local SFTP target, not a real Storage Box)
- [x] First run ok; `box:config` names encrypted; bucket and `box:objects` object counts equal (5/5, later 125 files).
- [x] `HC_URL` ping arrives after a good run (1 hit), not after a failed one (silo stopped, hits unchanged).
- [x] Deleted object moved to `box:deleted/DATE/...`; box object count down by one.
- [x] Dummy `box:deleted/2000-01-01` pruned, today's folder kept.
- [x] `--max-delete 500`: run stops with error ("--max-delete threshold reached"). Note: up to 500 objects are moved to `deleted/DATE` before the abort.
- [x] `/var/backups/ente` 700, files 600; `/etc/ente-backup.env`, rclone.conf, key 600. Passphrase and Silo secret: 0 hits in `/var/log/ente-setup.log` and the journal.
- [ ] Real Storage Box (port 23, `ssh-copy-id -s`): not tested (no Box).
- Rclone with Silo down: retries for several minutes, then "not deleting files as there were IO errors" (nothing deleted on the Box).

## T5 Restore (host move)
Clean snapshot (Debian 13, 1.9 GB, blank 20 GB `/dev/sdb`) -> `bootstrap` (`DATA_DISK=/dev/sdb`) -> Box data put back on the local SFTP target (checksum verified) -> `restore` with the same `DOMAIN=ente.test`.
- [x] **Restore time: 167 s** (Docker + Caddy + rclone install included; DB restore ~2 s; 125 objects / 418 MB copied).
- [x] DB after restore: 2 users, 61 files, 2 collections (same as before); `museum.yaml` byte-identical to the original (same sha256), lockdown block (admin + disabled sign-ups) preserved; 125 objects in the bucket (= Box); objects on the data disk; temp dir with decrypted config removed.
- [x] Browser (Playwright, new local CA so certificate errors ignored): owner and family log in with their original passwords; owner sees 51 items (Test album with video tile), family 10 (Family album); full-size viewer loads originals (2400 px); public album link (same token and key) opens logged out: "Join Ente Test album, 51 memories", thumbnails rendered.
- [x] `backup-setup` on the restored host (remotes and key reused, no passphrase prompt), first backup success, `check` all OK.
- Not covered: the restored server had a new Caddy local CA (test mode); in production a real certificate is issued once DNS points at the new IP.

## T6 Low RAM (VM at 899 MB total RAM, `LOW_RAM=auto` -> yes)
Restored host from T5, VM shrunk to 1 GB, `bootstrap` + `install` re-run (zram 450 MB zstd + 2 GB swapfile; museum `GOMEMLIMIT=150MiB`, silo `200MiB`, postgres `shared_buffers=64MB`, backup `--transfers 2 --buffer-size 4M`).
- [x] 200 distinct photos (221 MB) uploaded in 24 s; then a second 230 MB video (multipart, 328 `part.*` objects on the data disk in total); backup after each: success.
- [x] `journalctl -k -b`: **0 OOM messages**; container restart counts all 0; `check` all OK.
- `docker stats` (MiB), idle -> peak during photos + backup: museum 42 -> 81, postgres 49 -> 94, silo 81 -> 187, web 2 -> 6. During the video upload + backup: museum 72, postgres 64, silo 139, web 5.
- System: idle after boot `used` 545 MB; max `used` 708 MB; minimum `available` 191 MB; swap used peaked at 400 MB (zram 223 MB + swapfile 70 MB at the end). `free -m` after the runs: total 899, used 607, buff/cache 336, available 291.
- Idle floor outside the containers (2 GB run, RSS): dockerd 60, containerd 54, caddy 53, fail2ban 25 MB, kernel slab ~120 MB. 1 GB works for this workload but with little headroom (minimum available 191 MB); 2 GB is the comfortable size.
- Note: `LOW_RAM=auto` is decided when a subcommand runs. A host bootstrapped at 2 GB and later shrunk needs `bootstrap` (zram) and `install` (container limits) re-run.

## T7
- [x] `fail2ban-client status sshd` works (jail active, backend systemd).
- [x] Syncthing: UI 127.0.0.1:8384 only, 22000 tcp/udp public, `/srv/syncthing` owned by 1000:1000; backup syncs `note.txt`, skips `/config`.

## Deviations from the brief
1. `ADMIN_USER` gets a `NOPASSWD` sudoers drop-in (key-only user has no password).
2. Caddy proxies to `127.0.0.1:PORT`, not `localhost` (avoids `::1` resolution surprises).
3. Docker `daemon.json` with log rotation (10 MB x 3), so container logs cannot fill a small disk.
4. Backup script: dump written atomically (`.tmp` + `mv`), refused if empty or unreadable by `pg_restore -l`; prune loop only touches `YYYY-MM-DD/` names; low-RAM flags replace `--transfers 4`.
5. New config value `BOX_PORT` (default 23) so backups can be tested against a local SFTP server.
6. `backup-setup` records all host key types with `ssh-keyscan` (when the host has no `known_hosts` entry) and prints fingerprints: with only the key type ssh negotiated, rclone failed with `knownhosts: key mismatch`.
7. `ssh-copy-id` asks for the Box password itself (not `read -rs`); only the backup passphrase is read by the script. Neither is stored in the config, log or history.
8. `install` restarts museum when `museum.yaml` changed while it was running (otherwise a changed `internal:` block was ignored).
9. Quickstart facts held (images, ports, `are_local_buckets`, `endpoint`, `public-albums`, no `internal:`). Differences: `museum.yaml` is created mode 644 (kept; inside the root-only 700 directory) and `apps:` lists more services (photobook, public-locker, public-paste, public-memories, accounts, cast, embed-albums) than the brief names; only `public-albums` is changed.
10. `--max-delete` stops the run but the objects processed before the stop have already been moved to `box:deleted/DATE` (recoverable for 60 days).

## Open issues and risks
- Museum logs request bodies for metadata endpoints (sign-up email, SRP parameters, file sizes, base64 ciphertext; sensitive endpoints are `redacted`). It never contains photo plaintext, but it is more than the brief's "no request-body logging". Upstream behaviour; Docker log rotation bounds retention.
- Real Storage Box (port 23, `ssh-copy-id -s`, 10-connection limit, snapshots) not tested; local SFTP only. Compare the printed host-key fingerprints with Hetzner's.
- Windows desktop app, Ente CLI `update-subscription --no-limit` (GitHub was down), phones and real Let's Encrypt not tested.
- The backup passphrase is passed to `rclone config create` on its command line (briefly visible in `ps` to root only).
- Backup `sync` of `/var/backups/ente` keeps 7 daily DB dumps on the Box; `box:deleted` keeps 60 days. Daily Box snapshots (Hetzner Console) remain the protection against a bad sync.
- Booting with the data disk missing leaves Silo stopped until the disk is back and `docker compose up -d` is run (by design).

## Pending
CLI step (`update-subscription --no-limit`), Windows desktop app, real Storage Box.
