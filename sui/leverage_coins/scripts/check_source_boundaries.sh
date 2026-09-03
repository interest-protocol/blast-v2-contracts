#!/usr/bin/env bash
# Mechanical boundary gate for the Blast leverage-coins package.
#
# The current slice contains consensus-critical arithmetic and one consolidated
# Series-domain module for immutable policy and the closed lifecycle state
# machine. This script fails if the package gains a dependency, external public
# function, object, custody, currency, transfer, event construct, source binding,
# or venue/launchpad reference before later gates are met.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '%s\n' "$1" >&2; exit 1; }

series_file="$package_dir/sources/series.move"
accounting_math_file="$package_dir/sources/accounting_math.move"

production_sources=()
non_accounting_math_sources=()
non_series_sources=()

while IFS= read -r -d '' source_file; do
  production_sources+=("$source_file")

  if [[ "$source_file" != "$accounting_math_file" ]]; then
    non_accounting_math_sources+=("$source_file")
  fi
  if [[ "$source_file" != "$series_file" ]]; then
    non_series_sources+=("$source_file")
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

[[ -f "$series_file" ]] || fail "The consolidated Series domain must live in series.move."
for retired_module in series_lifecycle.move series_policy.move valuation_policy.move; do
  if [[ -e "$package_dir/sources/$retired_module" ]]; then
    fail "$retired_module must remain consolidated under series.move."
  fi
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

# 6. Raw shareholder-NAV formulas are private inside accounting_math, so the
# Move compiler prevents future state modules from bypassing reserve-aware
# package functions. The bare funding-cost arithmetic still has no
# authentication input. A future production caller is forbidden until a typed
# funding completion owns the path.
raw_accounting_functions='fee_up|credit_fee|mint_quote|redemption_quote|leverage_bps_up|target_notional_down|mint_base_delta_down|mint_base_bounds|assert_mint_base_within_bounds'
if grep -nE \
  "^[[:space:]]*public(\\(package\\))?[[:space:]]+fun[[:space:]]+($raw_accounting_functions)[[:space:]]*[(]" \
  "$accounting_math_file"; then
  fail "Raw accounting functions must remain private behind reserve-aware package functions."
fi

if grep_move_sources \
  'accounting_math::.*absorb_funding_cost' \
  "${non_accounting_math_sources[@]}"; then
  fail "A typed funding completion must gate every production reserve debit."
fi

# 7. Only the Series-domain module constructs lifecycle variants.
if grep_move_sources \
  'Lifecycle::(Active|ReduceOnly|ShutdownPending|ShutdownSettled)' \
  "${non_series_sources[@]}"; then
  fail "Only series.move may construct or inspect lifecycle variants directly."
fi

# 8. The current Series-domain slice owns rules, not storage or custody.
if grep -nE \
  'UID|Balance<|Coin<|TreasuryCap|MetadataCap|TxContext|has[[:space:]][^{;]*(^|[[:space:],])key([[:space:],{]|$)|transfer::|sui::event|event::|sui::[{][^}]*event' \
  "$series_file"; then
  fail "The current series.move slice must not own objects, assets, capabilities, transfers, or events."
fi

# 9. Lifecycle upgrades require complete shared-Series proofs and do not exist
# in this pre-custody slice.
if grep -nE '[*][[:space:]]*[[:alnum:]_]+[[:space:]]*=' "$series_file" \
  | grep -vE \
    '^[[:digit:]]+:[[:space:]]*[*][[:space:]]*[[:alnum:]_]+[[:space:]]*=[[:space:]]*Lifecycle::(ReduceOnly|ShutdownPending);[[:space:]]*$'; then
  fail "Lifecycle resume and settlement finalization belong to a proved Series transition."
fi

# 10. No other production module may consume Series policy or lifecycle rules.
# Future shared state stays in this owner instead of introducing another module.
if grep_move_sources \
  'series::|blast_leverage_coins::series|Lifecycle::(Active|ReduceOnly|ShutdownPending|ShutdownSettled)|PositionSide::(Long|Short)' \
  "${non_series_sources[@]}"; then
  fail "Only series.move may own or consume Series policy and lifecycle rules."
fi

# Once Series storage lands, construction must contain exactly one visibly
# reviewable lifecycle initialization. Any additional call can reset a live
# lifecycle to Active and must fail this gate until it gains a stronger proof.
if grep -qE '^[[:space:]]*public[[:space:]]+struct[[:space:]]+Series([<[:space:]])' "$series_file"; then
  lifecycle_initializers="$(grep -cE '^[[:space:]]*lifecycle:[[:space:]]*new_lifecycle[(][)][,]?[[:space:]]*$' "$series_file" || true)"
  [[ "$lifecycle_initializers" == '1' ]] \
    || fail "series.move must contain exactly one lifecycle constructor call."
fi

# 11. Valuation policy stays a validated primitive value. Exact source
# identity and authentication belong to the future VenueAccount and adapter,
# and reading on-chain time belongs to the future Series transition.
if grep -nE \
  '(^|[^[:alnum:]_])(ID|UID|address)([^[:alnum:]_]|$)|&[[:space:]]*(mut[[:space:]]+)?(Clock|TxContext)' \
  "$series_file"; then
  fail "The current series.move slice must not bind a source id, a clock, or a transaction context."
fi

# 12. The venue mark is a margin-safety input only (ADR 0064 I25). It must
# never reach shareholder NAV, share pricing, or accounting leverage.
if grep_move_sources \
  '(^|[^[:alnum:]])mark([^[:alnum:]]|$)' \
  "$accounting_math_file"; then
  fail "A venue mark must never enter shareholder-NAV or share-pricing math."
fi

# 13. Mint contribution sanity owns a distinct Series policy bound. Venue mark
# divergence remains margin-only and must not become share-accounting authority.
mint_contribution_predicate="$(
  sed -n \
    '/^fun is_mint_contribution_within_bound(/,/^}/p' \
    "$series_file" || true
)"
[[ -n "$mint_contribution_predicate" ]] \
  || fail "series.move must own the mint-contribution bound predicate."
if grep -q 'max_mark_divergence_bps' <<<"$mint_contribution_predicate"; then
  fail "Mint contribution sanity must not reuse the venue mark-divergence bound."
fi
grep -q 'max_mint_contribution_divergence_bps' <<<"$mint_contribution_predicate" \
  || fail "Mint contribution sanity must use its distinct immutable policy bound."

printf 'Source boundaries hold.\n'
