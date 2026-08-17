#!/bin/bash

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
    echo "Run this installer as the logged-in user, not with sudo." >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
distribution_dir="$(cd "${script_dir}/.." && pwd)"
source_bundle="${distribution_dir}/MicFlurry.app"
driver_bundle="${script_dir}/MicFlurry.driver"
root_installer="${script_dir}/friend-install-root.sh"
installed_bundle="/Applications/MicFlurry.app"
user_plist="${HOME}/Library/LaunchAgents/io.phateffect.MicFlurry.daemon.plist"
service_target="gui/$(id -u)/io.phateffect.MicFlurry.daemon"

[[ -d "${source_bundle}" ]] || {
    echo "MicFlurry.app must remain next to the Support directory." >&2
    exit 1
}
[[ -d "${driver_bundle}" ]] || {
    echo "MicFlurry.driver must remain inside the Support directory." >&2
    exit 1
}
codesign --verify --deep --strict --verbose=2 "${source_bundle}"
codesign --verify --deep --strict --verbose=2 "${driver_bundle}"

launchctl bootout "${service_target}" 2>/dev/null || true
osascript - "${root_installer}" "${driver_bundle}" "${source_bundle}" <<'APPLESCRIPT'
on run argv
    set rootInstaller to item 1 of argv
    set driverBundle to item 2 of argv
    set sourceBundle to item 3 of argv
    do shell script quoted form of rootInstaller & space & quoted form of driverBundle & space & quoted form of sourceBundle with administrator privileges
end run
APPLESCRIPT

install -d -m 755 "${HOME}/Library/LaunchAgents"
install -m 644 \
    "${installed_bundle}/Contents/Library/LaunchAgents/io.phateffect.MicFlurry.daemon.plist" \
    "${user_plist}"
plutil -lint "${user_plist}"
launchctl bootstrap "gui/$(id -u)" "${user_plist}"
launchctl print "${service_target}" >/dev/null

echo "MicFlurry is installed: audio driver, per-user daemon, and HID helper."
echo "Grant Input Monitoring to /Applications/MicFlurry.app when macOS requests it."
