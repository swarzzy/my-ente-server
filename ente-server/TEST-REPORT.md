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
- [ ] Ente CLI `update-subscription --no-limit`: not tested (GitHub was returning 503/timeouts when downloading the CLI).

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

## T7
- [x] `fail2ban-client status sshd` works (jail active, backend systemd).
- [x] Syncthing: UI 127.0.0.1:8384 only, 22000 tcp/udp public, `/srv/syncthing` owned by 1000:1000; backup syncs `note.txt`, skips `/config`.

## T6 Low RAM (PARTIAL: VM still has 1.9 GB; a real 1 GB run is pending)
- [x] `LOW_RAM=yes` applied by `install`: museum `GOMEMLIMIT=150MiB`, silo `GOMEMLIMIT=200MiB`, postgres `shared_buffers=64MB`, zram + backup `--transfers 2 --buffer-size 4M`; override merged with `docker compose config`.
- [x] 200 distinct photos (221 MB) uploaded in 24 s; backup afterwards succeeded; `journalctl -k`: 0 OOM messages; `check` all OK.
- `docker stats` (MiB): museum idle 35 / peak 76, postgres 43 / 104, silo 86 / 247, web 13.5 / 13.6. `free -m` at the end: used 993, buff/cache 942, available 912, swap used 423 of 2905.
- Non-container idle floor (RSS): dockerd 60, containerd 54, caddy 53, fail2ban 25, kernel slab ~120 MB.
- [ ] Pending: same run with the VM at 1 GB (needs the owner to resize the VM).

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
T5 restore (needs a clean snapshot revert), T6 at 1 GB, CLI step, desktop app.
