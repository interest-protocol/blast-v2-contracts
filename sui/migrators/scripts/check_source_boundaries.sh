#!/usr/bin/env bash
set -euo pipefail
python3 "$(dirname "$0")/../../../scripts/check_admin_delay.py"

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$PACKAGE_DIR/sources"
BLUEFIN_SOURCE="$SOURCE_DIR/venues/bluefin.move"
CETUS_SOURCE="$SOURCE_DIR/venues/cetus.move"
EVENTS_SOURCE="$SOURCE_DIR/lib/events.move"
ERRORS_SOURCE="$SOURCE_DIR/lib/errors.move"
VENUE_CONFIG_SOURCE="$SOURCE_DIR/venues/venue_config.move"
CONSTANTS_SOURCE="$SOURCE_DIR/lib/constants.move"
mapfile -t source_files < <(find "$SOURCE_DIR" -type f -name '*.move' -print | LC_ALL=C sort)

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



# === Package surface ===
#
# The package is exactly these modules, and each file declares only its own, so any new module (a
# future venue included) fails here until it extends this gate explicitly. No module declares an
# `entry` function, and every module's public and package functions are pinned below with their
# exact signatures, so no helper or type parameter can lend a venue witness, the reserved creation
# cap, or a vault's position to a new caller. Vault custody, LP-fee collection, and holder rewards
# belong to `blast_vault`; the retired migrator vault, LP-fee policy, holder rewards, and Merkle
# modules may not return.
[[ "$(find "$SOURCE_DIR" -type f -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ')" \
    == 'blast_migrators.move lib/constants.move lib/errors.move lib/events.move venues/bluefin.move venues/cetus.move venues/venue_config.move ' ]] || \
    fail "sources must be exactly the pinned module set; a new module must extend this gate"
for source in "${source_files[@]}"; do
    module="$(basename "$source" .move)"
    facts="$(move_facts "$source")"
    [[ "$facts" != *MALFORMED* ]] || fail "the Move reader rejected ${module}.move"
    [[ "$(awk -F'\t' '$1 == "NORM" { print $2 }' <<<"$facts" | rg -o '\bmodule [^ ;{]+')" \
        == "module blast_migrators::${module}" ]] || \
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
# lends the reserved creation cap), or a changed parameter fails here until this pin is extended
# deliberately.
package_surface="$(for source in "${source_files[@]}"; do
    move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" \
        '$1 == "FN" && $6 == 0 && $7 == 0 && $3 != "private" { print module ":" $3 ":" $9 }'
done | LC_ALL=C sort)"
require_text "$package_surface" \
    "the package's public and package functions must have exactly the pinned signatures" <<'EOF'
bluefin:public:fun buyback_and_burn<Meme, Quote>( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, admin_witness: &AdminWitness<BuybackAdmin>, currency: &mut Currency<Meme>, bluefin_config: &GlobalConfig, pool: &mut Pool<Meme, Quote>, quote_in: u64, min_meme_out: u64, clock: &Clock, ctx: &mut TxContext, )
bluefin:public:fun collect_fees<Meme, Quote>( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, currency: &mut Currency<Meme>, bluefin_config: &GlobalConfig, pool: &mut Pool<Meme, Quote>, clock: &Clock, ctx: &mut TxContext, )
bluefin:public:fun compound_auto_lp<Meme, Quote>( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, bluefin_config: &GlobalConfig, pool: &mut Pool<Meme, Quote>, clock: &Clock, )
bluefin:public:fun migrate<Meme, Quote>( migration: Migration<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, venue_config: &VenueConfig, currency: &Currency<Meme>, quote_currency: &Currency<Quote>, bluefin_config: &mut GlobalConfig, registry: &mut VaultRegistry, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, creation_fee: Coin<SUI>, clock: &Clock, ctx: &mut TxContext, )
bluefin:public:fun prepare<Meme, Quote>( migrators_version: &PackageVersion<BLAST_MIGRATORS>, venue_config: &mut VenueConfig, _: &TreasuryCap<Meme>, currency: &Currency<Meme>, tick_spacing: u32, fee_rate: u64, ): VenueTicket<Meme, Quote>
bluefin:public:fun settle_and_apply_fee_split<Meme, Quote>( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, currency: &mut Currency<Meme>, bluefin_config: &GlobalConfig, pool: &mut Pool<Meme, Quote>, clock: &Clock, ctx: &mut TxContext, )
cetus:public:fun buyback_and_burn<Meme, Quote, CoinA, CoinB>( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, admin_witness: &AdminWitness<BuybackAdmin>, currency: &mut Currency<Meme>, cetus_config: &GlobalConfig, pool: &mut Pool<CoinA, CoinB>, quote_in: u64, min_meme_out: u64, clock: &Clock, ctx: &mut TxContext, )
cetus:public:fun collect_fees<Meme, Quote, CoinA, CoinB>( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, currency: &mut Currency<Meme>, cetus_config: &GlobalConfig, burn_manager: &BurnManager, pool: &mut Pool<CoinA, CoinB>, ctx: &mut TxContext, )
cetus:public:fun compound_auto_lp<Meme, Quote, CoinA, CoinB>( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, cetus_config: &GlobalConfig, pool: &mut Pool<CoinA, CoinB>, clock: &Clock, ctx: &mut TxContext, )
cetus:public:fun migrate<Meme, Quote, CoinA, CoinB>( migration: Migration<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, venue_config: &VenueConfig, cetus_config: &GlobalConfig, pools: &mut Pools, burn_manager: &mut BurnManager, registry: &mut VaultRegistry, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, clock: &Clock, ctx: &mut TxContext, )
cetus:public:fun prepare<Meme, Quote>( migrators_version: &PackageVersion<BLAST_MIGRATORS>, venue_config: &mut VenueConfig, cetus_config: &GlobalConfig, pools: &mut Pools, treasury_cap: &mut TreasuryCap<Meme>, tick_spacing: u32, ctx: &mut TxContext, ): VenueTicket<Meme, Quote>
cetus:public:fun settle_and_apply_fee_split<Meme, Quote, CoinA, CoinB>( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, currency: &mut Currency<Meme>, cetus_config: &GlobalConfig, burn_manager: &BurnManager, pool: &mut Pool<CoinA, CoinB>, clock: &Clock, ctx: &mut TxContext, )
constants:package:fun auto_lp_margin(): u256
constants:package:fun bluefin_max_fee_rate(): u64
constants:package:fun bluefin_max_tick_spacing(): u32
constants:package:fun max_meme_symbol_length(): u64
constants:package:fun max_swap_sqrt_price(): u128
constants:package:fun min_swap_sqrt_price(): u128
constants:package:fun q128_shift(): u8
constants:package:fun q64_shift(): u8
constants:package:fun version(): u64
errors:package:fun invalid_coin_order(): u64
errors:package:fun invalid_tier(): u64
errors:package:fun position_pool_mismatch(): u64
errors:package:fun symbol_too_long(): u64
errors:package:fun wrong_coin_pair(): u64
events:package:fun bluefin_pool_tier_recorded<Meme, Quote>(tick_spacing: u32, fee_rate: u64)
events:package:fun cetus_pool_reserved<Meme, Quote>(pool_creation_cap_id: ID, tick_spacing: u32)
venue_config:package:fun add_object<Key: copy + drop + store, Object: key + store>( self: &mut VenueConfig, key: Key, object: Object, )
venue_config:package:fun add_value<Key: copy + drop + store, Value: store>( self: &mut VenueConfig, key: Key, value: Value, )
venue_config:package:fun object<Key: copy + drop + store, Object: key + store>( self: &VenueConfig, key: Key, ): &Object
venue_config:package:fun value<Key: copy + drop + store, Value: store>( self: &VenueConfig, key: Key, ): &Value
EOF
# Every rename in the package is pinned. The rules here match protected types and calls by name,
# so a type, function, or method alias under a new name (`Venue as Seal`, a `use fun` that
# shadows `assert_current`) would hide them; each alias must be extended here deliberately.
package_aliases="$(for source in "${source_files[@]}"; do
    move_norm "$source" | rg -o -P '[\w:]+ as (?!u(8|16|32|64|128|256)\b(?!\.))[\w.]+' \
        | sed "s|^|$(basename "$source" .move): |"
done | LC_ALL=C sort)"
require_text "$package_aliases" \
    "every rename and method alias in the package must be exactly the pinned set" <<'EOF'
bluefin: collect_position_fees as Vault.collect_position_fees
bluefin: compound as Vault.compound
bluefin: fixed_side as Pool.fixed_side
bluefin: full_range_tick_range as GlobalConfig.full_range_tick_range
bluefin: is_meme_seed_side as Pool.is_meme_seed_side
bluefin: pool_name as Currency.pool_name
bluefin: seed as Pool.seed
bluefin: settle_fees as Vault.settle_fees
cetus: add_liquidity as Vault.add_liquidity
cetus: cast as UID.cast
cetus: collect_position_fees as Vault.collect_position_fees
cetus: compound as Vault.compound
cetus: fixed_side as Pool.fixed_side
cetus: pool_creation_cap as VenueConfig.pool_creation_cap
cetus: settle_fees as Vault.settle_fees
cetus: swap as Pool.swap
cetus: swap_quote_for_meme as Pool.swap_quote_for_meme
venue_config: dynamic_field::add as UID.add_dynamic_field
venue_config: dynamic_field::borrow as UID.dynamic_field
venue_config: dynamic_object_field::add as UID.add_dynamic_object_field
venue_config: dynamic_object_field::borrow as UID.dynamic_object_field
EOF
# Both versions are `blast_admin`'s generic `PackageVersion`, typed by the one-time witness (OTW)
# of the package each route checks: this package's own for the guard, the vault package's for the vault calls.
for module in bluefin cetus; do
    [[ "$(move_norm "$SOURCE_DIR/venues/${module}.move" | rg -o 'use blast_admin::[^;]*;')" \
        == 'use blast_admin::{blast_acl::AdminWitness, package_version::PackageVersion};' ]] || \
        fail "${module}.move must import blast_admin's generic PackageVersion once, unaliased"
