#!/usr/bin/env bash
# Publishes Series1 on Sui mainnet and consumes its UpgradeCap in the same PTB.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-}"

if [[ $# -ne 1 ]] || [[ "$mode" != "--preview" && "$mode" != "--execute" ]]; then
  printf 'usage: %s [--preview|--execute]\n' "$0" >&2
  exit 2
fi

execution_flag=()
if [[ "$mode" == "--preview" ]]; then
  execution_flag=(--preview)
fi

exec sui client --client.env mainnet ptb \
  --publish "$package_dir" \
  --assign series_upgrade_cap \
  --move-call 0x2::package::make_immutable series_upgrade_cap \
  --warn-shadows \
  --json \
  ${execution_flag[@]+"${execution_flag[@]}"}
