#!/usr/bin/env bash

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly UPSTREAM_DIR="${REPO_ROOT}/upstream/btleplug"
readonly PATCH_FILE="${REPO_ROOT}/patches/btleplug-macos-connected.patch"
readonly WORK_DIR="${REPO_ROOT}/.build/btleplug"
readonly STAMP_FILE="${WORK_DIR}/.micflurry-source"

if [[ ! -f "${UPSTREAM_DIR}/Cargo.toml" ]]; then
  echo "btleplug submodule is missing. Run: git submodule update --init --recursive" >&2
  exit 1
fi

readonly UPSTREAM_REVISION="$(git -C "${UPSTREAM_DIR}" rev-parse HEAD)"
readonly PATCH_CHECKSUM="$(shasum -a 256 "${PATCH_FILE}" | awk '{print $1}')"
readonly SOURCE_ID="${UPSTREAM_REVISION}:${PATCH_CHECKSUM}"

if [[ -f "${STAMP_FILE}" ]] &&
  [[ -f "${WORK_DIR}/Cargo.toml" ]] &&
  [[ "$(< "${STAMP_FILE}")" == "${SOURCE_ID}" ]]; then
  exit 0
fi

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
git -C "${UPSTREAM_DIR}" archive HEAD | tar -x -C "${WORK_DIR}"
patch --directory="${WORK_DIR}" --strip=1 --forward < "${PATCH_FILE}"
printf '%s\n' "${SOURCE_ID}" > "${STAMP_FILE}"

echo "Prepared patched btleplug from ${UPSTREAM_REVISION:0:7}."