done
# Every abort the package raises is a numeric code of the one registry, renumbered from zero, and
# the registry holds no state or assertion: no other module declares an error constant.
if rg -q '#\[error|\bconst E\w*' "$SOURCE_DIR" --glob '!errors.move'; then
    fail "errors must come from the package registry, never a module-local constant"
fi
[[ "$(move_facts "$ERRORS_SOURCE" | awk -F'\t' '$1 == "FN" { gsub(/[[:space:]]/, "", $10); print $2 ":" $10 }' | tr '\n' ' ')" \
    == 'invalid_coin_order:0 position_pool_mismatch:1 wrong_coin_pair:2 invalid_tier:3 symbol_too_long:4 ' ]] || \
    fail "the error registry must be exactly coin order 0, vault pool 1, coin pair 2, Bluefin tier 3, and symbol 4"

# === Release venue matrix ===
#
# Cetus and Bluefin are the release's only venues (ADR 0137). A venue reaches the hand-off seams
# (issuing a `VenueTicket`, migrating a launch, and redeeming its `Migration`) only by constructing
# its own sealed `Venue()`, so the matrix is exactly the modules that declare a venue witness and
# name those seams. Each prepares its coins through `prepare`, which ends by issuing the ticket,
# and migrates by redeeming the hand-off and creating a `blast_vault` vault from the redeemed terms,
# with its position attached, under its own witness; only Cetus needs local normalized venue
# interfaces. A future venue extends this matrix explicitly. The retired migration witness may
# not return.
matrix_venue_modules=""
matrix_seam_modules=""
for source in "${source_files[@]}"; do
    module="$(basename "$source" .move)"
    facts="$(move_facts "$source")"
    if awk -F'\t' '$1 == "TYPE" && $2 == "Venue" { found = 1 } END { exit !found }' <<<"$facts"; then
        matrix_venue_modules+="$module"$'\n'
    fi
    if awk -F'\t' '$1 == "NORM" { print $2 }' <<<"$facts" | rg -q \
        '\b(issue_ticket|redeem_ticket)\b|\.redeem\(|\bMigration<|\bvault::new\b'; then
        matrix_seam_modules+="$module"$'\n'
    fi
done
matrix_venue_modules="$(LC_ALL=C sort <<<"$matrix_venue_modules" | tr '\n' ' ' | sed 's/^ *//')"
matrix_seam_modules="$(LC_ALL=C sort <<<"$matrix_seam_modules" | tr '\n' ' ' | sed 's/^ *//')"
[[ "$matrix_venue_modules" == 'bluefin cetus ' ]] || \
    fail "only Cetus and Bluefin may declare a venue witness (found: ${matrix_venue_modules:-none})"
[[ "$matrix_seam_modules" == 'bluefin cetus ' ]] || \
    fail "only Cetus and Bluefin may reach the hand-off seams (found: ${matrix_seam_modules:-none})"
if rg -q '\bstruct Witness\b|\bWitness\(\)' "$SOURCE_DIR"; then
    fail "the retired migration witness is forbidden; each venue's one witness is its Venue"
