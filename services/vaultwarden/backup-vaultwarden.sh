#!/usr/bin/env bash
# Nightly Vaultwarden backup on Black-Betty (root cron, installed by install-on-nas.sh).
#
# Takes an online SQLite backup (safe while the server runs), checks its
# integrity, and bundles it with attachments, sends and the JWT signing keys.
# The bundle lands in the home share so the Mac's env-vault job can fold it
# into its age-encrypted, off-site copy. Vault items inside are already
# end-to-end encrypted by the Bitwarden clients.

set -euo pipefail

DATA=/volume1/docker/vaultwarden/data
DEST=/home/HuggyBearcat/mac-offload/secrets/vaultwarden
OWNER=HuggyBearcat:admin   # same owner:group SMB-created files get
KEEP=30

stamp=$(date +%Y%m%d-%H%M%S)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$DEST"
# Both levels belong to the share user so the Mac can read them over SMB.
chown "$OWNER" "${DEST%/*}" "$DEST" && chmod 700 "${DEST%/*}" "$DEST"

sqlite3 "$DATA/db.sqlite3" ".backup '$work/db.sqlite3'"
check=$(sqlite3 "$work/db.sqlite3" 'PRAGMA integrity_check;')
if [[ "$check" != "ok" ]]; then
    echo "$(date -Is) integrity_check failed: $check" >&2
    exit 1
fi

for item in attachments sends config.json rsa_key.pem rsa_key.pub.pem; do
    [[ -e "$DATA/$item" ]] && cp -a "$DATA/$item" "$work/"
done

out="$DEST/vaultwarden-$stamp.tar.gz"
tar -czf "$out.partial" -C "$work" .
tar -tzf "$out.partial" >/dev/null
mv "$out.partial" "$out"
chown "$OWNER" "$out" && chmod 600 "$out"

# Keep the newest $KEEP bundles.
ls -1t "$DEST"/vaultwarden-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "$(date -Is) ok $(du -h "$out" | cut -f1) $out"
