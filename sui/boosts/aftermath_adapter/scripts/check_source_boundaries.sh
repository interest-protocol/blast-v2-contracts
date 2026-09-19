#!/usr/bin/env bash
# Structural gate for the Boost packages: the facts the Move compiler and the
# Move tests do not check. Dependency direction, one linear module hierarchy
# per package, the public surface, the sole-driver rule, and the test seams.
# Behavior (custody sealed at construction, guard order, capture shape) is
# proven by the Move tests, never by grepping source lines here.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core_dir="$(cd "$package_dir/../core" && pwd)"
fail() { printf '%s\n' "$1" >&2; exit 1; }

# Production text of a module: everything before its Test-Only section.
# Callers grep a captured string, never a pipe: with pipefail an early `grep -q`
# exit would turn a match into a SIGPIPE'd, failed pipeline.
production() { sed '/^\/\/ === Test-Only Functions ===/,$d' "$1"; }
# Production `use` statements of a module, one per line; imports trail the module.
imports() {
  sed -n '/^\/\/ === Imports ===/,$p' "$1" \
    | sed '/^#\[test_only\]/,/;/d' \
    | tr '\n' ' ' \
    | grep -oE 'use (fun )?[a-z_:]+[^;]*;' || true
}

# --- Dependency direction (ADR 0064) ---

grep -q '^name = "blast_boosts_aftermath"$' "$package_dir/Move.toml" \
  || fail "Move.toml must name blast_boosts_aftermath."
grep -q 'blast_boosts_core = { local = "../core" }' "$package_dir/Move.toml" \
  || fail "The adapter must depend inward on the core."
if grep -rq 'blast_boosts_aftermath' "$core_dir/Move.toml" "$core_dir/sources"; then
  fail "The core must never depend back on the Aftermath adapter."
fi

# --- One linear hierarchy per package ---
# Every module names its layer; a module may import only modules of a strictly
# lower layer of its own package, and a lib/ module only other lib/ modules.

declare -A core_layers=(
  [errors]=0 [constants]=0 [blast_boosts_core]=0
  [lifecycle]=1 [policy]=1 [accounting_math]=1
  [observation]=2 [rebalance_math]=2
  [state]=3
)
declare -A adapter_layers=(
  [errors]=0 [constants]=0 [blast_events]=0 [blast_boosts_aftermath]=0
  [ifixed_math]=1 [blast_boost]=1 [protocol]=1
  [venue_account]=2 [package_admin]=2
  [events]=3 [snapshot]=3
  [vault]=4
  [operations]=5
)

