#!/usr/bin/env bash
# Seals the freshly published UpgradeCap in the shared PackageAdmin, narrowed to dependency-only
# upgrades in the same call.
set -euo pipefail

environment="${1:-}"
package_id="${2:-}"
upgrade_cap_id="${3:-}"
mode="${4:-}"

if [[ -z "$environment" || -z "$package_id" || -z "$upgrade_cap_id" ]] \
  || [[ "$mode" != "--preview" && "$mode" != "--execute" ]]; then
  printf 'usage: %s <sui-environment> <package-id> <upgrade-cap-id> [--preview|--execute]\n' "$0" >&2
  exit 2
fi

execution_flag=()
if [[ "$mode" == "--preview" ]]; then
  execution_flag=(--preview)
fi

exec sui client --client.env "$environment" ptb \
  --move-call "$package_id::package_admin::wrap" "@$upgrade_cap_id" \
  --json \
  "${execution_flag[@]}"
