#!/usr/bin/env bash
# Self-test: the error-registry gate accepts the committed registry and rejects drift.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch"/{scripts,sources/lib,tests}
cp "$package_dir/scripts/check_error_registry.sh" "$scratch/scripts/"
reset() {
  cp "$package_dir/sources/lib/errors.move" "$scratch/sources/lib/"
  cp "$package_dir/tests/errors_tests.move" "$scratch/tests/"
}
reset
bash "$scratch/scripts/check_error_registry.sh"

expect_failure() {
  if bash "$scratch/scripts/check_error_registry.sh" >/dev/null 2>&1; then
    echo "Error registry accepted $1." >&2
    exit 1
  fi
  printf 'Rejected %s.\n' "$1"
  reset
}

sed -i '/assert_eq!(errors::unguarded_notice!(), /d' "$scratch/tests/errors_tests.move"
expect_failure 'a missing pin'
sed -i 's/errors::unguarded_notice!(), \([0-9]*\)/errors::invalid_digest!(), \1/' "$scratch/tests/errors_tests.move"
expect_failure 'an equal-count duplicate replacing a pin'
sed -i 's/errors::zero_amount!(), 0)/errors::zero_amount!(), 9)/' "$scratch/tests/errors_tests.move"
expect_failure 'a pin with the wrong value'
printf '\nmacro public(package) fun unpinned(): u64 { 99 }\n' >>"$scratch/sources/lib/errors.move"
expect_failure 'a non-sequential, unpinned macro'
sed -i 's/^const EZeroAmount: u64 = 0;$/const EZeroAmount: u64 = 1;/' "$scratch/sources/lib/errors.move"
expect_failure 'a constant that disagrees with its macro'
