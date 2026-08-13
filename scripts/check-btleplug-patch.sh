#!/usr/bin/env bash

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly UPSTREAM_DIR="${REPO_ROOT}/upstream/btleplug"
readonly PATCH_FILE="${REPO_ROOT}/patches/btleplug-macos-connected.patch"
readonly TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

if [[ ! -f "${UPSTREAM_DIR}/Cargo.toml" ]]; then
  echo "btleplug submodule is missing. Run: git submodule update --init --recursive" >&2
  exit 1
fi

git -C "${UPSTREAM_DIR}" archive HEAD | tar -x -C "${TEMP_DIR}"
patch --directory="${TEMP_DIR}" --strip=1 --forward < "${PATCH_FILE}"

grep -q 'connected_peripherals_with_services' \
  "${TEMP_DIR}/src/corebluetooth/adapter.rs"
grep -q 'retrieveConnectedPeripheralsWithServices' \
  "${TEMP_DIR}/src/corebluetooth/internal.rs"

echo "MicFlurry btleplug patch applies cleanly to $(git -C "${UPSTREAM_DIR}" rev-parse --short HEAD)."
