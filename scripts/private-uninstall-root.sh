#!/bin/bash

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Private service removal must run through the macOS administrator prompt." >&2
    exit 1
fi

installed_bundle="/Applications/MicFlurry.app"
installed_plist="/Library/LaunchDaemons/io.phateffect.MicFlurry.hid-helper.plist"
service_target="system/io.phateffect.MicFlurry.hid-helper"

launchctl bootout "${service_target}" 2>/dev/null || true
rm -f "${installed_plist}"
rm -rf "${installed_bundle}"
echo "Removed the private MicFlurry app and HID LaunchDaemon."
