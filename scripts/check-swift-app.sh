#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
bundle_path="${1:-${project_dir}/build/MicFlurry.app}"

required_files=(
    "Contents/Info.plist"
    "Contents/MacOS/MicFlurry"
    "Contents/MacOS/micflurryd"
    "Contents/MacOS/micflurry-hid-helper"
    "Contents/Library/LaunchAgents/io.phateffect.MicFlurry.daemon.plist"
    "Contents/Library/LaunchDaemons/io.phateffect.MicFlurry.hid-helper.plist"
    "Contents/Resources/LICENSE"
)
for relative_path in "${required_files[@]}"; do
    if [[ ! -f "${bundle_path}/${relative_path}" ]]; then
        echo "Missing app payload: ${relative_path}" >&2
        exit 1
    fi
done

info_plist="${bundle_path}/Contents/Info.plist"
agent_plist="${bundle_path}/Contents/Library/LaunchAgents/io.phateffect.MicFlurry.daemon.plist"
helper_plist="${bundle_path}/Contents/Library/LaunchDaemons/io.phateffect.MicFlurry.hid-helper.plist"
plutil -lint "${info_plist}" "${agent_plist}" "${helper_plist}"

[[ "$(plutil -extract CFBundleIdentifier raw "${info_plist}")" == "io.phateffect.MicFlurry.app" ]]
[[ "$(plutil -extract Label raw "${agent_plist}")" == "io.phateffect.MicFlurry.daemon" ]]
[[ "$(plutil -extract Label raw "${helper_plist}")" == "io.phateffect.MicFlurry.hid-helper" ]]
[[ "$(/usr/libexec/PlistBuddy -c "Print :MachServices:io.phateffect.MicFlurry.hid-helper" "${helper_plist}")" == "true" ]]

if plutil -extract BundleProgram raw "${agent_plist}" >/dev/null 2>&1; then
    [[ "$(plutil -extract BundleProgram raw "${agent_plist}")" == "Contents/MacOS/micflurryd" ]]
    [[ "$(plutil -extract BundleProgram raw "${helper_plist}")" == "Contents/MacOS/micflurry-hid-helper" ]]
fi

for executable in MicFlurry micflurryd micflurry-hid-helper; do
    file "${bundle_path}/Contents/MacOS/${executable}" | rg -q "Mach-O 64-bit executable arm64"
    vtool -show-build "${bundle_path}/Contents/MacOS/${executable}" | rg -q "minos 15.0"
done

if [[ -d "${bundle_path}/Contents/_CodeSignature" ]]; then
    codesign --verify --deep --strict --verbose=2 "${bundle_path}"
fi
