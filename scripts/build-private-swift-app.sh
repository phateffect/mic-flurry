#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <version> [build-number]" >&2
    exit 2
fi

version="$1"
build_number="${2:-1}"
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must use MAJOR.MINOR.PATCH." >&2
    exit 2
fi
if [[ ! "${build_number}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Build number must be a positive integer." >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
bundle_path="${project_dir}/build/MicFlurry Private.app"
release_dir="${project_dir}/.build/arm64-apple-macosx/release"
template_dir="${project_dir}/packaging/swift-app"

cd "${project_dir}"
env \
    CLANG_MODULE_CACHE_PATH=/tmp/micflurry-swift-clang-module-cache \
    SWIFT_MODULECACHE_PATH=/tmp/micflurry-swift-module-cache \
    swift build -c release --arch arm64 --disable-sandbox \
        -Xswiftc -DMICFLURRY_PRIVATE_DISTRIBUTION \
        --cache-path /tmp/micflurry-swiftpm-cache \
        --config-path /tmp/micflurry-swiftpm-config \
        --security-path /tmp/micflurry-swiftpm-security

rm -rf "${bundle_path}"
install -d -m 755 \
    "${bundle_path}/Contents/MacOS" \
    "${bundle_path}/Contents/Library/LaunchAgents" \
    "${bundle_path}/Contents/Library/LaunchDaemons" \
    "${bundle_path}/Contents/Resources"
install -m 755 "${release_dir}/micflurry-service-host" "${bundle_path}/Contents/MacOS/MicFlurry"
install -m 755 "${release_dir}/micflurryd" "${bundle_path}/Contents/MacOS/micflurryd"
install -m 755 \
    "${release_dir}/micflurry-hid-helper" \
    "${bundle_path}/Contents/MacOS/micflurry-hid-helper"
install -m 644 \
    packaging/private/io.phateffect.MicFlurry.daemon.plist \
    "${bundle_path}/Contents/Library/LaunchAgents/io.phateffect.MicFlurry.daemon.plist"
install -m 644 \
    packaging/private/io.phateffect.MicFlurry.hid-helper.plist \
    "${bundle_path}/Contents/Library/LaunchDaemons/io.phateffect.MicFlurry.hid-helper.plist"
install -m 644 LICENSE "${bundle_path}/Contents/Resources/LICENSE"
sed \
    -e "s/__MICFLURRY_VERSION__/${version}/g" \
    -e "s/__MICFLURRY_BUILD__/${build_number}/g" \
    "${template_dir}/Info.plist" > "${bundle_path}/Contents/Info.plist"

codesign --force --sign - \
    --identifier io.phateffect.MicFlurry.daemon \
    "${bundle_path}/Contents/MacOS/micflurryd"
codesign --force --sign - \
    --identifier io.phateffect.MicFlurry.hid-helper \
    "${bundle_path}/Contents/MacOS/micflurry-hid-helper"

daemon_cdhash="$(codesign -dv --verbose=4 "${bundle_path}/Contents/MacOS/micflurryd" 2>&1 | sed -n 's/^CDHash=//p')"
helper_cdhash="$(codesign -dv --verbose=4 "${bundle_path}/Contents/MacOS/micflurry-hid-helper" 2>&1 | sed -n 's/^CDHash=//p')"
[[ "${daemon_cdhash}" =~ ^[0-9a-fA-F]{40}$ ]]
[[ "${helper_cdhash}" =~ ^[0-9a-fA-F]{40}$ ]]
/usr/libexec/PlistBuddy \
    -c "Add :MicFlurryDaemonCDHash string ${daemon_cdhash}" \
    "${bundle_path}/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Add :MicFlurryHIDHelperCDHash string ${helper_cdhash}" \
    "${bundle_path}/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Add :MicFlurryPrivateDistribution bool true" \
    "${bundle_path}/Contents/Info.plist"

codesign --force --sign - \
    --identifier io.phateffect.MicFlurry.app \
    "${bundle_path}"
codesign --verify --deep --strict --verbose=2 "${bundle_path}"
"${script_dir}/check-private-swift-app.sh" "${bundle_path}"
echo "Built ${bundle_path}"
