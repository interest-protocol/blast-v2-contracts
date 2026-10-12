#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

registry="$(awk -f scripts/move_facts.awk sources/lib/errors.move)"
tests="$(awk -f scripts/move_facts.awk tests/errors_tests.move)"
macros="$(awk -F'\t' '$1 == "FN" && $5 == 1 { print $2 }' <<<"$registry" | sort)"
# Compare names, including duplicates, so equal counts cannot hide an omitted pin.
pins="$(awk -F'\t' '$1 == "NORM" { print $2 }' <<<"$tests" \
  | { rg -o 'assert_eq!\(blast_fun::errors::[a-z_0-9]+!\(\), [0-9]+\);' || true; } \
  | sed -E 's/^assert_eq!\(blast_fun::errors::([a-z_0-9]+)!.*$/\1/' | sort)"

if [[ -z "$macros" || "$macros" != "$pins" ]]; then
  echo 'Every launchpad error macro must have exactly one literal numeric assertion in errors_tests.move.' >&2
  diff -u <(printf '%s\n' "$macros") <(printf '%s\n' "$pins") >&2 || true
  exit 1
fi