fi
for module in $matrix_venue_modules; do
    venue_facts="$(move_facts "$SOURCE_DIR/venues/${module}.move")"
    [[ "$(move_production_type Venue <<<"$venue_facts")" == 'struct Venue() has drop;' ]] || \
        fail "${module}::Venue must be a field-free drop-only witness"
    # The ticket is issued once, at the end of `prepare`, and the hand-off is redeemed once, at the
    # start of `migrate`'s custody, each under the module's own witness.
    [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "issue_ticket") > 0 { print $2 }' \
        <<<"$venue_facts")" == 'prepare' ]] \
        && [[ "$(awk -F'\t' '$1 == "FN" && $2 == "prepare" && $6 == 0 { print $10 }' <<<"$venue_facts" \
            | tr -d '[:space:]')" == 'migrators_version.assert_current(constants::version!());'*';migration::issue_ticket(Venue())' ]] || \
        fail "${module}::prepare alone must check this package's version first and end by issuing its own venue's ticket"
    custody_body="$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, ".redeem(") > 0 { print $2 "|" $10 }' \
        <<<"$venue_facts" | tr -d '[:space:]')"
    [[ "$custody_body" == 'migrate|migrators_version.assert_current(constants::version!());'* ]] \
        && in_order \
            'migration.redeem(Venue());' \
            'vault::new<Meme,Quote,_>(registry,&Venue(),vault_version,terms,pool_id).share_with_position(&Venue(),treasury,' \
            <<<"$custody_body" || \
        fail "${module}::migrate alone must redeem the hand-off under its own witness, then create and share a blast_vault vault from the redeemed terms"
done
[[ -n "$(find "$PACKAGE_DIR/interfaces" -mindepth 1 -maxdepth 1 -printf '%f\n')" \
    && -z "$(find "$PACKAGE_DIR/interfaces" -mindepth 1 -maxdepth 1 -printf '%f\n' \
        | rg -v '^cetus(_[a-z_]+)?$')" ]] || \
    fail "only Cetus packages may have local venue interfaces; an excluded venue keeps no interface"
# A sealed witness never leaves its venue: no venue function, whatever its visibility, names the
# witness in its signature, so none returns it or fills a caller's container with it. Only the
# two `prepare` routes return a ticket, and no route returns the hand-off.
for module in $matrix_venue_modules; do
    if move_facts "$SOURCE_DIR/venues/${module}.move" | awk -F'\t' '
        $1 == "FN" && $9 ~ /[^A-Za-z0-9_]Venue([^A-Za-z0-9_]|$)/ { found = 1 }
        END { exit !found }'; then
        fail "${module}::Venue must never appear in any ${module} function signature"
    fi
done
[[ "$(for source in "${source_files[@]}"; do
    move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" \
        '$1 == "FN" && index($9, "VenueTicket") > 0 { print module ":" $2 }'
done | LC_ALL=C sort | tr '\n' ' ')" == 'bluefin:prepare cetus:prepare ' ]] || \
    fail "only the venues' prepare routes may return a VenueTicket"
# Each venue's `migrate` takes the hand-off its product returned earlier in the PTB as its first
# argument and redeems it in place; no other function names the hand-off type, and none returns it.
[[ "$(for source in "${source_files[@]}"; do
    move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" \
        '$1 == "FN" && $6 == 0 && index($9, "Migration<") > 0 { print module ":" $2 ":" (index($9, "( migration: Migration<Meme, Quote>,") > 0 && index($9, "):") == 0) }'
done | LC_ALL=C sort | tr '\n' ' ')" == 'bluefin:migrate:1 cetus:migrate:1 ' ]] || \
    fail "only the venues' migrate routes may take the hand-off, first and by value, and none may return it"
if rg -q '\bblast_(fun|presale)\b' "$SOURCE_DIR" "$PACKAGE_DIR/tests" "$PACKAGE_DIR/Move.toml"; then
    fail "the migrators must import no product; products hand off through blast_core's Migration"
fi
# Each venue records its prepared coin's tier under a key of its own module, so one venue can
# never read another's tier.
for module in $matrix_venue_modules; do
    [[ "$(move_production_type PoolTierKey <<<"$(move_facts "$SOURCE_DIR/venues/${module}.move")")" \
        == 'struct PoolTierKey<phantom Meme>() has copy, drop, store;' ]] || \
        fail "${module} must key its prepared tier by its own PoolTierKey<Meme>"
done

# The seed price is core's `migration::sqrt_price_x64`, the one the presale checks at creation, so no
# venue derives its own, and no shared math module exists: each venue owns its seed and auto-LP
# side selection beside its only caller.
[[ ! -e "$SOURCE_DIR/migration_math.move" ]] || fail "venue math lives beside its caller, not in a separate math module"
if rg -q '\b(integer_sqrt|ratio_q128|sqrt_upper_bound_shift)\b|fun sqrt_price_x64' "$SOURCE_DIR"; then
    fail "the seed price must be blast_core's sqrt_price_x64, never a local copy"
fi
for module in bluefin cetus; do
    [[ "$(move_norm "$SOURCE_DIR/venues/${module}.move" | grep -o 'migration::sqrt_price_x64(' | wc -l)" -eq 1 ]] || \
        fail "${module}::migrate must price its pool once with blast_core's sqrt_price_x64"
done
# Auto-LP side selection adds nothing unless the price is strictly inside the range, checked first
# so every later subtraction is positive, and then prefers fixing coin A. Each side's check needs
# positive liquidity (below 2^128 when fixing A) and leaves the pinned margin of the other unused;
# an empty side yields zero liquidity or a need it cannot meet.
# Bluefin owns it, privately, beside its only caller `fixed_side`.
math_body() {
    move_facts "$BLUEFIN_SOURCE" | awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name && $6 == 0 { print $10 }' \
        | tr -d '[:space:]'
}
[[ "$(move_facts "$BLUEFIN_SOURCE" | awk -F'\t' '$1 == "FN" && $6 == 0 && ($2 == "auto_lp_fixed_side" || $2 == "can_fix_a" || $2 == "can_fix_b") { print $2 ":" $3 }' | LC_ALL=C sort | tr '\n' ' ')" \
    == 'auto_lp_fixed_side:private can_fix_a:private can_fix_b:private ' ]] || \
    fail "Bluefin's auto-LP side selection must be private to bluefin"
[[ "$(constant_body auto_lp_margin)" == '2' ]] \
    && [[ "$(math_body auto_lp_fixed_side)" == 'if(sqrt_price<=sqrt_lower||sqrt_price>=sqrt_upper)return(true,0);let(lower,price,upper)=(sqrt_lowerasu256,sqrt_priceasu256,sqrt_upperasu256);if(can_fix_a(lower,price,upper,amount_a,amount_b))return(true,amount_a);if(can_fix_b(lower,price,upper,amount_a,amount_b))return(false,amount_b);(true,0)' ]] \
    && [[ "$(math_body can_fix_a)" == 'letone=1u256<<constants::q64_shift!();letliquidity=(amount_aasu256)*(price*upper/one)/(upper-price);if(liquidity==0||liquidity>=(1u256<<constants::q128_shift!()))returnfalse;letneeded_b=(liquidity*(price-lower)).div_ceil(one);needed_b+constants::auto_lp_margin!()<=(amount_basu256)' ]] \
    && [[ "$(math_body can_fix_b)" == 'letliquidity=((amount_basu256)<<constants::q64_shift!())/(price-lower);if(liquidity==0)returnfalse;letneeded_a=(liquidity<<constants::q64_shift!()).div_ceil(price)-(liquidity<<constants::q64_shift!())/upper;needed_a+constants::auto_lp_margin!()<=(amount_aasu256)' ]] || \
    fail "auto-LP side selection must first skip out-of-range prices, prefer coin A, and keep a two-atom margin"

# === Events ===
#
# The package's two replay facts are the pool tier each venue records while preparing a pair: the
# Cetus pool reservation, written only by `cetus::prepare`, and the Bluefin pool tier, written only
# by `bluefin::prepare` after it stores the tier and before it issues the ticket. Each is a direct,
# raw payload typed by the pair's phantom `Meme` and `Quote`, as in `blast_vault_events`, with
# exactly one emitting helper. Vault creation, LP-fee collection,
# auto-LP, buybacks, owner claims, and holder rewards are `blast_vault` events, and delayed
# settings and the PackageAdmin record their lifecycle through `blast_admin`, so no migrator event
# may restate them.
[[ "$(move_facts "$EVENTS_SOURCE" | awk -F'\t' '$1 == "TYPE" && $5 == 0 { print $2 }' \
    | LC_ALL=C sort | tr '\n' ' ')" == 'BluefinPoolTierRecorded CetusPoolReserved ' ]] || \
    fail "events.move must declare exactly the Cetus pool reservation and Bluefin pool tier payloads"
[[ "$(move_production_type CetusPoolReserved <<<"$(move_facts "$EVENTS_SOURCE")")" \
    == 'struct CetusPoolReserved<phantom Meme, phantom Quote> has copy, drop { pool_creation_cap_id: ID, tick_spacing: u32, }' ]] || \
    fail "CetusPoolReserved must be typed by the pair and record the reserved capability and the tick spacing"
[[ "$(move_production_type BluefinPoolTierRecorded <<<"$(move_facts "$EVENTS_SOURCE")")" \
    == 'struct BluefinPoolTierRecorded<phantom Meme, phantom Quote> has copy, drop { tick_spacing: u32, fee_rate: u64, }' ]] || \
    fail "BluefinPoolTierRecorded must be typed by the pair and record the tick spacing and the fee rate"
[[ "$(rg -c 'sui::event::emit\(CetusPoolReserved<Meme, Quote> \{' "$EVENTS_SOURCE" || true)" -eq 1 \
    && "$(rg -c 'sui::event::emit\(BluefinPoolTierRecorded<Meme, Quote> \{' "$EVENTS_SOURCE" || true)" -eq 1 \
    && "$(rg -o 'sui::event::emit' "$EVENTS_SOURCE" | wc -l)" -eq 2 ]] || \
    fail "CetusPoolReserved and BluefinPoolTierRecorded must be the only payloads, each emitted directly by exactly one helper"
[[ "$(move_facts "$EVENTS_SOURCE" | awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "sui::event::emit(CetusPoolReserved<Meme, Quote> {") > 0 { print $2 }')" == 'cetus_pool_reserved' \
    && "$(move_facts "$EVENTS_SOURCE" | awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "sui::event::emit(BluefinPoolTierRecorded<Meme, Quote> {") > 0 { print $2 }')" == 'bluefin_pool_tier_recorded' ]] || \
    fail "each migrator event must be emitted only by its own typed helper"
if rg -q 'sui::event::emit' "$SOURCE_DIR" --glob '*.move' --glob '!events.move'; then
    fail "state modules must emit only through typed events helpers"
fi
if rg -q '\bTypeName\b|type_name::' "$EVENTS_SOURCE"; then
    fail "migrator events carry the pair as phantom type parameters, never as TypeName fields"
fi
reject_pattern 'protocol_meme_fee_total|creator_meme_fee_total|protocol_quote_fee_total|creator_quote_fee_total' \
    'derivable fee totals are forbidden in migrator events'
if rg -q '\b(VenueTierUpdated|venue_tier_updated|RoutesChanged|routes_changed|PolicySnapshot)\b' \
    "$SOURCE_DIR"; then
    fail "venue tiers and fee routes are sale settings and the Blast share is sealed in the vault terms; no admin tier, route, or snapshot record may return"
fi
reservation_writers="$(for source in "${source_files[@]}"; do
    [[ "$source" == "$EVENTS_SOURCE" ]] && continue
    move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" \
        '$1 == "FN" && $6 == 0 && index($10, "events::cetus_pool_reserved<") > 0 { print module ":" $2 }'
done | LC_ALL=C sort | tr '\n' ' ')"
[[ "$reservation_writers" == 'cetus:prepare ' ]] || \
    fail "CetusPoolReserved must be emitted only by cetus:prepare (found: ${reservation_writers:-none})"
tier_writers="$(for source in "${source_files[@]}"; do
    [[ "$source" == "$EVENTS_SOURCE" ]] && continue
    move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" \
        '$1 == "FN" && $6 == 0 && index($10, "events::bluefin_pool_tier_recorded<") > 0 { print module ":" $2 }'
done | LC_ALL=C sort | tr '\n' ' ')"
[[ "$tier_writers" == 'bluefin:prepare ' ]] || \
    fail "BluefinPoolTierRecorded must be emitted only by bluefin:prepare (found: ${tier_writers:-none})"

# === Vault custody ===
#
# The package holds no value of its own: every position, residual, and LP fee lives in the
# `blast_vault` vault each migration creates, which pays Blast through the core treasury and owns
# the fee split, auto-LP, buyback, and holder-reward balances. No migrator type stores a balance or
# a coin, and no module declares a vault, a fee policy, a treasury destination, or a round.
for source in "${source_files[@]}"; do
    if move_facts "$source" | awk -F'\t' '
        $1 == "TYPE" && $5 == 0 && $8 ~ /(^|[^A-Za-z0-9_])(Balance|Coin|Table|Bag)</ { found = 1 }
        END { exit !found }'; then
        fail "$(basename "$source") must hold no balance, coin, or collection; vault custody belongs to blast_vault"
    fi
done
if rg -q '\b(LpVault|LpFeePolicy|lp_fee_policy|blast_holder_rewards|Round<|merkle::|protocol_destination)\b' \
    "$SOURCE_DIR"; then
    fail "the retired migrator vault, LP-fee policy, holder rewards, and Merkle paths are forbidden"
fi
if rg -q 'vault::(create|share_for_testing)\b|share_for_testing' "$SOURCE_DIR"; then
    fail "venues must share their vault only through blast_vault's share_with_position"
fi

# === Venue config ===

require_pattern "$VENUE_CONFIG_SOURCE" 'public struct VenueConfig has key' \
    'shared venue-owned entry singleton'
require_pattern "$VENUE_CONFIG_SOURCE" 'transfer::share_object\(VenueConfig' \
    'shared venue config creation'
# The whole production API is package-only: write-once objects and plain records added under keys
# only a venue module constructs, and their immutable reads. Pool tiers are the creator's
# preparation settings, so no admin tier, reservation policy, or tier error may return.
require_text "$(move_facts "$VENUE_CONFIG_SOURCE" \
    | awk -F'\t' '$1 == "FN" && $6 == 0 { print $3 ":" $9 }' | LC_ALL=C sort)" \
    "VenueConfig must expose exactly its package-only object and record functions" <<'EOF'
package:fun add_object<Key: copy + drop + store, Object: key + store>( self: &mut VenueConfig, key: Key, object: Object, )
package:fun add_value<Key: copy + drop + store, Value: store>( self: &mut VenueConfig, key: Key, value: Value, )
package:fun object<Key: copy + drop + store, Object: key + store>( self: &VenueConfig, key: Key, ): &Object
package:fun value<Key: copy + drop + store, Value: store>( self: &VenueConfig, key: Key, ): &Value
private:fun init(ctx: &mut TxContext)
EOF
# Venue entries are write-once: no function borrows, replaces, or removes an entry.
if move_norm "$VENUE_CONFIG_SOURCE" | rg -q '\bborrow_mut\b|_field_mut\b|\bremove(_if_exists|_opt)?\b|\breplace\b' \
    || rg -q '#\[error' "$VENUE_CONFIG_SOURCE" \
    || rg -q '\b(TierKey|ReservationKey|set_tier|has_tier|effective_tier|reserved_tick_spacing|add_policy|has_policy)\b' \
        "$SOURCE_DIR"; then
    fail "venue entries must be write-once, and no admin tier or reservation policy may return"
fi
# Only the two preparations write records, and only the two migrations read them.
venue_record_sites="$(for module in bluefin cetus; do
    move_facts "$SOURCE_DIR/venues/${module}.move" | awk -F'\t' -v module="$module" '
        $1 == "FN" && $6 == 0 && index($10, "venue_config.add_value(") > 0 { print module ":" $2 " adds" }
        $1 == "FN" && $6 == 0 && index($10, "venue_config.value(") > 0 { print module ":" $2 " reads" }'
done | LC_ALL=C sort | tr '\n' ' ')"
[[ "$venue_record_sites" == 'bluefin:migrate reads bluefin:prepare adds cetus:migrate reads cetus:prepare adds ' ]] || \
    fail "only each venue's prepare may record its tier and only its migrate may read it (found: ${venue_record_sites:-none})"

# === Bluefin ===

require_pattern "$BLUEFIN_SOURCE" 'public struct Venue\(\) has drop;' 'sealed Bluefin venue witness'
# Bluefin has exactly one preparation, one atomic migrate route, one collection entry, one settled
# update entry, one compounding entry, and one buyback entry. Preparation checks the creator's
# tier against Bluefin's bounds, records it, emits the tier, and issues the ticket; migration
# reads that tier, redeems the hand-off, creates and funds the pool, creates and shares the vault
# holding the venue position, then shares the pool; every fee exit splits the collected
# position's fees through the vault and leaves the auto-LP share waiting; and compounding, on its
# own, adds that share back to the same position so a venue refusal never blocks collection. The
# buyback swaps the admin's `quote_in` of the vault's burn Quote for Meme in the vault's own pool
# and hands the result to the vault, which checks the admin's minimum and burns it.
bluefin_facts="$(move_facts "$BLUEFIN_SOURCE")"
[[ "$bluefin_facts" != *MALFORMED* ]] || fail "the Move reader rejected bluefin.move"
bluefin_public="$(awk -F'\t' '$1 == "FN" && $3 == "public" && $6 == 0 { print $2 }' <<<"$bluefin_facts" \
    | LC_ALL=C sort | tr '\n' ' ')"
[[ "$bluefin_public" == 'buyback_and_burn collect_fees compound_auto_lp migrate prepare settle_and_apply_fee_split ' ]] || \
    fail "Bluefin must expose exactly prepare, migrate, collect_fees, settle_and_apply_fee_split, compound_auto_lp, and buyback_and_burn"
bluefin_body() {
    awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name { print $10 }' <<<"$bluefin_facts" \
        | tr -d '[:space:]' | sed 's/,)/)/g'
}
[[ "$(bluefin_body prepare)" == 'migrators_version.assert_current(constants::version!());assert!(tick_spacing>0&&tick_spacing<=constants::bluefin_max_tick_spacing!()&&fee_rate>0&&fee_rate<=constants::bluefin_max_fee_rate!(),blast_migrators::errors::invalid_tier!());assert!(currency.symbol().length()<=constants::max_meme_symbol_length!(),blast_migrators::errors::symbol_too_long!());venue_config.add_value(PoolTierKey<Meme>(),PoolTier{tick_spacing,fee_rate});events::bluefin_pool_tier_recorded<Meme,Quote>(tick_spacing,fee_rate);migration::issue_ticket(Venue())' ]] \
    && [[ "$(move_production_type PoolTier <<<"$bluefin_facts")" == 'struct PoolTier has copy, drop, store { tick_spacing: u32, fee_rate: u64, }' ]] \
    && [[ "$(constant_body bluefin_max_tick_spacing)" == '400' ]] \
    && [[ "$(constant_body bluefin_max_fee_rate)" == '20_000' ]] \
    && [[ "$(constant_body max_meme_symbol_length)" == '32' ]] || \
    fail "bluefin::prepare must bound the tier to Bluefin's 1..=400 tick spacing and 1..=20,000 fee rate and the Meme symbol to 32 bytes, record the tier, emit its tier event, then issue the ticket"
bluefin_migrate_body="$(bluefin_body migrate)"
# Migration reads the recorded tier and the full-range bounds from Bluefin's config, redeems the
# hand-off, creates the named pool priced from the handed-off balances with the caller's whole
# creation fee, opens and seeds a full-range position, creates and shares the vault holding the
# position under the redeemed terms, then shares the pool.
[[ "$bluefin_migrate_body" == 'migrators_version.assert_current(constants::version!());let(meme,quote,terms)=migration.redeem(Venue());letPoolTier{tick_spacing,fee_rate}=*venue_config.value(PoolTierKey<Meme>());let(lower_tick,upper_tick)=bluefin_config.full_range_tick_range(tick_spacing);letmutpool=pool::create_pool_and_get_object<Meme,Quote,SUI>(clock,bluefin_config,currency.pool_name(quote_currency),b"",currency.symbol().into_bytes(),currency.decimals(),b"",quote_currency.symbol().into_bytes(),quote_currency.decimals(),quote_currency.icon_url().into_bytes(),tick_spacing,fee_rate,migration::sqrt_price_x64(meme.value(),quote.value(),true),creation_fee.into_balance(),ctx);letmutposition=pool::open_position(bluefin_config,&mutpool,lower_tick,upper_tick,ctx);let(residual_meme,residual_quote)=pool.seed(bluefin_config,&mutposition,meme,quote,clock);letpool_id=position.pool_id();letliquidity=position.liquidity();vault::new<Meme,Quote,_>(registry,&Venue(),vault_version,terms,pool_id).share_with_position(&Venue(),treasury,position,liquidity,residual_meme,residual_quote,ctx);pool.share_pool_object();' ]] \
    && [[ "$(bluefin_body full_range_tick_range)" == 'let(minimum_tick,maximum_tick)=bluefin_config.get_tick_range();letspacing=i32::from(tick_spacing);(minimum_tick.div(spacing).mul(spacing).as_u32(),maximum_tick.div(spacing).mul(spacing).as_u32())' ]] || \
    fail "Bluefin migrate must redeem the hand-off, create and fund the pool, create and share the vault holding the position, then share the pool"
# The pool and the position record no Meme icon, as Cetus: the position stores the URL it is given,
# and the metadata capability can lengthen the Meme icon URL past Sui's object size limit. The pool
# name, which the position stores twice, is exactly the two symbols around a one-byte separator
# (the reader masks string contents); `prepare` bounds the Meme symbol, and no mutable Meme
# metadata may join it.
[[ "$(bluefin_body pool_name)" == 'letmutname=currency.symbol().into_bytes();name.append(b"_");name.append(quote_currency.symbol().into_bytes());name' \
    && "$(grep -o 'pool_name' <<<"$bluefin_migrate_body" | wc -l)" -eq 1 \
    && "$(move_norm "$BLUEFIN_SOURCE" | grep -o 'create_pool_and_get_object' | wc -l)" -eq 1 \
    && "$(move_norm "$BLUEFIN_SOURCE" | grep -o 'icon_url()' | wc -l)" -eq 1 ]] || \
    fail "bluefin::migrate must name the pool by the two symbols and pass an empty Meme icon URL"
# The seed prefers to fix the side with more atoms, Meme on a tie, and fixes the other side when
# Bluefin's own liquidity math, at the position's bounds and the new pool's price, says the
# preferred side would overdraw its partner; nearly equal amounts can do that by one atom.
[[ "$(bluefin_body seed)" == 'letfix_meme=pool.is_meme_seed_side(position,meme.value(),quote.value());letfixed_amount=if(fix_meme)meme.value()elsequote.value();let(_,_,residual_meme,residual_quote)=pool::add_liquidity_with_fixed_amount(clock,bluefin_config,pool,position,meme,quote,fixed_amount,fix_meme);(residual_meme,residual_quote)' ]] \
    && [[ "$(bluefin_body is_meme_seed_side)" == 'letprefer_meme=meme_amount>=quote_amount;let(_,needed_meme,needed_quote)=pool::get_liquidity_by_amount(position.lower_tick(),position.upper_tick(),pool.current_tick_index(),pool.current_sqrt_price(),if(prefer_meme)meme_amountelsequote_amount,prefer_meme);seed_fixed_side(prefer_meme,meme_amount,quote_amount,needed_meme,needed_quote)' ]] \
    && [[ "$(bluefin_body seed_fixed_side)" == 'if(needed_a<=available_a&&needed_b<=available_b)preferredelse!preferred' ]] || \
    fail "Bluefin migrate must fix the larger side, Meme on a tie, unless Bluefin's own math says it overdraws the other side"
# Both fee exits settle through one helper: collect the position's fees and split them through the
# vault under Bluefin's witness; neither adds liquidity. Application checks the stored proposal
# readiness first and commits the new split only after settling under the current one.
[[ "$(bluefin_body settle_fees)" == 'let(meme_fee,quote_fee)=self.collect_position_fees(vault_version,bluefin_config,pool,clock);self.split_fees(&Venue(),vault_version,treasury,currency,meme_fee,quote_fee,ctx);' ]] \
    && [[ "$(bluefin_body collect_fees)" == 'migrators_version.assert_current(constants::version!());self.settle_fees(vault_version,treasury,currency,bluefin_config,pool,clock,ctx);' ]] || \
    fail "Bluefin collection must split the collected position's fees through the vault and never add liquidity"
# Compounding is its own permissionless route: it checks the version and the vault's pool, then
# adds the waiting auto-LP share, so a venue refusal of the add never blocks collection.
[[ "$(bluefin_body compound_auto_lp)" == 'migrators_version.assert_current(constants::version!());assert!(self.pool_id()==object::id(pool),blast_migrators::errors::position_pool_mismatch!());self.compound(vault_version,bluefin_config,pool,clock);' ]] || \
    fail "Bluefin compounding must check the version and the vault's pool, then add the waiting auto-LP share apart from collection"
[[ "$(bluefin_body settle_and_apply_fee_split)" == 'migrators_version.assert_current(constants::version!());self.assert_fee_split_ready(clock);self.settle_fees(vault_version,treasury,currency,bluefin_config,pool,clock,ctx);self.apply_fee_split(&Venue(),vault_version,clock);' ]] || \
    fail "Bluefin settled application must check stored proposal readiness before collecting, then split the accrued fees under the current split before committing a new one"
[[ "$(bluefin_body buyback_and_burn)" == 'migrators_version.assert_current(constants::version!());assert!(self.pool_id()==object::id(pool),blast_migrators::errors::position_pool_mismatch!());let(quote,receipt)=self.take_buyback_quote(&Venue(),admin_witness,vault_version,quote_in);let(meme,quote)=pool::swap(clock,bluefin_config,pool,balance::zero(),quote,false,true,quote_in,0,constants::max_swap_sqrt_price!());self.burn_buyback(&Venue(),vault_version,receipt,currency,meme,quote,min_meme_out,ctx);' ]] || \
    fail "the Bluefin buyback must check the vault's pool, take the admin's quote_in of the burn Quote under the buyback admin, swap all of it Quote-to-Meme, and let the vault check and burn"
in_order \
    'self.position_mut<_,_,_,Position>(&Venue(),vault_version);' \
    'assert!(position.pool_id()==object::id(pool),blast_migrators::errors::position_pool_mismatch!());' \
    'let(_,_,meme_fee,quote_fee)=pool::collect_fee(clock,bluefin_config,pool,position);' \
    '(meme_fee,quote_fee)' \
    <<<"$(bluefin_body collect_position_fees)" || \
    fail "Bluefin collection must check the custodied position's pool once, before the venue call"
# Auto-LP adds the waiting balances to the custodied position, fixing the side the shared
# selection chooses from the pool's price and the position's own tick bounds, and keeps the rest.
[[ "$(bluefin_body compound)" == 'let(meme,quote,receipt)=self.take_auto_lp(&Venue(),vault_version);letposition=self.position_mut<_,_,_,Position>(&Venue(),vault_version);let(fix_meme,fixed_amount)=pool.fixed_side(position,meme.value(),quote.value());let(_,_,meme,quote)=if(fixed_amount>0){pool::add_liquidity_with_fixed_amount(clock,bluefin_config,pool,position,meme,quote,fixed_amount,fix_meme)}else{(0,0,meme,quote)};self.keep_auto_lp(&Venue(),vault_version,receipt,meme,quote);' ]] \
    && [[ "$(bluefin_body fixed_side)" == 'letticks=pool.get_tick_manager();letsqrt_lower=ticks.get_tick_from_manager(position.lower_tick()).sqrt_price();letsqrt_upper=ticks.get_tick_from_manager(position.upper_tick()).sqrt_price();auto_lp_fixed_side(sqrt_lower,pool.current_sqrt_price(),sqrt_upper,meme_amount,quote_amount)' ]] || \
    fail "Bluefin auto-LP must add to the custodied position on the side the shared selection fixes and keep the rest"
# Bluefin's public routes share one parameter order: preparation takes this package's version
# and the venue config first; migration takes the product's hand-off, this package's version,
# then the venue config; every vault route takes the vault, this package's version,
# then the vault version. Split application consumes only the stored ready proposal.
for entry in prepare migrate collect_fees settle_and_apply_fee_split compound_auto_lp buyback_and_burn; do
    case "$entry" in
        prepare) expected="( migrators_version: &PackageVersion<BLAST_MIGRATORS>, venue_config: &mut VenueConfig," ;;
        migrate) expected="( migration: Migration<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, venue_config: &VenueConfig," ;;
        collect_fees|settle_and_apply_fee_split) expected="( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, currency: &mut Currency<Meme>," ;;
        compound_auto_lp) expected="( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, bluefin_config: &GlobalConfig," ;;
        buyback_and_burn) expected="( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, admin_witness: &AdminWitness<BuybackAdmin>, currency: &mut Currency<Meme>," ;;
        *) fail "unhandled venue entry ${entry}" ;;
    esac
    [[ "$(awk -F'\t' -v name="$entry" '$1 == "FN" && $2 == name && $6 == 0 { print $9 }' \
        <<<"$bluefin_facts")" == *"$expected"* ]] || \
        fail "bluefin::${entry} must take the shared venue parameter order"
