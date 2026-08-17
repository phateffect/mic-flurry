#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/project.sh
source "${script_dir}/lib/project.sh"

project_dir="$(micflurry_repo_root)"
source_bundle="${project_dir}/build/MicFlurry Private.app"
staging_dir="${project_dir}/.build/private-service-install"
staged_bundle="${staging_dir}/MicFlurry.app"
support_dir="${staging_dir}/Support"

if [[ ! -d "${source_bundle}" ]]; then
    echo "Missing ${source_bundle}; run mise run swift-private-app first." >&2
    exit 1
fi

rm -rf "${staging_dir}"
install -d -m 755 "${support_dir}"
ditto "${source_bundle}" "${staged_bundle}"
install -m 755 \
    "${script_dir}/install-private-services.sh" \
    "${support_dir}/install-private-services.sh"
install -m 755 \
    "${script_dir}/private-install-root.sh" \
    "${support_dir}/private-install-root.sh"

codesign --verify --deep --strict --verbose=2 "${staged_bundle}"
exec "${support_dir}/install-private-services.sh"
