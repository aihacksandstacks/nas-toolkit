#!/usr/bin/env bash
# Install one downloaded UGOS Pro firmware image. Does NOT reboot.
# This writes the inactive boot partition. Andy runs it, not an agent.
# Run from the Mac, after stop-containers.sh:
#   install-firmware.sh <image filename in /volume1/backups/firmware>
# Then, when it prints "Successful":
#   ssh nas sudo systemctl reboot
#
# Why not /usr/sbin/ugospro-upgrade: on 1.13.1 it unpacks the image, deletes
# it, then hands off to the package's own installer, which needs the image and
# fails. So this runs the package's own tool (ugpt) on a copy of the image.
# UGOS keeps the previous system on the other partition with its grub entry
# in /boot/EFI/debian/grub.cfg.bak.
set -euo pipefail

NAS_HOST="${NAS_HOST:-nas}"
img="${1:?usage: install-firmware.sh <image filename>}"
[[ "$img" == */* ]] && { echo "pass the filename only, not a path" >&2; exit 2; }

ssh "${NAS_HOST}" IMG="$img" 'bash -s' <<'REMOTE'
set -euo pipefail
F=/volume1/backups/firmware
D=$F/ugpt-run
[[ -f "$F/$IMG" ]] || { echo "no such image: $F/$IMG" >&2; exit 1; }
running=$(docker ps -q 2>/dev/null | wc -l)
if (( running > 0 )); then
    echo "$running containers are still running. Run stop-containers.sh first." >&2
    docker ps --format '  {{.Names}}' >&2
    exit 1
fi
echo "current: $(grep -oP '^OS_VERSION=\K.*' /etc/os-release)"
sudo rm -rf "$D"; sudo mkdir -p "$D"
sudo cp "$F/$IMG" "$F/hop.img"
sudo tar -xf "$F/hop.img" -C "$D" ./ugpt
set +e
sudo "$D/ugpt" upgrade -V -i "$F/hop.img" -a amd64 2>&1 | tee /tmp/ugpt-install.log
set -e
sudo rm -rf "$D" "$F/hop.img"
if grep -q 'info: Successful' /tmp/ugpt-install.log; then
    echo
    echo "INSTALLED. Reboot with: ssh nas sudo systemctl reboot"
else
    echo
    echo "INSTALL DID NOT REPORT Successful. Do not reboot. Log: /tmp/ugpt-install.log and /var/log/ugreen-upgrade.txt" >&2
    exit 1
fi
REMOTE
