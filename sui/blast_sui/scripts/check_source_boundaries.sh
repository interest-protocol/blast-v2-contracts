#!/usr/bin/env bash
# Mechanical boundary gate for the Blast SUI package.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '%s\n' "$1" >&2; exit 1; }

# 1. The manifest declares exactly one dependency: the pinned SuiSystem framework.
pinned_rev="06734f6ff0af45d8632a14a4dc4b100197f6b1a2"
deps="$(sed -n '/^\[dependencies\]/,/^\[/p' "$package_dir/Move.toml" | grep -E '^[A-Za-z]' || true)"
[ "$(wc -l <<<"$deps")" -eq 1 ] || fail "Move.toml must declare exactly one dependency."
grep -q '^SuiSystem = ' <<<"$deps" || fail "Move.toml dependency must be SuiSystem."
grep -q "rev = \"$pinned_rev\"" "$package_dir/Move.toml" || fail "SuiSystem must stay pinned to $pinned_rev."

# 2. This package must not reference the launchpad package.
if grep -rn "blast_fun" "$package_dir/sources" "$package_dir/tests"; then
  fail "blast_sui must not reference blast_fun."
fi

# 3. Every event goes through the events_wrapper envelope.
if grep -rn "sui::event::emit" "$package_dir/sources" | grep -v "sources/lib/events_wrapper.move"; then
  fail "Only events_wrapper may call sui::event::emit."
fi

printf 'Source boundaries hold.\n'
