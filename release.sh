#!/usr/bin/env bash
set -euo pipefail

INFO_FILE="${INFO_FILE:-update_info.json}"
DIST_DIR="${DIST_DIR:-dist}"
DOWNLOAD_FIRMWARE_ASSET="${DOWNLOAD_FIRMWARE_ASSET:-false}"

if [[ ! -f "$INFO_FILE" ]]; then
  echo "$INFO_FILE not found. Nothing to release."
  exit 0
fi

mkdir -p "$DIST_DIR"

sanitize() {
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^[_\.\-]+//; s/[_\.\-]+$//' | cut -c1-120
}

make_downloader_bundle() {
  local config="$1" title="$2" device="$3" url="$4" size="$5" description="$6"
  local safe_device safe_title bundle_dir bundle_zip
  safe_device="$(sanitize "$device")"
  safe_title="$(sanitize "$title")"
  [[ -n "$safe_device" ]] || safe_device="device"
  [[ -n "$safe_title" ]] || safe_title="ota"

  bundle_dir="$DIST_DIR/firmware-download-${safe_device}-${safe_title}"
  bundle_zip="${bundle_dir}.zip"
  rm -rf "$bundle_dir" "$bundle_zip"
  mkdir -p "$bundle_dir"

  printf '%s\n' "$url" > "$bundle_dir/firmware-url.txt"
  jq --arg config "$config" '.[$config]' "$INFO_FILE" > "$bundle_dir/update-info.json"

  cat > "$bundle_dir/download.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
URL='$url'
OUT="\${1:-firmware.zip}"
echo "Downloading firmware to \$OUT"
if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 5 --retry-delay 2 -C - -o "\$OUT" "\$URL"
elif command -v wget >/dev/null 2>&1; then
  wget -c -O "\$OUT" "\$URL"
else
  echo "curl or wget is required" >&2
  exit 1
fi
EOF
  chmod +x "$bundle_dir/download.sh"

  cat > "$bundle_dir/download.ps1" <<EOF
\$ErrorActionPreference = 'Stop'
\$Url = '$url'
\$OutFile = if (\$args.Count -gt 0) { \$args[0] } else { 'firmware.zip' }
Write-Host "Downloading firmware to \$OutFile"
Invoke-WebRequest -Uri \$Url -OutFile \$OutFile -UseBasicParsing
EOF

  cat > "$bundle_dir/download.bat" <<EOF
@echo off
set "URL=$url"
set "OUT=%~1"
if "%OUT%"=="" set "OUT=firmware.zip"
echo Downloading firmware to %OUT%
curl.exe -fL --retry 5 -C - -o "%OUT%" "%URL%"
if errorlevel 1 exit /b 1
EOF

  cat > "$bundle_dir/README.txt" <<EOF
Firmware download package
=========================
Device: $device
Update: $title
Reported size: $size

This archive does not contain the firmware image itself.
It contains the official OTA URL and downloader scripts.

Linux/macOS:
  ./download.sh

Windows PowerShell:
  powershell -ExecutionPolicy Bypass -File .\\download.ps1

Windows CMD (Windows 10/11 with curl):
  download.bat

Direct URL:
$url

Description:
$description
EOF

  (cd "$DIST_DIR" && zip -qr "$(basename "$bundle_zip")" "$(basename "$bundle_dir")")
  rm -rf "$bundle_dir"
  printf '%s\n' "$bundle_zip"
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

  asset="$(make_downloader_bundle "$config" "$update_title" "$update_device" "$update_url" "$update_size" "$update_description")"

  release_notes=$(cat <<EOF
# $update_device

## Changelog
$update_description

**Size:** $update_size

**Official OTA URL:** $update_url

### Firmware download archive
Download the attached **$(basename "$asset")** and run the script for your OS. The archive contains the official OTA URL plus Linux/macOS and Windows download scripts.
EOF
)

  if gh release view "$update_title" >/dev/null 2>&1; then
    echo "Release '$update_title' already exists. Ensuring downloader archive is attached."
    gh release upload "$update_title" "$asset" --clobber
  else
    gh release create "$update_title" "$asset" --title "$update_title" --notes "$release_notes"
    echo "Created release: $update_title"
  fi

  if [[ "$DOWNLOAD_FIRMWARE_ASSET" == "true" ]]; then
    firmware_name="$(sanitize "$update_device")-$(sanitize "$update_title").zip"
    firmware_path="$DIST_DIR/$firmware_name"
    echo "Downloading full OTA for release asset..."
    if curl -fL --retry 5 --retry-delay 2 -C - -o "$firmware_path" "$update_url"; then
      if gh release upload "$update_title" "$firmware_path" --clobber; then
        echo "Uploaded full OTA asset: $firmware_name"
      else
        echo "Warning: GitHub rejected the full OTA asset (often because it is too large). Downloader archive is still available." >&2
      fi
    else
      echo "Warning: failed to download full OTA. Downloader archive is still available." >&2
    fi
  fi
done <<< "$configs"