done
if rg -q 'fun [a-z_]*_meme_b\b|meme_is_coin_a|is_meme_coin_a' "$BLUEFIN_SOURCE"; then
    fail "Bluefin must use only the deterministic Meme-A/Quote-B orientation"
fi
BLUEFIN_COMPACT_SOURCE="$(tr -d '[:space:]' < "$BLUEFIN_SOURCE")"
BLUEFIN_PUBLIC_SIGNATURES="$(rg -U 'public fun (migrate|collect|settle)[^{]+\{' "$BLUEFIN_SOURCE" || true)"
if [[ "$BLUEFIN_PUBLIC_SIGNATURES" =~ (sqrt_price|orientation|meme_is|tick_spacing:|fee_rate:|amount|liquidity) ]]; then
    fail "caller-supplied Bluefin price, orientation, tier, or amount is forbidden after preparation"
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
if [[ "$BLUEFIN_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*[^A-Za-z0-9_]Venue([^A-Za-z0-9_]|$) ]]; then
    fail "public or package Bluefin venue exposure is forbidden"
fi
if [[ "$BLUEFIN_COMPACT_SOURCE" =~ publicfun[^\{]*Position ]]; then
    fail "public Bluefin position exposure is forbidden"
fi

# === Cetus ===

require_pattern "$CETUS_SOURCE" 'public struct Venue\(\) has drop;' 'sealed Cetus venue witness'
# Cetus has one preparation and one migrate, collection, settled-update, and buyback route, each
# serving both coin orders (ADR 0100). Preparation checks that Cetus registers the creator's tick
# spacing, then reserves pool creation before any Meme can leave the sale's custody: it mints the
# Meme type's cap from the treasury capability, registers the pair at that tick spacing, stores
# the cap and the tick spacing, records the reservation, and issues the ticket. Every later route
# takes the pool's coin types as `CoinA` and `CoinB`, checks this package's version first, and
# then proves `(CoinA, CoinB)` is exactly `{Meme, Quote}`; migration also requires Cetus's own
# coin order before that. Migration redeems the hand-off, creates the pair's pool only with the
# reserved cap at the recorded tick spacing, prices it from the handed-off balances in the pool's
# coin order, fixes the larger side (Meme on a tie) unless Cetus's own liquidity math says it
# overdraws the other, burns the position through Cetus LP Burn, and creates and shares a vault
# holding the burn proof. Every fee exit collects the burn proof's and the auto-LP position's fees
# and splits them through the vault, leaving the auto-LP share waiting; compounding, on its own,
# adds that share to the auto-LP position, so a Cetus refusal never blocks collection. Each
# buyback checks the vault's own pool, swaps the admin's `quote_in` of the vault's burn Quote for
# Meme, repays exactly what Cetus asks, and hands the result to the vault, which checks the
# admin's minimum and burns it.
cetus_facts="$(move_facts "$CETUS_SOURCE")"
[[ "$cetus_facts" != *MALFORMED* ]] || fail "the Move reader rejected cetus.move"
cetus_public="$(awk -F'\t' '$1 == "FN" && $3 == "public" && $6 == 0 { print $2 }' <<<"$cetus_facts" \
    | LC_ALL=C sort | tr '\n' ' ')"
[[ "$cetus_public" == 'buyback_and_burn collect_fees compound_auto_lp migrate prepare settle_and_apply_fee_split ' ]] || \
    fail "Cetus must expose exactly prepare and one migrate, collect, settled-update, compounding, and buyback route for both coin orders"
cetus_body() {
    awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name && $6 == 0 { print $10 }' <<<"$cetus_facts" \
        | tr -d '[:space:]' | sed 's/,)/)/g'
}
[[ "$(cetus_body prepare)" == 'migrators_version.assert_current(constants::version!());let_=config::get_fee_rate(tick_spacing,cetus_config);letpool_creation_cap=factory::mint_pool_creation_cap(cetus_config,pools,treasury_cap,ctx);factory::register_permission_pair<Meme,Quote>(cetus_config,pools,tick_spacing,&pool_creation_cap,ctx);letpool_creation_cap_id=object::id(&pool_creation_cap);venue_config.add_object(CreationCapKey<Meme>(),pool_creation_cap);venue_config.add_value(PoolTierKey<Meme>(),tick_spacing);events::cetus_pool_reserved<Meme,Quote>(pool_creation_cap_id,tick_spacing);migration::issue_ticket(Venue())' ]] \
    && [[ "$(cetus_body pool_creation_cap)" == 'venue_config.object(CreationCapKey<Meme>())' ]] || \
    fail "cetus::prepare must check Cetus registers the tick spacing, then mint the cap once, register the pair with it, store the cap and the tick spacing, record the reservation, and issue the ticket"
pair_proof='letmeme_is_a=is_meme_coin_a<Meme,Quote,CoinA,CoinB>();'
[[ "$(cetus_body migrate)" == "migrators_version.assert_current(constants::version!());assert!(factory::is_right_order<CoinA,CoinB>(),blast_migrators::errors::invalid_coin_order!());${pair_proof}"* ]] \
    && in_order \
        'let(meme,quote,terms)=migration.redeem(Venue());' \
        'lettick_spacing=*venue_config.value(PoolTierKey<Meme>());' \
        'let(tick_lower,tick_upper)=pool_creator::full_range_tick_range(tick_spacing);' \
        'letmeme_amount=meme.value();letquote_amount=quote.value();' \
        'letsqrt_price=migration::sqrt_price_x64(meme_amount,quote_amount,meme_is_a);' \
        'letfix_a=is_coin_a_seed_side(tick_lower,tick_upper,sqrt_price,meme_amount,quote_amount,meme_is_a);' \
        'let(coin_a,coin_b)=reorder(meme.into_coin(ctx),quote.into_coin(ctx),meme_is_a,ctx);' \
        'let(position,residual_a,residual_b)=pool_creator::create_pool_v3_with_creation_cap<CoinA,CoinB>(cetus_config,pools,venue_config.pool_creation_cap<Meme>(),tick_spacing,sqrt_price,b"".to_string(),tick_lower,tick_upper,coin_a,coin_b,fix_a,clock,ctx);' \
        'let(residual_meme,residual_quote):(Coin<Meme>,Coin<Quote>)=reorder(residual_a,residual_b,meme_is_a,ctx);' \
        'letpool_id=position.pool_id();' \
        'letliquidity=position.liquidity();' \
        'letburn_proof=lp_burn::burn_lp_v2(burn_manager,position,ctx);' \
        'vault::new<Meme,Quote,_>(registry,&Venue(),vault_version,terms,pool_id).share_with_position(&Venue(),treasury,burn_proof,liquidity,residual_meme.into_balance(),residual_quote.into_balance(),ctx);' \
        <<<"$(cetus_body migrate)" \
    && [[ "$(cetus_body migrate)" == *'ctx);' ]] \
    && [[ "$(cetus_body is_coin_a_seed_side)" == 'let(amount_a,amount_b)=if(meme_is_a)(meme_amount,quote_amount)else(quote_amount,meme_amount);letprefer_a=(meme_amount>=quote_amount)==meme_is_a;let(_,needed_a,needed_b)=clmm_math::get_liquidity_by_amount(i32::from_u32(tick_lower),i32::from_u32(tick_upper),i32::zero(),sqrt_price,if(prefer_a)amount_aelseamount_b,prefer_a);seed_fixed_side(prefer_a,amount_a,amount_b,needed_a,needed_b)' ]] \
    && [[ "$(cetus_body seed_fixed_side)" == 'if(needed_a<=available_a&&needed_b<=available_b)preferredelse!preferred' ]] || \
    fail "cetus::migrate must check the version, Cetus's coin order, and the pair first, then create the pool in that order with the reserved cap at the recorded tick spacing, fix the larger side (Meme on a tie) unless Cetus's own math says it overdraws the other, burn the position, and create the vault holding the burn proof"
[[ "$(cetus_body settle_fees)" == 'let(meme_fee,quote_fee)=self.collect_position_fees(vault_version,cetus_config,burn_manager,pool,meme_is_a,ctx);self.split_fees(&Venue(),vault_version,treasury,currency,meme_fee,quote_fee,ctx);' ]] \
    && [[ "$(cetus_body collect_fees)" == "migrators_version.assert_current(constants::version!());${pair_proof}self.settle_fees(vault_version,treasury,currency,cetus_config,burn_manager,pool,meme_is_a,ctx);" ]] || \
    fail "cetus::collect_fees must check the version and the pair, then split the collected fees through the vault and never add liquidity"
[[ "$(cetus_body settle_and_apply_fee_split)" == "migrators_version.assert_current(constants::version!());${pair_proof}self.assert_fee_split_ready(clock);self.settle_fees(vault_version,treasury,currency,cetus_config,burn_manager,pool,meme_is_a,ctx);self.apply_fee_split(&Venue(),vault_version,clock);" ]] || \
    fail "cetus::settle_and_apply_fee_split must check the pair and stored proposal readiness before collecting, then split the accrued fees under the current split before committing a new one"
[[ "$(cetus_body compound_auto_lp)" == "migrators_version.assert_current(constants::version!());${pair_proof}assert!(self.pool_id()==object::id(pool),blast_migrators::errors::position_pool_mismatch!());self.compound(vault_version,cetus_config,pool,meme_is_a,clock,ctx);" ]] || \
    fail "cetus::compound_auto_lp must check the version, the pair, and the vault's pool, then add the waiting auto-LP share apart from collection"
[[ "$(cetus_body buyback_and_burn)" == "migrators_version.assert_current(constants::version!());${pair_proof}assert!(self.pool_id()==object::id(pool),blast_migrators::errors::position_pool_mismatch!());let(quote,receipt)=self.take_buyback_quote(&Venue(),admin_witness,vault_version,quote_in);let(meme,quote)=pool.swap_quote_for_meme(cetus_config,quote,meme_is_a,clock,ctx);self.burn_buyback(&Venue(),vault_version,receipt,currency,meme,quote,min_meme_out,ctx);" ]] \
    && [[ "$(cetus_body swap_quote_for_meme)" == 'let(a,b)=reorder(balance::zero<Meme>(),quote,meme_is_a,ctx);let(a,b)=pool.swap(cetus_config,a,b,!meme_is_a,clock);reorder(a,b,meme_is_a,ctx)' ]] || \
    fail "cetus::buyback_and_burn must check the pair and the vault's pool, take the admin's quote_in of the burn Quote under the buyback admin, swap all of it Quote-to-Meme, and let the vault check and burn"
[[ "$(cetus_body compound)" == 'let(meme,quote,receipt)=self.take_auto_lp(&Venue(),vault_version);let(a,b)=reorder(meme,quote,meme_is_a,ctx);let(a,b)=self.add_liquidity(vault_version,cetus_config,pool,a,b,clock,ctx);let(meme,quote)=reorder(a,b,meme_is_a,ctx);self.keep_auto_lp(&Venue(),vault_version,receipt,meme,quote);' ]] || \
    fail "Cetus auto-LP must take the waiting balances in its pool's coin order and keep what the pool did not take"
# The pair proof is pure and total: `(CoinA, CoinB)` must be exactly `{Meme, Quote}` by original
# type name, in either order, and Meme's side is the answer. Every retype goes through one
# dynamic-field round trip on a fresh transient UID that is deleted afterwards, so the framework's
# `dynamic_field::remove` aborts unless the value keeps its exact type; nothing else in Cetus
# touches a dynamic field or names `CastKey`.
[[ "$(cetus_body is_meme_coin_a)" == 'let(meme,quote)=(type_name::with_original_ids<Meme>(),type_name::with_original_ids<Quote>());let(a,b)=(type_name::with_original_ids<CoinA>(),type_name::with_original_ids<CoinB>());assert!((meme==a&&quote==b)||(meme==b&&quote==a),blast_migrators::errors::wrong_coin_pair!());meme==a' ]] \
    && [[ "$(cetus_body reorder)" == 'letmutscratch=object::new(ctx);let(first,second)=if(meme_is_a){(scratch.cast(x),scratch.cast(y))}else{(scratch.cast(y),scratch.cast(x))};scratch.delete();(first,second)' ]] \
    && [[ "$(cetus_body cast)" == 'dynamic_field::add(scratch,CastKey(),value);dynamic_field::remove(scratch,CastKey())' ]] \
    && [[ "$(move_production_type CastKey <<<"$cetus_facts")" == 'struct CastKey() has copy, drop, store;' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "dynamic_field::") > 0 { print $2 }' <<<"$cetus_facts")" == 'cast' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && $10 ~ /(^|[^A-Za-z0-9_])cast\(/ { print $2 }' <<<"$cetus_facts")" == 'reorder' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "CastKey") > 0 { print $2 }' <<<"$cetus_facts")" == 'cast' ]] || \
    fail "Cetus must prove the coin pair by type name and retype only through one checked dynamic-field round trip on a transient UID"
