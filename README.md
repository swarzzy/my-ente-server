# my-ente-server

Scripts that turn a fresh Debian VPS into a self-hosted [Ente Photos](https://ente.com) server: photos in an S3 bucket,
nightly encrypted backups to a second bucket, daily health checks and Telegram alerts, plus three optional add-ons
(an S3 proxy, a Telegram bot, an AmneziaWG VPN).

## Layout

```
ente-server/            the deployable folder: copy it whole to the server (e.g. /root/ente-server), owned by root
  README.md             the runbook: install, backups, restore, updates, add-ons, tests
  ente-setup.sh         setup commands: deploy, bootstrap, install, codes, lockdown, backup-setup, restore, update
  ente-ops.sh           running it: check (daily), verify (monthly)
  ente-backup.sh        one backup run (installed by backup-setup, run daily by systemd)
  ente-s3-proxy.sh      add-on: photo traffic through the server
  ente_s3_rewrite.py      its link rewriter
  ente-tg-bot.sh        add-on: Telegram bot
  ente_tg_bot.py          the bot itself
  ente-vpn.sh           add-on: AmneziaWG VPN (independent of Ente)
  ente-setup.env.example       config template     -> ente-setup.env (git-ignored)
  ente-setup.secrets.example   secrets template    -> ente-setup.secrets (git-ignored, chmod 600)
  tests/                test suites; run_all.sh runs them
docs/
  functions-and-tests.md   one-page overview: every function and what must be tested
  handoff-brief.md         current state, open items and ground rules for whoever takes over
```

The scripts in `ente-server/` stay side by side on purpose: they source `ente-setup.sh` from their own folder, and the
units they install run them from there.

## Start here

- New to it: [docs/functions-and-tests.md](docs/functions-and-tests.md), then the runbook [ente-server/README.md](ente-server/README.md).
- Taking over: [docs/handoff-brief.md](docs/handoff-brief.md).
- Installing: the runbook's "Fresh install"; moving servers: its "Moving to a new VPS".
- Testing: `bash ente-server/tests/run_all.sh` (anywhere), `sudo bash tests/run_all.sh --server` from the folder on the server.

Never commit `ente-setup.env`, `ente-setup.secrets` or any key; `.gitignore` covers the usual names.
