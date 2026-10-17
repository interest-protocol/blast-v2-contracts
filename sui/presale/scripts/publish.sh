#!/usr/bin/env bash
# Publishes blast_presale. The sender receives the UpgradeCap, and must seal the
# UpgradeCap with scripts/wrap_package_admin.sh before any presale is created.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-}"

if [[ "$mode" != "--preview" && "$mode" != "--execute" ]]; then
  printf 'usage: %s [--preview|--execute]\n' "$0" >&2
  exit 2
fi

execution_flag=()
if [[ "$mode" == "--preview" ]]; then
  execution_flag=(--dry-run)
fi

sui client --client.env mainnet publish "$package_dir" \
  --json \
  ${execution_flag[@]+"${execution_flag[@]}"} | python3 -c '
import json
import sys

result = json.load(sys.stdin)
json.dump(result, sys.stdout, indent=2)
sys.stdout.write("\n")
try:
    status = result["effects"]["status"]["status"]
except (KeyError, TypeError):
    status = None
if status != "success":
    print("Publication failed or returned no successful transaction effects.", file=sys.stderr)
    sys.exit(1)
'
