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

# Right after boot Docker can lag: on 1.21.1 app_serv restored docker_serv.service
# about a minute in, and the DOCKER-USER rules load with Docker. Give it 3 min.
for _ in $(seq 1 36); do docker info >/dev/null 2>&1 && break; sleep 5; done
docker info >/dev/null 2>&1 || say "docker did not answer within 3 min"

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
# UGOS ugzram.sh resets swappiness to 60 after boot; this timer puts it back.
want "cabana-swappiness.timer" "$(systemctl is-enabled cabana-swappiness.timer 2>/dev/null)" enabled

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
    # A firmware update can recreate a UGOS App Center app under a new container
    # name (1.17 turned jellyfin-app-1 into comugreendockerjellyfin-app-1). The
    # old one shares the compose dir and port, so starting it would collide.
    # Don't start it; tell Andy to drop it from the list.
    replaced=""
    for m in $missing; do
        wd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$m" 2>/dev/null)
        [[ -z "$wd" ]] && continue
        other=$(docker ps --filter "label=com.docker.compose.project.working_dir=$wd" --format '{{.Names}}' | grep -vx "$m" | head -1)
        if [[ -n "$other" ]]; then
            replaced+="$m"$'\n'
            fail+=("$m was replaced by running $other (same compose dir $wd): remove $m from $LIST")
        fi
    done
    missing=$(comm -23 <(sort <<<"$missing") <(sort <<<"$replaced") | grep . || true)
    if [[ -n "$missing" && "$START" == 1 ]]; then
        say "starting: $(tr '\n' ' ' <<<"$missing")"
        xargs -r sudo docker start <<<"$missing" >/dev/null
        sleep 20
        missing=$(comm -23 "$LIST" <(docker ps --format '{{.Names}}' | sort))
        missing=$(comm -23 <(sort <<<"$missing") <(sort <<<"$replaced") | grep . || true)
    fi
    if [[ -n "$missing" ]]; then
        say "not running: $(tr '\n' ' ' <<<"$missing")"
        fail+=("saved containers not running (rerun with --start)")
    else
        n_replaced=$(grep -c . <<<"$replaced" || true)
        say "all $(( $(wc -l < "$LIST") - n_replaced )) saved containers are running${replaced:+ (plus $n_replaced replaced, see FAIL)}"
    fi
else
    say "no saved list at $LIST (stop-containers.sh was not run, or cleanup already happened)"
fi
docker ps --format '{{.Names}}\t{{.Status}}' | grep -vE '\(healthy\)' | sed 's/^/no healthcheck or not healthy yet: /'
docker ps --format '{{.Names}} {{.Status}}' | grep -q 'unhealthy' && fail+=("a container is unhealthy")
# A crash-looping container still counts as "running" to docker ps.
looping=$(docker ps --filter status=restarting --format '{{.Names}}' | tr '\n' ' ')
[[ -n "$looping" ]] && fail+=("restart loop: ${looping}(check docker logs)")

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