# Migration burns the full-range position through Cetus LP Burn exactly once (pinned in order
# above), before the vault takes custody of the burn proof and the residuals.
[[ "$(move_norm "$CETUS_SOURCE" | grep -o 'burn_lp_v2' | wc -l)" -eq 1 ]] || \
    fail "Cetus migration must burn the position through LP Burn exactly once"
# Collection checks the vault's own pool first, collects the burn proof only through LP Burn, and
# collects the auto-LP position only once it exists.
[[ "$(cetus_body collect_position_fees)" == 'assert!(self.pool_id()==object::id(pool),blast_migrators::errors::position_pool_mismatch!());let(fee_a,fee_b)=lp_burn::collect_fee(burn_manager,cetus_config,pool,self.position_mut<_,_,_,CetusLPBurnProof>(&Venue(),vault_version),ctx);letmutfee_a=fee_a.into_balance();letmutfee_b=fee_b.into_balance();if(self.has_auto_lp_position(&Venue())){letposition=self.auto_lp_position<_,_,_,Position>(&Venue());let(auto_lp_a,auto_lp_b)=pool::collect_fee(cetus_config,pool,position,true);fee_a.join(auto_lp_a);fee_b.join(auto_lp_b);};reorder(fee_a,fee_b,meme_is_a,ctx)' ]] || \
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
[[ "$(cetus_body add_liquidity)" == 'if(a.value()==0||b.value()==0)return(a,b);if(!self.has_auto_lp_position(&Venue())){let(tick_lower,tick_upper)=pool_creator::full_range_tick_range(pool.tick_spacing());letposition=pool::open_position(cetus_config,pool,tick_lower,tick_upper,ctx);self.attach_auto_lp_position(&Venue(),vault_version,position);};letposition=self.auto_lp_position_mut<_,_,_,Position>(&Venue(),vault_version);let(fix_a,fixed_amount)=pool.fixed_side(position,a.value(),b.value());if(fixed_amount==0)return(a,b);letreceipt=pool::add_liquidity_fix_coin(cetus_config,pool,position,fixed_amount,fix_a,clock);let(paid_a,paid_b)=receipt.add_liquidity_pay_amount();pool::repay_add_liquidity(cetus_config,pool,a.split(paid_a),b.split(paid_b),receipt);(a,b)' ]] \
    && [[ "$(cetus_body fixed_side)" == 'let(lower,upper)=position.tick_range();lettick=pool.current_tick_index();letprice=pool.current_sqrt_price();let(liquidity_a,_,needed_b)=clmm_math::get_liquidity_by_amount(lower,upper,tick,price,amount_a,true);let(liquidity_b,needed_a,_)=clmm_math::get_liquidity_by_amount(lower,upper,tick,price,amount_b,false);if(liquidity_a>0&&needed_b<=amount_b)return(true,amount_a);if(liquidity_b>0&&needed_a<=amount_a)return(false,amount_b);(true,0)' ]] \
    && [[ "$(move_norm "$CETUS_SOURCE" | grep -o 'open_position' | wc -l)" -eq 1 ]] \
    && [[ "$(move_norm "$CETUS_SOURCE" | grep -o 'add_liquidity_fix_coin' | wc -l)" -eq 1 ]] || \
    fail "Cetus auto-LP must open at most one full-range auto-LP position, then add with the fixed-coin receipt and repay it exactly"
