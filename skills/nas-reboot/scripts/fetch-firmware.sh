#!/usr/bin/env bash
# Download one official UGOS Pro firmware image to the NAS disk and check its MD5.
# Changes nothing on the system: it only writes the image to $DIR.
# Run from the Mac:
#   fetch-firmware.sh <download-id> <md5>
#
# Get both values from UGREEN's Download Center (ai.ugreen.com/pages/downloads,
# NAS > DXP4800 Plus > System Firmware). Each row's Download button carries the
# id in its data-cont URL (.../ua/temp/link?appType=firmware&id=<id>&model=7),
# and the MD5 button carries the checksum in data-cont. The page also lists each
# build's minimum version; a target past it needs an intermediate hop.
#
# Images go to /volume1/backups/firmware, not RAM-backed /tmp.
set -euo pipefail

NAS_HOST="${NAS_HOST:-nas}"
MODEL_ID="${MODEL_ID:-7}"   # 7 = DXP4800 Plus on the Download Center
id="${1:?usage: fetch-firmware.sh <download-id> <md5>}"
md5="${2:?usage: fetch-firmware.sh <download-id> <md5>}"
[[ "$id" =~ ^[0-9]+$ ]] || { echo "download id must be numeric" >&2; exit 2; }
[[ "$md5" =~ ^[0-9a-f]{32}$ ]] || { echo "md5 must be 32 hex chars" >&2; exit 2; }

ssh "${NAS_HOST}" ID="$id" MD5="$md5" MODEL_ID="$MODEL_ID" 'bash -s' <<'REMOTE'
set -euo pipefail
DIR=/volume1/backups/firmware
sudo mkdir -p "$DIR"
sudo chown "$(id -u)" "$DIR"
api="https://api-us.ugnas.com/api/system/v1/ua/temp/link?appType=firmware&id=${ID}&model=${MODEL_ID}"
url=$(curl -fsS -m 30 "$api" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["linkData"]["tempUrl"])')
[[ "$url" == https://dl-us.ugreennas.com/* ]] || { echo "unexpected download host: ${url%%\?*}" >&2; exit 1; }
name=$(basename "${url%%\?*}" | sed 's/%2B/+/g')
cd "$DIR"
if [[ -f "$name" ]] && [[ "$(md5sum "$name" | cut -d' ' -f1)" == "$MD5" ]]; then
    echo "already have $DIR/$name (md5 ok)"
    exit 0
fi
echo "downloading $name"
curl -fsS -m 1800 -o "$name.part" "$url"
got=$(md5sum "$name.part" | cut -d' ' -f1)
if [[ "$got" != "$MD5" ]]; then
    rm -f "$name.part"
    echo "MD5 MISMATCH: got $got, expected $MD5; deleted the download" >&2
    exit 1
fi
mv "$name.part" "$name"
echo "ok: $DIR/$name ($(stat -c%s "$name") bytes, md5 $got)"
REMOTE
