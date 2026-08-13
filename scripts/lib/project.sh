#!/usr/bin/env bash

# Shared path and argument helpers for repository scripts. This file is sourced;
# it is not intended to be executed directly.

micflurry_repo_root() {
    local source_dir
    source_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    cd "${source_dir}/.." && pwd
}

micflurry_validate_version() {
    local version="$1"
    if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Version must use MAJOR.MINOR.PATCH." >&2
        return 2
    fi
}

micflurry_validate_build_number() {
    local build_number="$1"
    if [[ ! "${build_number}" =~ ^[1-9][0-9]*$ ]]; then
        echo "Build number must be a positive integer." >&2
        return 2
    fi
}
