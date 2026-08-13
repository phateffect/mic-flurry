#!/bin/bash

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Private service installation must run through the macOS administrator prompt." >&2
    exit 1
fi
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <MicFlurry.app>" >&2
    exit 2
fi

source_bundle="$1"
installed_bundle="/Applications/MicFlurry.app"
staging_bundle="/Applications/.MicFlurry.app.installing"
backup_bundle="/Applications/.MicFlurry.app.previous"
installed_plist="/Library/LaunchDaemons/io.phateffect.MicFlurry.hid-helper.plist"
backup_plist="/Library/LaunchDaemons/.io.phateffect.MicFlurry.hid-helper.plist.previous"
service_target="system/io.phateffect.MicFlurry.hid-helper"
had_bundle=0
had_plist=0
committed=0

[[ -d "${source_bundle}" ]] || {
    echo "MicFlurry.app was not found." >&2
    exit 1
}
[[ "$(plutil -extract CFBundleIdentifier raw "${source_bundle}/Contents/Info.plist")" == "io.phateffect.MicFlurry.app" ]]
[[ "$(plutil -extract MicFlurryPrivateDistribution raw "${source_bundle}/Contents/Info.plist")" == "true" ]]
codesign --verify --deep --strict --verbose=2 "${source_bundle}"

rollback() {
    exit_code=$?
    if [[ "${committed}" -eq 1 ]]; then
        launchctl bootout "${service_target}" 2>/dev/null || true
        rm -rf "${installed_bundle}"
        rm -f "${installed_plist}"
        if [[ "${had_bundle}" -eq 1 && -d "${backup_bundle}" ]]; then
            mv "${backup_bundle}" "${installed_bundle}"
        fi
        if [[ "${had_plist}" -eq 1 && -f "${backup_plist}" ]]; then
            mv "${backup_plist}" "${installed_plist}"
            launchctl bootstrap system "${installed_plist}" 2>/dev/null || true
        fi
    fi
    rm -rf "${staging_bundle}"
    exit "${exit_code}"
}
trap rollback ERR

launchctl bootout "${service_target}" 2>/dev/null || true
rm -rf "${staging_bundle}" "${backup_bundle}"
rm -f "${backup_plist}"
ditto "${source_bundle}" "${staging_bundle}"
chown -R root:wheel "${staging_bundle}"
find "${staging_bundle}" -type d -exec chmod 755 {} +
find "${staging_bundle}" -type f -exec chmod 644 {} +
chmod 755 \
    "${staging_bundle}/Contents/MacOS/MicFlurry" \
    "${staging_bundle}/Contents/MacOS/micflurryd" \
    "${staging_bundle}/Contents/MacOS/micflurry-hid-helper"
codesign --verify --deep --strict --verbose=2 "${staging_bundle}"

if [[ -d "${installed_bundle}" ]]; then
    mv "${installed_bundle}" "${backup_bundle}"
    had_bundle=1
fi
if [[ -f "${installed_plist}" ]]; then
    mv "${installed_plist}" "${backup_plist}"
    had_plist=1
fi
mv "${staging_bundle}" "${installed_bundle}"
install -o root -g wheel -m 644 \
    "${installed_bundle}/Contents/Library/LaunchDaemons/io.phateffect.MicFlurry.hid-helper.plist" \
    "${installed_plist}"
committed=1

plutil -lint "${installed_plist}"
codesign --verify --deep --strict --verbose=2 "${installed_bundle}"
launchctl bootstrap system "${installed_plist}"
launchctl print "${service_target}" >/dev/null
committed=0
rm -rf "${backup_bundle}"
rm -f "${backup_plist}"
trap - ERR
