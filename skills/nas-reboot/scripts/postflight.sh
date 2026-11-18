#!/usr/bin/env bash
# Checks after a reboot or firmware update. Read-only unless you pass --start.
# Run from the Mac:
#   postflight.sh           report only
#   postflight.sh --start   also start containers from the saved list that
#                           didn't come back (Andy runs this one)
# Exit 0 when every check passes and every saved container is running.
# TEST_LIST=/path/on/nas points it at a different saved list (for testing).
set -uo pipefail

NAS_HOST="${NAS_HOST:-nas}"
START=0
[[ "${1:-}" == "--start" ]] && START=1

ssh "${NAS_HOST}" START="${START}" ${TEST_LIST:+LIST="$TEST_LIST"} 'bash -s' <<'REMOTE'
set -uo pipefail
LIST="${LIST:-/volume1/docker/.pre-reboot-running.txt}"
fail=()
say() { printf '%s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }
want() { # name, actual, expected
    say "$(printf '%-22s %s' "$1" "$2")"
    [[ "$2" == "$3" ]] || fail+=("$1 is '$2', expected '$3'")
}

hdr "Host"
say "UGOS: $(grep -oP '^OS_VERSION=\K.*' /etc/os-release)   Docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null)   kernel: $(uname -r)   up: $(uptime -p)"
cat /proc/mdstat
grep -qE '\[[U]*_[U_]*\]' /proc/mdstat && fail+=("an array is degraded")
want "vm.swappiness" "$(sysctl -n vm.swappiness)" 10
want "docker root" "$(docker info --format '{{.DockerRootDir}} {{.Driver}}' 2>/dev/null)" "/volume2/@docker overlay2"

hdr "GODEBUG drop-ins"
for u in cloudflared cloudflared-agent-mesh tailscaled containerd; do
    want "$u" "$(systemctl cat "$u.service" 2>/dev/null | grep -c '^Environment=GODEBUG=$')" 1
done

hdr "Services"
for u in cloudflared cloudflared-agent-mesh tailscaled docker_serv docker agent-mesh-connector agent-mesh-publisher nut-monitor earlyoom; do
    want "$u" "$(systemctl is-active "$u")" active
done

hdr "Root cron and firewall"
cron=$(sudo -n crontab -l 2>/dev/null)
for job in backup-supabase.sh backup_retell.py backup-hub.sh cabana-healthcheck.sh document_exporter; do
    grep -q "$job" <<<"$cron" && say "cron ok: $job" || fail+=("root crontab lost $job")
done
sudo -n iptables -S DOCKER-USER 2>/dev/null | grep -q UG_FORWARD \
    && say "DOCKER-USER chain present" || fail+=("DOCKER-USER iptables rules missing")

hdr "Containers"
if [[ -f "$LIST" ]]; then
    missing=$(comm -23 "$LIST" <(docker ps --format '{{.Names}}' | sort))
    if [[ -n "$missing" && "$START" == 1 ]]; then
        say "starting: $(tr '\n' ' ' <<<"$missing")"
        xargs -r sudo docker start <<<"$missing" >/dev/null
        sleep 20
        missing=$(comm -23 "$LIST" <(docker ps --format '{{.Names}}' | sort))
    fi
    if [[ -n "$missing" ]]; then
        say "not running: $(tr '\n' ' ' <<<"$missing")"
        fail+=("saved containers not running (rerun with --start)")
    else
        say "all $(wc -l < "$LIST") saved containers are running"
    fi
else
    say "no saved list at $LIST (stop-containers.sh was not run, or cleanup already happened)"
fi
docker ps --format '{{.Names}}\t{{.Status}}' | grep -vE '\(healthy\)' | sed 's/^/no healthcheck or not healthy yet: /'
docker ps --format '{{.Names}} {{.Status}}' | grep -q 'unhealthy' && fail+=("a container is unhealthy")

hdr "Cabana"
if sudo -n /opt/ops-checks/cabana-healthcheck.sh >/dev/null 2>&1; then
    say "cabana healthcheck OK"
else
    fail+=("cabana healthcheck failed")
fi

hdr "Memory"
free -h; cat /proc/swaps
ls -la /tmp/.cache/ugreen/ 2>/dev/null | grep '\.img' || say "no firmware images in /tmp/.cache/ugreen"

hdr "Result"
for m in "${fail[@]}"; do say "FAIL: $m"; done
if (( ${#fail[@]} )); then say "=> NOT DONE"; exit 1; fi
say "=> ALL GOOD. Remove $LIST and log the change in the SOP's History table."
exit 0
REMOTE
