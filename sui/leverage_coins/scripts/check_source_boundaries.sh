#!/usr/bin/env bash
# Mechanical boundary gate for the Blast leverage-coins package.
#
# The current slice contains consensus-critical arithmetic, immutable leverage
# bounds, and the closed Series lifecycle state machine. This script fails if
# the package gains a dependency, external public function, object, custody,
# currency, transfer, event construct, or venue/launchpad reference before
# later gates are met.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '%s\n' "$1" >&2; exit 1; }

lifecycle_file="$package_dir/sources/series_lifecycle.move"
series_file="$package_dir/sources/series.move"
share_math_file="$package_dir/sources/share_math.move"
maintenance_math_file="$package_dir/sources/maintenance_math.move"
leverage_bounds_file="$package_dir/sources/leverage_bounds.move"

production_sources=()
non_lifecycle_sources=()
non_math_sources=()
non_maintenance_math_sources=()
non_lifecycle_or_series_sources=()
non_leverage_bounds_or_series_sources=()

while IFS= read -r -d '' source_file; do
  production_sources+=("$source_file")

  if [[ "$source_file" != "$lifecycle_file" ]]; then
    non_lifecycle_sources+=("$source_file")
  fi
  if [[ "$source_file" != "$share_math_file" \
    && "$source_file" != "$maintenance_math_file" ]]; then
    non_math_sources+=("$source_file")
  fi
  if [[ "$source_file" != "$maintenance_math_file" ]]; then
    non_maintenance_math_sources+=("$source_file")
  fi
  if [[ "$source_file" != "$lifecycle_file" \
    && "$source_file" != "$series_file" ]]; then
    non_lifecycle_or_series_sources+=("$source_file")
  fi
  if [[ "$source_file" != "$leverage_bounds_file" \
    && "$source_file" != "$series_file" ]]; then
    non_leverage_bounds_or_series_sources+=("$source_file")
  fi
done < <(find "$package_dir/sources" -type f -name '*.move' -print0 | sort -z)

