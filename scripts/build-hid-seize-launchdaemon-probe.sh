#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
bundle_path="${project_dir}/build/MicFlurry HID Probe.app"
executable_path="${project_dir}/target/debug/micflurry-hid-probe"

cd "${project_dir}"
mise run hid-seize-probe-build

rm -rf "${bundle_path}"
install -d -m 755 "${bundle_path}/Contents/MacOS"
install -m 755 "${executable_path}" "${bundle_path}/Contents/MacOS/micflurry-hid-probe"
install -m 644 packaging/hid-probe/Info.plist "${bundle_path}/Contents/Info.plist"

plutil -lint "${bundle_path}/Contents/Info.plist"
codesign --force --deep --sign - \
    --identifier io.phateffect.MicFlurry.hid-probe \
    "${bundle_path}"
codesign --verify --deep --strict --verbose=2 "${bundle_path}"

echo "Built ${bundle_path}"
