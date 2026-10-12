#!/usr/bin/env bash

set -euo pipefail

package_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch"/{scripts,sources/lib,tests}
cp "$package_dir"/scripts/{check_error_registry.sh,move_facts.awk} "$scratch/scripts/"
cp "$package_dir/sources/lib/errors.move" "$scratch/sources/lib/"
cp "$package_dir/tests/errors_tests.move" "$scratch/tests/"
bash "$scratch/scripts/check_error_registry.sh"

expect_failure() {
  if bash "$scratch/scripts/check_error_registry.sh" >"$scratch/output" 2>&1; then
    echo "Error registry accepted $1." >&2
    exit 1
  fi
  rg -q 'Every launchpad error macro must have exactly one literal numeric assertion' "$scratch/output"
  printf 'Rejected %s.\n' "$1"
}

sed -i '/assert_eq!(blast_fun::errors::partner_mismatch!(), 37);/d' "$scratch/tests/errors_tests.move"
expect_failure 'a missing pin'
cp "$package_dir/tests/errors_tests.move" "$scratch/tests/"
sed -i 's/partner_mismatch!(), 37/partner_not_accepted!(), 36/' "$scratch/tests/errors_tests.move"
expect_failure 'an equal-count duplicate replacing a pin'
cp "$package_dir/tests/errors_tests.move" "$scratch/tests/"
printf '\nmacro public(package) fun unpinned(): u64 { 38 }\n' >>"$scratch/sources/lib/errors.move"
expect_failure 'an unpinned macro'
