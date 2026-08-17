#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <mi-rc001|mi-rc003> <source.toml>" >&2
    exit 2
fi

model="$1"
source_file="$2"
case "${model}" in
    mi-rc001 | mi-rc003) ;;
    *)
        echo "Unsupported MicFlurry model: ${model}" >&2
        exit 2
        ;;
esac

if [[ ! -f "${source_file}" || -L "${source_file}" ]]; then
    echo "Keymap source must be a regular, non-symlink file: ${source_file}" >&2
    exit 2
fi

config_dir="${HOME}/.config/micflurry"
destination="${config_dir}/${model}.toml"
install -d -m 700 "${config_dir}"
temporary="$(mktemp "${config_dir}/.${model}.XXXXXX")"
trap 'rm -f "${temporary}"' EXIT
install -m 600 "${source_file}" "${temporary}"
mv -f "${temporary}" "${destination}"
trap - EXIT

echo "Installed ${destination}"