check_hierarchy() {
  local package="$1" dir="$2"
  local -n layers="$3"
  local file module dep
  for file in "$dir"/sources/*.move "$dir"/sources/lib/*.move; do
    module="$(basename "$file" .move)"
    [[ -v "layers[$module]" ]] \
      || fail "$package::$module has no layer; add it to the hierarchy table in this gate."
    for dep in $(imports "$file" | grep -E "^use (fun )?$package::" | sed "s/$package:://g" | grep -oE '[a-z_][a-z0-9_]*'); do
      [[ -v "layers[$dep]" ]] || continue
      (( layers[$dep] < layers[$module] )) \
        || fail "$package::$module (layer ${layers[$module]}) imports $package::$dep (layer ${layers[$dep]}); modules build only on lower layers."
      if [[ "$file" == */lib/* && ! -f "$dir/sources/lib/$dep.move" ]]; then
        fail "$package::$module lives in lib/ and may import only lib/ modules, not $dep."
      fi
    done
  done
}

check_hierarchy blast_boosts_core "$core_dir" core_layers
check_hierarchy blast_boosts_aftermath "$package_dir" adapter_layers

for file in "$core_dir"/sources/*.move "$core_dir"/sources/lib/*.move \
            "$package_dir"/sources/*.move "$package_dir"/sources/lib/*.move; do
  if grep -qE '^use ' "$file"; then
    first_use="$(grep -m1 -nE '^use ' "$file" | cut -d: -f1)"
    imports_header="$(grep -m1 -nF '// === Imports ===' "$file" | cut -d: -f1 || true)"
    [[ -n "$imports_header" && "$first_use" -gt "$imports_header" ]] \
      || fail "$file must keep every import under a trailing // === Imports === section."
  fi
done

# --- Public surface ---
# Callers see three modules: vault (issuance, administration, shutdown),
# operations (the driver) and package_admin (upgrades). Everything else is
# package-private, and no function is an entry point.

for file in "$package_dir"/sources/*.move "$package_dir"/sources/lib/*.move; do
  module="$(basename "$file" .move)"
  case "$module" in vault|operations|package_admin) continue ;; esac
  if grep -qE '^public fun ' <<<"$(production "$file")"; then
    fail "$module exposes a public function; only vault, operations and package_admin are callable."
  fi
done
if grep -rnE '\bentry fun ' "$core_dir/sources" "$package_dir/sources"; then
  fail "Boost packages expose no entry functions; every call composes in a PTB."
fi
if grep -rnE 'AdapterRoot|AdapterDomain|venue_handoff|struct [A-Za-z0-9_]*AdminCap\b' "$package_dir/sources"; then
  fail "The adapter must not reintroduce a per-adapter ACL root, handoff layer or AdminCap; administration is the core domain."
fi

# --- Currency and custody ownership ---

grep -q '^public struct BLAST_BOOSTS_AFTERMATH() has drop;$' "$package_dir/sources/blast_boosts_aftermath.move" \
  || fail "The package one-time witness must be BLAST_BOOSTS_AFTERMATH."
grep -q 'sui::package::claim_and_keep(otw, ctx);' "$package_dir/sources/blast_boosts_aftermath.move" \
  || fail "Adapter initialization must claim and keep its Publisher."
if grep -rnE 'BlastBoost(<[^>]*>)? *[({]' "$package_dir/sources"; then
  fail "BlastBoost is a never-constructed currency marker."
fi
if grep -rn 'new_currency<Vault<' "$package_dir/sources"; then
  fail "The shared Vault type must never be a currency."
fi
[[ "$(grep -rl 'new_currency<' "$package_dir/sources" | sort | tr '\n' ' ')" == "$package_dir/sources/blast_boost.move $package_dir/sources/vault.move " ]] \
  || fail "Share currencies are registered by blast_boost and only issuance in vault calls it."
if grep -nE 'transfer::(public_)?transfer|burn_publisher' <<<"$(production "$package_dir/sources/package_admin.move")"; then
  fail "Package administration must expose no capability escape."
fi

# --- Sole driver (ADR 0087) ---
# vault stores; it never reads the venue. operations alone advances a
# checkpoint or completes a core plan.

if grep -q 'perpetuals' "$package_dir/sources/vault.move"; then
  fail "vault is custody only and must not import the venue."
fi
[[ "$(grep -rl 'replace_checkpoint(' "$package_dir/sources" | sort | tr '\n' ' ')" == "$package_dir/sources/operations.move $package_dir/sources/venue_account.move " ]] \
  || fail "Only operations advances a checkpoint."
[[ "$(grep -rlE '\.(complete_(mint|redemption|rebalance|donation)|finalize_shutdown)\(' "$package_dir/sources" | tr '\n' ' ')" == "$package_dir/sources/operations.move " ]] \
  || fail "Only operations completes a core plan."

# --- Test seams ---
# Tests reach production through #[test_only] wrappers under the Test-Only
# section; production text carries no test accommodation. The error registries
# are gap-free from zero while the packages are unpublished.

for file in "$core_dir"/sources/*.move "$core_dir"/sources/lib/*.move \
            "$package_dir"/sources/*.move "$package_dir"/sources/lib/*.move; do
  if grep -nE 'for_testing|test_scenario|test_utils' <<<"$(production "$file")"; then
    fail "$file leaks test accommodation into production text."
  fi
  if [[ "$(basename "$file")" != errors.move ]] && grep -qF '#[test_only]' <<<"$(production "$file")"; then
    fail "$file must keep #[test_only] items under its Test-Only section."
  fi
done

check_error_registry() {
  local file="$1"
  local expected=0 code
  for code in $(grep -oE '^macro public\(package\) fun [a-z_0-9]+\(\): u64 \{ [0-9]+ \}' "$file" | grep -oE '[0-9]+ \}$' | cut -d' ' -f1); do
    [[ "$code" -eq "$expected" ]] || fail "$file: error macros must run gap-free from zero; found $code, expected $expected."
    expected=$((expected + 1))
  done
  [[ "$(grep -cE '^const E[A-Za-z0-9]+: u64 = [0-9]+;$' "$file")" -eq "$expected" ]] \
    || fail "$file: every error macro needs its #[test_only] const and nothing else."
  local consts
  consts="$(grep -oE '^const E[A-Za-z0-9]+: u64 = [0-9]+;$' "$file" | grep -oE '= [0-9]+' | cut -d' ' -f2 | tr '\n' ' ')"
  [[ "$consts" == "$(seq -s ' ' 0 $((expected - 1))) " ]] \
    || fail "$file: #[test_only] error consts must mirror the macro codes in order."
}
check_error_registry "$core_dir/sources/lib/errors.move"
check_error_registry "$package_dir/sources/lib/errors.move"

printf 'Source boundaries hold: hierarchy, surface, sole driver and test seams.\n'
