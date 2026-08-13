#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

find scripts -type f -name '*.sh' -print0 | xargs -0 bash -n
find packaging -type f \( -name '*.sh' -o -name '*.command' \) -print0 | xargs -0 bash -n
plutil -lint packaging/swift-app/*.plist packaging/private/*.plist
"${SCRIPT_DIR}/check-patch.sh"
git diff --check

echo "Repository scripts, plists, patches, and diff formatting are valid."
