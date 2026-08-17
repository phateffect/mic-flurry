#!/bin/bash

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
    echo "Run this uninstaller as the logged-in user, not with sudo." >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_uninstaller="${script_dir}/friend-uninstall-root.sh"
user_plist="${HOME}/Library/LaunchAgents/io.phateffect.MicFlurry.daemon.plist"
service_target="gui/$(id -u)/io.phateffect.MicFlurry.daemon"

launchctl bootout "${service_target}" 2>/dev/null || true
rm -f "${user_plist}"
osascript - "${root_uninstaller}" <<'APPLESCRIPT'
on run argv
    do shell script quoted form of item 1 of argv with administrator privileges
end run
APPLESCRIPT

echo "Removed MicFlurry services and the audio driver. Recordings and user data were left intact."
