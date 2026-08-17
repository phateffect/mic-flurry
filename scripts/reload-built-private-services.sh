#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/project.sh
source "${script_dir}/lib/project.sh"

project_dir="$(micflurry_repo_root)"
installer="${project_dir}/.build/private-service-install/Support/install-private-services.sh"

if [[ ! -x "${installer}" ]]; then
    echo "No staged private build; run mise run swift-private-install first." >&2
    exit 1
fi

exec "${installer}"
