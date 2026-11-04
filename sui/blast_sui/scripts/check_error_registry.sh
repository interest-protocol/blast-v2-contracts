#!/usr/bin/env bash
# Every Blast SUI error code is sequential from zero, its test-only constant and its macro
# agree, and errors_tests.move pins each macro to its literal value exactly once.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
registry="$package_dir/sources/lib/errors.move"
pins_file="$package_dir/tests/errors_tests.move"
fail() { printf '%s\n' "$1" >&2; exit 1; }

macros="$(sed -nE 's/^macro public\(package\) fun ([a-z_0-9]+)\(\): u64 \{ ([0-9]+) \}$/\1 \2/p' "$registry")"
[ -n "$macros" ] || fail "The error registry declares no macros."
constants="$(sed -nE 's/^const E[A-Za-z0-9]+: u64 = ([0-9]+);$/\1/p' "$registry")"
expected="$(seq 0 $(( $(wc -l <<<"$macros") - 1 )))"
[ "$(cut -d' ' -f2 <<<"$macros")" == "$expected" ] \
  || fail "Error macros must be numbered sequentially from zero in declaration order."
[ "$constants" == "$expected" ] \
  || fail "Test-only error constants must match the macros one for one, in order."

pins="$(sed -nE 's/^    assert_eq!\(errors::([a-z_0-9]+)!\(\), ([0-9]+)\);$/\1 \2/p' "$pins_file" | sort)"
# Compare name-value pairs, so an equal count cannot hide an omitted or duplicated pin.
if [ "$(sort <<<"$macros")" != "$pins" ]; then
  echo 'Every Blast SUI error macro must have exactly one literal numeric assertion in errors_tests.move.' >&2
  diff -u <(sort <<<"$macros") <(printf '%s\n' "$pins") >&2 || true
  exit 1
fi
