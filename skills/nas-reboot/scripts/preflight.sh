#!/usr/bin/env bash
# Read-only go/no-go check before rebooting or updating Black-Betty.
# Run from the Mac: preflight.sh
# Changes nothing on the NAS.
#
# Exit codes:
#   0  GO: healthy, no client activity, inside a safe window
#   1  BLOCKED: health problem (RAID, UPS, backups, GODEBUG drop-ins). No override.
#   2  WAIT: client activity or a bad window. Only an override from Andy lifts it.
#   3  could not reach the NAS
set -uo pipefail

NAS_HOST="${NAS_HOST:-nas}"
MINUTES="${ACTIVITY_MINUTES:-30}"

if ! ssh -o ConnectTimeout=10 "${NAS_HOST}" true 2>/dev/null; then
    echo "BLOCKED: can't ssh to ${NAS_HOST}"
    exit 3
fi

ssh "${NAS_HOST}" MINUTES="${MINUTES}" 'bash -s' <<'REMOTE'
set -uo pipefail
block=(); wait_=(); info=()

say() { printf '%s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }

hdr "Versions"
say "UGOS: $(grep -oP '^OS_VERSION=\K.*' /etc/os-release)   Docker: $(docker version --format '{{.Server.Version}}')   kernel: $(uname -r)   up: $(uptime -p)"

hdr "Window"
hour=$(date +%H); dow=$(date +%u)
say "now: $(date '+%a %F %T %Z')"
if (( 10#$hour >= 2 && 10#$hour < 5 )); then
    wait_+=("inside the 02:00-05:00 cron window (backups, prune, exports)")
fi

hdr "RAID"
cat /proc/mdstat
if grep -qE 'recovery|resync|reshape|check' /proc/mdstat; then
    block+=("an array is rebuilding or checking")
fi
if grep -E '^\s+[0-9]+ blocks' /proc/mdstat | grep -qE '\[[U]*_[U_]*\]'; then
    block+=("an array is degraded")
fi

hdr "UPS"
ups=$(upsc ups0 2>/dev/null | grep -E 'ups.status|battery.charge:') || ups=""
say "${ups:-no UPS data}"
if [[ -z "$ups" ]]; then
    block+=("no UPS data from upsc ups0")
elif ! grep -q 'ups.status: OL' <<<"$ups"; then
    block+=("UPS is not on line power")
fi

hdr "Last night's backups"
sb=$(sudo -n tail -1 /opt/cabana-backups/logs/cron.log 2>/dev/null)
rt=$(sudo -n tail -1 /opt/cabana-backups/logs/retell.log 2>/dev/null)
say "supabase: ${sb:-missing}"
say "retell:   ${rt:-missing}"
grep -q 'overall_rc=0' <<<"$sb" || block+=("last Supabase backup did not finish with overall_rc=0")
grep -q 'failed 0' <<<"$rt" || block+=("last Retell backup reported failures or is missing")

hdr "GODEBUG drop-ins (2026-10-27 outage)"
for u in cloudflared cloudflared-agent-mesh tailscaled containerd; do
    n=$(systemctl cat "$u.service" 2>/dev/null | grep -c '^Environment=GODEBUG=$')
    say "$(printf '%-24s %s' "$u" "$n")"
    [[ "$n" == 1 ]] || block+=("$u.service is missing its godebug.conf drop-in")
done

hdr "Client activity, last ${MINUTES} min"
# Staff and client paths. Profiled from 72h of real traffic on 2026-11-17.
# Public page fetches, health checks, internal polling, and scanner probes
# (.env, phpinfo, actuator, graphql) are not activity.
human='"path": "/(api/(auth|appointments|forms|customers|chat|client-care|cards|packages/[^"]+/buy)|mcp/|webhook/retell)'
reqs=$(docker logs --since "${MINUTES}m" cabana-api-prod 2>&1 \
    | grep '"logger": "api.request"' \
    | grep -E "$human" \
    | grep -vE '"status": (4|5)[0-9]{2}')
n=$(grep -c . <<<"$reqs" || true)
if [[ "$n" -gt 0 ]]; then
    grep -oE '"path": "[^"]+"' <<<"$reqs" | sed -E 's/[0-9A-Za-z_-]{12,}/:id/g' | sort | uniq -c | sort -rn | head -15
    wait_+=("$n staff/client API requests in the last ${MINUTES} min")
else
    say "no staff or client API requests"
fi
sq=$(docker logs --since "${MINUTES}m" cabana-api-prod 2>&1 | grep -c '"path": "/api/webhooks/square"' || true)
say "square webhooks: ${sq} (bookings or payments happening; check Square)"
(( sq > 0 )) && info+=("${sq} Square webhooks in the last ${MINUTES} min: check Square for live appointments")

smb=$(sudo -n smbstatus -b 2>/dev/null | awk 'NR>4 && NF')
say "SMB sessions:"; say "${smb:-none}"
others=$(awk '$2!="HuggyBearcat"' <<<"$smb" | grep -c . || true)
(( others > 0 )) && wait_+=("$others SMB sessions from other users (Time Machine or family)")

jf=$(ss -tnH state established '( sport = :8096 )' 2>/dev/null | grep -c . || true)
say "Jellyfin connections: $jf"
(( jf > 0 )) && wait_+=("$jf open Jellyfin streams")

hdr "Memory"
free -h; cat /proc/swaps
fw=$(ls /tmp/.cache/ugreen/*.img 2>/dev/null | wc -l)
(( fw > 1 )) && info+=("$fw firmware images in RAM-backed /tmp/.cache/ugreen; delete all but the newest after the update")

hdr "Running containers"
docker ps --format '{{.Names}}' | sort | tr '\n' ' '; echo

hdr "Result"
for m in "${info[@]}";  do say "INFO:    $m"; done
for m in "${wait_[@]}"; do say "WAIT:    $m"; done
for m in "${block[@]}"; do say "BLOCKED: $m"; done
say "Not checked here: Square appointments in the window, and whether Hannah's mesh sessions are mid-task."
if (( ${#block[@]} )); then say "=> BLOCKED"; exit 1; fi
if (( ${#wait_[@]} )); then say "=> WAIT (an override from Andy can lift this)"; exit 2; fi
say "=> GO"
exit 0
REMOTE
