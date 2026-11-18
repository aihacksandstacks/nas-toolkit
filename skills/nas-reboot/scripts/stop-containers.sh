#!/usr/bin/env bash
# Save the running container list, then stop every container cleanly.
# This takes cabana prod offline. Andy runs it, not an agent.
# Run from the Mac: stop-containers.sh
#   --dry-run   show what would be saved and stopped, change nothing
set -euo pipefail

NAS_HOST="${NAS_HOST:-nas}"
LIST=/volume1/docker/.pre-reboot-running.txt
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

ssh "${NAS_HOST}" LIST="${LIST}" DRY="${DRY}" 'bash -s' <<'REMOTE'
set -euo pipefail
running=$(docker ps --format '{{.Names}}' | sort)
if [[ "$DRY" == 1 ]]; then
    echo "dry run: would save $(grep -c . <<<"$running") names to ${LIST}:"
    printf '  %s\n' $running
    echo "dry run: would run: sudo docker stop -t 60 <those containers>"
    exit 0
fi
if [[ -z "$running" ]]; then
    echo "nothing is running; leaving ${LIST} as is"
    exit 0
fi
# Saved on volume1 because /tmp is RAM and the reboot wipes it.
printf '%s\n' "$running" | sudo tee "${LIST}" >/dev/null
echo "saved $(wc -l < "${LIST}") names to ${LIST}"
# 60 s lets Postgres (paperless-db and friends) finish a clean shutdown.
sudo docker stop -t 60 $(docker ps -q)
left=$(docker ps -q | wc -l)
echo "still running: ${left}"
[[ "$left" == 0 ]]
REMOTE
