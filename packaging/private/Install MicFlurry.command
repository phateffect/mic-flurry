#!/bin/bash

set -euo pipefail
distribution_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${distribution_dir}/Support/install-private-services.sh"
