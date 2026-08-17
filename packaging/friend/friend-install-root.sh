#!/bin/bash

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Driver installation must run through the macOS administrator prompt." >&2
    exit 1
fi
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <MicFlurry.driver> <MicFlurry.app>" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
driver_source="$1"
app_source="$2"
driver_target="/Library/Audio/Plug-Ins/HAL/MicFlurry.driver"
driver_staging="/Library/Audio/Plug-Ins/HAL/.MicFlurry.driver.installing"
driver_backup="/Library/Audio/Plug-Ins/HAL/.MicFlurry.driver.previous"

[[ -d "${driver_source}" ]] || {
    echo "MicFlurry.driver was not found." >&2
    exit 1
}
[[ "$(plutil -extract CFBundleIdentifier raw "${driver_source}/Contents/Info.plist")" == "io.phateffect.MicFlurry" ]]
codesign --verify --deep --strict --verbose=2 "${driver_source}"

rm -rf "${driver_staging}" "${driver_backup}"
ditto "${driver_source}" "${driver_staging}"
chown -R root:wheel "${driver_staging}"
find "${driver_staging}" -type d -exec chmod 755 {} +
find "${driver_staging}" -type f -exec chmod 644 {} +
chmod 755 "${driver_staging}/Contents/MacOS/MicFlurry"
codesign --verify --deep --strict --verbose=2 "${driver_staging}"

if [[ -d "${driver_target}" ]]; then
    mv "${driver_target}" "${driver_backup}"
fi
mv "${driver_staging}" "${driver_target}"
rm -rf "${driver_backup}"

# launchd restarts coreaudiod immediately; this only forces a fresh driver scan.
killall coreaudiod 2>/dev/null || true

exec "${script_dir}/private-install-root.sh" "${app_source}"
