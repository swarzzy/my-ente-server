# Ente server setup script — handoff brief

Nov 8, 2026 · @Dmitrii

## Task and context

Build and test one reusable script that turns a fresh Debian server into a working, backed-up Ente Photos server, so the owner can rebuild it on any VPS provider in an afternoon. You develop it on a VM the owner gives you; the real target is a cheap EU storage VPS.

**Why it's needed**

- The owner self-hosts [Ente Photos](https://ente.com) (open source, end-to-end encrypted) for themselves and a few family members, some of whom are in Russia.
- Priorities, in order: privacy (the server never sees plaintext), backups that really restore, total cost under about $10 a month, and quick moves between hosts. The preferred host is out of stock, and Russian ISPs can start throttling a host's network at any time, forcing a move.
- Clients: Ente Photos for Android and for Windows (desktop app), plus the web app.

**Production target** (the script's defaults must be right for this)

- A KVM VPS in the EU with a public IPv4 (and IPv6), Debian 12 or 13, 1–4 GB RAM and about 1 TB of disk. That's either one big disk, or a small SSD system disk plus a separate 1 TB HDD.
- Offsite backups: a Hetzner Storage Box BX11 (1 TB), reached through an SSH sub-account on port 23, with daily automatic snapshots set in the Hetzner Console.
- A domain the owner controls. Hostnames live under `ente.example.com`, a placeholder throughout this brief.

**Your playground**

- A VM on the owner's PC: Debian 13 (or 12), at least 2 GB RAM, about 30 GB system disk, plus a second virtual disk of about 20 GB standing in for the data disk.
- It sits behind home NAT with no public IP, so Let's Encrypt and phones can't be tested there. See *Test mode*.
- Snapshot the clean VM before the first run and revert to it for every fresh-install test.

The owner also has a step-by-step plan for doing all this by hand. Everything the script needs from it is in this brief.

## Target setup

Caddy is the only service facing the internet, and every container listens on `127.0.0.1` only. The apps upload and download photos directly from the storage hostname, using links that Museum signs, so museum and clients must reach storage at the same public HTTPS address.

| Component | Runs as | Listens on | Public hostname | Data |
| --- | --- | --- | --- | --- |
| Caddy (TLS, reverse proxy) | apt package on the host | :80, :443 | the four below | certificates under `/var/lib/caddy` |
| Museum (Ente API) | container `museum` | 127.0.0.1:8080 | `api.ente.example.com` | `museum.yaml` only |
| Web apps (photos, public albums) | container `web` | 127.0.0.1:3000 and :3002 | `web.` and `albums.ente.example.com` | none |
| Silo (maintained MinIO fork, S3) | container `minio` | 127.0.0.1:3200 | `s3.ente.example.com` | encrypted photo objects: on the data disk if there is one |
| Postgres 15 | container `postgres` | not published | none | DB volume on the system disk |
| socat helper | container `socat` | none | none | disabled: not needed once storage has a public hostname |
| Backup | systemd timer at 03:00 running rclone | outbound SFTP to port 23 | none | Hetzner Storage Box |
| Syncthing (optional) | container | 22000 tcp/udp public; UI 127.0.0.1:8384 | none | `/srv/syncthing` |

- **Paths:** Ente's files go in `/opt/my-ente` (root-owned, mode 700). A data disk mounts at `/srv/ente-data` by UUID with `nofail`.
- **Firewall:** UFW allows 22, 80 and 443. Ports Docker publishes bypass UFW, which is why everything is bound to `127.0.0.1`.
- **DNS:** A/AAAA records for the four hostnames (or one wildcard), with a TTL of 300 so host moves take effect quickly.

## Verified facts

These were checked against Ente's quickstart script and docs, Hetzner's docs and rclone's docs on 8 Nov 2026. The quickstart lives on `main` and can change, so inspect the files it generates and fail loudly if an expected line is missing. Don't silently patch around it.

### Ente quickstart

- Run with `sh -c "$(curl -fsSL https://raw.githubusercontent.com/ente/ente/main/server/quickstart.sh)"` from the parent folder. It needs Docker Compose 2.30 or newer plus `base64`, refuses to run if `./my-ente` exists, and ends with the prompt `Do you want to start Ente? (y/n) [n]`. Answer **n**.
- It writes `my-ente/compose.yaml` and `my-ente/museum.yaml`, with fresh random secrets: the Postgres password, Silo user and password, `key.encryption`, `key.hash` and `jwt.secret`.
- No service in `compose.yaml` has a `restart:` policy. The services:
  - `museum`: image `ghcr.io/ente/server` (untagged). Port line `- 8080:8080 # API`, volumes `./museum.yaml:/museum.yaml:ro` and `./data:/data:ro`. Healthcheck on `/ping` with a 120 s start period; depends on a healthy `postgres`.
  - `socat`: `alpine/socat` with `network_mode: service:museum`. Forwards `localhost:3200` to `minio:3200`.
  - `web`: `ghcr.io/ente/web`. Port lines `- 3000:3000 # Photos web app` and `- 3002:3002 # Public albums`; 3001 and 3003–3010 are commented out. Env `ENTE_API_ORIGIN: http://localhost:8080`.
  - `postgres`: `postgres:15`, user `pguser`, database `ente_db`, no published ports, named volume `postgres-data`.
  - `minio`: image `pgsty/silo`. Port line `- 3200:3200 # MinIO API` (console 3201 commented out), named volume `minio-data:/data`. A Compose `post_start` hook creates the buckets `b2-eu-cen`, `wasabi-eu-central-2-v3` and `scw-eu-fr-v3`.
- `museum.yaml` contains:
  - `db:` host `postgres`, port 5432.
  - `s3:` with `are_local_buckets: true`, `use_path_style_urls: true`, and per bucket: key, secret, `endpoint: localhost:3200`, `region: eu-central-2`, bucket.
  - `apps:` (`public-albums: http://localhost:3002` plus cast, accounts, embed and others), `key:` and `jwt:`.
  - No `internal:` section.

### Ente configuration and tools

- **External or HTTPS storage:** set `s3.are_local_buckets: false` and keep `use_path_style_urls: true`. The endpoint is a bare hostname without a scheme, e.g. `s3.ente.example.com`. Only `b2-eu-cen` holds data while replication stays off.
- **CORS:** Silo, like MinIO, allows all origins by default.
- **Settings:**
  - `apps.public-albums` is the base URL of shared-album links.
  - `internal.admins: [<user_id>]` sets admins. The first user to sign up is admin until this is set.
  - `internal.disable-registration: true` closes sign-ups.
- **Verification codes:** without SMTP, museum logs `Verification code: 123456`. Alternatives:
  - SMTP keys: `smtp.host`, `port`, `username`, `password`, `email`, `sender-name`, `encryption`.
  - Fixed test codes: `internal.hardcoded-ott` (`emails` list of `"addr,code"`, `local-domain-suffix`, `local-domain-value`).
- **Environment overrides:** any key can be set as `ENTE_` + the key path with `.` and `-` turned into `_`, e.g. `ENTE_INTERNAL_DISABLE_REGISTRATION`.
- **Finding a user's ID:** emails are stored encrypted. Use `SELECT user_id, creation_time FROM users ORDER BY creation_time;`; the owner signs up first.
- **Backups:** the photo objects can't be decrypted without the database, which holds the wrapped keys. Back up the database, the bucket, and `museum.yaml` together.
- **CLI (run on the owner's Windows PC, not the server):**
  - Log in: `ente account login --account home-server --app photos --host https://api.ente.example.com`.
  - Lift the storage limit: `ente admin user update-subscription EMAIL --no-limit --account home-server` (100 TB). Admin commands need a login less than 10 minutes old.
  - On headless Linux the CLI needs `ENTE_CLI_SECRETS_PATH`.
- **Apps:** they reach a custom server after 7 taps on the welcome screen. The web app takes its API from `ENTE_API_ORIGIN`.

### Hetzner Storage Box

- **Access:** a sub-account's host is `uXXXXX-subN.your-storagebox.de`. Port 23 offers SSH, SFTP and rsync with OpenSSH-format keys. Install a key with `ssh-copy-id -p 23 -s -i KEY.pub USER@HOST`.
- **Limits:** at most 10 concurrent connections. A sub-account sees only its own folder, and password login can't be switched off.
- **Snapshots:** managed only in the Hetzner Console. `.zfs` is read-only over SFTP, and snapshots use the Box's own space.

### rclone and Debian

- **Creating remotes:** `rclone config create NAME TYPE key=value … --obscure`. The keys used:
  - sftp: `host`, `user`, `port`, `key_file`, `known_hosts_file`, `pass`.
  - s3: `provider=Minio`, `endpoint`, `access_key_id`, `secret_access_key`, `region`.
  - crypt: `remote`, `password`. File names are encrypted by default.
- **`--backup-dir`** must be on the destination's remote and must not overlap the destination. Moved files keep their original modification time, so prune old backup folders by their names, not by file age.
- **SSH:** put settings in drop-ins under `/etc/ssh/sshd_config.d/` and verify them with `sshd -T`, because some provider images lack the `Include` line. The service is called `ssh`.
- **fail2ban:** Debian 12+ logs SSH to the journal, so it needs `backend = systemd` and `python3-systemd`.
- **Automatic reboots:** kernel updates create `/var/run/reboot-required`, and unattended-upgrades can reboot at a set time.

## Script requirements

One bash script, `ente-setup.sh`, driven by a small config file and split into subcommands that are each safe to re-run.

### Shape

- **Language and platform:** bash with `set -euo pipefail`, clean under ShellCheck. Runs as root on Debian 12 or 13.
- **Idempotent:** re-running any subcommand changes nothing that's already right, and never duplicates lines in `museum.yaml`, `fstab`, sshd drop-ins and the like.
- **Logging:** a log in `/var/log/ente-setup.log` with no secrets in it. Clear error messages.
- **Secrets:** the backup passphrase and the Storage Box password are asked for interactively (`read -rs`). They're never written to the config file, shell history or the log.

### Config file `ente-setup.env` (commit an `.example`)

```bash
DOMAIN=ente.example.com     # hostnames api., web., albums. and s3. sit under it
ADMIN_USER=ops
ADMIN_SSH_PUBKEY="ssh-ed25519 AAAA… owner@pc"
MODE=production             # or: test (see Test mode)
DATA_DISK=                  # e.g. /dev/vdb; empty = everything on the system disk
LOW_RAM=auto                # auto = yes below 1.5 GB RAM; or yes / no
BOX_HOST=uXXXXX-sub1.your-storagebox.de
BOX_USER=uXXXXX-sub1
HC_URL=                     # optional healthchecks.io ping URL
FAIL2BAN=yes
SYNCTHING=no
```

### Subcommands

1. **`bootstrap`** — base OS:
   - Update packages. Create `ADMIN_USER` with sudo and the key.
   - SSH drop-in `10-hardening.conf`: `PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers <ADMIN_USER>`, `MaxAuthTries 3`. Apply it only after confirming the user and key exist, check the result with `sshd -T`, and tell the operator to test a second login before closing the session.
   - UFW: allow OpenSSH and 80,443/tcp, then enable.
   - unattended-upgrades, with automatic reboot at 02:00 only when `/var/run/reboot-required` exists.
   - A 2 GB swapfile on the system disk. In low-RAM mode, also zram (`zram-tools`, zstd, 50%).
   - If `FAIL2BAN=yes`: the sshd jail with `backend = systemd`.
   - If `DATA_DISK` is set: refuse if it's the root disk or holds any partition, filesystem or signature (unless `FORCE_FORMAT=yes`). Otherwise create ext4 labelled `ente-data` and mount it at `/srv/ente-data` by UUID with `nofail`.
2. **`install`** — Ente:
   - Install Docker via get.docker.com and check that Compose is 2.30 or newer. Install Caddy from its official apt repository.
   - Run the quickstart in `/opt` non-interactively, answering "n", and skip it if `/opt/my-ente` exists. Edit the generated files (below), write `compose.override.yaml` and the Caddyfile, then run `docker compose up -d`. Wait for museum to be healthy and check `https://api.$DOMAIN/ping`.
   - Finish by printing next steps: save `museum.yaml` in the password manager; sign up the owner first, then family.
3. **`codes`** — print recent verification codes from the museum log.
4. **`lockdown`** — run after all sign-ups:
   - List `user_id` and `creation_time`. Take the oldest as the owner, after confirming with the operator.
   - Add `internal.admins` and `internal.disable-registration: true` once, then restart museum.
5. **`backup-setup`** — install rclone (it needs `unzip`) and create `/root/.ssh/storagebox` (ed25519) if missing, then:
   - Install the key with `ssh-copy-id -p 23 -s`.
   - Create the remotes `ente-s3`, `box` and `box-crypt` (below).
   - Install the backup script and its systemd service and timer: 03:00, `Persistent=true`, service `OOMScoreAdjust=500`.
   - Pass `HC_URL` to the service with an `EnvironmentFile`. Start a first run with `systemctl start --no-block`.
6. **`restore`** — on a fresh server after `bootstrap`, with the same `DOMAIN`:
   - Recreate the remotes using the same passphrase. Copy `box-crypt:` to a temp folder, and put `compose.yaml` and `museum.yaml` into `/opt/my-ente` instead of running the quickstart.
   - Regenerate the override and Caddyfile for this host.
   - Restore the data: `docker compose up -d --wait postgres minio`, then `docker compose cp` the newest dump into the container and `pg_restore --clean --if-exists` it. Then `rclone copy box:objects ente-s3:b2-eu-cen`.
   - Start everything, check `/ping`, and print the DNS change to make.
7. **`check`** — report everything below, with clear OK/FAIL lines:
   - Container health and restart policies; that published ports are on 127.0.0.1 only; key `sshd -T` values; UFW status.
   - The timer's last run and its result, then `rclone check ente-s3:b2-eu-cen box:objects --one-way --size-only --checkers 4`.
   - Disk use (plus a reminder to check Box usage in the Console), OOM kills in `journalctl -k`, and whether `reboot-required` exists.
8. **`update`** — `docker compose pull && docker compose up -d && docker image prune -f`.
9. **`syncthing`** (only if `SYNCTHING=yes`) — the Syncthing container in `/opt/syncthing`: UI on 127.0.0.1:8384, 22000 tcp/udp public, data in `/srv/syncthing` owned by 1000:1000.

### Edits to the quickstart files

Assert each edit afterwards: grep for the expected result and validate YAML with `python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))'`.

- `compose.yaml`:
  - Port lines `- 8080:8080`, `- 3000:3000`, `- 3002:3002` and `- 3200:3200` become `- 127.0.0.1:PORT:PORT`.
  - `ENTE_API_ORIGIN` becomes `https://api.$DOMAIN`.
- `museum.yaml`:
  - `are_local_buckets: true` becomes `false`.
  - Every `endpoint: localhost:3200` becomes `endpoint: s3.$DOMAIN`.
  - `public-albums:` becomes `https://albums.$DOMAIN`.

### `compose.override.yaml` (generated per host)

Check the merged result with `docker compose config`. The same container path (`/data`) replaces the named volume.

```yaml
services:
  museum:
    restart: unless-stopped
    oom_score_adj: -300
    environment:
      GOMEMLIMIT: 150MiB                  # low-RAM mode only
  web:
    restart: unless-stopped
  postgres:
    restart: unless-stopped
    oom_score_adj: -500
    command: postgres -c shared_buffers=64MB -c maintenance_work_mem=32MB   # low-RAM only
  minio:
    restart: unless-stopped
    environment:
      GOMEMLIMIT: 200MiB                  # low-RAM mode only
    volumes:
      - type: bind                        # data-disk mode only
        source: /srv/ente-data/silo
        target: /data
        bind:
          create_host_path: false         # refuse to start if the disk isn't mounted
  socat:
    profiles: ["off"]
```

### Caddyfile (production)

```
api.ente.example.com {
    reverse_proxy http://localhost:8080
}
web.ente.example.com {
    reverse_proxy http://localhost:3000
}
albums.ente.example.com {
    reverse_proxy http://localhost:3002
}
s3.ente.example.com {
    reverse_proxy http://localhost:3200
}
```

### rclone remotes and the backup script

```bash
rclone config create ente-s3 s3 provider=Minio endpoint=http://127.0.0.1:3200 \
  access_key_id=KEY secret_access_key=SECRET region=eu-central-2   # from the b2-eu-cen block
rclone config create box sftp host=$BOX_HOST user=$BOX_USER port=23 \
  key_file=/root/.ssh/storagebox known_hosts_file=/root/.ssh/known_hosts
rclone config create box-crypt crypt remote=box:config password="$PASSPHRASE" --obscure
```

`/usr/local/bin/ente-backup.sh`. In data-disk mode it first exits with an error unless `mountpoint -q /srv/ente-data` succeeds. In low-RAM mode use `--transfers 2 --buffer-size 4M`; with Syncthing, add `rclone sync /srv/syncthing box:syncthing --exclude '/config/**' --checkers 4`.

```bash
#!/usr/bin/env bash
set -euo pipefail
umask 077
cd /opt/my-ente
DUMPS=/var/backups/ente; mkdir -p "$DUMPS"
docker compose exec -T postgres pg_dump -U pguser -d ente_db -Fc > "$DUMPS/ente_db-$(date +%F).dump"
find "$DUMPS" -name 'ente_db-*.dump' -mtime +6 -delete
cp museum.yaml compose.yaml compose.override.yaml "$DUMPS/"
rclone sync "$DUMPS" box-crypt: --checkers 4
rclone sync ente-s3:b2-eu-cen box:objects --size-only --checkers 4 --transfers 4 \
  --max-delete 500 --backup-dir "box:deleted/$(date +%F)"
cutoff=$(date -d '60 days ago' +%F)
for d in $(rclone lsf --dirs-only box:deleted 2>/dev/null || true); do
  if [[ "${d%/}" < "$cutoff" ]]; then rclone purge "box:deleted/${d%/}"; fi
done
if [[ -n "${HC_URL:-}" ]]; then curl -fsS -m 10 --retry 3 "$HC_URL" > /dev/null; fi
```

## Test mode (VM without a public IP)

`MODE=test` runs exactly the production path except for certificates and name resolution, so a pass on the VM means something. It is never the default, and it prints a loud banner.

- **Hostnames:** use `DOMAIN=ente.test`. The `.test` TLD never resolves publicly.
- **Certificates:** add a global `{ local_certs }` block to the Caddyfile so Caddy issues all four certificates from its own local CA.
  - The root certificate is at `/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt` for the apt package.
  - Copy it into `/usr/local/share/ca-certificates/` and run `update-ca-certificates`, so `curl` on the VM trusts it.
- **Names on the VM:** map the four hostnames to `127.0.0.1` in `/etc/hosts`.
- **Museum reaching storage:** museum, inside Docker, must reach `https://s3.ente.test` and trust the local CA. Production needs neither of these.
  - In the override, give museum `extra_hosts: ["s3.ente.test:host-gateway"]`.
  - Mount a CA bundle (system CAs plus Caddy's root) into museum and set `SSL_CERT_FILE` to it.
- **Owner's Windows PC, to use the web app and desktop app:** `install` prints these steps with the VM's IP filled in.
  - Hosts file (`C:\Windows\System32\drivers\etc\hosts`): `VM_IP api.ente.test web.ente.test albums.ente.test s3.ente.test`.
  - Trust the root: `Import-Certificate -FilePath root.crt -CertStoreLocation Cert:\CurrentUser\Root`. Edge, Chrome and the Ente desktop app use the Windows store; Firefox needs its own setting.
  - Give the VM a bridged network adapter, so it has its own LAN IP.
- **Verification codes:** use `codes`, or in test mode only, `internal.hardcoded-ott` with `local-domain-suffix: "@ente.test"`, so test sign-ups can be scripted.
- **Backups:** outbound SSH works from home, so run the real Storage Box once to prove port 23 and the key install, using a separate test sub-account. For repeated runs, point `box` at a local SFTP target on the VM.
- **Phones:** Android apps don't trust user-installed certificates, so phone tests wait for the real server.
  - Optional, only if the owner asks: if their DNS provider has an API (Cloudflare DNS-only, deSEC), a Caddy build with that DNS plugin can get real Let's Encrypt certificates without a public IP, with records pointing at the VM's LAN IP. Then phones on the home Wi-Fi can test too.

## Test plan

Run each block from a clean VM snapshot unless it says otherwise, and record pass/fail with evidence (command output) for every line.

**T1 — Fresh install** (test mode, 2 GB RAM, data disk attached)

- [ ] `bootstrap` and `install` finish without errors. A second SSH login as `ADMIN_USER` works, and `sshd -T` shows `passwordauthentication no` and `permitrootlogin no`.
- [ ] All containers are up and museum is healthy. `docker inspect` shows `unless-stopped` everywhere, and socat isn't running.
- [ ] `ss -tlnp` shows 8080, 3000, 3002 and 3200 only on 127.0.0.1. From the PC, `VM_IP:3200` and `VM_IP:8080` don't answer.
- [ ] On the VM, `curl https://api.ente.test/ping` succeeds without `-k`.
- [ ] The data disk is mounted at `/srv/ente-data` by UUID. Uploaded objects land there; Postgres stays on the system disk.
- [ ] In the PC's browser:
  - Sign up the owner, then a second "family" account.
  - Upload about 50 photos plus one video over 200 MB, which exercises multipart upload.
  - Thumbnails and full-size views load, and an album can be created.
  - A public album link opens in a private window.
- [ ] Optional: the Windows desktop app logs in through `https://api.ente.test`.
- [ ] `lockdown` makes the owner admin, and a new sign-up is refused.
- [ ] The Ente CLI on the PC runs `update-subscription --no-limit` successfully.

**T2 — Idempotency**

- [ ] Re-running `bootstrap`, `install` and `backup-setup` gives no errors. Diffs of every touched config file show no duplicated lines, and containers aren't recreated without reason.

**T3 — Reboots and a missing disk**

- [ ] After `reboot`, everything comes back by itself: disk mounted, Ente reachable, timer scheduled.
- [ ] With the data disk detached, the server still boots (`nofail`).
  - Silo must refuse to start rather than write to the empty mount point: use the long bind syntax with `create_host_path: false`.
  - The backup must refuse to run when `/srv/ente-data` isn't a mountpoint. Nothing on the Box gets deleted.

**T4 — Backups**

- [ ] Once, against a real Storage Box test sub-account:
  - The key is installed and a known\_hosts entry exists.
  - The first run completes, `box:config` shows encrypted names, and the object count in `box:objects` equals the bucket's.
- [ ] The `HC_URL` ping arrives after a good run, and not after a failed one (stop Silo to simulate).
- [ ] Deleting one object from the bucket moves it to `box:deleted/DATE` on the next run. Deleting more than the limit stops the run with an error; test this with a lowered limit.
- [ ] A dummy `box:deleted/2000-01-01` folder is pruned, and today's folder is kept.
- [ ] Files under `/var/backups/ente` are mode 600 or 700, and no secret appears in the log or the journal.

**T5 — Restore, i.e. a host move**

- [ ] On a second clean snapshot, `bootstrap` + `restore` with the same `DOMAIN` brings back every photo and album for both accounts. Public links work and `check` passes.

**T6 — Low RAM**

- [ ] Repeat a short T1 with the VM at 1 GB: upload 200 photos and run a backup with no OOM kills (`journalctl -k | grep -i oom`).
- [ ] Report `docker stats --no-stream` per container (idle and during upload) and `free -m`.

**T7 — Optional parts**

- [ ] `fail2ban-client status sshd` works.
- [ ] With Syncthing on: its UI listens on localhost only, and the backup skips `/config`.

## Deliverables and ground rules

Hand back a small repo plus a test report. Work only inside the VM, and stop to ask instead of guessing.

**Hand back**

1. A folder or git repo `ente-server/` containing `ente-setup.sh`, `ente-setup.env.example`, any template files, and a `README.md` runbook. The runbook covers: fresh production install, test mode, `lockdown` after sign-ups, backups, restore and host moves (including the DNS switch), the monthly `check`, and updates.
2. The T1–T7 checklist with pass/fail and short evidence, the RAM figures from T6, and how long a restore of the test data took.
3. Every deviation from this brief and why, including anything under *Verified facts* that turned out to be wrong.
4. Open issues and risks you couldn't close.

**Ground rules**

- **Stay inside the VM.** Don't change the owner's PC: give them the steps (hosts file, certificate import) to do themselves. Test anything destructive, like formatting a disk, only on the VM's spare disk, and revert to the clean snapshot for fresh-install tests.
- **No secrets anywhere visible.** No real `museum.yaml`, passphrases, keys or tokens go into the repo, logs or chat. Use placeholders.
- **Keep the end-to-end encryption intact.** No plaintext photo copies on the server, no logging of request bodies, and never expose Silo's console (3201) or Postgres.
- **Stay on this stack:** Ente's quickstart with Silo, Caddy, rclone, systemd and UFW. No Cloudflare proxy or tunnels in production (Cloudflare is throttled in Russia), no upstream MinIO image, no extra orchestration. Keep dependencies minimal: bash, coreutils, `python3-yaml` for validation.
- **No provider lock-in.** No hosting-provider APIs; the script must work on any KVM Debian VPS.
- **Fail loudly.** If Ente's quickstart output no longer matches *Verified facts*, stop and report instead of improvising.
- **Ask the owner** for the domain, the Storage Box details, and whether they want Syncthing.

## Open decisions and references

None of these block the script; it takes them as config values.

**Still open for the owner**

- **Hosting provider:** AlphaVPS's 1 TB storage VPS is out of stock as of 8 Nov 2026. The script must not depend on which provider wins.
- **Domain and DNS provider:** plus whether to try real certificates at home through the DNS challenge.
- **Backup target:** a Storage Box, or IDrive e2 with Object Lock if Hetzner refuses the owner's billing address. Only the Box is needed for now.
- **Optional extras:** healthchecks.io for backup alerts; Syncthing on or off.

**References**

- Ente self-hosting: [quickstart](https://ente.com/help/self-hosting/installation/quickstart), [quickstart script](https://raw.githubusercontent.com/ente/ente/main/server/quickstart.sh), [configuration](https://ente.com/help/self-hosting/installation/config), [object storage](https://ente.com/help/self-hosting/administration/object-storage), [reverse proxy](https://ente.com/help/self-hosting/administration/reverse-proxy), [users](https://ente.com/help/self-hosting/administration/users), [backups](https://ente.com/help/self-hosting/administration/backup), [post-install](https://ente.com/help/self-hosting/installation/post-install/)
- Ente tools: [CLI install](https://ente.com/help/cli/install), [CLI admin](https://ente.com/help/cli/admin), [CLI troubleshooting](https://ente.com/help/self-hosting/troubleshooting/cli), [export](https://ente.com/help/photos/migration/export/)
- [Silo, the maintained MinIO fork](https://vonng.com/en/db/long-live-silo/)
- Hetzner Storage Box: [general](https://docs.hetzner.com/storage/storage-box/general/), [SSH keys](https://docs.hetzner.com/storage/storage-box/backup-space-ssh-keys/), [snapshots](https://docs.hetzner.com/storage/storage-box/snapshots/), [rclone and rsync](https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/)
- rclone: [config create](https://rclone.org/commands/rclone_config_create/), [crypt](https://rclone.org/crypt/)
- [Caddy install on Debian](https://caddyserver.com/docs/install#debian-ubuntu-raspbian), [Syncthing untrusted devices](https://docs.syncthing.net/users/untrusted.html)
