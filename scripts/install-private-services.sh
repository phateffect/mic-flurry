#!/bin/bash

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
    echo "Run this installer as the logged-in user, not with sudo." >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_bundle="${script_dir}/../MicFlurry.app"
root_installer="${script_dir}/private-install-root.sh"
installed_bundle="/Applications/MicFlurry.app"
user_plist="${HOME}/Library/LaunchAgents/io.phateffect.MicFlurry.daemon.plist"
service_target="gui/$(id -u)/io.phateffect.MicFlurry.daemon"

[[ -d "${source_bundle}" ]] || {
    echo "MicFlurry.app must remain next to the Support directory." >&2
    exit 1
}
codesign --verify --deep --strict --verbose=2 "${source_bundle}"

launchctl bootout "${service_target}" 2>/dev/null || true
osascript - "${root_installer}" "${source_bundle}" <<'APPLESCRIPT'
on run argv
    set rootInstaller to item 1 of argv
    set sourceBundle to item 2 of argv
    do shell script quoted form of rootInstaller & space & quoted form of sourceBundle with administrator privileges
end run
APPLESCRIPT

install -d -m 755 "${HOME}/Library/LaunchAgents"
install -m 644 \
    "${installed_bundle}/Contents/Library/LaunchAgents/io.phateffect.MicFlurry.daemon.plist" \
    "${user_plist}"
plutil -lint "${user_plist}"
launchctl bootstrap "gui/$(id -u)" "${user_plist}"
launchctl print "${service_target}" >/dev/null

echo "MicFlurry private services are installed."
echo "Grant Input Monitoring to /Applications/MicFlurry.app when macOS requests it."
