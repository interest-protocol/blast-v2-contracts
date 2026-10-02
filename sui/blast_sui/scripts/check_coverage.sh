#!/usr/bin/env bash
# Coverage gate for the Blast SUI package.
#
# Every production module must stay at 100.00 except two documented cases:
#
#   * `deposit_receipt`, whose macro-expanded Display configuration reports
#     96.67 even though the canonical Display creation and dynamic-object-field
#     cap handoff execute in package-admin tests; and
#   * `package_admin`, whose `authorize_upgrade` and `commit_upgrade_and_advance`
#     bodies cannot execute under test compilation. Sealed custody binds the
#     UpgradeCap to `type_name::original_id<BLAST_SUI_PACKAGE>()`, which is `0x0` before
#     publication, and the framework refuses to authorize an upgrade for the
#     zero package id. The complete native authorize/commit/advance matrix is
#     proved in `blast_admin::upgrade_custody_tests`, which owns a package
#     marker at a nonzero address; the tests here prove this package's
#     provenance rule, guard order, policy narrowing, and
#     immutability.
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

require_module_exact() {
  local module="$1" expected="$2" actual
  actual="$(grep -A1 "::${module}\$" <<<"$coverage_summary" \
    | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected exactly %s%% coverage for module %s, got %s.\n' \
      "$expected" "$module" "${actual:-none}" >&2
    exit 1
  fi
}

for module in blast_events events blast_sui_package blast_sui \
  fun_sui math custody vault; do
  require_module "$module"
done

require_module_exact package_admin 88.06

total="$(grep -oE '% Move Coverage: [0-9]+\.[0-9]+' <<<"$coverage_summary" | grep -oE '[0-9]+\.[0-9]+')"
if ! awk -v t="$total" 'BEGIN { exit (t >= 97.00) ? 0 : 1 }'; then
  printf 'Expected at least 97.00%% total Move coverage, got %s.\n' "$total" >&2
  exit 1
fi
