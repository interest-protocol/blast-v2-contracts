#!/usr/bin/env bash
# Publishes blast_presale and consumes its UpgradeCap in the same PTB.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
environment="${1:-}"
mode="${2:-}"

if [[ -z "$environment" ]] || [[ "$mode" != "--preview" && "$mode" != "--execute" ]]; then
  printf 'usage: %s <sui-environment> [--preview|--execute]\n' "$0" >&2
  exit 2
fi

execution_flag=()
if [[ "$mode" == "--preview" ]]; then
  execution_flag=(--preview)
fi

exec sui client --client.env "$environment" ptb \
  --publish "$package_dir" \
  --assign presale_upgrade_cap \
  --move-call 0x2::package::make_immutable presale_upgrade_cap \
  --warn-shadows \
  --json \
  "${execution_flag[@]}"
