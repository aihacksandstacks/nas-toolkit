#!/usr/bin/env bash
# Install or refresh Vaultwarden on Black-Betty.
#
# Run from the Mac:
#   ./install-on-nas.sh                 # copy config, create .env, data dir, cron, Tailscale Serve
#   ./install-on-nas.sh --up            # ...and start or recreate the container
#   ./install-on-nas.sh --lock-signups  # set SIGNUPS_ALLOWED=false and recreate (run after you register)
#
# Never overwrites an existing .env except for the SIGNUPS_ALLOWED line with --lock-signups.

set -euo pipefail

NAS_HOST="${NAS_HOST:-nas}"
REMOTE_DIR=/volume1/docker/vaultwarden
HTTPS_PORT=10443
LOCAL_PORT=8812
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="/tmp/vaultwarden-install.$$"

ACTION=install
case "${1:-}" in
    "") ;;
    --up) ACTION=up ;;
    --lock-signups) ACTION=lock ;;
    *) echo "usage: $0 [--up|--lock-signups]" >&2; exit 1 ;;
esac

ssh "${NAS_HOST}" "mkdir -p ${STAGE}"
scp -q "${SCRIPT_DIR}/docker-compose.yml" "${SCRIPT_DIR}/env.example" \
    "${SCRIPT_DIR}/backup-vaultwarden.sh" "${NAS_HOST}:${STAGE}/"

ssh "${NAS_HOST}" STAGE="${STAGE}" REMOTE_DIR="${REMOTE_DIR}" ACTION="${ACTION}" \
    HTTPS_PORT="${HTTPS_PORT}" LOCAL_PORT="${LOCAL_PORT}" 'bash -s' <<'REMOTE'
set -euo pipefail
mkdir -p "${REMOTE_DIR}/data"
chmod 700 "${REMOTE_DIR}"
chown 10010:10010 "${REMOTE_DIR}/data"
chmod 700 "${REMOTE_DIR}/data"

install -m 0644 "${STAGE}/docker-compose.yml" "${REMOTE_DIR}/docker-compose.yml"
install -m 0755 "${STAGE}/backup-vaultwarden.sh" "${REMOTE_DIR}/backup-vaultwarden.sh"

if [[ ! -f "${REMOTE_DIR}/.env" ]]; then
    install -m 0600 "${STAGE}/env.example" "${REMOTE_DIR}/.env"
    echo "created ${REMOTE_DIR}/.env (signups open until --lock-signups)"
else
    echo "${REMOTE_DIR}/.env already exists, left alone"
fi
rm -rf "${STAGE}"

# Nightly backup at 03:40, after the Sunday docker prune and before cabana's 04:30 dump.
cron_line="40 3 * * * ${REMOTE_DIR}/backup-vaultwarden.sh >> /var/log/vaultwarden-backup.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "backup-vaultwarden.sh"; then
    echo "backup cron entry already present"
else
    { crontab -l 2>/dev/null; echo "# nas-toolkit vaultwarden nightly backup"; echo "${cron_line}"; } | crontab -
    echo "installed backup cron entry (03:40 daily)"
fi

# HTTPS on the tailnet only. GODEBUG from the login shell crashes the tailscale CLI.
if env -u GODEBUG tailscale serve status 2>/dev/null | grep -q ":${HTTPS_PORT} "; then
    echo "tailscale serve on :${HTTPS_PORT} already configured"
else
    env -u GODEBUG tailscale serve --bg --https="${HTTPS_PORT}" "http://127.0.0.1:${LOCAL_PORT}" >/dev/null
    echo "tailscale serve: https :${HTTPS_PORT} -> 127.0.0.1:${LOCAL_PORT}"
fi

cd "${REMOTE_DIR}"
docker compose config -q && echo "compose file is valid"

if [[ "${ACTION}" == lock ]]; then
    sed -i 's/^SIGNUPS_ALLOWED=.*/SIGNUPS_ALLOWED=false/' .env
    grep -q '^SIGNUPS_ALLOWED=false$' .env
    echo "signups locked"
    ACTION=up
fi

if [[ "${ACTION}" == up ]]; then
    docker compose up -d --force-recreate
    for _ in $(seq 1 30); do
        state=$(docker inspect -f '{{.State.Health.Status}}' vaultwarden 2>/dev/null || echo starting)
        [[ "$state" == healthy ]] && break
        sleep 2
    done
    echo "container health: ${state}"
    echo "signups: $(grep '^SIGNUPS_ALLOWED=' .env | cut -d= -f2)"
fi
REMOTE
