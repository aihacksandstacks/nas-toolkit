#!/usr/bin/env bash
# Install the swappiness timer on the NAS. Run from the Mac.
# Idempotent: re-running replaces the units and restarts the timer.
set -euo pipefail

NAS_HOST="${NAS_HOST:-nas}"
here="$(cd "$(dirname "$0")" && pwd)"

scp -q "$here/cabana-swappiness.service" "$here/cabana-swappiness.timer" "${NAS_HOST}:/tmp/"
ssh "${NAS_HOST}" 'set -e
sudo install -m 644 /tmp/cabana-swappiness.service /tmp/cabana-swappiness.timer /etc/systemd/system/
rm -f /tmp/cabana-swappiness.service /tmp/cabana-swappiness.timer
sudo systemctl daemon-reload
sudo systemctl enable --now cabana-swappiness.timer
sudo systemctl start cabana-swappiness.service
echo "timer: $(systemctl is-enabled cabana-swappiness.timer) / $(systemctl is-active cabana-swappiness.timer)"
echo "vm.swappiness = $(sysctl -n vm.swappiness)"'
