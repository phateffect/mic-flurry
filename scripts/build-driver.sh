#!/usr/bin/env bash

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly UPSTREAM_DIR="${REPO_ROOT}/upstream/BlackHole"
readonly PATCH_FILE="${REPO_ROOT}/patches/mic-flurry.patch"
readonly WORK_DIR="${REPO_ROOT}/.build/BlackHole"
readonly DERIVED_DATA_DIR="${REPO_ROOT}/.build/DerivedData"
readonly OUTPUT_DIR="${REPO_ROOT}/build"
readonly BUNDLE_ID="io.phateffect.MicFlurry"

if [[ ! -f "${UPSTREAM_DIR}/BlackHole/BlackHole.c" ]]; then
  echo "BlackHole submodule is missing. Run: git submodule update --init --recursive" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required. Install Xcode and select it with xcode-select." >&2
  exit 1
fi

if [[ "$(xcode-select -p 2>/dev/null || true)" == *CommandLineTools ]]; then
  echo "Full Xcode is required; Command Line Tools alone cannot build this driver." >&2
  echo "After installing Xcode, run: sudo xcode-select --switch /Applications/Xcode.app" >&2
  exit 1
fi

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"
git -C "${UPSTREAM_DIR}" archive HEAD | tar -x -C "${WORK_DIR}"
patch --directory="${WORK_DIR}" --strip=1 --forward < "${PATCH_FILE}"

readonly DEFINITIONS='$(inherited) DEBUG=0 kDriver_Name=\"MicFlurry\" kDevice_Name=\"MicFlurry\" kHas_Driver_Name_Format=false kPlugIn_BundleID=\"io.phateffect.MicFlurry\" kPlugIn_Icon=\"\" kManufacturer_Name=\"MicFlurry\" kNumber_Of_Channels=1 kSampleRates=16000,44100,48000 kDevice_HasInput=true kDevice_HasOutput=true'

xcodebuild \
  -quiet \
  -project "${WORK_DIR}/BlackHole.xcodeproj" \
  -scheme BlackHole \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  "CONFIGURATION_BUILD_DIR=${OUTPUT_DIR}" \
  "PRODUCT_BUNDLE_IDENTIFIER=${BUNDLE_ID}" \
  "PRODUCT_NAME=MicFlurry" \
  "GCC_PREPROCESSOR_DEFINITIONS=${DEFINITIONS}" \
  CODE_SIGNING_ALLOWED=NO \
  build

rm -f \
  "${OUTPUT_DIR}/MicFlurry.driver/Contents/Resources/BlackHole.icns" \
  "${OUTPUT_DIR}/MicFlurry.driver/Contents/Resources/CHANGELOG.md" \
  "${OUTPUT_DIR}/MicFlurry.driver/Contents/Resources/README.md" \
  "${OUTPUT_DIR}/MicFlurry.driver/Contents/Resources/VERSION"
cp "${REPO_ROOT}/LICENSE" \
  "${OUTPUT_DIR}/MicFlurry.driver/Contents/Resources/LICENSE"
codesign --force --deep --sign - "${OUTPUT_DIR}/MicFlurry.driver"

echo "Built and ad-hoc signed ${OUTPUT_DIR}/MicFlurry.driver"
