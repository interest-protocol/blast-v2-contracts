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

# 4. Functions with a natural first receiver use Move 2024 method syntax.
if rg -n 'dynamic_object_field::(add|borrow|borrow_mut|exists_with_type)\(' \
  "$package_dir/sources"; then
  fail "Dynamic-object-field operations must use semantic UID receiver aliases."
fi

if rg -n 'package::test_upgrade\(|test_scenario::return_to_sender\(|\.has_blast_coin\(' \
  "$package_dir/tests"; then
  fail "Test helpers with a natural first receiver must use Move 2024 dot syntax."
fi

if rg -n 'let[[:space:]]+[[:alnum:]_]+:[[:space:]]+&(mut[[:space:]]+)?Capability' \
  "$package_dir/sources"; then
  fail "Local reference types must be inferred from explicit generic arguments."
fi

printf 'Source boundaries hold.\n'
