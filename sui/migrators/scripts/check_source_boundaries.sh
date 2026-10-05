#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$PACKAGE_DIR/sources"
VAULT_SOURCE="$SOURCE_DIR/vault.move"
BLUEFIN_SOURCE="$SOURCE_DIR/bluefin.move"
CETUS_SOURCE="$SOURCE_DIR/cetus.move"
EVENTS_SOURCE="$SOURCE_DIR/blast_events.move"
VENUE_CONFIG_SOURCE="$SOURCE_DIR/venue_config.move"
LP_FEE_POLICY_SOURCE="$SOURCE_DIR/lp_fee_policy.move"
MIGRATION_MATH_SOURCE="$SOURCE_DIR/migration_math.move"
REWARDS_SOURCE="$SOURCE_DIR/blast_holder_rewards.move"
MERKLE_SOURCE="$SOURCE_DIR/merkle.move"
CONSTANTS_SOURCE="$SOURCE_DIR/constants.move"

fail() {
    echo "Migrator source boundary failed: $1" >&2
    exit 1
}

# Launchpad's comment- and string-stripping Move reader; see move_facts.awk for its records.
MOVE_FACTS_READER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../launchpad/scripts" && pwd)/move_facts.awk"

move_facts() {
    awk -f "$MOVE_FACTS_READER" "$1" || echo "MALFORMED	parser rejected $1"
}

# Emits the exact production declaration of one named struct or enum from move_facts records.
move_production_type() {
    awk -F'\t' -v name="$1" '
        $1 == "TYPE" && $2 == name && $5 == 0 { declaration = $8; found += 1 }
        END { if (found == 1) print declaration }
    '
}

