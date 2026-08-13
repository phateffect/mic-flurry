#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
bundle_path="${1:-${project_dir}/build/MicFlurry Private.app}"
info_plist="${bundle_path}/Contents/Info.plist"
agent_plist="${bundle_path}/Contents/Library/LaunchAgents/io.phateffect.MicFlurry.daemon.plist"
helper_plist="${bundle_path}/Contents/Library/LaunchDaemons/io.phateffect.MicFlurry.hid-helper.plist"

"${script_dir}/check-swift-app.sh" "${bundle_path}"
[[ "$(plutil -extract Program raw "${agent_plist}")" == "/Applications/MicFlurry.app/Contents/MacOS/micflurryd" ]]
[[ "$(plutil -extract Program raw "${helper_plist}")" == "/Applications/MicFlurry.app/Contents/MacOS/micflurry-hid-helper" ]]
[[ "$(plutil -extract MicFlurryPrivateDistribution raw "${info_plist}")" == "true" ]]

daemon_cdhash="$(plutil -extract MicFlurryDaemonCDHash raw "${info_plist}")"
helper_cdhash="$(plutil -extract MicFlurryHIDHelperCDHash raw "${info_plist}")"
actual_daemon_cdhash="$(codesign -dv --verbose=4 "${bundle_path}/Contents/MacOS/micflurryd" 2>&1 | sed -n 's/^CDHash=//p')"
actual_helper_cdhash="$(codesign -dv --verbose=4 "${bundle_path}/Contents/MacOS/micflurry-hid-helper" 2>&1 | sed -n 's/^CDHash=//p')"
[[ "${daemon_cdhash}" == "${actual_daemon_cdhash}" ]]
[[ "${helper_cdhash}" == "${actual_helper_cdhash}" ]]

codesign -dv --verbose=4 "${bundle_path}/Contents/MacOS/micflurryd" 2>&1 | rg -q '^Identifier=io\.phateffect\.MicFlurry\.daemon$'
codesign -dv --verbose=4 "${bundle_path}/Contents/MacOS/micflurry-hid-helper" 2>&1 | rg -q '^Identifier=io\.phateffect\.MicFlurry\.hid-helper$'
codesign --verify -R="identifier \"io.phateffect.MicFlurry.daemon\" and cdhash H\"${daemon_cdhash}\"" "${bundle_path}/Contents/MacOS/micflurryd"
codesign --verify -R="identifier \"io.phateffect.MicFlurry.hid-helper\" and cdhash H\"${helper_cdhash}\"" "${bundle_path}/Contents/MacOS/micflurry-hid-helper"
if strings "${bundle_path}/Contents/MacOS/micflurryd" | rg MICFLURRY_ALLOW_ADHOC_XPC >/dev/null; then
    echo "Private release unexpectedly contains the DEBUG environment bypass." >&2
    exit 1
fi
