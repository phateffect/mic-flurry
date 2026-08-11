#!/usr/bin/env bash

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly VERSION="${1:-0.1.0}"
readonly DRIVER_PATH="${REPO_ROOT}/build/MicFlurry.driver"
readonly PACKAGE_ROOT="${REPO_ROOT}/.build/package-root"
readonly PACKAGE_SCRIPTS="${REPO_ROOT}/packaging/scripts"
readonly DIST_DIR="${REPO_ROOT}/dist"
readonly PACKAGE_NAME="MicFlurry-${VERSION}.pkg"
readonly PACKAGE_PATH="${DIST_DIR}/${PACKAGE_NAME}"
readonly CHECKSUM_NAME="${PACKAGE_NAME}.sha256"
readonly BUNDLE_ID="io.phateffect.MicFlurry"

if [[ ! "${VERSION}" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
  echo "Invalid package version: ${VERSION}" >&2
  exit 1
fi

"${REPO_ROOT}/scripts/build-driver.sh"

rm -rf "${PACKAGE_ROOT}"
mkdir -p "${PACKAGE_ROOT}/Library/Audio/Plug-Ins/HAL" "${DIST_DIR}"
ditto --norsrc --noextattr \
  "${DRIVER_PATH}" \
  "${PACKAGE_ROOT}/Library/Audio/Plug-Ins/HAL/MicFlurry.driver"
codesign --verify --deep --strict \
  "${PACKAGE_ROOT}/Library/Audio/Plug-Ins/HAL/MicFlurry.driver"

pkgbuild \
  --root "${PACKAGE_ROOT}" \
  --scripts "${PACKAGE_SCRIPTS}" \
  --identifier "${BUNDLE_ID}" \
  --version "${VERSION}" \
  --install-location / \
  --ownership recommended \
  "${PACKAGE_PATH}"

(
  cd "${DIST_DIR}"
  shasum -a 256 "${PACKAGE_NAME}" > "${CHECKSUM_NAME}"
  shasum -a 256 -c "${CHECKSUM_NAME}"
)

echo "Built unsigned test installer ${PACKAGE_PATH}"
echo "Wrote checksum ${DIST_DIR}/${CHECKSUM_NAME}"
