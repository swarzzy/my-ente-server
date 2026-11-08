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

## Pending
T5 restore, T6 low RAM, CLI step, desktop app.