# Run one grep over an explicit file array. This avoids basename exclusions and
# `find -exec ... {} +` status aggregation, which can fail open across batches.
grep_move_sources() {
  local pattern="$1"
  shift

  (($# > 0)) || return 1
  grep -nHE "$pattern" "$@"
}

# 1. The manifest declares the pinned identity and no dependency of its own.
grep -q '^name = "blast_leverage_coins"$' "$package_dir/Move.toml" \
  || fail "Move.toml must name the package blast_leverage_coins."
grep -q '^edition = "2024"$' "$package_dir/Move.toml" \
  || fail "Move.toml must use the stable 2024 edition."
grep -q '^blast_leverage_coins = "0x0"$' "$package_dir/Move.toml" \
  || fail "Move.toml must keep the unpublished 0x0 named address."
if grep -qE '^\[(dev-)?dependencies(\]|[.])' "$package_dir/Move.toml"; then
  fail "The current slice uses only the implicit framework; it declares no dependency."
fi

# 2. The lockfile pins the launchpad's framework revision for both environments.
pinned_rev="06734f6ff0af45d8632a14a4dc4b100197f6b1a2"
grep -q "rev = \"$pinned_rev\"" "$package_dir/Move.lock" \
  || fail "Move.lock must stay pinned to $pinned_rev."
for environment in mainnet testnet; do
  grep -q "^\[pinned.$environment.blast_leverage_coins\]$" "$package_dir/Move.lock" \
    || fail "Move.lock must pin the $environment environment."
done

# 3. Production code exposes no public ABI: every function is package or private.
# Inspect the complete declaration before checking modifier tokens so both
# `public macro fun` and the repository's `macro public fun` order are covered.
function_declaration='^[[:space:]]*(#[^]]*][[:space:]]*)*((macro|native|public(\(package\))?|entry)[[:space:]]+)*fun[[:space:]]'
if grep_move_sources "$function_declaration" "${production_sources[@]}" \
  | grep -E '(^|[[:space:]])(public|entry)([[:space:]]|$)'; then
  fail "Every production function must be public(package) or private."
fi

# 4. The current slice owns no object, custody, currency, transfer, or event construct.
later_gates='TreasuryCap|MetadataCap|Publisher|UpgradeCap|coin_registry'
later_gates="$later_gates"'|UID|Balance<|Coin<|has[[:space:]][^{;]*(^|[[:space:],])key([[:space:],{]|$)'
later_gates="$later_gates"'|share_object|public_transfer|transfer::|sui::event|event::|sui::[{][^}]*event'
if grep_move_sources "$later_gates" "${production_sources[@]}"; then
  fail "Currencies, capabilities, shared objects, transfers, and events are later gates."
fi

# 5. Core imports no venue adapter and no launchpad package.
if grep -rniE 'aftermath|blast_fun' "$package_dir/sources" "$package_dir/tests"; then
  fail "The core package must not reference a venue adapter or the launchpad."
fi

# 6. Only maintenance_math may compose the low-level shareholder-NAV mint and
# redemption formulas. Future state modules must use its reserve-aware quotes.
if grep_move_sources \
  'share_math::.*(mint_quote|redemption_quote|leverage_bps_up|target_notional_down|mint_base_delta_down|mint_base_bounds|assert_mint_base_within_bounds)' \
  "${non_math_sources[@]}"; then
  fail "State modules must use maintenance_math reserve-aware accounting functions."
fi

# 7. The bare funding-cost arithmetic has no authentication input. A future
# production caller is forbidden until a typed funding completion owns the path.
if grep_move_sources \
  'maintenance_math::.*absorb_funding_cost' \
  "${non_maintenance_math_sources[@]}"; then
  fail "A typed funding completion must gate every production reserve debit."
fi

# 8. Only the lifecycle-owning module constructs lifecycle variants. Future
# Series code must use its package API so lifecycle legality has one owner.
if grep_move_sources \
  'Lifecycle::(Active|ReduceOnly|ShutdownPending|ShutdownSettled)' \
  "${non_lifecycle_sources[@]}"; then
  fail "Only series_lifecycle may construct or inspect lifecycle variants directly."
fi

# 9. The lifecycle module is an inert state machine, not Series storage or custody.
if grep -nE \
  'UID|Balance<|Coin<|TreasuryCap|MetadataCap|TxContext|has[[:space:]][^{;]*(^|[[:space:],])key([[:space:],{]|$)|transfer::|sui::event|event::|sui::[{][^}]*event' \
  "$lifecycle_file"; then
  fail "series_lifecycle must not own objects, assets, capabilities, transfers, or events."
fi

# 10. Lifecycle upgrades require complete Series proofs and do not exist in
# this isolated state-machine slice.
if grep -nE '[*][[:space:]]*[[:alnum:]_]+[[:space:]]*=' "$lifecycle_file" \
  | grep -vE \
    '^[[:digit:]]+:[[:space:]]*[*][[:space:]]*[[:alnum:]_]+[[:space:]]*=[[:space:]]*Lifecycle::(ReduceOnly|ShutdownPending);[[:space:]]*$'; then
  fail "Lifecycle resume and settlement finalization belong to a proved Series transition."
fi

if grep_move_sources \
  '([.]lifecycle|[*][[:space:]]*[[:alnum:]_]*lifecycle)[[:space:]]*=|[*][[:space:]]*[[:alnum:]_]+[[:space:]]*=[[:space:]]*(Lifecycle::|series_lifecycle::new[(])' \
  "${non_lifecycle_sources[@]}"; then
  fail "Production modules must mutate lifecycle only through series_lifecycle."
fi

# 11. Only Series may consume lifecycle predicates, guards, and transitions in
# production. Other modules cannot bypass Series-owned authority and proofs.
if grep_move_sources \
  'series_lifecycle|[.](is_active|is_reduce_only|is_shutdown_pending|is_shutdown_settled|enter_reduce_only|enter_shutdown_pending|assert_active|assert_normal_redemption_allowed|assert_operating_risk_reduction_allowed|assert_shutdown_close_allowed|assert_shutdown_redemption_allowed)[(]' \
  "${non_lifecycle_or_series_sources[@]}"; then
  fail "Only series.move may consume the series_lifecycle production API."
fi

# Once Series storage lands, construction must contain exactly one visibly
# reviewable lifecycle initialization. Any additional call can reset a live
# lifecycle to Active and must fail this gate until it gains a stronger proof.
if [[ -f "$series_file" ]]; then
  lifecycle_new_calls="$(grep -oF 'series_lifecycle::new()' "$series_file" | wc -l)"
  [[ "$lifecycle_new_calls" == '1' ]] \
    || fail "series.move must contain exactly one lifecycle constructor call."
  grep -qE \
    '^[[:space:]]*lifecycle:[[:space:]]*series_lifecycle::new[(][)][,]?[[:space:]]*$' \
    "$series_file" \
    || fail "Series lifecycle construction must remain a visible struct-field initializer."
fi

# 12. Only Series may consume validated leverage bounds in production. No
# helper or adapter-facing seam may rebuild or reinterpret the risk ordering.
if grep_move_sources \
  '(^|[^[:alnum:]_])leverage_bounds([^[:alnum:]_]|$)' \
  "${non_leverage_bounds_or_series_sources[@]}"; then
  fail "Only series.move may consume the leverage_bounds production API."
fi

printf 'Source boundaries hold.\n'