# Succeeds when every literal needle occurs exactly once in stdin, in the given order.
in_order() {
    local text needle rest offset=-1
    text="$(cat)"
    for needle in "$@"; do
        rest="${text//"$needle"/}"
        (( ${#text} - ${#rest} == ${#needle} )) || return 1
        rest="${text%%"$needle"*}"
        (( ${#rest} > offset )) || return 1
        offset=${#rest}
    done
}

require_pattern() {
    local source="$1"
    local pattern="$2"
    local description="$3"

    rg -q "$pattern" "$source" || fail "missing $description"
}

reject_pattern() {
    local pattern="$1"
    local description="$2"

    if rg -q "$pattern" "$SOURCE_DIR"; then
        fail "$description"
    fi
}

move_function_section() {
    local source="$1"
    local name="$2"

    awk -v name="$name" '
        function declaration(line) {
            return line ~ /^[[:space:]]*(public(\(package\))?[[:space:]]+)?(entry[[:space:]]+)?fun[[:space:]]+/
        }
        function target(line) {
            return declaration(line) && line ~ ("fun[[:space:]]+" name "[<(]")
        }
        target($0) { active = 1 }
        active && !target($0) && declaration($0) { exit }
        active { print }
    ' "$source"
}

production_section() {
    sed '/^\/\/ === Test-Only Functions ===/,$d' "$1"
}

require_exact_count() {
    local pattern="$1"
    local required_count="$2"
    local description="$3"
    shift 3
    local count

    count="$(cat "$@" | rg -o -F "$pattern" | wc -l || true)"
    [[ "$count" -eq "$required_count" ]] || fail "$description"
}

# Emits a source's comment-free text with whitespace collapsed (the move_facts NORM record).
move_norm() {
    move_facts "$1" | awk -F'\t' '$1 == "NORM" { print $2 }'
}

# Body of one constants.move macro, whitespace removed.
constant_body() {
    move_facts "$CONSTANTS_SOURCE" | awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name { print $10 }' \
        | tr -d '[:space:]'
}

# Fails with the description unless the text equals stdin exactly.
require_text() {
    [[ "$1" == "$(cat)" ]] || fail "$2"
}

# Pins a source's coded errors, as `code name message` lines in source order, to stdin.
require_errors() {
    local source="$1"
    local description="$2"
    local table

    table="$(rg -U -o --replace '$1 $2 $3' \
        '#\[error\(code = ([0-9]+)\)\]\s*const (\w+): vector<u8> =\s*b"([^"]*)";' "$source" || true)"
    [[ "$table" == "$(cat)" && "$(rg -c '#\[error' "$source")" -eq "$(wc -l <<<"$table")" ]] || \
        fail "$description"
}

# === Package surface ===
#
# The package is exactly these modules, and each file declares only its own, so any new module (a
# future adapter included) fails here until it extends this gate explicitly. No module declares an
# `entry` function, and every module's public and package functions are pinned below with their
# exact signatures, so no helper or type parameter can lend a witness, the reserved creation cap,
# the custodied position, or vault balances to a new caller.
[[ "$(find "$SOURCE_DIR" -mindepth 1 -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ')" \
    == 'blast_events.move blast_fun_migrators.move blast_holder_rewards.move bluefin.move cetus.move constants.move lp_fee_policy.move merkle.move migration_math.move package_admin.move vault.move venue_config.move ' ]] || \
    fail "sources must be exactly the pinned module set; a new module must extend this gate"
for source in "$SOURCE_DIR"/*.move; do
    module="$(basename "$source" .move)"
    facts="$(move_facts "$source")"
    [[ "$facts" != *MALFORMED* ]] || fail "the Move reader rejected ${module}.move"
    [[ "$(awk -F'\t' '$1 == "NORM" { print $2 }' <<<"$facts" | rg -o '\bmodule [^ ;{]+')" \
        == "module blast_fun_migrators::${module}" ]] || \
        fail "${module}.move must declare exactly its own module"
    if awk -F'\t' '$1 == "FN" && $4 == 1 { found = 1 } END { exit !found }' <<<"$facts"; then
        fail "${module}.move must not declare an entry function; every route is a pinned public function"
    fi
    # Production checks skip `#[test_only]` declarations, so the attribute and the test-only
    # marker must agree in both directions.
    if awk -F'\t' '($1 == "FN" && $6 != $7) || ($1 == "TYPE" && $5 != $6) { found = 1 }
        END { exit !found }' <<<"$facts"; then
        fail "${module}.move must keep every #[test_only] declaration, and only those, below its test-only marker"
    fi
done
# The non-private production functions of every module are pinned with their exact signatures:
# visibility, type parameters and their abilities, parameters, and return type. A new public or
# package function, an added type parameter or return value (a generic `Lent: key + store` that
# lends the custodied position or the reserved creation cap), or a changed parameter fails here
# until this pin is extended deliberately.
package_surface="$(for source in "$SOURCE_DIR"/*.move; do
    move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" \
        '$1 == "FN" && $6 == 0 && $7 == 0 && $3 != "private" { print module ":" $3 ":" $9 }'
done | LC_ALL=C sort)"
require_text "$package_surface" \
    "the package's public and package functions must have exactly the pinned signatures" <<'EOF'
blast_events:package:fun auto_liquidity_added( vault_id: ID, meme_amount: u64, quote_amount: u64, meme_pending: u64, quote_pending: u64, )
blast_events:package:fun auto_lp_position_opened(vault_id: ID, position_id: ID)
blast_events:package:fun buyback_burned( vault_id: ID, quote_spent: u64, meme_burned: u64, quote_pending: u64, )
blast_events:package:fun cetus_pool_reserved<Meme, Quote>(pool_creation_cap_id: ID, tick_spacing: u32)
blast_events:package:fun creator_fees_claimed(vault_id: ID, meme_amount: u64, quote_amount: u64)
blast_events:package:fun fee_split_changed( vault_id: ID, old_generation: u64, new_generation: u64, old_fee_split: FeeSplit, new_fee_split: FeeSplit, )
blast_events:package:fun fees_collected( vault_id: ID, generation: u64, gross_meme: u64, gross_quote: u64, protocol_destination: Option<address>, protocol_meme: u64, protocol_quote: u64, creator_meme: u64, creator_quote: u64, auto_lp_meme: u64, auto_lp_quote: u64, rewards_meme: u64, rewards_quote: u64, burn_meme: u64, burn_quote: u64, recipient_meme: vector<u64>, recipient_quote: vector<u64>, )
blast_events:package:fun lp_fee_destination_changed(old_destination: address, new_destination: address)
blast_events:package:fun lp_fee_policy_changed( meme: Option<TypeName>, old_meme_bps: Option<u64>, old_quote_bps: Option<u64>, new_meme_bps: Option<u64>, new_quote_bps: Option<u64>, )
blast_events:package:fun protocol_fees_claimed<Meme, Quote>( vault_id: ID, claimant: address, meme_amount: u64, quote_amount: u64, )
blast_events:package:fun protocol_lp_fees_claimed( vault_id: ID, protocol_destination: address, protocol_meme: u64, protocol_quote: u64, partner_meme: u64, partner_quote: u64, )
blast_events:package:fun reward_paid( round_id: ID, index: u64, beneficiary: address, meme_amount: u64, quote_amount: u64, meme_remaining: u64, quote_remaining: u64, )
blast_events:package:fun round_published( vault_id: ID, round_id: ID, number: u64, start_checkpoint: u64, end_checkpoint: u64, root: vector<u8>, manifest_digest: vector<u8>, leaf_count: u64, meme_amount: u64, quote_amount: u64, meme_unallocated: u64, quote_unallocated: u64, )
blast_events:package:fun vault_created<Meme, Quote, Venue>( vault_id: ID, pool_id: ID, position_id: ID, residual_meme: u64, residual_quote: u64, liquidity: u128, fee_split: FeeSplit, )
blast_fun_migrators:package:fun advance(self: &mut PackageVersion)
blast_fun_migrators:package:fun assert_current(self: &PackageVersion)
blast_fun_migrators:package:fun assert_next(self: &PackageVersion)
blast_holder_rewards:public:fun claim<Meme, Quote>( self: &mut Round<Meme, Quote>, migrators_version: &MigratorsVersion, index: u64, beneficiary: address, meme_amount: u64, quote_amount: u64, proof: vector<vector<u8>>, ctx: &mut TxContext, )
blast_holder_rewards:public:fun publish_round<Meme, Quote>( vault: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, _: &AdminWitness<RewardsAdmin>, number: u64, start_checkpoint: u64, end_checkpoint: u64, root: vector<u8>, manifest_digest: vector<u8>, leaf_count: u64, meme_amount: u64, quote_amount: u64, ctx: &mut TxContext, )
bluefin:public:fun buyback_and_burn<Meme, Quote>( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, admin_witness: &AdminWitness<BuybackAdmin>, currency: &mut Currency<Meme>, bluefin_config: &GlobalConfig, pool: &mut Pool<Meme, Quote>, min_meme_out: u64, clock: &Clock, ctx: &mut TxContext, )
bluefin:public:fun collect_fees<Meme, Quote>( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, policy: &LpFeePolicy, currency: &mut Currency<Meme>, bluefin_config: &GlobalConfig, pool: &mut Pool<Meme, Quote>, clock: &Clock, ctx: &mut TxContext, )
bluefin:public:fun migrate<Meme, Quote>( launch: &mut Launch<Meme, Quote>, migrators_version: &MigratorsVersion, package_version: &PackageVersion, currency: &mut Currency<Meme>, quote_currency: &Currency<Quote>, bluefin_config: &mut GlobalConfig, creation_fee: Coin<SUI>, clock: &Clock, ctx: &mut TxContext, )
bluefin:public:fun new<Meme, Quote>( ticket: LaunchTicket<Meme>, migrators_version: &MigratorsVersion, package_version: &PackageVersion, config: &LaunchConfig, tick_spacing: u32, fee_rate: u64, ): LaunchInitializer<Meme, Quote>
bluefin:public:fun settle_and_update_fee_split<Meme, Quote>( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, policy: &LpFeePolicy, launch: &Launch<Meme, Quote>, curve_fee_cap: &CurveFeeCap<Meme>, currency: &mut Currency<Meme>, bluefin_config: &GlobalConfig, pool: &mut Pool<Meme, Quote>, proposed: FeeSplit, clock: &Clock, ctx: &mut TxContext, )
cetus:public:fun buyback_and_burn<Meme, Quote, CoinA, CoinB>( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, admin_witness: &AdminWitness<BuybackAdmin>, currency: &mut Currency<Meme>, cetus_config: &GlobalConfig, pool: &mut Pool<CoinA, CoinB>, min_meme_out: u64, clock: &Clock, ctx: &mut TxContext, )
cetus:public:fun collect_fees<Meme, Quote, CoinA, CoinB>( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, policy: &LpFeePolicy, currency: &mut Currency<Meme>, cetus_config: &GlobalConfig, burn_manager: &BurnManager, pool: &mut Pool<CoinA, CoinB>, clock: &Clock, ctx: &mut TxContext, )
cetus:public:fun migrate<Meme, Quote, CoinA, CoinB>( launch: &mut Launch<Meme, Quote>, migrators_version: &MigratorsVersion, package_version: &PackageVersion, currency: &mut Currency<Meme>, venue_config: &VenueConfig, cetus_config: &GlobalConfig, pools: &mut Pools, burn_manager: &mut BurnManager, clock: &Clock, ctx: &mut TxContext, )
cetus:public:fun new<Meme, Quote>( ticket: LaunchTicket<Meme>, migrators_version: &MigratorsVersion, package_version: &PackageVersion, config: &LaunchConfig, venue_config: &mut VenueConfig, cetus_config: &GlobalConfig, pools: &mut Pools, tick_spacing: u32, ctx: &mut TxContext, ): LaunchInitializer<Meme, Quote>
cetus:public:fun settle_and_update_fee_split<Meme, Quote, CoinA, CoinB>( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, policy: &LpFeePolicy, launch: &Launch<Meme, Quote>, curve_fee_cap: &CurveFeeCap<Meme>, currency: &mut Currency<Meme>, cetus_config: &GlobalConfig, burn_manager: &BurnManager, pool: &mut Pool<CoinA, CoinB>, proposed: FeeSplit, clock: &Clock, ctx: &mut TxContext, )
constants:package:fun auto_lp_margin(): u256
constants:package:fun bluefin_max_fee_rate(): u64
constants:package:fun bluefin_max_tick_spacing(): u32
constants:package:fun digest_length(): u64
constants:package:fun max_reward_leaves(): u64
constants:package:fun max_swap_sqrt_price(): u128
constants:package:fun min_swap_sqrt_price(): u128
constants:package:fun q128_shift(): u8
constants:package:fun q64_shift(): u8
constants:package:fun sqrt_upper_bound_shift(): u8
lp_fee_policy:package:fun protocol_destination(self: &LpFeePolicy): address
lp_fee_policy:package:fun shares<Meme>(self: &LpFeePolicy): (Bps, Bps)
lp_fee_policy:public:fun clear_coin_shares<Meme>( self: &mut LpFeePolicy, migrators_version: &MigratorsVersion, _: &AdminWitness<FeeAdmin>, )
lp_fee_policy:public:fun set_coin_shares<Meme>( self: &mut LpFeePolicy, migrators_version: &MigratorsVersion, _: &AdminWitness<FeeAdmin>, meme_bps: Bps, quote_bps: Bps, )
lp_fee_policy:public:fun set_default_shares( self: &mut LpFeePolicy, migrators_version: &MigratorsVersion, _: &AdminWitness<FeeAdmin>, meme_bps: Bps, quote_bps: Bps, )
lp_fee_policy:public:fun set_protocol_destination( self: &mut LpFeePolicy, migrators_version: &MigratorsVersion, _: &AdminWitness<TreasuryAdmin>, destination: address, )
merkle:package:fun leaf( vault: ID, round: u64, index: u64, beneficiary: address, meme: u64, quote: u64, ): vector<u8>
merkle:package:fun verify( root: vector<u8>, mut digest: vector<u8>, mut index: u64, leaves: u64, proof: &vector<vector<u8>>, ): bool
migration_math:package:fun auto_lp_fixed_side( sqrt_lower: u128, sqrt_price: u128, sqrt_upper: u128, amount_a: u64, amount_b: u64, ): (bool, u64)
migration_math:package:fun sqrt_price_x64( meme_amount: u64, quote_amount: u64, meme_is_coin_a: bool, ): u128
package_admin:public:fun authorize_upgrade( self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, digest: vector<u8>, ): UpgradeTicket
package_admin:public:fun commit_upgrade_and_advance( self: &mut PackageAdmin, package_version: &mut PackageVersion, _: &AdminWitness<UpgradeAdmin>, receipt: UpgradeReceipt, )
package_admin:public:fun wrap(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext)
vault:package:fun assert_fee_split_update<Meme, Quote>( self: &LpVault<Meme, Quote>, launch: &Launch<Meme, Quote>, curve_fee_cap: &CurveFeeCap<Meme>, proposed: FeeSplit, )
vault:package:fun attach_auto_lp_position<Meme, Quote, Venue, Position: key + store>( self: &mut LpVault<Meme, Quote>, _venue: &Venue, position: Position, )
vault:package:fun auto_lp_position< Meme, Quote, Venue, Position: key + store, >( self: &LpVault<Meme, Quote>, _venue: &Venue, ): &Position
vault:package:fun auto_lp_position_mut< Meme, Quote, Venue, Position: key + store, >( self: &mut LpVault<Meme, Quote>, _venue: &Venue, ): &mut Position
vault:package:fun burn_buyback<Meme, Quote>( self: &mut LpVault<Meme, Quote>, currency: &mut Currency<Meme>, meme: Balance<Meme>, unspent_quote: Balance<Quote>, quote_in: u64, min_meme_out: u64, ctx: &mut TxContext, )
vault:package:fun create<Meme, Quote, Venue, Position: key + store>( launch: &Launch<Meme, Quote>, venue: &Venue, pool_id: ID, position: Position, liquidity: u128, protocol_meme_residual: Balance<Meme>, protocol_quote_residual: Balance<Quote>, ctx: &mut TxContext, )
vault:package:fun fund_round<Meme, Quote>( self: &mut LpVault<Meme, Quote>, end_checkpoint: u64, meme_amount: u64, quote_amount: u64, ): (Balance<Meme>, Balance<Quote>)
vault:package:fun has_auto_lp_position<Meme, Quote, Venue>( self: &LpVault<Meme, Quote>, _venue: &Venue, ): bool
vault:package:fun keep_auto_lp<Meme, Quote>( self: &mut LpVault<Meme, Quote>, added_meme: u64, added_quote: u64, meme: Balance<Meme>, quote: Balance<Quote>, )
vault:package:fun last_checkpoint<Meme, Quote>(self: &LpVault<Meme, Quote>): Option<u64>
vault:package:fun next_round<Meme, Quote>(self: &LpVault<Meme, Quote>): u64
vault:package:fun pay<T>( balance: &mut Balance<T>, amount: u64, destination: address, ctx: &mut TxContext, )
vault:package:fun pool_id<Meme, Quote>(self: &LpVault<Meme, Quote>): ID
vault:package:fun position_mut< Meme, Quote, Venue, Position: key + store, >( self: &mut LpVault<Meme, Quote>, _venue: &Venue, ): &mut Position
vault:package:fun rewards_balances<Meme, Quote>(self: &LpVault<Meme, Quote>): (u64, u64)
vault:package:fun split_fees<Meme, Quote>( self: &mut LpVault<Meme, Quote>, policy: &LpFeePolicy, currency: &mut Currency<Meme>, mut meme: Balance<Meme>, mut quote: Balance<Quote>, ctx: &mut TxContext, )
vault:package:fun take_auto_lp<Meme, Quote>( self: &mut LpVault<Meme, Quote>, ): (Balance<Meme>, Balance<Quote>)
vault:package:fun take_buyback_quote<Meme, Quote>( self: &mut LpVault<Meme, Quote>, _: &AdminWitness<BuybackAdmin>, ): Balance<Quote>
vault:package:fun update_fee_split<Meme, Quote>( self: &mut LpVault<Meme, Quote>, proposed: FeeSplit, )
vault:public:fun claim_creator_fees<Meme, Quote>( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, launch: &Launch<Meme, Quote>, curve_fee_cap: &CurveFeeCap<Meme>, ctx: &mut TxContext, ): (Coin<Meme>, Coin<Quote>)
vault:public:fun claim_protocol_fees<Meme, Quote>( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, _: &AdminWitness<TreasuryAdmin>, ctx: &mut TxContext, ): (Coin<Meme>, Coin<Quote>)
vault:public:fun claim_protocol_lp_fees_with_partner<Meme, Quote>( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, policy: &LpFeePolicy, partner: &Partner, clock: &Clock, ctx: &mut TxContext, )
venue_config:package:fun add_object<Key: copy + drop + store, Object: key + store>( self: &mut VenueConfig, key: Key, object: Object, )
venue_config:package:fun object<Key: copy + drop + store, Object: key + store>( self: &VenueConfig, key: Key, ): &Object
EOF
# `blast_admin::upgrade_custody::new` requires this package's Publisher and its never-upgraded
# cap, and at version one `BLAST_FUN_MIGRATORS` is the package's only one-time witness, so custody
# declares no publisher check or error of its own.
if rg -q '#\[error|\bconst E\w*|from_module' "$SOURCE_DIR/package_admin.move"; then
    fail "package admin must leave publisher validation to blast_admin's upgrade custody"
fi
# Every rename in the package is pinned. The rules here match protected types and calls by name,
# so a type, function, or method alias under a new name (`Witness as Seal`, a `use fun` that
# shadows `assert_current`) would hide them; each alias must be extended here deliberately.
package_aliases="$(for source in "$SOURCE_DIR"/*.move; do
    move_norm "$source" | rg -o -P '[\w:]+ as (?!u(8|16|32|64|128|256)\b(?!\.))[\w.]+' \
        | sed "s|^|$(basename "$source" .move): |"
done | LC_ALL=C sort)"
require_text "$package_aliases" \
    "every rename and method alias in the package must be exactly the pinned set" <<'EOF'
blast_holder_rewards: blast_fun_migrators::PackageVersion as MigratorsVersion
blast_holder_rewards: vault::pay as Balance.pay
bluefin: blast_fun_migrators::PackageVersion as MigratorsVersion
bluefin: collect_position_fees as LpVault.collect_position_fees
bluefin: compound as LpVault.compound
bluefin: settle_fees as LpVault.settle_fees
cetus: add_liquidity as LpVault.add_liquidity
cetus: blast_fun_migrators::PackageVersion as MigratorsVersion
cetus: collect_position_fees as LpVault.collect_position_fees
cetus: compound as LpVault.compound
cetus: pool_creation_cap as VenueConfig.pool_creation_cap
cetus: settle_fees as LpVault.settle_fees
lp_fee_policy: blast_fun_migrators::PackageVersion as MigratorsVersion
vault: blast_fun_migrators::PackageVersion as MigratorsVersion
vault: dynamic_object_field::add as UID.add_dynamic_object_field
vault: dynamic_object_field::borrow as UID.dynamic_object_field
vault: dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut
vault: dynamic_object_field::exists as UID.has_dynamic_object_field
vault: pay as Balance.pay
vault: pay_all as Balance.pay_all
venue_config: dynamic_object_field::add as UID.add_dynamic_object_field
venue_config: dynamic_object_field::borrow as UID.dynamic_object_field
EOF
# `MigratorsVersion` must name this package's generation, not the launchpad's.
for module in lp_fee_policy vault blast_holder_rewards bluefin cetus; do
    [[ "$(move_norm "$SOURCE_DIR/${module}.move" | rg -o 'use [^;]*\bMigratorsVersion\b[^;]*;' \
        | rg -c '^use blast_fun_migrators::\{')" == 1 ]] || \
        fail "${module}.move must import MigratorsVersion once, from this package's marker module"
done
# Every source error is an explicitly coded constant, so the per-module code pins see them all.
if rg -q '#\[error\]|\bconst E\w*\s*:\s*u(8|16|32|64|128|256)\b' "$SOURCE_DIR"; then
    fail "source errors must be #[error(code = N)] constants, never uncoded or bare integers"
fi

# === Release adapter matrix ===
#
# Cetus and Bluefin are the release's only adapters. An adapter reaches the launchpad migration
# seams (starting a launch, the initializer's treasury-capability loan, and begin and complete
# migration) only by constructing its own sealed `Witness()`, so the matrix is exactly the modules
# that declare a witness and name those seams (a call, an alias, or an import alike). Each starts
# its launches through `launch::new` and completes its migration into a vault it creates, with its
# position attached, under its own venue marker; only Cetus needs local normalized venue
# interfaces. A future adapter extends this matrix explicitly.
matrix_witness_modules=""
matrix_seam_modules=""
for source in "$SOURCE_DIR"/*.move; do
    module="$(basename "$source" .move)"
    facts="$(move_facts "$source")"
    if awk -F'\t' '$1 == "TYPE" && $2 == "Witness" { found = 1 } END { exit !found }' <<<"$facts"; then
        matrix_witness_modules+="$module"$'\n'
    fi
    if awk -F'\t' '$1 == "NORM" { print $2 }' <<<"$facts" | rg -q \
        '\b(launch::new|treasury_cap_mut)\b|launch\.migrate\('; then
        matrix_seam_modules+="$module"$'\n'
    fi
done
matrix_witness_modules="$(LC_ALL=C sort <<<"$matrix_witness_modules" | tr '\n' ' ' | sed 's/^ *//')"
matrix_seam_modules="$(LC_ALL=C sort <<<"$matrix_seam_modules" | tr '\n' ' ' | sed 's/^ *//')"
[[ "$matrix_witness_modules" == 'bluefin cetus ' ]] || \
    fail "only Cetus and Bluefin may declare a migration witness (found: ${matrix_witness_modules:-none})"
[[ "$matrix_seam_modules" == 'bluefin cetus ' ]] || \
    fail "only Cetus and Bluefin may reach the launchpad migration seams (found: ${matrix_seam_modules:-none})"
for module in $matrix_witness_modules; do
    custody_body="$(move_facts "$SOURCE_DIR/${module}.move" \
        | awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "vault::create(") > 0 { print $10 }' \
        | tr -d '[:space:]')"
    in_order 'vault::create(launch,&Venue(),' <<<"$custody_body" || \
        fail "${module} must lock the migration in a vault it creates under its own venue marker"
    start_body="$(move_facts "$SOURCE_DIR/${module}.move" \
        | awk -F'\t' '$1 == "FN" && $2 == "new" && $6 == 0 { print $10 }' | tr -d '[:space:]')"
    in_order 'migrators_version.assert_current();' \
        'launch::new<Meme,Quote,_>(ticket,package_version,config,Witness(),tick_spacing,' \
        <<<"$start_body" || \
        fail "${module}::new must check this package's generation, then start the launch under its own witness"
done
[[ -n "$(find "$PACKAGE_DIR/interfaces" -mindepth 1 -maxdepth 1 -printf '%f\n')" \
    && -z "$(find "$PACKAGE_DIR/interfaces" -mindepth 1 -maxdepth 1 -printf '%f\n' \
        | rg -v '^cetus(_[a-z_]+)?$')" ]] || \
    fail "only Cetus packages may have local venue interfaces; an excluded venue keeps no interface"
# A sealed witness never leaves its adapter: no adapter function, whatever its visibility, names
# the witness in its signature, so none returns it or fills a caller's container with it.
for module in $matrix_witness_modules; do
    if move_facts "$SOURCE_DIR/${module}.move" | awk -F'\t' '
        $1 == "FN" && $9 ~ /[^A-Za-z0-9_]Witness([^A-Za-z0-9_]|$)/ { found = 1 }
        END { exit !found }'; then
        fail "${module}::Witness must never appear in any ${module} function signature"
    fi
done

# Migration math is the venues' shared seed-price derivation and auto-LP side selection, and
# nothing else: pure package-only arithmetic.
[[ "$(rg -o '^public\(package\) fun \w+' "$MIGRATION_MATH_SOURCE" | LC_ALL=C sort | tr '\n' ';')" \
    == 'public(package) fun auto_lp_fixed_side;public(package) fun sqrt_price_x64;' ]] || \
    fail "migration math must expose exactly its package-only seed price and auto-LP side selection"
if rg -q '^public fun |^entry fun |^public entry fun ' "$MIGRATION_MATH_SOURCE"; then
    fail "migration math must not expose a public transaction or composition ABI"
fi
require_pattern "$MIGRATION_MATH_SOURCE" \
    'module blast_fun_migrators::migration_math;' \
    'migrator-owned migration math module'
# Seed balances come only from `launch.migrate`, which hands off a positive amount of each asset,
# so the math declares no errors of its own.
if rg -q '#\[error|\bconst E\w*' "$MIGRATION_MATH_SOURCE"; then
    fail "migration math must declare no errors; its seed balances are the launch's positive hand-off"
fi
require_pattern "$MIGRATION_MATH_SOURCE" \
    'integer_sqrt\(ratio_q128\(meme_amount, quote_amount, meme_is_coin_a\)\)' \
    'exact Q128 price derivation'
# Auto-LP side selection adds nothing unless the price is strictly inside the range, checked first
# so every later subtraction is positive, and then prefers fixing coin A. Each side's check needs
# positive liquidity (below 2^128 when fixing A) and leaves the pinned margin of the other unused;
# an empty side yields zero liquidity or a need it cannot meet.
math_body() {
    move_facts "$MIGRATION_MATH_SOURCE" | awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name { print $10 }' \
        | tr -d '[:space:]'
}
[[ "$(constant_body auto_lp_margin)" == '2' ]] \
    && [[ "$(math_body auto_lp_fixed_side)" == 'if(sqrt_price<=sqrt_lower||sqrt_price>=sqrt_upper)return(true,0);let(lower,price,upper)=(sqrt_lowerasu256,sqrt_priceasu256,sqrt_upperasu256);if(can_fix_a(lower,price,upper,amount_a,amount_b))(true,amount_a)elseif(can_fix_b(lower,price,upper,amount_a,amount_b))(false,amount_b)else(true,0)' ]] \
    && [[ "$(math_body can_fix_a)" == 'letone=1u256<<constants::q64_shift!();letliquidity=(amount_aasu256)*(price*upper/one)/(upper-price);if(liquidity==0||liquidity>=(1u256<<constants::q128_shift!()))returnfalse;letneeded_b=(liquidity*(price-lower)).div_ceil(one);needed_b+constants::auto_lp_margin!()<=(amount_basu256)' ]] \
    && [[ "$(math_body can_fix_b)" == 'letliquidity=((amount_basu256)<<constants::q64_shift!())/(price-lower);if(liquidity==0)returnfalse;letneeded_a=(liquidity<<constants::q64_shift!()).div_ceil(price)-(liquidity<<constants::q64_shift!())/upper;needed_a+constants::auto_lp_margin!()<=(amount_aasu256)' ]] || \
    fail "auto-LP side selection must first skip out-of-range prices, prefer coin A, and keep a two-atom margin"
if rg -q '\b(blast_fun::(constants|errors)|UID|key|Balance|Coin|TxContext|transfer::|blast_events::|RuntimeConfig)\b' \
    "$MIGRATION_MATH_SOURCE"; then
    fail "migration math must remain a pure migrator-owned arithmetic module"
fi
if rg -U -q 'use blast_fun::\{[^}]*migration_math' "$SOURCE_DIR"; then
    fail "venue modules must use migrator-owned migration math"
fi

# === Events ===
#
# Every replay fact is one direct, strongly typed payload with exactly one emitter function.
[[ "$(move_facts "$EVENTS_SOURCE" | awk -F'\t' '$1 == "TYPE" && $5 == 0 { print $2 }' \
    | LC_ALL=C sort | tr '\n' ' ')" \
    == 'AutoLiquidityAdded AutoLpPositionOpened BuybackBurned CetusPoolReserved CreatorFeesClaimed FeeSplitChanged FeesCollected LpFeeDestinationChanged LpFeePolicyChanged ProtocolFeesClaimed ProtocolLpFeesClaimed RewardPaid RoundPublished VaultCreated ' ]] || \
    fail "blast_events.move must declare exactly the pinned event payloads"
for payload in AutoLiquidityAdded AutoLpPositionOpened BuybackBurned CetusPoolReserved CreatorFeesClaimed \
    FeeSplitChanged FeesCollected LpFeeDestinationChanged LpFeePolicyChanged ProtocolFeesClaimed \
    ProtocolLpFeesClaimed RewardPaid RoundPublished VaultCreated; do
    [[ "$(rg -c "sui::event::emit\(${payload} \{" "$EVENTS_SOURCE" || true)" -eq 1 ]] || \
        fail "${payload} must be emitted directly by exactly one helper"
done
[[ "$(rg -o 'sui::event::emit' "$EVENTS_SOURCE" | wc -l)" -eq 14 ]] || \
    fail "blast_events.move must emit exactly the fourteen pinned payloads"
if rg -q 'sui::event::emit' "$SOURCE_DIR" --glob '*.move' --glob '!blast_events.move'; then
    fail "state modules must emit only through typed events helpers"
fi
require_pattern "$EVENTS_SOURCE" 'type_name::with_original_ids<Venue>' 'venue type facts'
require_pattern "$EVENTS_SOURCE" 'type_name::with_original_ids<Meme>' 'Meme type facts'
require_pattern "$EVENTS_SOURCE" 'type_name::with_original_ids<Quote>' 'Quote type facts'
require_pattern "$EVENTS_SOURCE" 'position_id: ID' 'stable position identity'
reject_pattern 'protocol_meme_fee_total|creator_meme_fee_total|protocol_quote_fee_total|creator_quote_fee_total' \
    'derivable fee totals are forbidden in migrator events'
if rg -q '\b(VenueTierUpdated|venue_tier_updated|RoutesChanged|routes_changed|PolicySnapshot)\b' \
    "$SOURCE_DIR"; then
    fail "venue tiers and fee routes are launch settings and the Blast share is read live; no admin tier, route, or snapshot record may return"
fi
# Each replay fact has exactly one writer: the vault's split, buyback, auto-LP, split update,
# custody, and claims (the partner claim included); the holder-reward publication and claim; and the policy's destination and
# share setters.
for emitter in \
    'fees_collected:vault:split_fees' \
    'buyback_burned:vault:burn_buyback' \
    'auto_liquidity_added:vault:keep_auto_lp' \
    'auto_lp_position_opened:vault:attach_auto_lp_position' \
    'fee_split_changed:vault:update_fee_split' \
    'creator_fees_claimed:vault:claim_creator_fees' \
    'protocol_fees_claimed<Meme, Quote>:vault:claim_protocol_fees' \
    'protocol_lp_fees_claimed:vault:claim_protocol_lp_fees_with_partner' \
    'vault_created<Meme, Quote, Venue>:vault:new' \
    'round_published:blast_holder_rewards:publish_round' \
    'reward_paid:blast_holder_rewards:claim' \
    'lp_fee_destination_changed:lp_fee_policy:set_protocol_destination' \
    'lp_fee_policy_changed:lp_fee_policy:clear_coin_shares set_coin_shares set_default_shares'; do
    event="${emitter%%:*}"
    rest="${emitter#*:}"
    writers="$(for source in "$SOURCE_DIR"/*.move; do
        [[ "$source" == "$EVENTS_SOURCE" ]] && continue
        move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" -v needle="blast_events::${event}(" \
            '$1 == "FN" && $6 == 0 && index($10, needle) > 0 { print module ":" $2 }'
    done | LC_ALL=C sort | tr '\n' ' ')"
    expected="$(for writer in ${rest#*:}; do echo "${rest%%:*}:${writer}"; done | LC_ALL=C sort | tr '\n' ' ')"
    [[ "$writers" == "$expected" ]] || \
        fail "${event%%<*} must be emitted only by ${expected}(found: ${writers:-none})"
done

# === Vault ===
#
# The vault custodies one position (and, on venues that need it, one auto-LP position), the
# protocol migration residuals, and the balances every LP-fee collection is split into. Pinning the
# whole layout, the constructor, the two public claims, the immutable-reference reads, and the
# absence of any object-owned coin receipt keeps a new vault from carrying a second fee path.
VAULT_FACTS="$(move_facts "$VAULT_SOURCE")"
[[ "$VAULT_FACTS" != *MALFORMED* ]] || fail "the Move reader rejected vault.move"
[[ "$(move_production_type LpVault <<<"$VAULT_FACTS")" \
    == 'struct LpVault<phantom Meme, phantom Quote> has key { id: UID, pool_id: ID, partner_id: Option<ID>, protocol_meme_residual: Balance<Meme>, protocol_quote_residual: Balance<Quote>, unpaid_protocol_meme: Balance<Meme>, unpaid_protocol_quote: Balance<Quote>, generation: u64, fee_split: FeeSplit, creator_meme: Balance<Meme>, creator_quote: Balance<Quote>, auto_lp_meme: Balance<Meme>, auto_lp_quote: Balance<Quote>, rewards_meme: Balance<Meme>, rewards_quote: Balance<Quote>, burn_quote: Balance<Quote>, next_round: u64, last_checkpoint: Option<u64>, }' ]] || \
    fail "LpVault must hold only its position key space, the pool binding, the launch's partner, the protocol residuals, Blast's LP fees held for the partner, its fee split and generation, the split balances, and the round cursor"
vault_body() {
    awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name && $6 == 0 { print $10 }' <<<"$VAULT_FACTS" \
        | tr -d '[:space:]' | sed 's/,)/)/g'
}
# The vault is born shared with its real pool binding and its position already attached: `create`
# only shares what `new` builds, and `new` copies the launch's fee split at generation zero with
# empty balances and no round.
[[ "$(vault_body create)" \
    == 'transfer::share_object(new(launch,venue,pool_id,position,liquidity,protocol_meme_residual,protocol_quote_residual,ctx));' ]] \
    && [[ "$(vault_body new)" \
    == 'assert!(liquidity>0,EZeroLiquidity);letposition_id=object::id(&position);letmutvault=LpVault{id:object::new(ctx),pool_id,partner_id:launch.partner_id(),protocol_meme_residual,protocol_quote_residual,unpaid_protocol_meme:balance::zero(),unpaid_protocol_quote:balance::zero(),generation:0,fee_split:launch.lp_fee_split(),creator_meme:balance::zero(),creator_quote:balance::zero(),auto_lp_meme:balance::zero(),auto_lp_quote:balance::zero(),rewards_meme:balance::zero(),rewards_quote:balance::zero(),burn_quote:balance::zero(),next_round:0,last_checkpoint:option::none(),};vault.id.add_dynamic_object_field(PositionKey<Venue>(),position);blast_events::vault_created<Meme,Quote,Venue>(vault.id.to_inner(),pool_id,position_id,vault.protocol_meme_residual.value(),vault.protocol_quote_residual.value(),liquidity,vault.fee_split);vault' ]] || \
    fail "vault::create must share only what vault::new builds: the launch's partner and fee split at generation zero, empty balances, no round, and the attached position"
[[ "$(awk -F'\t' '$1 == "FN" && $3 == "public" && $6 == 0 { print $2 }' <<<"$VAULT_FACTS" \
    | LC_ALL=C sort | tr '\n' ' ')" \
    == 'claim_creator_fees claim_protocol_fees claim_protocol_lp_fees_with_partner ' ]] || \
    fail "the protocol, partner, and creator claims must be the vault's only public functions"
# Every collection is split exactly and at once: Blast's live share for this Meme rounds up and
# pays the live destination, or waits for the partner claim when the launch named a partner; the rest is apportioned by the vault's fee split into the creator,
# auto-LP, and rewards balances, the burn share's Meme is burned and its Quote kept for buyback,
# every recipient is paid, nothing stays behind, and FeesCollected is the last fact. A zero
# collection returns before anything moves or is announced.
in_order \
    'letgross_meme=meme.value();letgross_quote=quote.value();if(gross_meme==0&&gross_quote==0){meme.destroy_zero();quote.destroy_zero();return};' \
    'let(meme_share,quote_share)=policy.shares<Meme>();' \
    'letprotocol_meme=meme_share.apply_up(gross_meme);' \
    'letprotocol_quote=quote_share.apply_up(gross_quote);' \
    'let(creator_meme,auto_lp_meme,rewards_meme,burn_meme,recipient_meme)=self.fee_split.apportion_fee_split(gross_meme-protocol_meme);' \
    'let(creator_quote,auto_lp_quote,rewards_quote,burn_quote,recipient_quote)=self.fee_split.apportion_fee_split(gross_quote-protocol_quote);' \
    'letprotocol_destination=self.pay_or_hold_protocol_lp_fees(meme.split(protocol_meme),quote.split(protocol_quote),policy,ctx);' \
    'self.creator_meme.join(meme.split(creator_meme));self.creator_quote.join(quote.split(creator_quote));' \
    'self.auto_lp_meme.join(meme.split(auto_lp_meme));self.auto_lp_quote.join(quote.split(auto_lp_quote));' \
    'self.rewards_meme.join(meme.split(rewards_meme));self.rewards_quote.join(quote.split(rewards_quote));' \
    'burn(currency,meme.split(burn_meme),ctx);self.burn_quote.join(quote.split(burn_quote));' \
    'meme.pay(recipient_meme[i],recipients[i].destination(),ctx);quote.pay(recipient_quote[i],recipients[i].destination(),ctx);});' \
    'meme.destroy_zero();quote.destroy_zero();blast_events::fees_collected(' \
    <<<"$(vault_body split_fees)" \
    && [[ "$(vault_body split_fees)" =~ blast_events::fees_collected\([^\;]*\)\;$ ]] || \
    fail "vault splits must pay (or hold for the partner) the round-up live Blast share and every recipient immediately, credit the three balances, burn the burn Meme and keep the burn Quote, keep nothing else, and emit FeesCollected last"
# Blast's share goes to the live destination at once, unless the launch named a partner: then it
# waits in the vault, and nothing but the claim below takes it out. The claim needs no authority,
# since both payees are fixed: after the generation and the launch's partner, it pays the partner
# its cut in force and the live destination the rest, leaving nothing held. Holding nothing, it
# returns before anything moves or is announced. The vault's partner is the launch's, for good.
[[ "$(vault_body pay_or_hold_protocol_lp_fees)" \
    == 'if(self.partner_id.is_some()){self.unpaid_protocol_meme.join(protocol_meme);self.unpaid_protocol_quote.join(protocol_quote);returnoption::none()};letprotocol_destination=policy.protocol_destination();protocol_meme.pay_all(protocol_destination,ctx);protocol_quote.pay_all(protocol_destination,ctx);option::some(protocol_destination)' ]] \
    && [[ "$(vault_body pay_all)" == 'letamount=balance.value();balance.pay(amount,destination,ctx);balance.destroy_zero();' ]] \
    && in_order \
        'migrators_version.assert_current();' \
        'assert!(self.partner_id.contains(&object::id(partner)),EPartnerMismatch);' \
        'if(self.unpaid_protocol_meme.value()==0&&self.unpaid_protocol_quote.value()==0)return;' \
        'letprotocol_destination=policy.protocol_destination();' \
        'letmutprotocol_meme=self.unpaid_protocol_meme.withdraw_all();letmutprotocol_quote=self.unpaid_protocol_quote.withdraw_all();' \
        'letpartner_meme=partner.pay(&mutprotocol_meme,clock);letpartner_quote=partner.pay(&mutprotocol_quote,clock);' \
        'protocol_meme.pay_all(protocol_destination,ctx);protocol_quote.pay_all(protocol_destination,ctx);' \
        'blast_events::protocol_lp_fees_claimed(self.id.to_inner(),protocol_destination,paid_meme,paid_quote,partner_meme,partner_quote);' \
        <<<"$(vault_body claim_protocol_lp_fees_with_partner)" \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "self.unpaid_protocol_") > 0 { print $2 }' <<<"$VAULT_FACTS" \
        | LC_ALL=C sort | tr '\n' ' ')" == 'claim_protocol_lp_fees_with_partner pay_or_hold_protocol_lp_fees ' ]] \
    && ! rg -q '\.partner_id\s*=' "$VAULT_SOURCE" || \
    fail "Blast's share must wait only on a partnered vault, and only the permissionless partner claim may pay it: the partner its cut, then the live destination the rest"
# A buyback takes the whole burn Quote only under the buyback-admin role, and burns only Meme that
# reaches the admin's minimum; what the pool did not take goes back to wait.
[[ "$(vault_body take_buyback_quote)" == 'assert!(self.burn_quote.value()>0,ENoBuybackQuote);self.burn_quote.withdraw_all()' ]] \
    && in_order \
        'letmeme_burned=meme.value();' \
        'assert!(meme_burned>=min_meme_out,EBuybackBelowMinimum);' \
        'letquote_spent=quote_in-unspent_quote.value();' \
        'burn(currency,meme,ctx);' \
        'self.burn_quote.join(unspent_quote);' \
        'blast_events::buyback_burned(' \
        <<<"$(vault_body burn_buyback)" \
    && [[ "$(vault_body burn)" == 'if(currency.is_supply_burn_only())returncurrency.burn_balance(meme);letamount=meme.value();meme.pay(amount,@0x0,ctx);meme.destroy_zero();' ]] || \
    fail "buybacks must require the buyback-admin role and a nonzero burn Quote, burn only Meme at or above the minimum, and keep the unspent Quote"
[[ "$(vault_body take_auto_lp)" == '(self.auto_lp_meme.withdraw_all(),self.auto_lp_quote.withdraw_all())' ]] \
    && [[ "$(vault_body keep_auto_lp)" == 'self.auto_lp_meme.join(meme);self.auto_lp_quote.join(quote);if(added_meme==0&&added_quote==0)return;blast_events::auto_liquidity_added(self.id.to_inner(),added_meme,added_quote,self.auto_lp_meme.value(),self.auto_lp_quote.value());' ]] || \
    fail "auto-LP must take every waiting unit, keep whatever the venue did not take, and announce only a nonzero addition"
# A split update requires the launch's live curve-fee cap and a changed proposal, checked apart
# from the commit so the adapters check before collecting, settle the current split, and only then
# commit the next generation.
[[ "$(vault_body assert_fee_split_update)" \
    == 'launch.assert_curve_fee_cap(curve_fee_cap);assert!(proposed!=self.fee_split,EFeeSplitUnchanged);' ]] \
    && in_order \
        'letold_generation=self.generation;' \
        'letold_fee_split=self.fee_split;' \
        'self.fee_split=proposed;' \
        'self.generation=old_generation+1;' \
        'blast_events::fee_split_changed(' \
        <<<"$(vault_body update_fee_split)" \
    && [[ "$(vault_body update_fee_split)" == 'letold_generation=self.generation;'* ]] || \
    fail "vault split updates must check the live curve-fee cap and a new proposal apart from the commit, which only records the next generation"
in_order \
    'migrators_version.assert_current();' \
    'launch.assert_curve_fee_cap(curve_fee_cap);' \
    'assert!(self.creator_meme.value()>0||self.creator_quote.value()>0,ENoCreatorFees);' \
    'letmeme=self.creator_meme.withdraw_all().into_coin(ctx);' \
    'letquote=self.creator_quote.withdraw_all().into_coin(ctx);' \
    'blast_events::creator_fees_claimed(' \
    <<<"$(vault_body claim_creator_fees)" || \
    fail "creator claims must check the generation, then the live curve-fee cap, then a nonzero balance, and pay the whole creator balance"
[[ "$(vault_body fund_round)" == 'self.next_round=self.next_round+1;self.last_checkpoint=option::some(end_checkpoint);(self.rewards_meme.split(meme_amount),self.rewards_quote.split(quote_amount))' ]] || \
    fail "vault::fund_round must advance the round cursor and reserve only from the rewards balances"
# Each balance and cursor has exactly its pinned writers.
for field in 'fee_split generation:update_fee_split' 'next_round last_checkpoint:fund_round'; do
    writers="$(awk -F'\t' -v fields="${field%%:*}" '
        $1 == "FN" && $6 == 0 {
            count = split(fields, names, " ")
            for (i = 1; i <= count; i++) if (index($10, "self." names[i] " = ") > 0) { print $2; next }
        }' <<<"$VAULT_FACTS" | LC_ALL=C sort -u | tr '\n' ' ')"
    [[ "$writers" == "${field#*:} " ]] || \
        fail "only vault::${field#*:} may assign ${field%%:*} (found: ${writers:-none})"
done
for balance in creator auto_lp rewards burn; do
    [[ "$(awk -F'\t' -v needle="self.${balance}_" '$1 == "FN" && $6 == 0 && index($10, needle) > 0 { print $2 }' \
        <<<"$VAULT_FACTS" | LC_ALL=C sort | tr '\n' ' ')" == "$(case "$balance" in
            creator) echo 'claim_creator_fees split_fees ' ;;
            auto_lp) echo 'keep_auto_lp split_fees take_auto_lp ' ;;
            rewards) echo 'fund_round rewards_balances split_fees ' ;;
            burn) echo 'burn_buyback split_fees take_buyback_quote ' ;;
        esac)" ]] || \
        fail "the ${balance} balances must be touched only by the split and their exits"
done
[[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "transfer::public_transfer(") > 0 { print $2 }' <<<"$VAULT_FACTS")" \
    == 'pay' ]] || \
    fail "vault payments must go through its one pay helper"
if rg -q 'transfer::(public_)?receive|Receiving<' "$SOURCE_DIR"; then
    fail "migrators must not receive object-owned coins; LP fees leave only by the vault's split"
fi
# The curve-fee cap is the creator's split-update and creator-claim authority, and only the launch
# that issued it can check it: migrators imports only its type, the vault checks it through the
# launch before each use, and adapters only hand it to the vault's split-update check.
curve_fee_cap_uses="$(for source in "$SOURCE_DIR"/*.move; do
    move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" '$1 == "FN" && $6 == 0 {
        body = $10; gsub(/[[:space:]]/, "", body)
        while (match(body, /[A-Za-z_.]*\([^()]*curve_fee_cap[^()]*\)/)) {
            print module ":" $2 ":" substr(body, RSTART, RLENGTH)
            body = substr(body, RSTART + RLENGTH)
        }
    }'
done | sed -E 's/^(cetus|bluefin):[a-z_]+:/adapter:/' | LC_ALL=C sort -u)"
require_text "$curve_fee_cap_uses" \
    "migrators may use the curve-fee cap only through launch.assert_curve_fee_cap and the vault's split-update check" <<'EOF'
adapter:self.assert_fee_split_update(launch,curve_fee_cap,proposed)
vault:assert_fee_split_update:launch.assert_curve_fee_cap(curve_fee_cap)
vault:claim_creator_fees:launch.assert_curve_fee_cap(curve_fee_cap)
EOF
if rg -U -q 'blast_fun::\{[^}]*\bfees\b|blast_fun::fees\b' "$SOURCE_DIR" \
    || [[ "$(for source in "$SOURCE_DIR"/*.move; do move_norm "$source"; done \
        | rg -o 'creator_authority::[A-Za-z_]+' | LC_ALL=C sort -u | tr '\n' ' ')" \
        != 'creator_authority::CurveFeeCap ' ]]; then
    fail "migrators must not embed Launchpad's curve-fee ledger, and may name only the curve-fee cap type from creator authority"
fi
require_pattern "$VAULT_SOURCE" 'public struct PositionKey' 'sealed position key type'
require_pattern "$VAULT_SOURCE" 'dynamic_object_field::add' 'dynamic object-field position attachment'
require_pattern "$VAULT_SOURCE" 'self\.id\.dynamic_object_field_mut' 'typed mutable position borrow'
require_pattern "$VAULT_SOURCE" '_venue: &Venue' 'borrowed venue witness on position access'
# Another venue's key finds no field, so the framework borrow itself aborts.
[[ "$(vault_body position_mut)" == 'self.id.dynamic_object_field_mut(PositionKey<Venue>())' ]] || \
    fail "vault::position_mut must only borrow the position under the sealed venue key"
# The auto-LP slot is a second venue-sealed key for the position auto-LP adds to on venues whose
# migration position cannot receive liquidity. It is written once, announced, and read in place;
# nothing removes or replaces it, and only Cetus's auto-LP addition and collection reach it.
[[ "$(move_production_type AutoLpPositionKey <<<"$VAULT_FACTS")" \
    == 'struct AutoLpPositionKey<phantom Venue>() has copy, drop, store;' ]] \
    && [[ "$(vault_body has_auto_lp_position)" == 'self.id.has_dynamic_object_field(AutoLpPositionKey<Venue>())' ]] \
    && [[ "$(vault_body attach_auto_lp_position)" == 'letposition_id=object::id(&position);self.id.add_dynamic_object_field(AutoLpPositionKey<Venue>(),position);blast_events::auto_lp_position_opened(self.id.to_inner(),position_id);' ]] \
    && [[ "$(vault_body auto_lp_position)" == 'self.id.dynamic_object_field(AutoLpPositionKey<Venue>())' ]] \
    && [[ "$(vault_body auto_lp_position_mut)" == 'self.id.dynamic_object_field_mut(AutoLpPositionKey<Venue>())' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "AutoLpPositionKey<") > 0 { print $2 }' \
        <<<"$VAULT_FACTS" | LC_ALL=C sort | tr '\n' ' ')" \
        == 'attach_auto_lp_position auto_lp_position auto_lp_position_mut has_auto_lp_position ' ]] || \
    fail "the vault's auto-LP slot must be attached once with its announcement, and only read in place"
[[ "$(for source in "$SOURCE_DIR"/*.move; do
        move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" '
            $1 == "FN" && $6 == 0 && module != "vault" \
                && $10 ~ /(attach_auto_lp_position|auto_lp_position(_mut)?|has_auto_lp_position)[<(]/ { print module ":" $2 }'
    done | LC_ALL=C sort | tr '\n' ' ')" == 'cetus:add_liquidity cetus:collect_position_fees ' ]] || \
    fail "only Cetus's auto-LP addition and collection may reach the vault's auto-LP slot"
require_pattern "$VAULT_SOURCE" 'protocol_meme_residual\.withdraw_all' \
    'protocol Meme residual claim'
require_pattern "$VAULT_SOURCE" 'protocol_quote_residual\.withdraw_all' \
    'protocol Quote residual claim'
# T-013: VaultCreated is a direct event emitted only after the pool binding and position custody
# it records are written.
[[ "$(vault_body new)" == 'assert!(liquidity>0,EZeroLiquidity);'* ]] \
    && in_order 'assert!(liquidity>0,EZeroLiquidity);' 'LpVault{id:object::new(ctx),pool_id,' 'vault.id.add_dynamic_object_field(' 'blast_events::vault_created<' \
        <<<"$(vault_body new)" || fail "VaultCreated must follow the liquidity check, the pool binding, and the position attachment"
require_exact_count 'PackageVersion' 1 \
    "vault must take only the Migrators generation, never a Launchpad PackageVersion" \
    "$VAULT_SOURCE"
require_pattern "$VAULT_SOURCE" 'blast_fun_migrators::PackageVersion as MigratorsVersion' \
    'Migrators generation imported under its guard alias'
require_exact_count '&AdminWitness<' 2 \
    "vault Launchpad authority must be exactly the protocol residual claim and the buyback" \
    <(production_section "$VAULT_SOURCE")
require_errors "$VAULT_SOURCE" "vault must use sequential codes 0-6 for its residual, split, creator, liquidity, buyback, and partner checks" <<'EOF'
0 ENothingClaimable No protocol migration residuals are available to claim.
1 EFeeSplitUnchanged Fee split proposal must differ from the current split.
2 ENoCreatorFees No creator LP fees are available to claim.
3 EZeroLiquidity Migration position must hold liquidity.
4 ENoBuybackQuote No burn Quote is waiting to buy Meme back.
5 EBuybackBelowMinimum Buyback must return at least the minimum Meme.
6 EPartnerMismatch The partner is not the one the vault's launch named at creation.
EOF

# === Holder rewards ===
#
# A Blast administrator publishes a round that reserves its budget from one vault's rewards
# balance; afterwards anyone may relay a Merkle proof, and each leaf pays its committed
# beneficiary once from the round's own funds.
REWARDS_FACTS="$(move_facts "$REWARDS_SOURCE")"
[[ "$REWARDS_FACTS" != *MALFORMED* ]] || fail "the Move reader rejected blast_holder_rewards.move"
[[ "$(move_production_type Round <<<"$REWARDS_FACTS")" \
    == 'struct Round<phantom Meme, phantom Quote> has key { id: UID, vault: ID, number: u64, root: vector<u8>, leaf_count: u64, claimed: vector<u256>, meme: Balance<Meme>, quote: Balance<Quote>, }' ]] \
    && [[ "$(awk -F'\t' '$1 == "TYPE" && $5 == 0 { print $2 }' <<<"$REWARDS_FACTS")" == 'Round' ]] || \
    fail "a round must hold only what claims read (its vault, number, root, leaf count, claim bitmap, and funds); RoundPublished carries the interval and manifest"
rewards_body() {
    awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name && $6 == 0 { print $10 }' <<<"$REWARDS_FACTS" \
        | tr -d '[:space:]' | sed 's/,)/)/g'
}
in_order \
    'migrators_version.assert_current();' \
    'assert!(number==vault.next_round(),EWrongRound);' \
    'assert!(start_checkpoint<end_checkpoint&&vault.last_checkpoint().is_none_or!(|last|*last==start_checkpoint),EInvalidInterval);' \
    'assert!(root.length()==constants::digest_length!()&&manifest_digest.length()==constants::digest_length!(),EInvalidCommitment);' \
    'assert!(leaf_count>0&&leaf_count<=constants::max_reward_leaves!(),EInvalidLeafCount);' \
    'assert!(meme_amount>0||quote_amount>0,EEmptyBudget);' \
    'let(meme,quote)=vault.fund_round(end_checkpoint,meme_amount,quote_amount);' \
    'claimed:unclaimed(leaf_count),' \
    'transfer::share_object(round);' \
    'blast_events::round_published(' \
    <<<"$(rewards_body publish_round)" \
    && [[ "$(rewards_body publish_round)" == 'migrators_version.assert_current();'* ]] \
    && [[ "$(rewards_body unclaimed)" == 'vector::tabulate!(leaf_count.div_ceil(256),|_|0u256)' ]] \
    && [[ "$(constant_body max_reward_leaves)" == '65_536' && "$(constant_body digest_length)" == '32' ]] || \
    fail "publication must check the generation first, then the round number, interval, commitment, leaf count, and a nonzero budget, then reserve from the vault (whose split aborts past its balances) and share the round with every claim bit clear"
in_order \
    'migrators_version.assert_current();' \
    'assert!(index<self.leaf_count,EInvalidIndex);' \
    'let(word,bit)=claim_bit(index);' \
    'assert!(self.claimed[word]&bit==0,EAlreadyClaimed);' \
    'assert!(beneficiary!=@0x0,EInvalidBeneficiary);' \
    'assert!(meme_amount>0||quote_amount>0,EEmptyBudget);' \
    'letleaf=merkle::leaf(self.vault,self.number,index,beneficiary,meme_amount,quote_amount);' \
    'assert!(merkle::verify(self.root,leaf,index,self.leaf_count,&proof),EInvalidProof);' \
    '*&mutself.claimed[word]=self.claimed[word]|bit;' \
    'self.meme.pay(meme_amount,beneficiary,ctx);' \
    'self.quote.pay(quote_amount,beneficiary,ctx);' \
    'blast_events::reward_paid(' \
    <<<"$(rewards_body claim)" \
    && [[ "$(rewards_body claim)" == 'migrators_version.assert_current();'* ]] \
    && [[ "$(rewards_body claim_bit)" == '(index/256,1u256<<((index%256)asu8))' ]] || \
    fail "claims must check the generation first, reject a used or invalid leaf before proof work, mark its own bitmap bit, and pay only its beneficiary"
[[ "$(for source in "$SOURCE_DIR"/*.move; do
        move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" \
            '$1 == "FN" && $6 == 0 && index($10, "fund_round(") > 0 { print module ":" $2 }'
    done | tr '\n' ' ')" == 'blast_holder_rewards:publish_round ' ]] || \
    fail "only holder-reward publication may reserve a vault's rewards balance"
# Round funds leave only through the vault's skip-empty `pay`, and only from a proven claim.
[[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, ".pay(") > 0 { print $2 }' \
    <<<"$REWARDS_FACTS")" == 'claim' ]] \
    && ! rg -q 'transfer::public_transfer' "$REWARDS_SOURCE" || \
    fail "round funds must leave only by a proven claim"
require_exact_count '&AdminWitness<' 1 \
    "holder-reward authority must be exactly round publication" \
    <(production_section "$REWARDS_SOURCE")
require_errors "$REWARDS_SOURCE" "holder rewards must use sequential codes 0-8 for their round and claim checks" <<'EOF'
0 EWrongRound Round number must match the vault's next round.
1 EInvalidInterval Checkpoint interval must be nonempty and contiguous with the previous round.
2 EInvalidCommitment Root and manifest digest must each contain exactly 32 bytes.
3 EInvalidLeafCount Round must contain between 1 and 65,536 leaves.
4 EEmptyBudget At least one reward amount must be nonzero.
5 EInvalidIndex Claim index must be less than the committed leaf count.
6 EAlreadyClaimed This allocation has already been paid.
7 EInvalidBeneficiary Beneficiary must not be the zero address.
8 EInvalidProof Proof must match the committed recipient, amounts and domain.
EOF
# Leaves and internal nodes hash under distinct domains, and every leaf binds the vault, round,
# index, beneficiary, and both amounts. Verification rejects a proof whose depth does not match the
# committed leaf count or whose siblings are not digests; the claim bounds the index first and
# publication bounds the leaf count and root, so verification repeats neither.
merkle_leaf_body="$(move_facts "$MERKLE_SOURCE" \
    | awk -F'\t' '$1 == "FN" && $2 == "leaf" { print $10 }' | tr -d '[:space:]')"
rg -q '^    let mut bytes = b"\\x00blast-holder-rewards-v1";$' "$MERKLE_SOURCE" \
    && in_order 'bytes.append(bcs::to_bytes(&vault));' 'bytes.append(bcs::to_bytes(&round));' \
        'bytes.append(bcs::to_bytes(&index));' 'bytes.append(bcs::to_bytes(&beneficiary));' \
        'bytes.append(bcs::to_bytes(&meme));' 'bytes.append(bcs::to_bytes(&quote));' \
        'hash::blake2b256(&bytes)' <<<"$merkle_leaf_body" \
    && [[ "$(move_facts "$MERKLE_SOURCE" | awk -F'\t' '$1 == "FN" && $2 == "node" { print $10 }' \
        | tr -d '[:space:]')" == 'letmutbytes=vector[1u8];bytes.append(left);bytes.append(right);hash::blake2b256(&bytes)' ]] \
    && [[ "$(move_facts "$MERKLE_SOURCE" | awk -F'\t' '$1 == "FN" && $2 == "verify" { print $10 }' \
        | tr -d '[:space:]')" == 'if(proof.length()!=proof_depth(leaves)||!proof.all!(|sibling|sibling.length()==constants::digest_length!()))returnfalse;proof.do_ref!(|sibling|{digest=if(index%2==0)node(digest,*sibling)elsenode(*sibling,digest);index=index/2;});digest==root' ]] \
    && [[ "$(move_facts "$MERKLE_SOURCE" | awk -F'\t' '$1 == "FN" && $2 == "proof_depth" { print $10 }' \
        | tr -d '[:space:]')" == 'letmutwidth=leaves;letmutdepth=0;while(width>1){width=width.div_ceil(2);depth=depth+1;};depth' ]] \
    && ! move_facts "$MERKLE_SOURCE" | awk -F'\t' '$1 == "FN" && $3 == "public" && $6 == 0 { found = 1 }
        END { exit !found }' || \
    fail "merkle leaves must bind the vault-domain leaf fields under the leaf domain, nodes their own domain, with package-only verification of proof depth and sibling length"

# === Venue config ===

require_pattern "$VENUE_CONFIG_SOURCE" 'public struct VenueConfig has key' \
    'shared venue-owned entry singleton'
require_pattern "$VENUE_CONFIG_SOURCE" 'transfer::share_object\(VenueConfig' \
    'shared venue config creation'
# The whole production API is package-only: write-once objects added under keys only a venue
# module constructs, and their immutable reads. Pool tiers are the creator's launch settings, so
# no admin tier, reservation policy, or tier error may return.
require_text "$(move_facts "$VENUE_CONFIG_SOURCE" \
    | awk -F'\t' '$1 == "FN" && $6 == 0 { print $3 ":" $9 }' | LC_ALL=C sort)" \
    "VenueConfig must expose exactly its package-only object functions" <<'EOF'
package:fun add_object<Key: copy + drop + store, Object: key + store>( self: &mut VenueConfig, key: Key, object: Object, )
package:fun object<Key: copy + drop + store, Object: key + store>( self: &VenueConfig, key: Key, ): &Object
private:fun init(ctx: &mut TxContext)
EOF
# Venue entries are write-once: no function borrows an entry mutably.
if move_norm "$VENUE_CONFIG_SOURCE" | rg -q '\bborrow_mut\b|_field_mut\b|\bdynamic_field\b' \
    || rg -q '#\[error' "$VENUE_CONFIG_SOURCE" \
    || rg -q '\b(TierKey|ReservationKey|set_tier|has_tier|effective_tier|reserved_tick_spacing|add_policy|has_policy)\b' \
        "$SOURCE_DIR"; then
    fail "venue entries must be write-once objects, and no admin tier or reservation policy may return"
fi

# === Bluefin ===

require_pattern "$BLUEFIN_SOURCE" 'public struct Witness' 'sealed Bluefin witness'
require_pattern "$BLUEFIN_SOURCE" 'public struct Venue' 'sealed Bluefin venue marker'
# Bluefin has exactly one launch start, one atomic migrate route, one collection entry, one
# settled update entry, and one buyback entry. The start checks the creator's tier against Bluefin's bounds and delegates
# to the core; migration reads that tier from the launch, begins, creates and funds the pool,
# completes once into a shared vault holding the venue position, then shares the pool; and every fee
# exit splits the collected position's fees through the vault and adds the auto-LP share back to
# the same position. The buyback swaps the vault's whole burn Quote for Meme in the vault's own
# pool and hands the result to the vault, which checks the admin's minimum and burns it.
bluefin_facts="$(move_facts "$BLUEFIN_SOURCE")"
[[ "$bluefin_facts" != *MALFORMED* ]] || fail "the Move reader rejected bluefin.move"
bluefin_public="$(awk -F'\t' '$1 == "FN" && $3 == "public" && $6 == 0 { print $2 }' <<<"$bluefin_facts" \
    | sort | tr '\n' ' ')"
[[ "$bluefin_public" == 'buyback_and_burn collect_fees migrate new settle_and_update_fee_split ' ]] || \
    fail "Bluefin must expose exactly new, migrate, collect_fees, settle_and_update_fee_split, and buyback_and_burn"
bluefin_body() {
    awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name { print $10 }' <<<"$bluefin_facts" \
        | tr -d '[:space:]' | sed 's/,)/)/g'
}
[[ "$(bluefin_body new)" == 'migrators_version.assert_current();assert!(tick_spacing>0&&tick_spacing<=constants::bluefin_max_tick_spacing!()&&fee_rate>0&&fee_rate<=constants::bluefin_max_fee_rate!(),EInvalidTier);launch::new<Meme,Quote,_>(ticket,package_version,config,Witness(),tick_spacing,fee_rate)' ]] \
    && [[ "$(constant_body bluefin_max_tick_spacing)" == '400' ]] \
    && [[ "$(constant_body bluefin_max_fee_rate)" == '20_000' ]] || \
    fail "bluefin::new must bound the tier to Bluefin's 1..=400 tick spacing and 1..=20,000 fee rate, then only start the launch through the core"
bluefin_migrate_body="$(bluefin_body migrate)"
# Migration reads the tier from the launch and the full-range bounds from Bluefin's config, begins,
# creates the named pool priced from the handed-off balances with the caller's whole creation fee,
# opens and seeds a full-range position, completes once into a shared vault holding the position,
# then shares the pool.
[[ "$bluefin_migrate_body" == 'migrators_version.assert_current();let(tick_spacing,fee_rate)=launch.pool_tier();let(lower_tick,upper_tick)=full_range_tick_range(bluefin_config,tick_spacing);let(meme,quote)=launch.migrate(package_version,currency,Witness(),ctx);letmutpool=pool::create_pool_and_get_object<Meme,Quote,SUI>(clock,bluefin_config,pool_name(currency,quote_currency),b"",currency.symbol().into_bytes(),currency.decimals(),b"",quote_currency.symbol().into_bytes(),quote_currency.decimals(),quote_currency.icon_url().into_bytes(),tick_spacing,fee_rate,migration_math::sqrt_price_x64(meme.value(),quote.value(),true),creation_fee.into_balance(),ctx);letmutposition=pool::open_position(bluefin_config,&mutpool,lower_tick,upper_tick,ctx);let(residual_meme,residual_quote)=seed(bluefin_config,&mutpool,&mutposition,meme,quote,clock);lock_into_vault(launch,position,residual_meme,residual_quote,ctx);pool.share_pool_object();' ]] \
    && [[ "$(bluefin_body full_range_tick_range)" == 'let(minimum_tick,maximum_tick)=bluefin_config.get_tick_range();letspacing=i32::from(tick_spacing);(minimum_tick.div(spacing).mul(spacing).as_u32(),maximum_tick.div(spacing).mul(spacing).as_u32())' ]] \
    && [[ "$(bluefin_body lock_into_vault)" == 'letliquidity=position.liquidity();vault::create(launch,&Venue(),position.pool_id(),position,liquidity,residual_meme,residual_quote,ctx);' ]] || \
    fail "Bluefin migrate must migrate the launch, create and fund the pool, lock the position in a new vault, then share the pool"
# The pool and the position record no Meme icon, as Cetus: the position stores the URL it is given,
# and the metadata capability can lengthen the Meme icon URL past Sui's object size limit. The pool
# name, which the position stores twice, is exactly the two symbols around a one-byte separator
# (the reader masks string contents); launch intake bounds the Meme symbol, and no mutable Meme
# metadata may join it.
[[ "$(bluefin_body pool_name)" == 'letmutname=currency.symbol().into_bytes();name.append(b"_");name.append(quote_currency.symbol().into_bytes());name' \
    && "$(grep -o 'pool_name' <<<"$bluefin_migrate_body" | wc -l)" -eq 1 \
    && "$(move_norm "$BLUEFIN_SOURCE" | grep -o 'create_pool_and_get_object' | wc -l)" -eq 1 \
    && "$(move_norm "$BLUEFIN_SOURCE" | grep -o 'icon_url()' | wc -l)" -eq 1 ]] || \
    fail "bluefin::migrate must name the pool by the two symbols and pass an empty Meme icon URL"
# The seed prefers to fix the side with more atoms, Meme on a tie, and fixes the other side when
# Bluefin's own liquidity math, at the position's bounds and the new pool's price, says the
# preferred side would overdraw its partner; nearly equal amounts can do that by one atom.
[[ "$(bluefin_body seed)" == 'letfix_meme=seed_fixes_meme(pool,position,meme.value(),quote.value());letamount=if(fix_meme)meme.value()elsequote.value();let(_,_,residual_meme,residual_quote)=pool::add_liquidity_with_fixed_amount(clock,bluefin_config,pool,position,meme,quote,amount,fix_meme);(residual_meme,residual_quote)' ]] \
    && [[ "$(bluefin_body seed_fixes_meme)" == 'letprefer_meme=meme_amount>=quote_amount;let(_,needed_meme,needed_quote)=pool::get_liquidity_by_amount(position.lower_tick(),position.upper_tick(),pool.current_tick_index(),pool.current_sqrt_price(),if(prefer_meme)meme_amountelsequote_amount,prefer_meme);if(needed_meme<=meme_amount&&needed_quote<=quote_amount)prefer_memeelse!prefer_meme' ]] || \
    fail "Bluefin migrate must fix the larger side, Meme on a tie, unless Bluefin's own math says it overdraws the other side"
# Both fee exits settle through one helper: collect the position's fees, split them through the
# vault, and add the auto-LP share back. A settled update checks the cap and proposal first and
# commits the new split only after settling under the current one.
[[ "$(bluefin_body settle_fees)" == 'let(meme_fee,quote_fee)=self.collect_position_fees(bluefin_config,pool,clock);self.split_fees(policy,currency,meme_fee,quote_fee,ctx);self.compound(bluefin_config,pool,clock);' ]] \
    && [[ "$(bluefin_body collect_fees)" == 'migrators_version.assert_current();self.settle_fees(policy,currency,bluefin_config,pool,clock,ctx);' ]] || \
    fail "Bluefin collection must split the collected position's fees, then add the auto-LP share back"
[[ "$(bluefin_body settle_and_update_fee_split)" == 'migrators_version.assert_current();self.assert_fee_split_update(launch,curve_fee_cap,proposed);self.settle_fees(policy,currency,bluefin_config,pool,clock,ctx);self.update_fee_split(proposed);' ]] || \
    fail "Bluefin settled updates must check the cap and proposal before collecting, then split the accrued fees under the current split before committing a new one"
[[ "$(bluefin_body buyback_and_burn)" == 'migrators_version.assert_current();assert!(self.pool_id()==object::id(pool),EPositionPoolMismatch);letquote=self.take_buyback_quote(admin_witness);letquote_in=quote.value();let(meme,quote)=pool::swap(clock,bluefin_config,pool,balance::zero(),quote,false,true,quote_in,0,constants::max_swap_sqrt_price!());self.burn_buyback(currency,meme,quote,quote_in,min_meme_out,ctx);' ]] || \
    fail "the Bluefin buyback must check the vault's pool, take the burn Quote under the buyback admin, swap all of it Quote-to-Meme, and let the vault check and burn"
in_order \
    'self.position_mut<_,_,_,Position>(&Venue());' \
    'assert!(position.pool_id()==object::id(pool),EPositionPoolMismatch);' \
    'let(_,_,meme_fee,quote_fee)=pool::collect_fee(clock,bluefin_config,pool,position);' \
    '(meme_fee,quote_fee)' \
    <<<"$(bluefin_body collect_position_fees)" || \
    fail "Bluefin collection must check the custodied position's pool once, before the venue call"
# Auto-LP adds the waiting balances to the custodied position, fixing the side the shared
# selection chooses from the pool's price and the position's own tick bounds, and keeps the rest.
[[ "$(bluefin_body compound)" == 'let(meme,quote)=self.take_auto_lp();letposition=self.position_mut<_,_,_,Position>(&Venue());let(fix_meme,amount)=fixed_side(pool,position,meme.value(),quote.value());let(added_meme,added_quote,meme,quote)=if(amount>0){pool::add_liquidity_with_fixed_amount(clock,bluefin_config,pool,position,meme,quote,amount,fix_meme)}else{(0,0,meme,quote)};self.keep_auto_lp(added_meme,added_quote,meme,quote);' ]] \
    && [[ "$(bluefin_body fixed_side)" == 'letticks=pool.get_tick_manager();letsqrt_lower=ticks.get_tick_from_manager(position.lower_tick()).sqrt_price();letsqrt_upper=ticks.get_tick_from_manager(position.upper_tick()).sqrt_price();migration_math::auto_lp_fixed_side(sqrt_lower,pool.current_sqrt_price(),sqrt_upper,meme_amount,quote_amount)' ]] || \
    fail "Bluefin auto-LP must add to the custodied position on the side the shared selection fixes and keep the rest"
require_errors "$BLUEFIN_SOURCE" "Bluefin must use codes 0-1 for its position-pool and tier checks" <<'EOF'
0 EPositionPoolMismatch Custodied position must belong to the supplied pool.
1 EInvalidTier Bluefin tier needs a tick spacing in 1..=400 and a fee rate in 1..=20,000.
EOF
# Bluefin's public routes share one parameter order: the subject, this package's generation, the
# launchpad generation where the launch is started or migrated, the LP-fee policy after
# migration, and (for a settled update) the launch and its live curve-fee cap, then venue inputs.
for entry in new migrate collect_fees settle_and_update_fee_split buyback_and_burn; do
    case "$entry" in
        new) expected="( ticket: LaunchTicket<Meme>, migrators_version: &MigratorsVersion, package_version: &PackageVersion, config: &LaunchConfig," ;;
        migrate) expected="( launch: &mut Launch<Meme, Quote>, migrators_version: &MigratorsVersion, package_version: &PackageVersion, currency: &mut Currency<Meme>," ;;
        collect_fees) expected="( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, policy: &LpFeePolicy, currency: &mut Currency<Meme>," ;;
        buyback_and_burn) expected="( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, admin_witness: &AdminWitness<BuybackAdmin>, currency: &mut Currency<Meme>," ;;
        *) expected="( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, policy: &LpFeePolicy, launch: &Launch<Meme, Quote>, curve_fee_cap: &CurveFeeCap<Meme>, currency: &mut Currency<Meme>," ;;
    esac
    [[ "$(awk -F'\t' -v name="$entry" '$1 == "FN" && $2 == name && $6 == 0 { print $9 }' \
        <<<"$bluefin_facts")" == *"$expected"* ]] || \
        fail "bluefin::${entry} must take the shared adapter parameter order"
done
if rg -q 'fun [a-z_]*_meme_b\b|meme_is_coin_a' "$BLUEFIN_SOURCE"; then
    fail "Bluefin must use only the deterministic Meme-A/Quote-B orientation"
fi
BLUEFIN_COMPACT_SOURCE="$(tr -d '[:space:]' < "$BLUEFIN_SOURCE")"
BLUEFIN_PUBLIC_SIGNATURES="$(rg -U 'public fun (migrate|collect|settle)[^{]+\{' "$BLUEFIN_SOURCE" || true)"
if [[ "$BLUEFIN_PUBLIC_SIGNATURES" =~ (sqrt_price|orientation|meme_is|tick_spacing:|fee_rate:|amount|liquidity) ]]; then
    fail "caller-supplied Bluefin price, orientation, tier, or amount is forbidden"
fi
# The caller's SUI coin is the whole creation fee; Bluefin enforces the exact configured amount.
# The only constructed balance is the buyback swap's empty Meme input.
[[ "$(rg -o 'into_balance' "$BLUEFIN_SOURCE" | wc -l)" -eq 1 ]] \
    && [[ "$BLUEFIN_COMPACT_SOURCE" == *'creation_fee:Coin<SUI>,'* ]] \
    && [[ "$bluefin_migrate_body" == *',creation_fee.into_balance(),ctx);'* ]] \
    && [[ "$(grep -o 'balance::zero()' <<<"$BLUEFIN_COMPACT_SOURCE" | wc -l)" -eq 1 ]] \
    && [[ "$(bluefin_body buyback_and_burn)" == *'pool,balance::zero(),quote,'* ]] \
    && ! [[ "$BLUEFIN_COMPACT_SOURCE" =~ balance::(create|from|withdraw|split)|creation_fee\.(split|balance_mut) ]] || \
    fail "the Bluefin creation fee must be the caller's whole SUI coin"
if [[ "$BLUEFIN_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*Venue([^C]|$) ]]; then
    fail "public or package Bluefin venue exposure is forbidden"
fi
if [[ "$(tr -d '[:space:]' < "$BLUEFIN_SOURCE")" =~ publicfun[^\{]*Position ]]; then
    fail "public Bluefin position exposure is forbidden"
fi

# === Cetus ===

require_pattern "$CETUS_SOURCE" 'public struct Witness' 'sealed Cetus witness'
require_pattern "$CETUS_SOURCE" 'public struct Venue' 'sealed Cetus venue marker'
# Cetus has one launch start and one migrate, collection, settled-update, and buyback entry, each
# serving both coin orders (ADR 0100). The start takes the fee rate Cetus registers for the
# creator's tick spacing, starts the launch under the sealed witness, then reserves pool creation
# before any Meme can leave the ticket: it mints the Meme type's cap from the initializer's treasury
# loan, registers the pair at that tick spacing, and stores the cap. Every later route takes the
# pool's coin types as `CoinA` and `CoinB`, checks this package's generation first, and then proves
# `(CoinA, CoinB)` is exactly `{Meme, Quote}`; migration also requires Cetus's own coin order
# before that. Migration creates the pair's pool only with the reserved cap at the launch's tick
# spacing, prices it from the handed-off balances in the pool's coin order, fixes the larger side
# (Meme on a tie) unless Cetus's own liquidity math says it overdraws the other, burns the position
# through Cetus LP Burn, and completes into a new vault holding the burn proof. Every fee exit
# collects the burn proof's and the auto-LP position's fees, splits them through the vault, and adds
# the auto-LP share to the auto-LP position. Each buyback checks the vault's own pool, swaps the
# vault's whole burn Quote for Meme, repays exactly what Cetus asks, and hands the result to the
# vault, which checks the admin's minimum and burns it.
cetus_facts="$(move_facts "$CETUS_SOURCE")"
[[ "$cetus_facts" != *MALFORMED* ]] || fail "the Move reader rejected cetus.move"
cetus_public="$(awk -F'\t' '$1 == "FN" && $3 == "public" && $6 == 0 { print $2 }' <<<"$cetus_facts" \
    | LC_ALL=C sort | tr '\n' ' ')"
[[ "$cetus_public" == 'buyback_and_burn collect_fees migrate new settle_and_update_fee_split ' ]] || \
    fail "Cetus must expose exactly new and one migrate, collect, settled-update, and buyback route for both coin orders"
cetus_body() {
    awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name && $6 == 0 { print $10 }' <<<"$cetus_facts" \
        | tr -d '[:space:]' | sed 's/,)/)/g'
}
in_order \
    'migrators_version.assert_current();' \
    'letfee_rate=config::get_fee_rate(tick_spacing,cetus_config);' \
    'letmutlaunch=launch::new<Meme,Quote,_>(ticket,package_version,config,Witness(),tick_spacing,fee_rate);' \
    'letpool_creation_cap=factory::mint_pool_creation_cap(cetus_config,pools,launch.treasury_cap_mut(Witness()),ctx);' \
    'factory::register_permission_pair<Meme,Quote>(cetus_config,pools,tick_spacing,&pool_creation_cap,ctx);' \
    'letpool_creation_cap_id=object::id(&pool_creation_cap);' \
    'venue_config.add_object(CreationCapKey<Meme>(),pool_creation_cap);' \
    'blast_events::cetus_pool_reserved<Meme,Quote>(pool_creation_cap_id,tick_spacing);' \
    <<<"$(cetus_body new)" \
    && [[ "$(cetus_body new)" == 'migrators_version.assert_current();'*'tick_spacing);launch' ]] \
    && [[ "$(cetus_body pool_creation_cap)" == 'venue_config.object(CreationCapKey<Meme>())' ]] || \
    fail "cetus::new must take Cetus's fee rate for the tick spacing, start the launch, then mint the cap once, register the pair with it, and store it"
pair_proof='letmeme_is_a=meme_is_coin_a<Meme,Quote,CoinA,CoinB>();'
[[ "$(cetus_body migrate)" == "migrators_version.assert_current();assert!(factory::is_right_order<CoinA,CoinB>(),EInvalidCoinOrder);${pair_proof}"* ]] \
    && in_order \
        'let(tick_spacing,_)=launch.pool_tier();' \
        'let(tick_lower,tick_upper)=pool_creator::full_range_tick_range(tick_spacing);' \
        'let(meme,quote)=launch.migrate(package_version,currency,Witness(),ctx);' \
        'letmeme_amount=meme.value();letquote_amount=quote.value();' \
        'letsqrt_price=migration_math::sqrt_price_x64(meme_amount,quote_amount,meme_is_a);' \
        'letfix_a=seed_fixes_a(tick_lower,tick_upper,sqrt_price,meme_amount,quote_amount,meme_is_a);' \
        'let(coin_a,coin_b)=reorder(meme.into_coin(ctx),quote.into_coin(ctx),meme_is_a,ctx);' \
        'let(position,residual_a,residual_b)=pool_creator::create_pool_v3_with_creation_cap<CoinA,CoinB>(cetus_config,pools,venue_config.pool_creation_cap<Meme>(),tick_spacing,sqrt_price,b"".to_string(),tick_lower,tick_upper,coin_a,coin_b,fix_a,clock,ctx);' \
        'let(residual_meme,residual_quote)=reorder(residual_a,residual_b,meme_is_a,ctx);' \
        'burn_into_vault(launch,burn_manager,position,residual_meme,residual_quote,ctx);' \
        <<<"$(cetus_body migrate)" \
    && [[ "$(cetus_body migrate)" == *'ctx);' ]] \
    && [[ "$(cetus_body seed_fixes_a)" == 'let(amount_a,amount_b)=if(meme_is_a)(meme_amount,quote_amount)else(quote_amount,meme_amount);letprefer_a=(meme_amount>=quote_amount)==meme_is_a;let(_,needed_a,needed_b)=clmm_math::get_liquidity_by_amount(i32::from_u32(tick_lower),i32::from_u32(tick_upper),i32::zero(),sqrt_price,if(prefer_a)amount_aelseamount_b,prefer_a);if(needed_a<=amount_a&&needed_b<=amount_b)prefer_aelse!prefer_a' ]] || \
    fail "cetus::migrate must check the generation, Cetus's coin order, and the pair first, then create the pool in that order with the reserved cap at the launch's tick spacing, fix the larger side (Meme on a tie) unless Cetus's own math says it overdraws the other, and burn into a vault"
[[ "$(cetus_body settle_fees)" == 'let(meme_fee,quote_fee)=self.collect_position_fees(cetus_config,burn_manager,pool,meme_is_a,ctx);self.split_fees(policy,currency,meme_fee,quote_fee,ctx);self.compound(cetus_config,pool,meme_is_a,clock,ctx);' ]] \
    && [[ "$(cetus_body collect_fees)" == "migrators_version.assert_current();${pair_proof}self.settle_fees(policy,currency,cetus_config,burn_manager,pool,meme_is_a,clock,ctx);" ]] || \
    fail "cetus::collect_fees must check the generation and the pair, split the collected fees, then add the auto-LP share back"
[[ "$(cetus_body settle_and_update_fee_split)" == "migrators_version.assert_current();${pair_proof}self.assert_fee_split_update(launch,curve_fee_cap,proposed);self.settle_fees(policy,currency,cetus_config,burn_manager,pool,meme_is_a,clock,ctx);self.update_fee_split(proposed);" ]] || \
    fail "cetus::settle_and_update_fee_split must check the pair, cap, and proposal before collecting, then split the accrued fees under the current split before committing a new one"
[[ "$(cetus_body buyback_and_burn)" == "migrators_version.assert_current();${pair_proof}assert!(self.pool_id()==object::id(pool),EPositionPoolMismatch);letquote=self.take_buyback_quote(admin_witness);letquote_in=quote.value();let(meme,quote)=swap_quote_for_meme(cetus_config,pool,quote,meme_is_a,clock,ctx);self.burn_buyback(currency,meme,quote,quote_in,min_meme_out,ctx);" ]] \
    && [[ "$(cetus_body swap_quote_for_meme)" == 'let(a,b)=reorder(balance::zero<Meme>(),quote,meme_is_a,ctx);let(a,b)=swap(cetus_config,pool,a,b,!meme_is_a,clock);reorder(a,b,meme_is_a,ctx)' ]] || \
    fail "cetus::buyback_and_burn must check the pair and the vault's pool, take the burn Quote under the buyback admin, swap all of it Quote-to-Meme, and let the vault check and burn"
[[ "$(cetus_body compound)" == 'let(meme,quote)=self.take_auto_lp();let(a,b)=reorder(meme,quote,meme_is_a,ctx);let(a,b,added_a,added_b)=self.add_liquidity(cetus_config,pool,a,b,clock,ctx);let(meme,quote)=reorder(a,b,meme_is_a,ctx);let(added_meme,added_quote)=if(meme_is_a)(added_a,added_b)else(added_b,added_a);self.keep_auto_lp(added_meme,added_quote,meme,quote);' ]] || \
    fail "Cetus auto-LP must take the waiting balances in its pool's coin order and keep what the pool did not take"
# The pair proof is pure and total: `(CoinA, CoinB)` must be exactly `{Meme, Quote}` by original
# type name, in either order, and Meme's side is the answer. Every retype goes through one
# dynamic-field round trip on a fresh transient UID that is deleted afterwards, so the framework's
# `dynamic_field::remove` aborts unless the value keeps its exact type; nothing else in Cetus
# touches a dynamic field or names `CastKey`.
[[ "$(cetus_body meme_is_coin_a)" == 'let(meme,quote)=(type_name::with_original_ids<Meme>(),type_name::with_original_ids<Quote>());let(a,b)=(type_name::with_original_ids<CoinA>(),type_name::with_original_ids<CoinB>());assert!((meme==a&&quote==b)||(meme==b&&quote==a),EWrongCoinPair);meme==a' ]] \
    && [[ "$(cetus_body reorder)" == 'letmutscratch=object::new(ctx);let(first,second)=if(meme_is_a){(cast(&mutscratch,x),cast(&mutscratch,y))}else{(cast(&mutscratch,y),cast(&mutscratch,x))};scratch.delete();(first,second)' ]] \
    && [[ "$(cetus_body cast)" == 'dynamic_field::add(scratch,CastKey(),value);dynamic_field::remove(scratch,CastKey())' ]] \
    && [[ "$(move_production_type CastKey <<<"$cetus_facts")" == 'struct CastKey() has copy, drop, store;' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "dynamic_field::") > 0 { print $2 }' <<<"$cetus_facts")" == 'cast' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && $10 ~ /(^|[^A-Za-z0-9_])cast\(/ { print $2 }' <<<"$cetus_facts")" == 'reorder' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "CastKey") > 0 { print $2 }' <<<"$cetus_facts")" == 'cast' ]] || \
    fail "Cetus must prove the coin pair by type name and retype only through one checked dynamic-field round trip on a transient UID"
# Migration burns the full-range position through Cetus LP Burn exactly once, before the vault
# takes custody of the burn proof and the residuals.
in_order \
    'letpool_id=position.pool_id();' \
    'letliquidity=position.liquidity();' \
    'letburn_proof=lp_burn::burn_lp_v2(burn_manager,position,ctx);' \
    'vault::create(launch,&Venue(),pool_id,burn_proof,liquidity,residual_meme.into_balance(),residual_quote.into_balance(),ctx);' \
    <<<"$(cetus_body burn_into_vault)" \
    && [[ "$(move_norm "$CETUS_SOURCE" | grep -o 'burn_lp_v2' | wc -l)" -eq 1 ]] || \
    fail "Cetus migration must burn the position through LP Burn exactly once, then lock the burn proof and residuals in the vault"
# Collection checks the vault's own pool first, collects the burn proof only through LP Burn, and
# collects the auto-LP position only once it exists.
[[ "$(cetus_body collect_position_fees)" == 'assert!(self.pool_id()==object::id(pool),EPositionPoolMismatch);let(fee_a,fee_b)=lp_burn::collect_fee(burn_manager,cetus_config,pool,self.position_mut<_,_,_,CetusLPBurnProof>(&Venue()),ctx);letmutfee_a=fee_a.into_balance();letmutfee_b=fee_b.into_balance();if(self.has_auto_lp_position(&Venue())){letposition=self.auto_lp_position<_,_,_,Position>(&Venue());let(auto_lp_a,auto_lp_b)=pool::collect_fee(cetus_config,pool,position,true);fee_a.join(auto_lp_a);fee_b.join(auto_lp_b);};reorder(fee_a,fee_b,meme_is_a,ctx)' ]] || \
    fail "Cetus collection must check the vault's pool first, collect the burn proof through LP Burn, and the auto-LP position only once it exists"
# The burn proof leaves LP Burn only for the vault, and is borrowed only to collect its fees: the
# vault's main slot is never read under another type or for any other call.
[[ "$(move_norm "$CETUS_SOURCE" | grep -o 'CetusLPBurnProof' | wc -l)" -eq 2 ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 { print $10 }' <<<"$cetus_facts" | tr -d '[:space:]' \
        | grep -o '\.position\(_mut\)\?<[^>]*>' | tr '\n' ' ')" == '.position_mut<_,_,_,CetusLPBurnProof> ' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 { print $10 }' <<<"$cetus_facts" | tr -d '[:space:]' \
        | grep -o 'burn_proof[^A-Za-z_]' | tr '\n' ' ')" == 'burn_proof= burn_proof, ' ]] \
    && [[ "$(move_norm "$CETUS_SOURCE" | grep -o 'lp_burn::collect_fee' | wc -l)" -eq 1 ]] || \
    fail "the burn proof must be borrowed only to collect its fees through LP Burn"
# Auto-LP opens at most one full-range position in the vault's pool, on first use, then adds with
# Cetus's own fixed-coin math, fixing coin A first when coin B covers it, and repays exactly what
# the receipt asks.
[[ "$(cetus_body add_liquidity)" == 'if(a.value()==0||b.value()==0)return(a,b,0,0);if(!self.has_auto_lp_position(&Venue())){let(tick_lower,tick_upper)=pool_creator::full_range_tick_range(pool.tick_spacing());letposition=pool::open_position(cetus_config,pool,tick_lower,tick_upper,ctx);self.attach_auto_lp_position(&Venue(),position);};letposition=self.auto_lp_position_mut<_,_,_,Position>(&Venue());let(fix_a,amount)=fixed_side(pool,position,a.value(),b.value());if(amount==0)return(a,b,0,0);letreceipt=pool::add_liquidity_fix_coin(cetus_config,pool,position,amount,fix_a,clock);let(paid_a,paid_b)=receipt.add_liquidity_pay_amount();pool::repay_add_liquidity(cetus_config,pool,a.split(paid_a),b.split(paid_b),receipt);(a,b,paid_a,paid_b)' ]] \
    && [[ "$(cetus_body fixed_side)" == 'let(lower,upper)=position.tick_range();lettick=pool.current_tick_index();letprice=pool.current_sqrt_price();let(liquidity_a,_,needed_b)=clmm_math::get_liquidity_by_amount(lower,upper,tick,price,amount_a,true);let(liquidity_b,needed_a,_)=clmm_math::get_liquidity_by_amount(lower,upper,tick,price,amount_b,false);if(liquidity_a>0&&needed_b<=amount_b)(true,amount_a)elseif(liquidity_b>0&&needed_a<=amount_a)(false,amount_b)else(true,0)' ]] \
    && [[ "$(move_norm "$CETUS_SOURCE" | grep -o 'open_position' | wc -l)" -eq 1 ]] \
    && [[ "$(move_norm "$CETUS_SOURCE" | grep -o 'add_liquidity_fix_coin' | wc -l)" -eq 1 ]] || \
    fail "Cetus auto-LP must open at most one full-range auto-LP position, then add with the fixed-coin receipt and repay it exactly"
# A swap runs all of its input to the widest price limit, since the admin's minimum is the
# protection, and repays exactly what the receipt asks.
in_order \
    'let(amount,sqrt_price_limit)=if(a2b)(a.value(),constants::min_swap_sqrt_price!())else(b.value(),constants::max_swap_sqrt_price!());' \
    'let(out_a,out_b,receipt)=pool::flash_swap(cetus_config,pool,a2b,true,amount,sqrt_price_limit,clock);' \
    'letpaid=receipt.swap_pay_amount();' \
    'let(pay_a,pay_b)=if(a2b)(a.split(paid),balance::zero())else(balance::zero(),b.split(paid));' \
    'pool::repay_flash_swap(cetus_config,pool,pay_a,pay_b,receipt);' \
    'a.join(out_a);b.join(out_b);(a,b)' \
    <<<"$(cetus_body swap)" \
    && [[ "$(constant_body min_swap_sqrt_price)" == '4_295_048_017' ]] \
    && [[ "$(constant_body max_swap_sqrt_price)" == '79_226_673_515_401_279_992_447_579_054' ]] \
    && [[ "$(move_norm "$CETUS_SOURCE" | grep -o 'flash_swap' | wc -l)" -eq 2 ]] || \
    fail "Cetus buybacks must swap through one flash swap at the widest limit and repay exactly the receipt"
require_errors "$CETUS_SOURCE" "Cetus must use sequential codes 0-2 for coin order, vault-pool, and coin-pair checks" <<'EOF'
0 EInvalidCoinOrder CoinA and CoinB must follow the Cetus coin order.
1 EPositionPoolMismatch Pool must be the vault's own pool.
2 EWrongCoinPair CoinA and CoinB must be exactly the launch's Meme and Quote.
EOF
# Cetus's public routes share Bluefin's parameter order, with the LP Burn manager among the venue
# inputs.
for entry in new migrate collect_fees settle_and_update_fee_split buyback_and_burn; do
    case "$entry" in
        new) expected="( ticket: LaunchTicket<Meme>, migrators_version: &MigratorsVersion, package_version: &PackageVersion, config: &LaunchConfig," ;;
        migrate) expected="( launch: &mut Launch<Meme, Quote>, migrators_version: &MigratorsVersion, package_version: &PackageVersion, currency: &mut Currency<Meme>," ;;
        collect_fees) expected="( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, policy: &LpFeePolicy, currency: &mut Currency<Meme>," ;;
        buyback_and_burn) expected="( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, admin_witness: &AdminWitness<BuybackAdmin>, currency: &mut Currency<Meme>," ;;
        *) expected="( self: &mut LpVault<Meme, Quote>, migrators_version: &MigratorsVersion, policy: &LpFeePolicy, launch: &Launch<Meme, Quote>, curve_fee_cap: &CurveFeeCap<Meme>, currency: &mut Currency<Meme>," ;;
    esac
    [[ "$(awk -F'\t' -v name="$entry" '$1 == "FN" && $2 == name && $6 == 0 { print $9 }' \
        <<<"$cetus_facts")" == *"$expected"* ]] || \
        fail "cetus::${entry} must take the shared adapter parameter order"
