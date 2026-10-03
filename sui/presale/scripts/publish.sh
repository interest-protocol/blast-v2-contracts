#!/usr/bin/env bash
# Publishes blast_presale. The sender receives the AdminCap and the UpgradeCap, and must seal the
# UpgradeCap with scripts/wrap_package_admin.sh before any presale is created.
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
  execution_flag=(--dry-run)
fi

exec sui client --client.env "$environment" publish "$package_dir" \
  --json \
  "${execution_flag[@]}"
