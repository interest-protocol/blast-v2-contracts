#!/usr/bin/env bash
# Publishes blast_fun_auto_lp and consumes its UpgradeCap in the same PTB.
#
# AutoLP holds permanent creator-cap and LP-position custody with no withdrawal
# path, so it must never leave an UpgradeCap that could add one.
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
  --assign auto_lp_upgrade_cap \
  --move-call 0x2::package::make_immutable auto_lp_upgrade_cap \
  --warn-shadows \
  --json \
  "${execution_flag[@]}"
