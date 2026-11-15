# Ente server setup script — handoff brief

Nov 15, 2026 · @Dmitrii

## What this is

`ente-server/` holds scripts that turn a fresh Debian 12/13 VPS into a backed-up, self-hosted [Ente Photos](https://ente.com) server for the owner and a few family members, some of them in Russia. Priorities, in order: privacy (end-to-end encryption intact), backups that really restore, low cost, and quick moves between hosts.

`ente-server/README.md` is the runbook and the source of truth for how everything works. Read it first.

## Current state

- **Production:** one Debian 13 VPS deployed with `ente-setup.sh deploy`. Photos are in an external S3 bucket. Backups run daily to a second S3 bucket.
- **Monitoring and extras:** Telegram alerts, a Better Stack heartbeat, and a monthly `verify` are on. Registration is locked and the image versions are pinned.
- **Yandex Disk:** support was removed from the repo, but the server still has the old nightly Yandex step and rclone remote. They go when `backup-setup` is re-run; the Yandex token and the files on the Disk are then the owner's to revoke and delete.
- **Add-ons:** the AmneziaWG VPN (`ente-vpn.sh`) is set up. The S3 proxy is installed but off. The Telegram bot is running.
- **Repo:** the server runs commit `0ccd89a`. `master` is ahead of it: Yandex Disk removed, the VPN moved to `ente-vpn.sh`.

## Open items

- A stale `.restore-incomplete` marker can make a later `restore` wipe a live database (review finding 17). Do this one next.
- `update` moves the image pins even when one image fails to pull (16).
- The rclone config is written non-atomically (18).
- The fix that makes `restore` keep downloaded dumps has only been code-reviewed, not run.
- Unattended upgrades don't cover the Amnezia packages.

## Ground rules

- No secrets in the repo, logs or chat. `creds.txt`, `ente-setup.env` and `ente-setup.secrets` stay uncommitted.
- Keep the end-to-end encryption intact: no plaintext photos on the server, and no logging of request bodies.
- Every change comes with tests (see README, "Tests"), run on the server before committing.
- The production server holds real data. Ask before anything destructive, such as a restore or wiping a bucket.
