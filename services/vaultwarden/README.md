# Vaultwarden on Black-Betty

A self-hosted Bitwarden server. Use the official Bitwarden apps, browser extension and `bw` CLI against it.

- URL: `https://black-betty.tail584407.ts.net:10443`. It's reachable only on the tailnet, through Tailscale Serve. The container binds `127.0.0.1:8812`.
- Data: `/volume1/docker/vaultwarden/data` on the RAID5 pool.
- The admin panel is off because there's no `ADMIN_TOKEN`. Invitations and password hints are off too.

## Why the NAS can't read your passwords

Bitwarden clients encrypt every item with a key derived from your master password before they send it. The server, the NAS disks and the backups hold only ciphertext. The master password never leaves your devices, so root on the NAS can't recover it.

## Setup

```bash
./install-on-nas.sh --up            # deploy, cron, Tailscale Serve; signups open
# create your account in the web vault, then:
./install-on-nas.sh --lock-signups  # SIGNUPS_ALLOWED=false, recreate
```

In each Bitwarden client, choose "Self-hosted" and enter the URL above as the server URL.

Set the clients to lock after a timeout and to ask for the master password on restart. Touch ID unlock is fine, but logging in to the Mac alone must never open the vault.

## Backups

`backup-vaultwarden.sh` runs from root cron at 03:40:
- It takes an online SQLite `.backup`, runs `PRAGMA integrity_check`, and bundles the result with attachments, sends and the JWT keys.
- The bundle goes to `/home/HuggyBearcat/mac-offload/secrets/vaultwarden/`, which keeps the newest 30.
- The Mac's `env-vault` job folds the newest bundle into its age-encrypted archive, which also goes to iCloud Drive. That's the off-site copy.

Also export an encrypted JSON from a Bitwarden client now and then, with a separate password. It's a backup that doesn't depend on this server at all.

## Restore

```bash
docker compose -f /volume1/docker/vaultwarden/docker-compose.yml down
tar -xzf vaultwarden-YYYYmmdd-HHMMSS.tar.gz -C /volume1/docker/vaultwarden/data
chown -R 10010:10010 /volume1/docker/vaultwarden/data
docker compose -f /volume1/docker/vaultwarden/docker-compose.yml up -d
```

## Upgrades

Read the release notes, then bump the tag and digest in `docker-compose.yml`. Get the digest with `docker pull vaultwarden/server:<tag>` and `docker image inspect -f '{{index .RepoDigests 0}}'`. Then run `./install-on-nas.sh --up`.