done
CETUS_COMPACT_SOURCE="$(tr -d '[:space:]' < "$CETUS_SOURCE")"
if [[ "$CETUS_COMPACT_SOURCE" =~ abort0 ]]; then
    fail "production Cetus abort stubs are forbidden"
fi
if [[ "$CETUS_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*Venue([^C]|$) ]]; then
    fail "public or package Cetus venue exposure is forbidden"
fi
if [[ "$CETUS_COMPACT_SOURCE" =~ publicfun[^\{]*(Position|CetusLPBurnProof) ]]; then
    fail "public Cetus position or burn-proof exposure is forbidden"
fi
# The creator chooses only the tick spacing when starting a launch; Cetus fixes its fee rate, and
# no later route takes a tier, price, or orientation from the caller.
CETUS_PUBLIC_SIGNATURES="$(rg -U 'public fun (migrate|collect|settle)[^{]+\{' "$CETUS_SOURCE" || true)"
CETUS_START_SIGNATURE="$(rg -U 'public fun new[^{]+\{' "$CETUS_SOURCE" || true)"
if [[ "$CETUS_PUBLIC_SIGNATURES" =~ (sqrt_price|orientation|meme_is|tick_spacing:|fee_rate:) ]] \
    || [[ "$CETUS_START_SIGNATURE" =~ (sqrt_price|orientation|meme_is|fee_rate:) ]]; then
    fail "caller-supplied Cetus price, orientation, fee rate, or post-start tier is forbidden"
fi
# Only the reserved capability creates the pool: never an unreserved creation or a released
# reservation.
[[ "$(rg -c 'pool_creator::create_pool_v3_with_creation_cap<' "$CETUS_SOURCE" || true)" -eq 1 ]] || \
    fail "the Cetus migration route must create its pool with the reserved capability"
if rg -q 'create_pool_v3[[:space:]]*[<(]|unregister_permission_pair|policy_mut' "$CETUS_SOURCE"; then
    fail "Cetus must neither create an unreserved pool nor release a reservation"
fi
[[ "$(rg -c 'launch\.treasury_cap_mut\(Witness\(\)\)' "$CETUS_SOURCE" || true)" -eq 1 ]] \
    && ! rg -q 'treasury_cap_mut' "$BLUEFIN_SOURCE" "$VAULT_SOURCE" "$VENUE_CONFIG_SOURCE" \
        "$LP_FEE_POLICY_SOURCE" "$REWARDS_SOURCE" || \
    fail "the Cetus capability must be minted once from the initializer's lent treasury capability, and no other module borrows it"

# === Package-wide custody rules ===

# The one removal is Cetus's checked retype, pinned above, which removes only the value it added
# to its own transient UID in the same call.
[[ "$(rg -o 'dynamic(_object)?_field::(remove(_opt)?|replace)' "$SOURCE_DIR" | LC_ALL=C sort | tr '\n' ' ')" \
    == "${CETUS_SOURCE}:dynamic_field::remove " ]] || \
    fail "dynamic-field removal or replacement is forbidden outside Cetus's transient checked retype"
reject_pattern 'events_wrapper|public struct Event<' \
    'generic adapter event envelopes are forbidden'
reject_pattern 'protocol_treasury|residual_treasury' \
    'address-based residual treasury routing is forbidden'
reject_pattern 'remove_liquidity' 'principal removal is forbidden'
reject_pattern 'decrease_liquidity|withdraw_liquidity' 'principal withdrawal is forbidden'
reject_pattern 'close_position' 'position closure is forbidden'
# Cetus's LP Burn call is pinned above as the one sanctioned burn; nothing else may burn or
# destroy a position.
reject_pattern 'burn_position|destroy_position' 'position destruction is forbidden'
reject_pattern 'gauge|stake_position|staking' 'position gauge staking is forbidden'
reject_pattern '(position\.(burn|delete|destroy)|((burn|delete|destroy)[[:space:]]*\([^)]*position))' \
    'position burn or destruction is forbidden'
reject_pattern '(sequence|revision|nonce|schema_version|action_tag):' \
    'application-level event ordering fields are forbidden'
COMPACT_SOURCE="$(sed -n 'p' "$SOURCE_DIR"/*.move | tr -d '[:space:]')"
if [[ "$COMPACT_SOURCE" =~ transfer::(public_)?transfer\([^\)]*position ]]; then
    fail "position transfer is forbidden"
fi
if [[ "$COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*(cetus|bluefin)::Venue ]]; then
    fail "cross-module venue exposure is forbidden"
fi
# Object custody paths: the vault's position attachments and `VenueConfig`'s object API, whose
# only caller stores the Meme type's Cetus pool-creation capability while starting a launch. Call
# sites are counted, not imports: each of the two modules names `dynamic_object_field::add` only
# in its one alias, and `add_object` is named only by its declaration and the Cetus start. No
# module renames a dynamic field module or imports its members, so none reaches a field function
# under another name.
for source in "$SOURCE_DIR"/*.move; do
    if move_norm "$source" | rg -q '\bdynamic_(object_)?field( as |::\{)'; then
        fail "$(basename "$source") must import dynamic field modules by name only"
    fi
done
object_custody_sites="$(for source in "$SOURCE_DIR"/*.move; do
    module="$(basename "$source" .move)"
    facts="$(move_facts "$source")"
    awk -F'\t' -v module="$module" '$1 == "FN" {
        for (calls = gsub(/add_dynamic_object_field/, "", $10); calls > 0; calls--) print module "::" $2 " adds"
    }' <<<"$facts"
    awk -F'\t' '$1 == "NORM" { print $2 }' <<<"$facts" \
        | rg -o '\bdynamic_object_field::add\b[^;]*|[.:]?\badd_object\b.' | sed "s/^/${module} names /" || true
done | LC_ALL=C sort)"
require_text "$object_custody_sites" \
    "only the vault's attachments and venue_config::add_object add object fields; only Cetus calls add_object" <<'EOF'
cetus names .add_object(
vault names dynamic_object_field::add as UID.add_dynamic_object_field
vault::attach_auto_lp_position adds
vault::new adds
venue_config names add_object<
venue_config names dynamic_object_field::add as UID.add_dynamic_object_field
venue_config::add_object adds
EOF
# Functions with a natural first receiver are called with Move 2024 dot syntax, in sources and
# tests alike.
if rg -n \
    'vault::(split_fees|take_auto_lp|keep_auto_lp|assert_fee_split_update|update_fee_split|fund_round|claim_creator_fees|claim_protocol_fees|attach_auto_lp_position|position_mut|auto_lp_position|auto_lp_position_mut|has_auto_lp_position)[[:space:]]*(<[^>]*>)?\(|lp_fee_policy::(shares|set_protocol_destination|set_default_shares|set_coin_shares|clear_coin_shares|protocol_destination|default_shares)[[:space:]]*(<[^>]*>)?\(|blast_holder_rewards::claim[[:space:]]*(<[^>]*>)?\(|pool::add_liquidity_pay_amount[[:space:]]*\(|coin::from_balance[[:space:]]*\(|(^|[^.[:alnum:]_])collect_position_fees[[:space:]]*\(' \
    "$SOURCE_DIR" "$PACKAGE_DIR/tests"; then
    fail "functions with a natural first receiver must use Move 2024 dot syntax"
fi


# === Shared administration boundary ===
#
# Migrators takes the Launchpad's roles in the shared blast_admin ACL. It must never
# reimplement the reusable ACL, declare a role of its own, reimplement generation arithmetic or
# native custody, or treat the Launchpad generation as its own.

for forbidden in acl.move blast_acl.move; do
    [[ -e "$SOURCE_DIR/$forbidden" ]] && \
        fail "Migrators must not define a local $forbidden"
done

if rg -n '^public struct (ACL|Authority|ProtocolAuthority|SuperAdminCap|AdminCap|AdminWitness)\b' \
    "$SOURCE_DIR"; then
    fail "administration types must come from blast_admin, never from a local copy"
fi

if rg -n 'fun (grant_admin|revoke_admin|sign_in)\(' "$SOURCE_DIR"; then
    fail "Migrators must not manage administrators"
fi

# The roles are the Launchpad domain's ability-free role types, which the launchpad gate pins.
LAUNCHPAD_ROLES="$(move_facts "$PACKAGE_DIR/../launchpad/sources/blast_fun_domain.move" \
    | awk -F'\t' '$1 == "TYPE" && $5 == 0 { print $2 }' | paste -sd '|')"
[[ -n "$LAUNCHPAD_ROLES" ]] || fail "the Launchpad role types must be readable"
if rg -n "^public struct (${LAUNCHPAD_ROLES})\\b" "$SOURCE_DIR"; then
    fail "Migrators must take the Launchpad's roles, never declare a same-named copy"
fi
# The witness type is each administrator action's role check, so every witness a source names is
# borrowed and names one concrete Launchpad role; a generic or foreign role fails here.
admin_witness_violations="$(for source in "$SOURCE_DIR"/*.move; do
    move_norm "$source" | { rg -o '&?AdminWitness<[^>]*>' || true; } \
        | { rg -v -x "&AdminWitness<(${LAUNCHPAD_ROLES})>" || true; } \
        | sed "s|^|$(basename "$source"): |"
done)"
[[ -z "$admin_witness_violations" ]] || \
    fail "every administrator witness must be a borrowed AdminWitness of one concrete Launchpad role: ${admin_witness_violations}"

for required in blast_fun_migrators.move package_admin.move; do
    [[ -f "$SOURCE_DIR/$required" ]] || \
        fail "Migrators must own $required"
done

rg -q '^public struct PackageVersion has key \{$' "$SOURCE_DIR/blast_fun_migrators.move" || \
    fail "Migrators must own one canonical generation container"
rg -q 'generation: OperationalVersion<BLAST_FUN_MIGRATORS>,' "$SOURCE_DIR/blast_fun_migrators.move" || \
    fail "the generation value must be the shared typed value"
rg -q '^const PACKAGE_VERSION: u64 = 1;$' "$SOURCE_DIR/blast_fun_migrators.move" || \
    fail "Migrators must compile its current generation constant"
rg -q '^const NEXT_PACKAGE_VERSION: u64 = 2;$' "$SOURCE_DIR/blast_fun_migrators.move" || \
    fail "Migrators must compile its cutover target constant"
if rg -n '\.checked_add\(|fun activate\(' "$SOURCE_DIR/blast_fun_migrators.move"; then
    fail "generation arithmetic and separate activation belong to blast_admin"
fi

rg -q 'custody: UpgradeCustody<BLAST_FUN_MIGRATORS>,' "$SOURCE_DIR/package_admin.move" || \
    fail "Migrators custody must hold the shared typed value"
rg -q 'public fun commit_upgrade_and_advance\(' "$SOURCE_DIR/package_admin.move" || \
    fail "Migrators must expose one atomic commit-and-advance finalizer"
if rg -n '^public fun commit_upgrade\(|^public fun activate' "$SOURCE_DIR/package_admin.move"; then
    fail "a separate receipt commit or activation entry point is forbidden"
fi
if rg -U -n '^public fun [^(]+\([^)]*\): (&)?(Publisher|UpgradeCap)' \
    "$SOURCE_DIR/package_admin.move"; then
    fail "no custody path may release the sealed Publisher or UpgradeCap"
fi
CUSTODY_ROLE_GATES="$(rg -c '^    _: &AdminWitness<UpgradeAdmin>,$' \
    "$SOURCE_DIR/package_admin.move" || true)"
[[ "${CUSTODY_ROLE_GATES:-0}" -eq 2 ]] || \
    fail "every governed custody transition must require Launchpad's upgrade-admin role"
# Upgrade authorization checks the current generation first, so a retired generation cannot
# authorize, and the finalizer proves the exact next generation first.
[[ "$(move_facts "$SOURCE_DIR/package_admin.move" \
    | awk -F'\t' '$1 == "FN" && $2 == "authorize_upgrade" { print $10 }')" \
    == 'package_version.assert_current();'* ]] || \
    fail "authorize_upgrade must check the current generation first"
[[ "$(move_facts "$SOURCE_DIR/package_admin.move" \
    | awk -F'\t' '$1 == "FN" && $2 == "commit_upgrade_and_advance" { print $10 }')" \
    == 'package_version.assert_next();'* ]] || \
    fail "commit_upgrade_and_advance must check the next generation first"
# Every administrator action takes exactly one role, the one pinned here, so no role reaches
# another role's action. A new function that takes a witness fails until it is mapped
# deliberately. The buybacks hand their witness to `take_buyback_quote`, whose bodies are pinned
# above.
admin_roles="$(for source in "$SOURCE_DIR"/*.move; do
    move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" '
        $1 == "FN" && $6 == 0 && index($9, "AdminWitness<") > 0 {
            rest = $9
            roles = ""
            while (match(rest, /AdminWitness<[^>]*>/)) {
                roles = roles (roles == "" ? "" : ",") substr(rest, RSTART + 13, RLENGTH - 14)
                rest = substr(rest, RSTART + RLENGTH)
            }
            print module ":" $2 ":" roles
        }
    '
done | LC_ALL=C sort)"
require_text "$admin_roles" \
    "every administrator action must take exactly its pinned role witness" <<'ROLES'
blast_holder_rewards:publish_round:RewardsAdmin
bluefin:buyback_and_burn:BuybackAdmin
cetus:buyback_and_burn:BuybackAdmin
lp_fee_policy:clear_coin_shares:FeeAdmin
lp_fee_policy:set_coin_shares:FeeAdmin
lp_fee_policy:set_default_shares:FeeAdmin
lp_fee_policy:set_protocol_destination:TreasuryAdmin
package_admin:authorize_upgrade:UpgradeAdmin
package_admin:commit_upgrade_and_advance:UpgradeAdmin
vault:claim_protocol_fees:TreasuryAdmin
vault:take_buyback_quote:BuybackAdmin
ROLES
# Venues gate callers by package version and launchpad cutovers advance its version, so this
# package must always be able to relink (ADR 0088): nothing may destroy its UpgradeCap. Every
# commit also advances the generation, and an additive or dependency-only upgrade cannot change the
# generation constants, so narrowing the policy would freeze the package at its next upgrade.
if rg -n '\bmake_immutable\b|\brestrict_to_' "$SOURCE_DIR"; then
    fail "the migrators package stays upgradeable under the compatible policy: no path may narrow its policy or make it immutable"
fi

# Every production public function in these modules is a protected mutation, except the vault's
# and the LP-fee policy's getters, whose names and exact signatures are pinned above. The getter
# exemption is limited to those two modules: elsewhere a function with only immutable parameters
# can still create a value, such as a sealed witness. The set comes from the Move reader, so
# spacing or line breaks cannot hide a function, and each one must take this package's generation
# and check it before doing anything else.
for guard_module in lp_fee_policy vault blast_holder_rewards bluefin cetus; do
    guard_facts="$(move_facts "$SOURCE_DIR/${guard_module}.move")"
    [[ "$guard_facts" != *MALFORMED* ]] || fail "the Move reader rejected ${guard_module}.move"
    unguarded="$(awk -F'\t' -v module="$guard_module" '
        $1 != "FN" || $3 != "public" || $6 != 0 { next }
        {
            parameters = substr($9, index($9, "(") + 1)
            parameters = substr(parameters, 1, index(parameters, ")") - 1)
        }
        (module == "vault" || module == "lp_fee_policy") && parameters !~ /&mut / && parameters !~ /: [A-Za-z]/ { next }
        index($9, " migrators_version: &MigratorsVersion,") == 0 \
            || index($10, "migrators_version.assert_current();") != 1 { print $2 }
    ' <<<"$guard_facts")"
    [[ -z "$unguarded" ]] || \
        fail "${guard_module} must take this package's generation and assert it first in every protected mutation (unguarded: ${unguarded//$'\n'/ })"
done

# In the venue and vault modules `package_version` names the Launchpad object.
# It may be passed through to a composed Launchpad call, but it may never stand
# in for this package's own guard. (`package_admin.move` owns no Launchpad
# input: its `package_version` parameter is this package's own container.)
for guard_module in lp_fee_policy vault blast_holder_rewards bluefin cetus; do
    if rg -n '^[[:space:]]+package_version\.assert_current\(\);' \
        "$SOURCE_DIR/${guard_module}.move"; then
        fail "${guard_module}.move must not assert the Launchpad generation as if it were its own"
    fi
done

# The fee-split fixture models the only safe collection shape: one adapter-only wrapper withdraws
# the attached position's fees and splits them through the vault in the same call, and one checks
# the update, settles through that wrapper, and then commits the new split.
FEE_SPLIT_UPDATE_TEST="$PACKAGE_DIR/tests/fee_split_update_tests.move"
[[ -f "$FEE_SPLIT_UPDATE_TEST" ]] || fail "missing the sealed fee-split update adapter fixture"
[[ "$(move_norm "$FEE_SPLIT_UPDATE_TEST" | rg -o '\.split_fees\(' | wc -l)" -eq 1 ]] || \
    fail "only the fixture's adapter wrapper may call the vault split"
[[ "$(move_norm "$FEE_SPLIT_UPDATE_TEST" | rg -o '\.assert_fee_split_update\(' | wc -l)" -eq 1 \
    && "$(move_norm "$FEE_SPLIT_UPDATE_TEST" | rg -o '\.update_fee_split\(' | wc -l)" -eq 1 ]] || \
    fail "only the fixture's settling wrapper may check and commit the vault split update"

# T-010's cross-package conformance adapter migrates, then locks the child position in a new
# shared vault, and exposes no protected return. Only order anchors are pinned, on whitespace-free
# text so formatting cannot change the verdict.
ATOMIC_MIGRATION_TEST="$PACKAGE_DIR/tests/atomic_migration_tests.move"
[[ -f "$ATOMIC_MIGRATION_TEST" ]] || fail "missing T-010 atomic migration adapter fixture"
atomic_facts="$(move_facts "$ATOMIC_MIGRATION_TEST")"
[[ "$atomic_facts" != *MALFORMED* ]] || fail "the Move reader rejected the atomic migration fixture"
atomic_public="$(awk -F'\t' '$1 == "FN" && $3 == "public" { print $2 ":" $9 }' <<<"$atomic_facts")"
atomic_body="$(awk -F'\t' '$1 == "FN" && $2 == "mock_adapter_with" { print $10 }' <<<"$atomic_facts" \
    | tr -d '[:space:]' | sed 's/,)/)/g')"

[[ "$atomic_public" == mock_adapter:* && "$atomic_public" != *$'\n'* && "$atomic_public" != *'):'* ]] || \
    fail "the atomic fixture's only public function must be the unit-returning mock_adapter"
in_order \
    'launch.migrate(' \
    'vault::create(launch,&Venue(),pool_id,position,liquidity,' \
    'transfer::share_object(pool)' \
    <<<"$atomic_body" || \
    fail "atomic adapter must migrate, then lock the position in a new vault"

# No public migrator function, in any source or the atomic fixture, may hand out a raw balance, a
# position, a vault, a round, a pool, or the reserved pool creation capability.
protected_returners="$(for file in "$SOURCE_DIR"/*.move "$ATOMIC_MIGRATION_TEST"; do move_facts "$file"; done \
    | awk -F'\t' '
        $1 == "MALFORMED" { print "MALFORMED" }
        $1 == "FN" && $3 == "public" && $6 == 0 && index($9, "):") > 0 {
            if (substr($9, index($9, "):") + 2) ~ /(^|[^A-Za-z0-9_])(Balance|LpVault|Round|Position|Pool|PoolCreationCap)([^A-Za-z0-9_]|$)/) print $2
        }')"
[[ -z "$protected_returners" ]] || \
    fail "public functions must not return balances or custody objects: $protected_returners"

echo "Migrator source boundaries passed"
