#!/usr/bin/env bash
# Activates the package by consuming its Bootstrap and sealing compatible upgrade custody.
set -euo pipefail

package_id="${1:-}"
bootstrap_id="${2:-}"
upgrade_cap_id="${3:-}"
mode="${4:-}"

if [[ -z "$package_id" || -z "$bootstrap_id" || -z "$upgrade_cap_id" ]] \
  || [[ "$mode" != "--preview" && "$mode" != "--execute" ]]; then
  printf 'usage: %s <package-id> <bootstrap-id> <upgrade-cap-id> [--preview|--execute]\n' "$0" >&2
  exit 2
fi

execution_flag=()
if [[ "$mode" == "--preview" ]]; then
  execution_flag=(--preview)
fi

exec sui client --client.env mainnet ptb \
  --move-call "$package_id::package_admin::wrap" "@$bootstrap_id" "@$upgrade_cap_id" \
  --json \
  ${execution_flag[@]+"${execution_flag[@]}"}
