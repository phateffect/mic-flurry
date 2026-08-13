#!/bin/bash

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "This installer must run as root." >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
source_bundle="${project_dir}/build/MicFlurry HID Probe.app"
source_plist="${project_dir}/packaging/hid-probe/io.phateffect.MicFlurry.hid-probe.plist"
install_dir="/Library/Application Support/MicFlurry"
installed_bundle="${install_dir}/MicFlurry HID Probe.app"
installed_plist="/Library/LaunchDaemons/io.phateffect.MicFlurry.hid-probe.plist"
service_target="system/io.phateffect.MicFlurry.hid-probe"

[[ -d "${source_bundle}" ]] || {
    echo "Build the probe bundle before installing it." >&2
    exit 1
}

codesign --verify --deep --strict --verbose=2 "${source_bundle}"
plutil -lint "${source_plist}"

launchctl bootout "${service_target}" 2>/dev/null || true
rm -rf "${installed_bundle}"
install -d -o root -g wheel -m 755 "${install_dir}"
ditto "${source_bundle}" "${installed_bundle}"
chown -R root:wheel "${installed_bundle}"
find "${installed_bundle}" -type d -exec chmod 755 {} +
find "${installed_bundle}" -type f -exec chmod 644 {} +
chmod 755 "${installed_bundle}/Contents/MacOS/micflurry-hid-probe"
install -o root -g wheel -m 644 "${source_plist}" "${installed_plist}"

codesign --verify --deep --strict --verbose=2 "${installed_bundle}"
plutil -lint "${installed_plist}"
launchctl bootstrap system "${installed_plist}"
launchctl print "${service_target}"
