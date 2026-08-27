#!/usr/bin/env bash
set -euo pipefail

INFO_FILE="${INFO_FILE:-update_info.json}"
DIST_DIR="${DIST_DIR:-dist}"
# GitHub Release assets have a per-file size limit. Keep a little margin.
MAX_ASSET_BYTES="${MAX_ASSET_BYTES:-2000000000}"

if [[ ! -f "$INFO_FILE" ]]; then
  echo "$INFO_FILE not found. Nothing to release."
  exit 0
fi

mkdir -p "$DIST_DIR"

sanitize() {
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^[_\.\-]+//; s/[_\.\-]+$//' | cut -c1-150
}

human_size() {
  local bytes="$1"
  python3 - "$bytes" <<'PY'
import sys
n = int(sys.argv[1])
for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
    if n < 1024 or unit == "TiB":
        print(f"{n:.2f} {unit}" if unit != "B" else f"{int(n)} B")
        break
    n /= 1024
PY
}

download_firmware() {
  local url="$1" output="$2"
  echo "Downloading full OTA firmware..."
  echo "URL: $url"
  echo "Output: $output"
  rm -f "$output.part"
  curl \
    --fail \
    --location \
    --retry 8 \
    --retry-delay 3 \
    --retry-all-errors \
    --connect-timeout 30 \
    --speed-time 120 \
    --speed-limit 1024 \
    --continue-at - \
    --output "$output.part" \
    "$url"
  mv "$output.part" "$output"
}

upload_full_firmware() {
  local tag="$1" firmware_path="$2"
  local size sha sums base
  size="$(stat -c '%s' "$firmware_path")"
  sha="$(sha256sum "$firmware_path" | awk '{print $1}')"
  base="$(basename "$firmware_path")"

  echo "Firmware size: $(human_size "$size")"
  echo "SHA-256: $sha"

  sums="$DIST_DIR/SHA256SUMS-${tag//\//_}.txt"
  printf '%s  %s\n' "$sha" "$base" > "$sums"

  if (( size <= MAX_ASSET_BYTES )); then
    echo "Uploading complete firmware as one GitHub Release asset..."
    gh release upload "$tag" "$firmware_path" --clobber
    gh release upload "$tag" "$sums" --clobber
    echo "Uploaded full firmware: $base"
    return 0
  fi

  echo "Firmware is larger than the single-asset GitHub limit."
  echo "Splitting the REAL firmware bytes into release parts..."

  local part_prefix="$DIST_DIR/${base}.part-"
  rm -f "${part_prefix}"*
  split --bytes=1900M --numeric-suffixes=1 --suffix-length=3 "$firmware_path" "$part_prefix"

  local parts=("${part_prefix}"*)
  if (( ${#parts[@]} == 0 )); then
    echo "Failed to split firmware." >&2
    return 1
  fi

  : > "$sums"
  for part in "${parts[@]}"; do
    sha256sum "$part" >> "$sums"
  done

  echo "Uploading ${#parts[@]} firmware parts..."
  for part in "${parts[@]}"; do
    gh release upload "$tag" "$part" --clobber
  done
  gh release upload "$tag" "$sums" --clobber

  rm -f "$firmware_path"
  echo "Uploaded complete firmware as ${#parts[@]} data parts."
}

configs="$(jq -r 'keys[]' "$INFO_FILE")"
while IFS= read -r config; do
  [[ -n "$config" ]] || continue

  new_update="$(jq -r --arg config "$config" '.[$config].found // false' "$INFO_FILE")"
  if [[ "$new_update" != "true" ]]; then
    echo "No new update for config $config"
    continue
  fi

  update_title="$(jq -r --arg config "$config" '.[$config].title // empty' "$INFO_FILE")"
  update_device="$(jq -r --arg config "$config" '.[$config].device // "Unknown device"' "$INFO_FILE")"
  update_description="$(jq -r --arg config "$config" '.[$config].description // ""' "$INFO_FILE")"
  update_url="$(jq -r --arg config "$config" '.[$config].url // empty' "$INFO_FILE")"
  update_size="$(jq -r --arg config "$config" '.[$config].size // "Unknown"' "$INFO_FILE")"

  if [[ -z "$update_title" || -z "$update_url" ]]; then
    echo "Incomplete update data for $config; skipping release."
    continue
  fi

  safe_device="$(sanitize "$update_device")"
  safe_title="$(sanitize "$update_title")"
  [[ -n "$safe_device" ]] || safe_device="device"
  [[ -n "$safe_title" ]] || safe_title="ota"

  firmware_name="${safe_device}-${safe_title}-FULL-OTA.zip"
  firmware_path="$DIST_DIR/$firmware_name"

  release_notes=$(cat <<EOF2
# $update_device

## Changelog
$update_description

**Reported size:** $update_size

**Official OTA source:** $update_url

## Full firmware
The assets below contain the **actual OTA firmware downloaded from Google's OTA server**.

If the firmware fits GitHub's per-file asset limit, download **$firmware_name** directly.
If it is larger, GitHub cannot store it as one asset, so the exact firmware bytes are uploaded as numbered **.part-001, .part-002, ...** files. Concatenate the parts in numeric order to reconstruct the original ZIP.
EOF2
)

  if gh release view "$update_title" >/dev/null 2>&1; then
    echo "Release '$update_title' already exists. Updating notes."
    gh release edit "$update_title" --notes "$release_notes"
  else
    gh release create "$update_title" --title "$update_title" --notes "$release_notes"
    echo "Created release: $update_title"
  fi

  download_firmware "$update_url" "$firmware_path"
  upload_full_firmware "$update_title" "$firmware_path"

done <<< "$configs"
