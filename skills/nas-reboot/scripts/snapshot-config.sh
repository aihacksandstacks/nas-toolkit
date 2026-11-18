#!/usr/bin/env bash
# Back up Black-Betty's hand-built host config before a firmware update.
# Run from the Mac: snapshot-config.sh
#
# UGOS root is an overlay over the firmware image, and everything we built
# lives in its upper layer: systemd units and drop-ins, cron, sysctl, Docker's
# daemon.json, /opt stacks and their .env files, tunnel credentials. A firmware
# update that resets the overlay takes prod and both tunnels down. This
# tarball is how you put it back.
#
# Writes one root-only tarball under /volume1/backups/pre-reboot/. It doesn't
# stop or change anything else. The tarball holds secrets (.env files, tunnel
# credentials), so it's mode 600 in a 700 dir.
set -euo pipefail

NAS_HOST="${NAS_HOST:-nas}"

ssh "${NAS_HOST}" 'bash -s' <<'REMOTE'
set -euo pipefail
ver=$(grep -oP '^OS_VERSION=\K.*' /etc/os-release || echo unknown)
dir=/volume1/backups/pre-reboot
out="$dir/$(date +%Y%m%dT%H%M%S)-ugos-${ver}.tgz"
work=$(mktemp -d)
trap 'sudo rm -rf "$work"' EXIT

sudo install -d -m 700 "$dir"
sudo crontab -l > "$work/root-crontab.txt"
sudo iptables-save > "$work/iptables-save.txt"
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' > "$work/containers.txt"
docker version --format '{{.Server.Version}}' > "$work/docker-version.txt"
cp /etc/os-release "$work/os-release"

# Only paths that exist; tar fails on missing ones.
paths=()
for p in /etc/systemd/system /etc/sysctl.d /etc/docker/daemon.json /etc/cloudflared \
         /root/.cloudflared /opt /usr/local/bin /etc/sudoers.d /etc/fail2ban/jail.local; do
    sudo test -e "$p" && paths+=("$p")
done

# Config only: files under 2 MB, skipping source trees, build output, and
# media. Repo checkouts are rebuildable from git, archives are backed up
# elsewhere, and /opt/gcp-vm-backup alone is 1.8 GB. -xdev keeps find out of
# the /opt symlinks into /volume1.
sudo find "${paths[@]}" -xdev \
    \( -name node_modules -o -name .git -o -name .next -o -name ios -o -name android \
       -o -name Pods -o -name dist -o -name build -o -name deliverables \
       -o -name .claude -o -name .mypy_cache -o -name __pycache__ -o -name .venv -o -name .remember -o -name quality \
       -o -path /opt/gcp-vm-backup -o -path /opt/@cache \) -prune \
    -o \( -type f -o -type l \) -size -2M -print 2>/dev/null \
    | sed 's#^/##' | sudo tee "$work/files.txt" >/dev/null
sudo timeout 300 tar czf "$out" -C / -T "$work/files.txt" -C "$work" \
    root-crontab.txt iptables-save.txt containers.txt docker-version.txt os-release files.txt
size=$(sudo stat -c %s "$out")
if (( size > 200*1024*1024 )); then
    echo "snapshot is $((size/1024/1024)) MB, over the 200 MB limit; something big slipped in" >&2
    sudo rm -f "$out"; exit 1
fi
sudo chmod 600 "$out"
sudo ls -lh "$out"
sudo tar tzf "$out" | grep -cE '^(etc|opt|root|usr)/' | xargs echo "entries:"
REMOTE
