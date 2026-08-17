#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 <MAJOR.MINOR.PATCH>" >&2
  exit 2
fi

version="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
staging_dir="${project_dir}/dist/MicFlurry-friend-${version}"
archive_path="${staging_dir}.zip"

cd "${project_dir}"
"${script_dir}/build-driver.sh"
"${script_dir}/build-private-swift-app.sh" "${version}"

rm -rf "${staging_dir}"
rm -f "${archive_path}" "${archive_path}.sha256"
install -d -m 755 "${staging_dir}/Support"
ditto "${project_dir}/build/MicFlurry Private.app" "${staging_dir}/MicFlurry.app"
ditto --norsrc --noextattr \
  "${project_dir}/build/MicFlurry.driver" \
  "${staging_dir}/Support/MicFlurry.driver"
install -m 755 "packaging/friend/Install MicFlurry.command" "${staging_dir}/Install MicFlurry.command"
install -m 755 "packaging/friend/Uninstall MicFlurry.command" "${staging_dir}/Uninstall MicFlurry.command"
install -m 755 packaging/friend/friend-install.sh "${staging_dir}/Support/friend-install.sh"
install -m 755 packaging/friend/friend-install-root.sh "${staging_dir}/Support/friend-install-root.sh"
install -m 755 packaging/friend/friend-uninstall.sh "${staging_dir}/Support/friend-uninstall.sh"
install -m 755 packaging/friend/friend-uninstall-root.sh "${staging_dir}/Support/friend-uninstall-root.sh"
install -m 755 scripts/private-install-root.sh "${staging_dir}/Support/private-install-root.sh"
install -m 755 scripts/private-uninstall-root.sh "${staging_dir}/Support/private-uninstall-root.sh"
install -m 644 packaging/friend/README.md "${staging_dir}/README.md"
install -m 644 packaging/private/SOURCE.md "${staging_dir}/SOURCE.md"
install -d -m 755 "${staging_dir}/Source"
rsync -a \
  --exclude '/.git/' \
  --exclude '/.build/' \
  --exclude '/build/' \
  --exclude '/dist/' \
  --exclude '/target/' \
  --exclude '/.swiftpm/' \
  --exclude 'DerivedData/' \
  --exclude '.DS_Store' \
  --exclude '*.db' \
  --exclude '*.db-shm' \
  --exclude '*.db-wal' \
  --exclude '*.wav' \
  "${project_dir}/" "${staging_dir}/Source/"

[[ -f "${staging_dir}/Source/LICENSE" ]]
[[ -f "${staging_dir}/Source/Package.swift" ]]
[[ -f "${staging_dir}/Source/patches/mic-flurry.patch" ]]
[[ -f "${staging_dir}/Source/upstream/BlackHole/LICENSE" ]]

codesign --verify --deep --strict --verbose=2 "${staging_dir}/MicFlurry.app"
codesign --verify --deep --strict --verbose=2 "${staging_dir}/Support/MicFlurry.driver"
ditto -c -k --norsrc --noextattr --noacl --keepParent "${staging_dir}" "${archive_path}"
cd "${project_dir}/dist"
shasum -a 256 "$(basename "${archive_path}")" > "$(basename "${archive_path}").sha256"
echo "Built ${archive_path}"
