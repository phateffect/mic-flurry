#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export CLANG_MODULE_CACHE_PATH="/tmp/micflurry-swift-clang-module-cache"
export SWIFT_MODULECACHE_PATH="/tmp/micflurry-swift-module-cache"

readonly SWIFTPM_PATH_ARGS=(
    --cache-path /tmp/micflurry-swiftpm-cache
    --config-path /tmp/micflurry-swiftpm-config
    --security-path /tmp/micflurry-swiftpm-security
)
readonly SWIFTPM_BUILD_ARGS=(
    --arch arm64
    --disable-sandbox
    "${SWIFTPM_PATH_ARGS[@]}"
)

usage() {
    cat >&2 <<'EOF'
Usage: scripts/swift-package.sh <command>

Commands:
  format          lint Package.swift, Sources, and Tests
  build           build the debug Swift core
  test            run deterministic Swift tests
  private-test    run private-distribution authentication tests
  socket-test     run the host-only Unix socket integration test
  release         build release executables
  private-release build private-distribution release executables
EOF
    exit 2
}

[[ $# -eq 1 ]] || usage
cd "${REPO_ROOT}"

case "$1" in
    format)
        swift format lint --recursive --strict Package.swift Sources Tests
        ;;
    build)
        swift build "${SWIFTPM_BUILD_ARGS[@]}"
        ;;
    test)
        swift test "${SWIFTPM_BUILD_ARGS[@]}"
        ;;
    private-test)
        swift test "${SWIFTPM_BUILD_ARGS[@]}" \
            -Xswiftc -DMICFLURRY_PRIVATE_DISTRIBUTION \
            --filter private
        ;;
    socket-test)
        MICFLURRY_RUN_SOCKET_TESTS=1 swift test "${SWIFTPM_BUILD_ARGS[@]}" \
            --filter unixSocketServesMultipleClientsAndBroadcastsNotifications
        ;;
    release)
        swift build -c release "${SWIFTPM_BUILD_ARGS[@]}"
        ;;
    private-release)
        swift build -c release "${SWIFTPM_BUILD_ARGS[@]}" \
            -Xswiftc -DMICFLURRY_PRIVATE_DISTRIBUTION
        ;;
    *)
        usage
        ;;
esac
