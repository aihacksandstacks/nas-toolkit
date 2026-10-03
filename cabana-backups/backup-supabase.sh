#!/usr/bin/env bash
# Nightly Supabase logical backup for Cabana prod + sandbox.
#
# Source of truth for connection info:
#   - Passwords/URLs come from /opt/cabana-{prod,sandbox}/.env (no duplication).
#   - Pooler hosts + ports are pinned in /opt/cabana-backups/.env (rewritten to
#     session pooler :5432 so pg_dump works; the app envs hold transaction :6543).
#
# Storage:
#   - pg_dump streams to /volume2/cabana-backups-staging/tmp (NVMe scratch).
#   - On success, atomically moved to /opt/cabana-backups/<env>/ (RAID5 spinners).
#
# Retention: keeps the most recent N dumps per env (default 14), oldest pruned.
# Status: every run rewrites /opt/cabana-backups/status.json with per-env state.

set -euo pipefail

BACKUP_ROOT="/opt/cabana-backups"             # symlink -> /volume1/cabana-backups
STAGING_ROOT="/volume2/cabana-backups-staging/tmp"
LOG_DIR="${BACKUP_ROOT}/logs"
STATUS_FILE="${BACKUP_ROOT}/status.json"
CONFIG_FILE="${BACKUP_ROOT}/.env"
RETENTION_DAYS_DEFAULT=14

mkdir -p "${LOG_DIR}" "${STAGING_ROOT}"

log() { echo "[$(date -Iseconds)] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ -r "${CONFIG_FILE}" ]] || die "Missing ${CONFIG_FILE} — run install-on-nas.sh first"
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

RETENTION_DAYS="${RETENTION_DAYS:-${RETENTION_DAYS_DEFAULT}}"

# Targets: "<env_name>:<source_env_path>:<pooler_host>:<db_user>"
# We rewrite to port 5432 (session pooler) regardless of what the app uses.
target_for() {
    case "$1" in
        prod)
            echo "prod:${SOURCE_PROD_ENV}:${POOLER_PROD}:postgres.nbhezncrdwqzzxmsmchr"
            ;;
        sandbox)
            echo "sandbox:${SOURCE_SANDBOX_ENV}:${POOLER_SANDBOX}:postgres.omjieoavpotzknntmxex"
            ;;
        *) return 1 ;;
    esac
}

# Pull password from source env without leaving it in process args/exports for long.
resolve_password() {
    local env_path="$1"
    # Prod stores a full URL: extract password between : and @ in the user:pass@host segment.
    # Sandbox stores just SUPABASE_DB_PASSWORD.
    local full_url password
    full_url=$(grep -E '^SUPABASE_DATABASE_URL=' "${env_path}" | head -1 | cut -d= -f2- | tr -d '"'"'") || true
    if [[ -n "${full_url}" ]]; then
        # postgresql://user:password@host:port/db?...
        password=$(printf '%s' "${full_url}" | sed -nE 's#^[a-z]+://[^:]+:([^@]+)@.*#\1#p')
    else
        password=$(grep -E '^SUPABASE_DB_PASSWORD=' "${env_path}" | head -1 | cut -d= -f2- | tr -d '"'"'") || true
    fi
    [[ -n "${password}" ]] || return 1
    printf '%s' "${password}"
}

# JSON-safe escape for status.json values.
json_str() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

# Hold per-env results so we can write status.json at the end.
declare -A R_STATUS R_SIZE R_DURATION R_PATH R_ERROR R_FINISHED

