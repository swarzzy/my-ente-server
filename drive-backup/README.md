# drive-backup

A nightly backup of the bucket that holds your Mountain Duck / Cryptomator vault, to a Backblaze B2 bucket that keeps every
changed and deleted file for 30 days. The server only ever sees encrypted files: the vault password stays on your devices.
It plugs into [opsbot](../opsbot/README.md) for alerts and Telegram commands; it is independent of Ente.

- **Nightly at 04:00** (`drive-backup.timer`): `rclone sync` of the drive bucket to the backup bucket. A file changed or deleted
  on the drive is changed or hidden in the backup, and B2 keeps the old version for the lifecycle's days.
- **The guard:** before syncing, it compares both. If more than `DRIVE_MAX_CHANGE` % (default 10) of the backup's files would
  be overwritten or removed (a wiped drive, or ransomware that re-encrypted it), it stops, changes nothing and alerts you.
  New files do not count. After a look at the drive: `/drive_force` in Telegram (or `drive-backup.sh run --force`).
- **The keys cannot destroy the backup:** the server's drive key only reads; its backup key has no `deleteFiles`, so the worst
  it can do is hide files, which B2 keeps for 30 days (the lifecycle rule, which this key cannot change).
- **Monthly verify** (the 1st, 05:00): every file of the drive is in the backup at the same size, and 5 random ones are the
  same byte for byte.
- **Telegram** (through opsbot): `/drive_sync`, `/drive_force`, a 🗂 line in `/status`; a failed sync, the guard or a failed
  verify sends an alert.

## Buckets and keys

| | The drive (e.g. IDrive e2 `my-drive`) | The backup (B2 `my-drive-backup`) |
| --- | --- | --- |
| Bucket | as Mountain Duck uses it | Private, no Object Lock; Lifecycle Settings: "Keep prior versions for this number of days: 30" |
| Keys | devices: read/write/delete (Mountain Duck); the server: **read only** | the server: `listBuckets,listFiles,readFiles,writeFiles` (no `deleteFiles`) |

The B2 website cannot make a key with exactly these rights; the B2 command line can:
```
pip install b2
b2 account authorize                 # your master key, only here
b2 key create --bucket my-drive-backup drive-backup-server listBuckets,listFiles,readFiles,writeFiles
```
`install` tries what each key can do and warns if the drive key may write or the backup key may delete.

## Install

Needs opsbot with its bot (`../opsbot`; on the Ente server `ente-tg-bot.sh install` sets it up) and rclone (installed if missing).
```
cp drive-backup.env.example drive-backup.env          # fill in
cp drive-backup.secrets.example drive-backup.secrets  # the two keys; chmod 600
sudo ./drive-backup.sh install
```
It writes the keys to `/etc/drive-backup/rclone.conf` (600; the secrets file may be deleted afterwards), tests both buckets,
installs the timers, registers the opsbot plugin `drive` and starts a first sync. The folder must be root's alone (opsbot
checks this script, the config and the keys before each action). `check` (OK/FAIL lines), `uninstall` (the buckets stay).

## Restore

```
sudo ./drive-backup.sh restore '2026-11-20 12:00'          # the whole vault as it was then (the server's time)
sudo ./drive-backup.sh restore '2026-11-20 12:00' d/AB      # one folder of it
```
It goes into a new folder `/var/tmp/drive-restore-<time>/`: the vault's encrypted files. Open it with Cryptomator (copy it to a
PC), or copy it back into the drive bucket with a key that may write (from a PC: `rclone copy`). Inside the vault the folder
names are encrypted too, so restoring the whole vault is the usual way.

## Tests

| Command | Where | What |
| --- | --- | --- |
| `bash tests/test_drive.sh` | anywhere with rclone (local folders stand in for the buckets) | config checks, first sync, the guard (changes and deletions over the limit stop it, new files do not), forcing past it, `/status`, check, verify, the lock, rclone.conf, units, the plugin file |
| `sudo bash tests/drive_e2e.sh` | a server with opsbot's bot, `DRIVE_E2E_ENV`/`DRIVE_E2E_SECRETS` pointing at test buckets | against real buckets (a test folder in each): sync, a change and a deletion kept as versions in B2 and restored as of before, the guard and `/drive_force` through opsbot's real helper, what the keys may do; removes its test folders |
