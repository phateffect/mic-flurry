#!/bin/bash

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "This runner must run as root." >&2
    exit 1
fi

service_target="system/io.phateffect.MicFlurry.hid-probe"
stdout_log="/var/tmp/micflurry-hid-probe.out.log"
stderr_log="/var/tmp/micflurry-hid-probe.err.log"

rm -f "${stdout_log}" "${stderr_log}"
launchctl kickstart -k "${service_target}"
echo "Started ${service_target}; logs: ${stdout_log}, ${stderr_log}"
