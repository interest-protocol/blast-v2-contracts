#!/usr/bin/env bash
# Consumes the presale's Publication and seals custody through blast_admin's generic package
# administration; initial configuration uses normal ACL roles at zero delay.
set -euo pipefail

admin_package_id="${1:-}"
package_id="${2:-}"
publication_id="${3:-}"
upgrade_cap_id="${4:-}"
mode="${5:-}"

if [[ $# -ne 5 ]] || [[ -z "$admin_package_id" || -z "$package_id" || -z "$publication_id" || -z "$upgrade_cap_id" ]] \
  || [[ "$mode" != "--preview" && "$mode" != "--execute" ]]; then
  printf 'usage: %s <admin-package-id> <presale-package-id> <publication-id> <upgrade-cap-id> <--preview|--execute>\n' "$0" >&2
  exit 2
fi

execution_flag=()
if [[ "$mode" == "--preview" ]]; then
  execution_flag=(--preview)
fi

exec sui client --client.env mainnet ptb \
  --move-call "$admin_package_id::package_admin::wrap<$package_id::blast_presale_package::BLAST_PRESALE_PACKAGE>" \
  "@$publication_id" "@$upgrade_cap_id" \
  --json \
  ${execution_flag[@]+"${execution_flag[@]}"}
