#!/usr/bin/env bash

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly UPSTREAM_DIR="${REPO_ROOT}/upstream/BlackHole"
readonly PATCH_FILE="${REPO_ROOT}/patches/mic-flurry.patch"
readonly TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

if [[ ! -f "${UPSTREAM_DIR}/BlackHole/BlackHole.c" ]]; then
  echo "BlackHole submodule is missing. Run: git submodule update --init --recursive" >&2
  exit 1
fi

git -C "${UPSTREAM_DIR}" archive HEAD | tar -x -C "${TEMP_DIR}"
patch --directory="${TEMP_DIR}" --strip=1 --forward < "${PATCH_FILE}"

grep -q 'kAudioDeviceTransportTypeUSB' "${TEMP_DIR}/BlackHole/BlackHole.c"
grep -q '67a7bfee-45f5-4ea8-91f0-bf42528402d7' "${TEMP_DIR}/BlackHole/BlackHole.plist"
grep -q 'kObjectID_Stream_Output) ? kObjectID_Device2' "${TEMP_DIR}/BlackHole/BlackHole.c"
grep -q 'kObjectID_Volume_Output_Master) ? kObjectID_Device2' "${TEMP_DIR}/BlackHole/BlackHole.c"
grep -q 'kObjectID_Mute_Output_Master) ? kObjectID_Device2' "${TEMP_DIR}/BlackHole/BlackHole.c"
grep -q 'kSampleRates=8000,16000,44100,48000' "${REPO_ROOT}/scripts/build-driver.sh"
grep -q 'kDevice_Name=\\"MicFlurry\\"' "${REPO_ROOT}/scripts/build-driver.sh"
grep -q 'kDevice_HasInput=true kDevice_HasOutput=false' "${REPO_ROOT}/scripts/build-driver.sh"
grep -q 'kDevice2_Name=\\"MicFlurry\\ Internal\\"' "${REPO_ROOT}/scripts/build-driver.sh"
grep -q 'kDevice2_IsHidden=true kDevice2_HasInput=false kDevice2_HasOutput=true' "${REPO_ROOT}/scripts/build-driver.sh"

echo "MicFlurry patch applies cleanly to $(git -C "${UPSTREAM_DIR}" rev-parse --short HEAD)."
