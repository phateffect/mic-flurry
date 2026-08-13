#!/bin/bash

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "This uninstaller must run as root." >&2
    exit 1
fi

service_target="system/io.phateffect.MicFlurry.hid-probe"
installed_bundle="/Library/Application Support/MicFlurry/MicFlurry HID Probe.app"
installed_plist="/Library/LaunchDaemons/io.phateffect.MicFlurry.hid-probe.plist"

launchctl bootout "${service_target}" 2>/dev/null || true
rm -rf "${installed_bundle}"
rm -f "${installed_plist}"
echo "Removed the MicFlurry HID LaunchDaemon probe. Diagnostic logs remain under /var/tmp."