backup_one() {
    local target="$1"
    IFS=':' read -r env_name env_path pooler_host db_user <<<"${target}"
    local started size password url out_dir tmp_dir tmp_file final_file
    local rc=0 duration

    out_dir="${BACKUP_ROOT}/${env_name}"
    tmp_dir="${STAGING_ROOT}/${env_name}"
    mkdir -p "${out_dir}" "${tmp_dir}"

    local date_tag
    date_tag="$(date -u +%Y-%m-%d)"
    tmp_file="${tmp_dir}/${date_tag}.dump.partial"
    final_file="${out_dir}/${date_tag}.dump"

    log "[${env_name}] start  pooler=${pooler_host} user=${db_user}"
    started=$(date +%s)

    password=$(resolve_password "${env_path}") || {
        R_STATUS[$env_name]="error"
        R_ERROR[$env_name]="could not resolve password from ${env_path}"
        R_FINISHED[$env_name]="$(date -Iseconds)"
        log "[${env_name}] ${R_ERROR[$env_name]}"
        return 1
    }

    # Session pooler URL (port 5432, sslmode=require). Password goes via PGPASSWORD
    # to dodge URL-encoding pitfalls.
    url="postgresql://${db_user}@${pooler_host}:5432/postgres?sslmode=require"

    # pg_dump:
    #   -Fc       custom format (compressed, supports parallel restore)
    #   -Z 6      moderate compression
    #   --no-owner --no-acl  portable across restore targets
    if docker run --rm -e PGPASSWORD="${password}" -v "${tmp_dir}:${tmp_dir}" postgres:latest pg_dump \
            --dbname="${url}" \
            --format=custom \
            --compress=6 \
            --no-owner --no-acl \
            --file="${tmp_file}" 2>>"${LOG_DIR}/${env_name}.log"; then
        # Atomic move from NVMe staging to spinner. Same filesystem? No (cross-volume) — so cp+rename.
        mv -f "${tmp_file}" "${final_file}.partial" 2>>"${LOG_DIR}/${env_name}.log"
        mv -f "${final_file}.partial" "${final_file}"
        size=$(stat -c '%s' "${final_file}")
        duration=$(( $(date +%s) - started ))
        R_STATUS[$env_name]="ok"
        R_SIZE[$env_name]="${size}"
        R_DURATION[$env_name]="${duration}"
        R_PATH[$env_name]="${final_file}"
        R_FINISHED[$env_name]="$(date -Iseconds)"
        log "[${env_name}] ok     size=${size}B dur=${duration}s path=${final_file}"
    else
        rc=$?
        rm -f "${tmp_file}" "${final_file}.partial" 2>/dev/null || true
        duration=$(( $(date +%s) - started ))
        R_STATUS[$env_name]="error"
        R_DURATION[$env_name]="${duration}"
        R_ERROR[$env_name]="pg_dump exited ${rc} — see ${LOG_DIR}/${env_name}.log"
        R_FINISHED[$env_name]="$(date -Iseconds)"
        log "[${env_name}] FAIL   rc=${rc} dur=${duration}s"
        return "${rc}"
    fi

    # Retention: keep newest ${RETENTION_DAYS} dumps in this env's dir, prune the rest.
    local kept=0 pruned=0 f
    while IFS= read -r f; do
        kept=$((kept + 1))
        if (( kept > RETENTION_DAYS )); then
            rm -f -- "${f}"
            pruned=$((pruned + 1))
            log "[${env_name}] prune  ${f}"
        fi
    done < <(ls -1t "${out_dir}"/*.dump 2>/dev/null || true)
    log "[${env_name}] keep=${kept} prune=${pruned} retention=${RETENTION_DAYS}"
}

write_status() {
    local now overall
    now="$(date -Iseconds)"
    overall="ok"
    for env_name in prod sandbox; do
        [[ "${R_STATUS[$env_name]:-missing}" != "ok" ]] && overall="degraded"
    done
    {
        printf '{\n'
        printf '  "last_run_at": %s,\n' "$(json_str "${now}")"
        printf '  "overall": %s,\n' "$(json_str "${overall}")"
        printf '  "retention_days": %s,\n' "${RETENTION_DAYS}"
        printf '  "backup_root": %s,\n' "$(json_str "${BACKUP_ROOT}")"
        printf '  "environments": {\n'
        local first=1
        for env_name in prod sandbox; do
            [[ -z "${R_STATUS[$env_name]:-}" ]] && continue
            (( first )) || printf ',\n'
            first=0
            printf '    %s: {\n' "$(json_str "${env_name}")"
            printf '      "status": %s,\n' "$(json_str "${R_STATUS[$env_name]}")"
            printf '      "finished_at": %s,\n' "$(json_str "${R_FINISHED[$env_name]:-}")"
            printf '      "duration_sec": %s,\n' "${R_DURATION[$env_name]:-0}"
            printf '      "size_bytes": %s,\n' "${R_SIZE[$env_name]:-0}"
            printf '      "path": %s,\n' "$(json_str "${R_PATH[$env_name]:-}")"
            printf '      "error": %s\n' "$(json_str "${R_ERROR[$env_name]:-}")"
            printf '    }'
        done
        printf '\n  }\n}\n'
    } > "${STATUS_FILE}.tmp"
    mv -f "${STATUS_FILE}.tmp" "${STATUS_FILE}"
}

main() {
    local mode="${1:-ALL}"
    local targets=() rc=0

    case "${mode^^}" in
        PROD)    targets+=("$(target_for prod)") ;;
        SANDBOX) targets+=("$(target_for sandbox)") ;;
        ALL)     targets+=("$(target_for prod)" "$(target_for sandbox)") ;;
        *) die "usage: $0 [PROD|SANDBOX|ALL]" ;;
    esac

    for t in "${targets[@]}"; do
        backup_one "${t}" || rc=$?
    done

    write_status
    log "done overall_rc=${rc}"
    exit "${rc}"
}

main "$@"
