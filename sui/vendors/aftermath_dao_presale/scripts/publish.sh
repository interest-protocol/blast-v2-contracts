#!/usr/bin/env bash
# Publishes blast_aftermath_dao_presale and, in the same PTB, sends its UpgradeCap to the TREASURY
# compiled into the module, which also receives every pool's DAO fees, OwnerCap, and locked LP.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$package_dir/sources/blast_aftermath_dao_presale.move"
mode="${1:-}"

if [[ "$mode" != "--preview" && "$mode" != "--execute" ]]; then
  printf 'usage: %s [--preview|--execute]\n' "$0" >&2
  exit 2
fi

treasury="$(sed -n 's/^const TREASURY: address = @\(0x[0-9a-f]\{64\}\);$/\1/p' "$source_file")"
if [[ -z "$treasury" ]]; then
  printf 'publish: no 64-hex-digit TREASURY constant in %s\n' "$source_file" >&2
  exit 1
fi

execution_flag=()
if [[ "$mode" == "--preview" ]]; then
  execution_flag=(--preview)
fi

exec sui client --client.env mainnet ptb \
  --publish "$package_dir" \
  --assign upgrade_cap \
  --transfer-objects "[upgrade_cap]" "@$treasury" \
  --warn-shadows \
  --json \
  ${execution_flag[@]+"${execution_flag[@]}"}
