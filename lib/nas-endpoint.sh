#!/bin/zsh
# nas-endpoint.sh - pick the best path to the NAS and inspect the current mount.
#
# Sourced by nas-mount and nas-health after config.sh. Preference order:
#   1. LAN  ($NAS_LAN_IP)  when SMB answers there AND Keychain has credentials
#   2. Tailscale ($NAS_TS_IP, falls back to $NAS_IP)
# Every network probe is bounded so a dead path never hangs launchd.

NAS_TS_IP="${NAS_TS_IP:-$NAS_IP}"
NETFS_HELPER="${TOOLKIT_ROOT:-${SCRIPT_DIR:h}}/bin/nas-netfs-mount"

# Run a command with a hard timeout (macOS has no coreutils `timeout`).
with_timeout() {
    local secs=$1; shift
    perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
}

# SMB port reachable within 2 seconds?
smb_port_open() {
    [ -n "$1" ] && nc -z -G 2 "$1" 445 >/dev/null 2>&1
}

# Keychain has a saved password for user@host (attributes only, no secret read).
has_keychain_creds() {
    security find-internet-password -s "$1" -a "$NAS_USER" >/dev/null 2>&1
}

lan_ready() {
    [ -n "$NAS_LAN_IP" ] && smb_port_open "$NAS_LAN_IP" && has_keychain_creds "$NAS_LAN_IP"
}

# Print the host to mount from, or nothing if the NAS is unreachable.
pick_endpoint() {
    if lan_ready; then
        echo "$NAS_LAN_IP"
    elif smb_port_open "$NAS_TS_IP"; then
        echo "$NAS_TS_IP"
    fi
}

endpoint_label() {
    case "$1" in
        "$NAS_LAN_IP") echo "LAN" ;;
        "$NAS_TS_IP")  echo "Tailscale" ;;
        *)             echo "$1" ;;
    esac
}

# Host the share is currently mounted from (empty if not mounted).
mounted_host() {
    mount | awk -v mp="$NAS_MOUNT_POINT" '$2 == "on" && $3 == mp && $1 ~ /^\/\// {
        sub(/^\/\/[^@]*@/, "", $1); sub(/\/.*/, "", $1); print $1; exit }'
}

is_mounted() {
    [ -n "$(mounted_host)" ]
}

# A mount whose server vanished hangs on any access, so probe with timeouts.
# Avoid reading files on the share: launchd jobs lack the "Network Volumes"
# privacy permission, so `ls` fails there even on a healthy mount. statfs (df)
# is allowed and still round-trips to the server, so it detects a dead mount.
mount_alive() {
    local host=$(mounted_host)
    [ -n "$host" ] && smb_port_open "$host" &&
        with_timeout 6 /bin/df "$NAS_MOUNT_POINT" >/dev/null 2>&1
}

# Unmount: gently (refuses if files are open) or forced (for dead mounts).
unmount_share() {
    if [ "$1" = "force" ]; then
        with_timeout 15 diskutil unmount force "$NAS_MOUNT_POINT" >/dev/null 2>&1 ||
            with_timeout 15 umount -f "$NAS_MOUNT_POINT" >/dev/null 2>&1
    else
        with_timeout 15 diskutil unmount "$NAS_MOUNT_POINT" >/dev/null 2>&1
    fi
    ! is_mounted
}

# Mount from a host with NetFS (Keychain creds, never any UI).
mount_from() {
    local host=$1 out
    out=$(with_timeout 30 "$NETFS_HELPER" "smb://${NAS_USER}@${host}/${NAS_SMB_SHARE}" 2>&1)
    if [ "$(mounted_host)" = "$host" ]; then
        return 0
    fi
    # NetFS picks /Volumes/<share>-1 if a stale folder blocks the usual path,
    # which would break the cache symlinks. Report it rather than hide it.
    [ -n "$out" ] && echo "$out"
    return 1
}
