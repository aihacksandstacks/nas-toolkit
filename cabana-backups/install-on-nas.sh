#!/usr/bin/env bash
# Bootstrap / refresh the Cabana Supabase backup setup on the NAS.
#
# Idempotent: safe to re-run after pulling a newer backup-supabase.sh into the
# repo. Creates dirs, seeds /opt/cabana-backups/.env (only if missing), installs
# the root cron entry (only if missing), and copies the latest backup script in.
#
# Run as root on Black-Betty. See docs/runbooks/nas-supabase-backups.md for
# context and recovery procedures.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "must run as root"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_LINK="/opt/cabana-backups"
SPINNER_ROOT="/volume1/cabana-backups"
NVME_STAGING="/volume2/cabana-backups-staging/tmp"
CRON_LINE='30 4 * * * /opt/cabana-backups/scripts/backup-supabase.sh ALL >> /opt/cabana-backups/logs/cron.log 2>&1'
CRON_TAG='# cabana-supabase-nightly'

echo ">> ensuring directory structure on spinners + nvme staging"
mkdir -p "${SPINNER_ROOT}"/{prod,sandbox,logs,scripts} "${NVME_STAGING}"
chmod 750 "${SPINNER_ROOT}" "$(dirname "${NVME_STAGING}")"

echo ">> ensuring /opt/cabana-backups symlink -> ${SPINNER_ROOT}"
if [[ -e "${BACKUP_LINK}" && ! -L "${BACKUP_LINK}" ]]; then
    echo "ERROR: ${BACKUP_LINK} exists and is not a symlink. Move it aside first."
    exit 1
fi
ln -sfn "${SPINNER_ROOT}" "${BACKUP_LINK}"

echo ">> installing backup-supabase.sh"
SRC="${SCRIPT_DIR}/backup-supabase.sh"
DST="${BACKUP_LINK}/scripts/backup-supabase.sh"
if [[ -e "${DST}" ]] && [[ "$(readlink -f "${SRC}")" == "$(readlink -f "${DST}")" ]]; then
    echo "   already in place at ${DST}, fixing perms"
    chmod 0750 "${DST}"
else
    install -m 0750 "${SRC}" "${DST}"
fi

echo ">> seeding ${BACKUP_LINK}/.env (only if missing)"
if [[ ! -f "${BACKUP_LINK}/.env" ]]; then
    cat > "${BACKUP_LINK}/.env" <<'EOF'
# Cabana NAS backup config — sourced by backup-supabase.sh.
# Secrets themselves are NOT stored here; we read passwords from the existing
# app env files at runtime. This file only pins paths + pooler hosts.

# Source env files (passwords resolved at runtime, never written elsewhere)
SOURCE_PROD_ENV=/opt/cabana-prod/.env
SOURCE_SANDBOX_ENV=/opt/cabana-sandbox/.env

# Supabase session-pooler hosts (port 5432 is implied by the script).
# These were resolved 2026-05-21 via the Supabase Management API.
# If Supabase migrates the project to a different cluster, update here.
POOLER_PROD=aws-0-us-east-1.pooler.supabase.com
POOLER_SANDBOX=aws-1-us-east-1.pooler.supabase.com

# Retention: number of daily dumps to keep per env (oldest pruned).
RETENTION_DAYS=14
EOF
    chmod 600 "${BACKUP_LINK}/.env"
    echo "   wrote default ${BACKUP_LINK}/.env"
else
    echo "   ${BACKUP_LINK}/.env already exists, leaving alone"
fi

echo ">> installing root cron entry (idempotent)"
existing=$(crontab -l 2>/dev/null || true)
if printf '%s\n' "${existing}" | grep -q "${CRON_TAG}"; then
    echo "   cron entry already present"
else
    {
        printf '%s\n' "${existing}"
        printf '%s\n' "${CRON_TAG}"
        printf '%s\n' "${CRON_LINE}"
    } | crontab -
    echo "   added: ${CRON_LINE}"
fi

echo
echo "install complete."
echo "  backups dir : ${BACKUP_LINK} -> ${SPINNER_ROOT}"
echo "  staging dir : ${NVME_STAGING}"
echo "  cron        : 04:30 UTC daily (00:30 EDT)"
echo "  next steps  : run a manual test —  ${BACKUP_LINK}/scripts/backup-supabase.sh ALL"
