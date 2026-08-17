#!/bin/bash

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Driver removal must run through the macOS administrator prompt." >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
driver_target="/Library/Audio/Plug-Ins/HAL/MicFlurry.driver"

"${script_dir}/private-uninstall-root.sh"

rm -rf "${driver_target}"
killall coreaudiod 2>/dev/null || true
echo "Removed the MicFlurry audio driver."
