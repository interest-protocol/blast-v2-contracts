#!/usr/bin/env bash
# Publishes blast_aftermath_dao_presale and, in the same PTB, makes it immutable, so no one can
# change how a funded sale migrates (ADR 0104); init sends the AdminCap to the publisher.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-}"

if [[ "$mode" != "--preview" && "$mode" != "--execute" ]]; then
  printf 'usage: %s [--preview|--execute]\n' "$0" >&2
  exit 2
fi

execution_flag=()
if [[ "$mode" == "--preview" ]]; then
  execution_flag=(--preview)
fi

exec sui client --client.env mainnet ptb \
  --publish "$package_dir" \
  --assign upgrade_cap \
  --move-call 0x2::package::make_immutable upgrade_cap \
  --warn-shadows \
  --json \
  ${execution_flag[@]+"${execution_flag[@]}"}
