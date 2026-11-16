# Ente server setup scripts — handoff brief

Nov 16, 2026 · @Dmitrii

## What this is

`ente-server/` holds scripts that turn a fresh Debian 12/13 VPS into a backed-up, self-hosted [Ente Photos](https://ente.com) server for the owner and a few family members, some of them in Russia. Priorities, in order: privacy (end-to-end encryption intact), backups that really restore, low cost, and quick moves between hosts.

- `ente-setup.sh` builds the server: `deploy` (= `bootstrap` + `install` or `restore` + `backup-setup`), `codes`, `lockdown`, `update`.
- `ente-ops.sh` runs it: `check` (daily; every FAIL is something nothing else reports) and `verify` (monthly; also reports the backup bucket's growth).
- Add-ons: `ente-s3-proxy.sh`, `ente-tg-bot.sh`, `ente-vpn.sh`.

`ente-server/README.md` is the runbook and the source of truth for how everything works. Read it first.

## Current state

- **Production:** one Debian 13 VPS, reinstalled and deployed fresh on Nov 15 (`RESTORE=no`; both buckets were empty). It runs the scripts as of the latest commit on `master`.
- **Working and tested on the server:** Ente, daily backups to the second bucket (copy only: nothing is ever deleted there; the owner cleans it up by hand) plus the encrypted config copy in the photo bucket, Telegram alerts, the Better Stack heartbeat, the monthly `verify`, the Telegram bot, the S3 proxy (installed, off) and the AmneziaWG VPN. All test suites pass there, including the browser end-to-end test.
- **Waiting on the owner:** sign up at `https://web.<domain>`, then family, then `sudo ./ente-setup.sh lockdown`. Fetch the VPN client config `/root/awg-client.conf`, import it, then `shred -u` it on the server.

## Open items

- The backup never deletes in the backup bucket (B2), but the server's key still could: swap it for a key without `deleteFiles`. The bucket still has the lifecycle rule `ente-setup-keep-deleted` (old versions expire after 60 days) from the earlier design; harmless, remove it if unwanted.
- Do the yearly read-only restore drill from the PC (README, "Moving to a new VPS"): it proves the offline copies of the keys and `BACKUP_PASSPHRASE` open the backup. A full `restore` needs the same domain, so it is tested for real only by tests and the next server move.
- `restore` does not fall back to the other bucket when the newer dump is unreadable.
- Add an HTTP monitor on `https://api.<domain>/ping`. The heartbeat only notices a down server after a missed backup, about a day later.
- `ente-setup.env` is sourced as root. Parsing it as plain `KEY=value` would be safer and would turn quoting mistakes into clear errors.
- The installers (get.docker.com, Ente's quickstart from `main`) are not pinned.
- There is no strength check on `BACKUP_PASSPHRASE`. The photo bucket's config copy allows offline guessing.
- Unattended upgrades do not cover the Amnezia packages.
- There is no CI and no shellcheck. The tests run by hand on the server.
- Optional simplifications not done: `apply_edits` checks each edit three ways, the `sshd -T` count plus the Ubuntu socket branch, and `lockdown`'s y/N prompt.

## Ground rules

- No secrets in the repo, logs or chat. `ente-setup.env` and `ente-setup.secrets` stay uncommitted.
- Keep the end-to-end encryption intact: no plaintext photos on the server, and no logging of request bodies.
- Every change comes with tests (see README, "Tests"), run on the server before committing.
- The production server holds real data. Ask before anything destructive, such as a restore or wiping a bucket.