# A swap runs all of its input to the widest price limit, since the admin's minimum is the
# protection, and repays exactly what the receipt asks.
in_order \
    'let(amount_in,sqrt_price_limit)=if(a2b)(a.value(),constants::min_swap_sqrt_price!())else(b.value(),constants::max_swap_sqrt_price!());' \
    'let(out_a,out_b,receipt)=pool::flash_swap(cetus_config,pool,a2b,true,amount_in,sqrt_price_limit,clock);' \
    'letpaid=receipt.swap_pay_amount();' \
    'let(pay_a,pay_b)=if(a2b)(a.split(paid),balance::zero())else(balance::zero(),b.split(paid));' \
    'pool::repay_flash_swap(cetus_config,pool,pay_a,pay_b,receipt);' \
    'a.join(out_a);b.join(out_b);(a,b)' \
    <<<"$(cetus_body swap)" \
    && [[ "$(constant_body min_swap_sqrt_price)" == '4_295_048_017' ]] \
    && [[ "$(constant_body max_swap_sqrt_price)" == '79_226_673_515_401_279_992_447_579_054' ]] \
    && [[ "$(move_norm "$CETUS_SOURCE" | grep -o 'flash_swap' | wc -l)" -eq 2 ]] || \
    fail "Cetus buybacks must swap through one flash swap at the widest limit and repay exactly the receipt"
