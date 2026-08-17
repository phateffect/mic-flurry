#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Press the remote buttons now; checking daemon status in 15 seconds..."
sleep 15
exec "${script_dir}/micflurryctl.py" --compact status
