#!/usr/bin/env bash
# Coverage gate for the Blast SUI package.
#
# 100% package coverage is deliberately not required:
# - `deposit_receipt::create_display` needs the framework `DisplayRegistry`,
#   whose test constructor is package-private to `sui`;
# - defensive aborts (`insufficient_native_redemption`,
#   `fun_backing_below_supply`, and the custody raise of
#   `wrong_delegation_pool`) back production guards that the tests
#   deliberately do not bypass.
# Modules free of those exclusions must stay at 100.00.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sui move test --path "$package_dir" --coverage
coverage_summary="$(sui move coverage --path "$package_dir" summary)"
printf '%s\n' "$coverage_summary"

require_module() {
  if ! grep -A1 "::$1\$" <<<"$coverage_summary" | grep -Fq '100.00'; then
    printf 'Expected 100.00%% coverage for module %s.\n' "$1" >&2
    exit 1
  fi
}

for module in events_wrapper events package_version acl blast blast_sui fun_sui; do
  require_module "$module"
done

total="$(grep -oE '% Move Coverage: [0-9]+\.[0-9]+' <<<"$coverage_summary" | grep -oE '[0-9]+\.[0-9]+')"
if ! awk -v t="$total" 'BEGIN { exit (t >= 95.00) ? 0 : 1 }'; then
  printf 'Expected at least 95.00%% total Move coverage, got %s.\n' "$total" >&2
  exit 1
fi