# Cetus's public routes share Bluefin's parameter order, with the LP Burn manager among the venue
# inputs.
for entry in prepare migrate collect_fees settle_and_apply_fee_split compound_auto_lp buyback_and_burn; do
    case "$entry" in
        prepare) expected="( migrators_version: &PackageVersion<BLAST_MIGRATORS>, venue_config: &mut VenueConfig," ;;
        migrate) expected="( migration: Migration<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, venue_config: &VenueConfig," ;;
        collect_fees|settle_and_apply_fee_split) expected="( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, treasury: &Treasury, currency: &mut Currency<Meme>," ;;
        compound_auto_lp) expected="( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, cetus_config: &GlobalConfig," ;;
        buyback_and_burn) expected="( self: &mut Vault<Meme, Quote>, migrators_version: &PackageVersion<BLAST_MIGRATORS>, vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>, admin_witness: &AdminWitness<BuybackAdmin>, currency: &mut Currency<Meme>," ;;
        *) fail "unhandled venue entry ${entry}" ;;
    esac
    [[ "$(awk -F'\t' -v name="$entry" '$1 == "FN" && $2 == name && $6 == 0 { print $9 }' \
        <<<"$cetus_facts")" == *"$expected"* ]] || \
        fail "cetus::${entry} must take the shared venue parameter order"
done
CETUS_COMPACT_SOURCE="$(tr -d '[:space:]' < "$CETUS_SOURCE")"
if [[ "$CETUS_COMPACT_SOURCE" =~ abort0 ]]; then
    fail "production Cetus abort stubs are forbidden"
fi
if [[ "$CETUS_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*[^A-Za-z0-9_]Venue([^A-Za-z0-9_]|$) ]]; then
    fail "public or package Cetus venue exposure is forbidden"
fi
if [[ "$CETUS_COMPACT_SOURCE" =~ publicfun[^\{]*(Position|CetusLPBurnProof) ]]; then
    fail "public Cetus position or burn-proof exposure is forbidden"
fi
# The creator chooses only the tick spacing when preparing a coin; Cetus fixes its fee rate, and
# no later route takes a tier, price, or orientation from the caller.
CETUS_PUBLIC_SIGNATURES="$(rg -U 'public fun (migrate|collect|settle)[^{]+\{' "$CETUS_SOURCE" || true)"
CETUS_PREPARE_SIGNATURE="$(rg -U 'public fun prepare[^{]+\{' "$CETUS_SOURCE" || true)"
if [[ "$CETUS_PUBLIC_SIGNATURES" =~ (sqrt_price|orientation|meme_is|tick_spacing:|fee_rate:) ]] \
    || [[ "$CETUS_PREPARE_SIGNATURE" =~ (sqrt_price|orientation|meme_is|fee_rate:) ]]; then
    fail "caller-supplied Cetus price, orientation, fee rate, or post-preparation tier is forbidden"
fi
# Only the reserved capability creates the pool: never an unreserved creation or a released
# reservation.
[[ "$(rg -c 'pool_creator::create_pool_v3_with_creation_cap<' "$CETUS_SOURCE" || true)" -eq 1 ]] || \
    fail "the Cetus migration route must create its pool with the reserved capability"
if rg -q 'create_pool_v3[[:space:]]*[<(]|unregister_permission_pair|policy_mut' "$CETUS_SOURCE"; then
    fail "Cetus must neither create an unreserved pool nor release a reservation"
fi
# The capability is minted once, from the treasury capability `cetus::prepare` borrows mutably;
# Bluefin only reads its caller's capability, and no other module names one.
[[ "$(rg -c 'factory::mint_pool_creation_cap\(' "$CETUS_SOURCE" || true)" -eq 1 ]] \
    && [[ "$(for source in "${source_files[@]}"; do
        move_facts "$source" | awk -F'\t' -v module="$(basename "$source" .move)" \
            '$1 == "FN" && $6 == 0 && index($9, "TreasuryCap<") > 0 { print module ":" $2 ":" ($9 ~ /&mut TreasuryCap</ ? "mut" : "ref") }'
    done | LC_ALL=C sort | tr '\n' ' ')" == 'bluefin:prepare:ref cetus:prepare:mut ' ]] || \
    fail "the Cetus capability must be minted once from the treasury capability cetus::prepare borrows, and only the two preparations may take one"

# === Package-wide custody rules ===

# The one removal is Cetus's checked retype, pinned above, which removes only the value it added
# to its own transient UID in the same call.
[[ "$(rg -o 'dynamic(_object)?_field::(remove(_opt)?|replace)' "$SOURCE_DIR" | LC_ALL=C sort | tr '\n' ' ')" \
    == "${CETUS_SOURCE}:dynamic_field::remove " ]] || \
    fail "dynamic-field removal or replacement is forbidden outside Cetus's transient checked retype"
reject_pattern 'events_wrapper|public struct Event<' \
    'generic venue event envelopes are forbidden'
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
COMPACT_SOURCE="$(sed -n 'p' "${source_files[@]}" | tr -d '[:space:]')"
if [[ "$COMPACT_SOURCE" =~ transfer::(public_)?transfer\([^\)]*position ]]; then
    fail "position transfer is forbidden"
fi
if [[ "$COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*(cetus|bluefin)::Venue ]]; then
    fail "cross-module venue exposure is forbidden"
fi
# Object custody paths: `VenueConfig`'s object API, whose only caller stores the Meme type's Cetus
# pool-creation capability while preparing a coin; positions live in `blast_vault`. Call sites are
# counted, not imports: `venue_config` names `dynamic_object_field::add` only in its one alias,
# and `add_object` is named only by its declaration and the Cetus preparation. No module renames a
# dynamic field module or imports its members, so none reaches a field function under another
# name.
for source in "${source_files[@]}"; do
    if move_norm "$source" | rg -q '\bdynamic_(object_)?field( as |::\{)'; then
        fail "$(basename "$source") must import dynamic field modules by name only"
    fi
done
object_custody_sites="$(for source in "${source_files[@]}"; do
    module="$(basename "$source" .move)"
    facts="$(move_facts "$source")"
    awk -F'\t' -v module="$module" '$1 == "FN" {
        for (calls = gsub(/add_dynamic_object_field/, "", $10); calls > 0; calls--) print module "::" $2 " adds"
    }' <<<"$facts"
    awk -F'\t' '$1 == "NORM" { print $2 }' <<<"$facts" \
        | rg -o '\bdynamic_object_field::add\b[^;]*|[.:]?\badd_object\b.' | sed "s/^/${module} names /" || true
done | LC_ALL=C sort)"
require_text "$object_custody_sites" \
    "only venue_config::add_object adds object fields; only Cetus calls add_object" <<'EOF'
cetus names .add_object(
venue_config names add_object<
venue_config names dynamic_object_field::add as UID.add_dynamic_object_field
venue_config::add_object adds
EOF
# Functions with a natural first receiver are called with Move 2024 dot syntax, in sources and
# tests alike.
if rg -n \
    'vault::(split_fees|take_auto_lp|keep_auto_lp|take_buyback_quote|burn_buyback|assert_fee_split_ready|apply_fee_split|schedule_fee_split|cancel_fee_split|claim_owner_balances|pay_protocol_fees_with_partner|share_with_position|attach_auto_lp_position|position_mut|auto_lp_position|auto_lp_position_mut|has_auto_lp_position|pool_id)[[:space:]]*(<[^>]*>)?\(|pool::add_liquidity_pay_amount[[:space:]]*\(|coin::from_balance[[:space:]]*\(|(^|[^.[:alnum:]_])collect_position_fees[[:space:]]*\(' \
    "$SOURCE_DIR" "$PACKAGE_DIR/tests"; then
    fail "functions with a natural first receiver must use Move 2024 dot syntax"
fi


# === Shared administration boundary ===
#
# Migrators adopts `blast_admin`'s generic administration: `init` hands the one-time witness to
# `package_version::new_publication` with no pause bits and keeps the publication for the
# publisher, who wraps it with the package's UpgradeCap through `package_admin::wrap`. The package
# declares no local custody, version, pause, or upgrade copy, no role of its own, and no
# unpause; its only administrator action is the buyback, under the core domain's `BuybackAdmin`,
# the role `blast_vault` checks.

for forbidden in acl.move blast_acl.move package_admin.move package_version.move; do
    [[ -e "$SOURCE_DIR/$forbidden" ]] && \
        fail "Migrators must not define a local $forbidden"
done

if rg -n '^public struct (ACL|Authority|ProtocolAuthority|SuperAdminCap|AdminCap|AdminWitness|PackageAdmin|PackageVersion|Publication)\b' \
    "$SOURCE_DIR"; then
    fail "administration types must come from blast_admin, never from a local copy"
fi

if rg -n 'fun (grant_admin|revoke_admin|sign_in|unpause|pause)\(' "$SOURCE_DIR"; then
    fail "Migrators must not manage administrators or pause bits"
fi

if rg -n '\b(OperationalVersion|UpgradeCustody|DelayedAction|operational_version|upgrade_custody|restrict_to_\w+)\b' \
    "$SOURCE_DIR"; then
    fail "version, custody, and upgrade machinery belong to blast_admin's generic administration"
fi

otw_facts="$(move_facts "$SOURCE_DIR/blast_migrators.move")"
[[ "$otw_facts" != *MALFORMED* ]] || fail "the Move reader rejected blast_migrators.move"
[[ "$(awk -F'\t' '$1 == "TYPE" && $5 == 0 { print $8 }' <<<"$otw_facts" | LC_ALL=C sort | tr '\n' ';')" \
    == 'struct BLAST_MIGRATORS() has drop;;struct PackageWitness() has drop;;' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 { print $2 ":" $3 }' <<<"$otw_facts" | tr '\n' ' ')" == 'init:private ' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $2 == "init" { print $10 }' <<<"$otw_facts" | tr -d '[:space:]')" \
        == 'package_version::new_publication<_,PackageWitness>(otw,0,ctx).keep(ctx);' ]] || \
    fail "blast_migrators must declare only its one-time witness (OTW) and an unconstructed package witness, and init must keep a zero-bit publication"
if rg -q 'PackageWitness\(\)' "$SOURCE_DIR" --glob '!blast_migrators.move' \
    || [[ "$(production_section "$SOURCE_DIR/blast_migrators.move" | grep -o 'PackageWitness()' | wc -l)" -ne 1 ]]; then
    fail "nothing may construct the package witness; the package defines no pause bits"
fi
[[ "$(constant_body version)" == '1' ]] || fail "Migrators must compile version one"

# The roles are the core domain's ability-free role types, which its gate pins.
CORE_ROLES="$(move_facts "$PACKAGE_DIR/../core/sources/blast_domain.move" \
    | awk -F'\t' '$1 == "TYPE" && $5 == 0 { print $2 }' | paste -sd '|')"
[[ -n "$CORE_ROLES" ]] || fail "the core role types must be readable"
if rg -n "^public struct (${CORE_ROLES})\\b" "$SOURCE_DIR"; then
    fail "Migrators must take core's roles, never declare a same-named copy"
fi
# The witness type is each administrator action's role check, so every witness a source names is
# borrowed and names one concrete core role; a generic or foreign role fails here.
admin_witness_violations="$(for source in "${source_files[@]}"; do
    move_norm "$source" | { rg -o '&?AdminWitness<[^>]*>' || true; } \
        | { rg -v -x "&AdminWitness<(${CORE_ROLES})>" || true; } \
        | sed "s|^|$(basename "$source"): |"
done)"
[[ -z "$admin_witness_violations" ]] || \
    fail "every administrator witness must be a borrowed AdminWitness of one concrete role: ${admin_witness_violations}"
for module in bluefin cetus; do
    move_norm "$SOURCE_DIR/venues/${module}.move" | rg -q 'use blast_core::\{ blast_domain::BuybackAdmin,' || \
        fail "${module} buybacks must take the core domain's BuybackAdmin, the role blast_vault checks"
done
# Every administrator action takes exactly one role, the one pinned here. The buybacks hand their
# witness to `blast_vault`'s `take_buyback_quote`, whose calls are pinned above.
admin_roles="$(for source in "${source_files[@]}"; do
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
bluefin:buyback_and_burn:BuybackAdmin
cetus:buyback_and_burn:BuybackAdmin
ROLES

# Every production public function in the venue modules is a protected mutation. The set comes
# from the Move reader, so spacing or line breaks cannot hide a function, and each one must take
# this package's version and check it before doing anything else.
for guard_module in bluefin cetus; do
    guard_facts="$(move_facts "$SOURCE_DIR/venues/${guard_module}.move")"
    [[ "$guard_facts" != *MALFORMED* ]] || fail "the Move reader rejected ${guard_module}.move"
    unguarded="$(awk -F'\t' '
        $1 != "FN" || $3 != "public" || $6 != 0 { next }
        index($9, " migrators_version: &PackageVersion<BLAST_MIGRATORS>,") == 0 \
            || index($10, "migrators_version.assert_current(constants::version!());") != 1 { print $2 }
    ' <<<"$guard_facts")"
    [[ -z "$unguarded" ]] || \
        fail "${guard_module} must take this package's version and assert it first in every protected mutation (unguarded: ${unguarded//$'\n'/ })"
done

# `vault_version` is `blast_vault`'s version, which the vault checks itself; it never stands in
# for this package's own guard.
for guard_module in bluefin cetus; do
    if rg -n '^[[:space:]]+vault_version\.assert_current\(' "$SOURCE_DIR/venues/${guard_module}.move"; then
        fail "${guard_module}.move must not assert the vault version as if it were its own"
    fi
done

# No public migrator function may hand out a raw balance, a position, a vault, the hand-off, a
# pool, or the reserved pool creation capability.
protected_returners="$(for file in "${source_files[@]}"; do move_facts "$file"; done \
    | awk -F'\t' '
        $1 == "MALFORMED" { print "MALFORMED" }
        $1 == "FN" && $3 == "public" && $6 == 0 && index($9, "):") > 0 {
            if (substr($9, index($9, "):") + 2) ~ /(^|[^A-Za-z0-9_])(Balance|Vault|Migration|Position|Pool|PoolCreationCap)([^A-Za-z0-9_]|$)/) print $2
        }')"
[[ -z "$protected_returners" ]] || \
    fail "public functions must not return balances or custody objects: $protected_returners"

echo "Migrator source boundaries passed"
