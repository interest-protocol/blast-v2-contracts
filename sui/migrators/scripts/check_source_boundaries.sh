#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$PACKAGE_DIR/sources"
VAULT_SOURCE="$SOURCE_DIR/vault.move"
BLUEFIN_SOURCE="$SOURCE_DIR/bluefin.move"
MMT_SOURCE="$SOURCE_DIR/mmt.move"
CETUS_SOURCE="$SOURCE_DIR/cetus.move"
TURBOS_SOURCE="$SOURCE_DIR/turbos.move"
AFTERMATH_SOURCE="$SOURCE_DIR/aftermath.move"
EVENTS_SOURCE="$SOURCE_DIR/events.move"
VENUE_CONFIG_SOURCE="$SOURCE_DIR/venue_config.move"

fail() {
    echo "Migrator source boundary failed: $1" >&2
    exit 1
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

cetus_section() {
    local name="$1"

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
    ' "$CETUS_SOURCE"
}

require_cetus_public() {
    local route="$1"
    local expected="$2"
    local description="$3"
    local section declaration compact count

    section="$(cetus_section "$route")"
    declaration="$(printf '%s\n' "$section" | sed -n '1p' | tr -d '[:space:]')"
    [[ "$declaration" == "publicfun${route}<"* ]] || \
        fail "Cetus $route must be public"
    compact="$(printf '%s' "$section" | tr -d '[:space:]')"
    count="$(printf '%s' "$compact" | rg -o -F "$expected" | wc -l || true)"
    [[ -n "$compact" && "$count" -eq 1 ]] || \
        fail "Cetus $route missing $description"
}

require_cetus_private() {
    local function="$1"
    local expected="$2"
    local description="$3"
    local section declaration compact count

    section="$(cetus_section "$function")"
    declaration="$(printf '%s\n' "$section" | sed -n '1p' | tr -d '[:space:]')"
    [[ "$declaration" == "fun${function}<"* || "$declaration" == "fun${function}("* ]] || \
        fail "Cetus $function must be private"
    compact="$(printf '%s' "$section" | tr -d '[:space:]')"
    count="$(printf '%s' "$compact" | rg -o -F "$expected" | wc -l || true)"
    [[ -n "$compact" && "$count" -eq 1 ]] || \
        fail "Cetus $function missing $description"
}

require_cetus_private_count() {
    local function="$1"
    local expected="$2"
    local required_count="$3"
    local description="$4"
    local section declaration compact count

    section="$(cetus_section "$function")"
    declaration="$(printf '%s\n' "$section" | sed -n '1p' | tr -d '[:space:]')"
    [[ "$declaration" == "fun${function}<"* || "$declaration" == "fun${function}("* ]] || \
        fail "Cetus $function must be private"
    compact="$(printf '%s' "$section" | tr -d '[:space:]')"
    count="$(printf '%s' "$compact" | rg -o -F "$expected" | wc -l || true)"
    [[ -n "$compact" && "$count" -eq "$required_count" ]] || \
        fail "Cetus $function missing $description"
}

reject_cetus_pre_guard_mutator() {
    local route="$1"
    local section before_guard call redemption_count

    section="$(cetus_section "$route")"
    before_guard="${section%%migration_math::assert_price_within_bps*}"
    [[ "$before_guard" != "$section" ]] || \
        fail "Cetus $route missing price guard"
    redemption_count="$(printf '%s' "$section" | rg -o -F 'payload.redeem_migration(Witness())' | wc -l || true)"
    [[ "$redemption_count" -eq 1 ]] || \
        fail "Cetus $route must redeem exactly once"
    [[ "$before_guard" == *'payload.redeem_migration(Witness())'* ]] || \
        fail "Cetus $route must redeem before its price guard"

    while IFS= read -r call; do
        case "$call" in
            pool::tick_spacing|pool::fee_rate) ;;
            pool.tick_spacing|pool.fee_rate|pool.current_sqrt_price) ;;
            *) fail "Cetus $route mutates a pool before its price guard" ;;
        esac
    done < <(printf '%s' "$before_guard" | rg -o 'pool(::|\.)[[:alnum:]_]+' | sort -u)

    if printf '%s' "$before_guard" | rg -q 'position::'; then
        fail "Cetus $route mutates a position before its price guard"
    fi
}

turbos_section() {
    local name="$1"

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
    ' "$TURBOS_SOURCE"
}

require_turbos_public() {
    local route="$1"
    local expected="$2"
    local description="$3"
    local section declaration compact count

    section="$(turbos_section "$route")"
    declaration="$(printf '%s\n' "$section" | sed -n '1p' | tr -d '[:space:]')"
    [[ "$declaration" == "publicfun${route}<"* ]] || \
        fail "Turbos $route must be public"
    compact="$(printf '%s' "$section" | tr -d '[:space:]')"
    count="$(printf '%s' "$compact" | rg -o -F "$expected" | wc -l || true)"
    [[ -n "$compact" && "$count" -eq 1 ]] || \
        fail "Turbos $route missing $description"
}

require_turbos_private() {
    local function="$1"
    local expected="$2"
    local description="$3"
    local section declaration compact count

    section="$(turbos_section "$function")"
    declaration="$(printf '%s\n' "$section" | sed -n '1p' | tr -d '[:space:]')"
    [[ "$declaration" == "fun${function}<"* || "$declaration" == "fun${function}("* ]] || \
        fail "Turbos $function must be private"
    compact="$(printf '%s' "$section" | tr -d '[:space:]')"
    count="$(printf '%s' "$compact" | rg -o -F "$expected" | wc -l || true)"
    [[ -n "$compact" && "$count" -eq 1 ]] || \
        fail "Turbos $function missing $description"
}

require_turbos_private_count() {
    local function="$1"
    local expected="$2"
    local required_count="$3"
    local description="$4"
    local section declaration compact count

    section="$(turbos_section "$function")"
    declaration="$(printf '%s\n' "$section" | sed -n '1p' | tr -d '[:space:]')"
    [[ "$declaration" == "fun${function}<"* || "$declaration" == "fun${function}("* ]] || \
        fail "Turbos $function must be private"
    compact="$(printf '%s' "$section" | tr -d '[:space:]')"
    count="$(printf '%s' "$compact" | rg -o -F "$expected" | wc -l || true)"
    [[ -n "$compact" && "$count" -eq "$required_count" ]] || \
        fail "Turbos $function missing $description"
}

reject_turbos_pre_guard_mutator() {
    local route="$1"
    local section before_guard call redemption_count

    section="$(turbos_section "$route")"
    before_guard="${section%%migration_math::assert_price_within_bps*}"
    [[ "$before_guard" != "$section" ]] || \
        fail "Turbos $route missing price guard"
    redemption_count="$(printf '%s' "$section" | rg -o -F 'payload.redeem_migration(Witness())' | wc -l || true)"
    [[ "$redemption_count" -eq 1 ]] || \
        fail "Turbos $route must redeem exactly once"
    [[ "$before_guard" == *'payload.redeem_migration(Witness())'* ]] || \
        fail "Turbos $route must redeem before its price guard"

    while IFS= read -r call; do
        case "$call" in
            pool::get_pool_tick_spacing|pool::get_pool_fee) ;;
            pool.get_pool_tick_spacing|pool.get_pool_fee|pool.get_pool_sqrt_price) ;;
            *) fail "Turbos $route mutates a venue before its price guard" ;;
        esac
    done < <(printf '%s' "$before_guard" | rg -o '(pool|position_manager|pool_factory)(::|\.)[[:alnum:]_]+' | sort -u)
}

[[ -f "$VAULT_SOURCE" ]] || fail "missing sources/vault.move"
[[ -f "$BLUEFIN_SOURCE" ]] || fail "missing sources/bluefin.move"
[[ -f "$MMT_SOURCE" ]] || fail "missing sources/mmt.move"
[[ -f "$CETUS_SOURCE" ]] || fail "missing sources/cetus.move"
[[ -f "$TURBOS_SOURCE" ]] || fail "missing sources/turbos.move"
[[ -f "$AFTERMATH_SOURCE" ]] || fail "missing sources/aftermath.move"
[[ -f "$EVENTS_SOURCE" ]] || fail "missing sources/events.move"
[[ -f "$VENUE_CONFIG_SOURCE" ]] || fail "missing sources/venue_config.move"

require_pattern "$EVENTS_SOURCE" 'public struct VaultCreated' 'vault creation event'
require_pattern "$EVENTS_SOURCE" 'public struct MigrationCompleted' 'completed migration event'
require_pattern "$EVENTS_SOURCE" 'public struct LpFeesCollected' 'LP-fee accrual event'
require_pattern "$EVENTS_SOURCE" 'public struct CreatorFeesClaimed' 'creator claim event'
require_pattern "$EVENTS_SOURCE" 'public struct ProtocolFeesClaimed' 'protocol claim event'
require_pattern "$EVENTS_SOURCE" 'type_name::with_original_ids<Venue>' 'venue type facts'
require_pattern "$EVENTS_SOURCE" 'type_name::with_original_ids<Meme>' 'Meme type facts'
require_pattern "$EVENTS_SOURCE" 'type_name::with_original_ids<Quote>' 'Quote type facts'
require_pattern "$EVENTS_SOURCE" 'position_id: ID' 'stable position identity'
require_pattern "$EVENTS_SOURCE" 'protocol_fee_share_bps: u64' 'applied protocol fee share'
require_pattern "$EVENTS_SOURCE" 'principal_liquidity: u128' \
    'verified final principal liquidity'
if rg -q 'principal_liquidity_(before|after)' "$EVENTS_SOURCE" "$VAULT_SOURCE"; then
    fail "LP fee events and common accrual must carry one final principal value"
fi
require_pattern "$EVENTS_SOURCE" 'protocol_meme_fee_total: u64' \
    'final protocol Meme fee total'
require_pattern "$EVENTS_SOURCE" 'creator_meme_fee_total: u64' \
    'final creator Meme fee total'
require_pattern "$EVENTS_SOURCE" 'protocol_quote_fee_total: u64' \
    'final protocol Quote fee total'
require_pattern "$EVENTS_SOURCE" 'creator_quote_fee_total: u64' \
    'final creator Quote fee total'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(VaultCreated' \
    'direct strongly typed vault event emission'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(MigrationCompleted' \
    'direct strongly typed migration event emission'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(LpFeesCollected' \
    'direct strongly typed LP-fee event emission'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(CreatorFeesClaimed' \
    'direct strongly typed creator-claim event emission'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(ProtocolFeesClaimed' \
    'direct strongly typed protocol-claim event emission'
require_pattern "$EVENTS_SOURCE" 'public struct VenueTierUpdated' 'sealed venue tier mutation event'
require_pattern "$EVENTS_SOURCE" 'public struct AftermathPolicyUpdated' \
    'Aftermath policy mutation event'
require_pattern "$EVENTS_SOURCE" 'public struct AftermathMigrationCompleted' \
    'Aftermath-specific completed migration event'
require_pattern "$EVENTS_SOURCE" 'public struct AftermathDaoFeeUpdated' \
    'Aftermath DAO fee mutation event'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(AftermathPolicyUpdated' \
    'direct strongly typed Aftermath policy event emission'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(AftermathMigrationCompleted' \
    'direct strongly typed Aftermath migration event emission'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(AftermathDaoFeeUpdated' \
    'direct strongly typed Aftermath DAO fee event emission'

require_pattern "$VAULT_SOURCE" 'public struct LpVault' 'shared LpVault'
require_pattern "$VAULT_SOURCE" 'protocol_meme_residual: Balance<Meme>' \
    'protocol Meme residual custody'
require_pattern "$VAULT_SOURCE" 'protocol_quote_residual: Balance<Quote>' \
    'protocol Quote residual custody'
require_pattern "$VAULT_SOURCE" 'public struct PositionKey' 'sealed position key type'
require_pattern "$VAULT_SOURCE" 'public\(package\) fun new' 'package-only vault construction'
require_pattern "$VAULT_SOURCE" 'public\(package\) fun prepare' \
    'package-only unshared vault preparation'
require_pattern "$VAULT_SOURCE" 'public\(package\) fun finish' \
    'package-only atomic vault completion'
require_pattern "$VAULT_SOURCE" 'transfer::public_receive' \
    'object-owned fee coin receive path'
require_pattern "$VAULT_SOURCE" 'const MAX_RECEIVING_COIN_BATCH_SIZE: u64 = 100' \
    'bounded fee coin receipt workload'
require_pattern "$VAULT_SOURCE" 'quote_size <= MAX_RECEIVING_COIN_BATCH_SIZE - meme_size' \
    'combined Meme and Quote fee coin batch bound'
require_pattern "$VAULT_SOURCE" 'meme_size \+ quote_size > 0' \
    'nonempty combined fee coin batch guard'
require_pattern "$VAULT_SOURCE" 'while \(!receivings\.is_empty\(\)\)' \
    'bounded fee coin merge loop'
require_pattern "$VAULT_SOURCE" '_venue: Venue' 'owned venue witness on vault construction'
require_pattern "$VAULT_SOURCE" 'dynamic_object_field::add' 'dynamic object-field position attachment'
require_pattern "$VAULT_SOURCE" 'self\.id\.dynamic_object_field_mut' 'typed mutable position borrow'
require_pattern "$VAULT_SOURCE" '_venue: &Venue' 'borrowed venue witness on position access'
VAULT_VENUE_GUARD_COUNT="$(rg -o 'self\.id\.has_dynamic_object_field' "$VAULT_SOURCE" | wc -l || true)"
[[ "$VAULT_VENUE_GUARD_COUNT" -eq 3 ]] || \
    fail "vault borrow, receive, and accrual must guard the sealed venue key"
require_pattern "$VAULT_SOURCE" 'public fun claim_creator_fees' 'creator fee claim'
require_pattern "$VAULT_SOURCE" 'public fun claim_protocol_fees' 'protocol fee claim'
require_pattern "$VAULT_SOURCE" 'has_protocol_fees \|\| has_residuals' \
    'protocol claim availability across both custody sources'
require_pattern "$VAULT_SOURCE" 'protocol_meme_residual\.withdraw_all' \
    'protocol Meme residual drain'
require_pattern "$VAULT_SOURCE" 'protocol_quote_residual\.withdraw_all' \
    'protocol Quote residual drain'
require_pattern "$VAULT_SOURCE" 'public\(package\) fun accrue_fees' \
    'witness-gated shared fee accrual'
require_pattern "$VAULT_SOURCE" 'events::vault_created' 'vault creation event emission'
require_pattern "$VAULT_SOURCE" 'events::lp_fees_collected' 'LP-fee event emission'
require_pattern "$VAULT_SOURCE" 'events::creator_fees_claimed' 'creator claim event emission'
require_pattern "$VAULT_SOURCE" 'events::protocol_fees_claimed' 'protocol claim event emission'

require_pattern "$VENUE_CONFIG_SOURCE" 'public struct VenueConfig has key' \
    'shared venue tier policy singleton'
require_pattern "$VENUE_CONFIG_SOURCE" 'transfer::share_object\(VenueConfig' \
    'shared venue config creation'
require_pattern "$VENUE_CONFIG_SOURCE" 'public struct TierKey' \
    'sealed per-venue tier key'
require_pattern "$VENUE_CONFIG_SOURCE" 'public\(package\) fun set_tier<Venue: drop>' \
    'witness-sealed package-only tier write'
require_pattern "$VENUE_CONFIG_SOURCE" '_venue: Venue' \
    'owned venue witness on tier writes'
require_pattern "$VENUE_CONFIG_SOURCE" 'public\(package\) fun has_tier<Venue>' \
    'package-only pin presence read'
require_pattern "$VENUE_CONFIG_SOURCE" 'public\(package\) fun tier<Venue>' \
    'package-only tier read'
require_pattern "$VENUE_CONFIG_SOURCE" 'dynamic_field::add' \
    'dynamic-field tier storage for upgrade-safe venue registration'
require_pattern "$VENUE_CONFIG_SOURCE" 'events::venue_tier_updated<Venue>' \
    'sealed tier mutation emission'
require_pattern "$VENUE_CONFIG_SOURCE" 'public\(package\) fun add_policy<Key:' \
    'sealed-key package-only policy installation'
require_pattern "$VENUE_CONFIG_SOURCE" 'public\(package\) fun has_policy<Key:' \
    'sealed-key package-only policy presence read'
require_pattern "$VENUE_CONFIG_SOURCE" 'public\(package\) fun policy<Key:' \
    'sealed-key package-only policy read'
require_pattern "$VENUE_CONFIG_SOURCE" 'public\(package\) fun policy_mut<Key:' \
    'sealed-key package-only policy mutation'
VENUE_TIER_SETTER_COUNT=0
for source in "$BLUEFIN_SOURCE" "$CETUS_SOURCE" "$MMT_SOURCE" "$TURBOS_SOURCE"; do
    rg -q 'public fun set_tier' "$source" || \
        fail "every venue module must expose its admin tier pin"
    count="$(rg -c '_: &AdminWitness,' "$source" || true)"
    VENUE_TIER_SETTER_COUNT=$((VENUE_TIER_SETTER_COUNT + ${count:-0}))
    rg -q 'fun effective_tier\(venue_config: &VenueConfig\)' "$source" || \
        fail "every venue module must own its default-tier fallback read"
    rg -q 'const DEFAULT_TICK_SPACING: u32' "$source" || \
        fail "every venue module must compile its researched default tick spacing"
    rg -q 'const DEFAULT_FEE_RATE: u64' "$source" || \
        fail "every venue module must compile its researched default fee rate"
done
[[ "$VENUE_TIER_SETTER_COUNT" -eq 4 ]] || \
    fail "every venue tier pin must take a live core admin witness exactly once"

# Aftermath wraps its base pool in a DAO-fee pool and locks LP principal plus policy authority.
require_pattern "$AFTERMATH_SOURCE" 'public struct Witness' 'sealed Aftermath witness'
require_pattern "$AFTERMATH_SOURCE" 'public struct Venue' 'sealed Aftermath venue marker'
require_pattern "$AFTERMATH_SOURCE" 'public struct PolicyKey' \
    'sealed Aftermath policy key'
require_pattern "$AFTERMATH_SOURCE" 'public struct AftermathPolicy' \
    'typed Aftermath future-migration policy'
require_pattern "$AFTERMATH_SOURCE" 'public struct AftermathPosition' \
    'sealed Aftermath LP and DAO-cap position'
require_pattern "$AFTERMATH_SOURCE" 'lp_balance: Balance<Lp>' \
    'locked LP balance custody'
require_pattern "$AFTERMATH_SOURCE" 'dao_fee_owner_cap: OwnerCap<Lp>' \
    'locked DAO fee owner capability'
require_pattern "$AFTERMATH_SOURCE" 'public fun migrate_meme_first' \
    'canonical Meme-first migration route'
require_pattern "$AFTERMATH_SOURCE" 'public fun migrate_meme_second' \
    'canonical Meme-second migration route'
require_pattern "$AFTERMATH_SOURCE" 'assert_canonical_order<Meme, Quote>\(true\)' \
    'Meme-first pre-redemption order guard'
require_pattern "$AFTERMATH_SOURCE" 'assert_canonical_order<Meme, Quote>\(false\)' \
    'Meme-second pre-redemption order guard'
require_pattern "$AFTERMATH_SOURCE" 'type_name::with_defining_ids<A>' \
    'Aftermath defining-ID canonical sorter'
require_pattern "$AFTERMATH_SOURCE" 'pool_registry\.contains_lp_coin<Lp>' \
    'fresh LP type precondition'
require_pattern "$AFTERMATH_SOURCE" 'create_pool_2_coins_v2<Lp, C1, C2>' \
    'Aftermath V2 two-coin creation call'
require_pattern "$AFTERMATH_SOURCE" 'const BASE_SWAP_IN_FEE: u64 = 100_000_000_000_000' \
    'fixed minimum base LP fee'
require_pattern "$AFTERMATH_SOURCE" 'pool_registry\.lp_type_to_pool_id<Lp>\(\) == object::id\(&pool\)' \
    'exact LP-type-to-pool registry reconciliation'
require_pattern "$AFTERMATH_SOURCE" 'pool\.balance_of<Lp, C1>\(\) == amount_1' \
    'exact first source-balance reconciliation'
require_pattern "$AFTERMATH_SOURCE" 'pool\.balance_of<Lp, C2>\(\) == amount_2' \
    'exact second source-balance reconciliation'
require_pattern "$AFTERMATH_SOURCE" 'pool\.weight_of<Lp, C1>\(\) == weight_1' \
    'first configured weight reconciliation'
require_pattern "$AFTERMATH_SOURCE" 'pool\.weight_of<Lp, C2>\(\) == weight_2' \
    'second configured weight reconciliation'
require_pattern "$AFTERMATH_SOURCE" 'pool\.fees_swap_in_for<Lp, C1>\(\) == fee_rate' \
    'symmetric swap-in fee reconciliation'
require_pattern "$AFTERMATH_SOURCE" 'pool\.fees_swap_out_for<Lp, C1>\(\) == 0' \
    'zero swap-out fee reconciliation'
require_pattern "$AFTERMATH_SOURCE" 'pool\.fees_deposit_for<Lp, C1>\(\) == 0' \
    'zero deposit fee reconciliation'
require_pattern "$AFTERMATH_SOURCE" 'pool\.fees_withdraw_for<Lp, C1>\(\) == 0' \
    'zero withdrawal fee reconciliation'
require_pattern "$AFTERMATH_SOURCE" 'pool\.lp_decimals\(\) == REQUIRED_LP_DECIMALS' \
    'nine-decimal LP reconciliation'
require_pattern "$AFTERMATH_SOURCE" 'lp_supply - locked_lp_amount == MIN_ILLIQUID_LP' \
    'exact illiquid LP reserve reconciliation'
require_pattern "$AFTERMATH_SOURCE" 'vault::prepare<Meme, Quote>' \
    'pre-wrapper vault address construction'
require_pattern "$AFTERMATH_SOURCE" 'let vault_address = vault_id\.to_address\(\)' \
    'vault-address DAO fee recipient'
require_pattern "$AFTERMATH_SOURCE" 'dao_fee_pool::new' \
    'DAO-fee wrapper construction'
require_pattern "$AFTERMATH_SOURCE" 'dao_fee_pool\.fee_bps\(\) == policy\.dao_fee_bps' \
    'DAO fee reconciliation'
require_pattern "$AFTERMATH_SOURCE" 'dao_fee_pool\.fee_recipient\(\) == vault_address' \
    'DAO recipient reconciliation'
require_pattern "$AFTERMATH_SOURCE" 'let position = AftermathPosition' \
    'whole LP and DAO-cap position construction'
require_pattern "$AFTERMATH_SOURCE" 'lp_balance: lp_coin\.into_balance\(\)' \
    'LP coin wrapper deletion before position custody'
require_pattern "$AFTERMATH_SOURCE" 'vault::finish' \
    'atomic prepared-vault completion'
require_pattern "$AFTERMATH_SOURCE" 'transfer::public_share_object\(dao_fee_pool\)' \
    'outer DAO-fee pool sharing'
require_pattern "$AFTERMATH_SOURCE" 'public fun accrue_dao_fees' \
    'combined Meme and Quote DAO-fee receiving path'
require_pattern "$AFTERMATH_SOURCE" 'vector<Receiving<Coin<Meme>>>' \
    'batched Meme DAO fee receiving ABI'
require_pattern "$AFTERMATH_SOURCE" 'vector<Receiving<Coin<Quote>>>' \
    'batched Quote DAO fee receiving ABI'
require_pattern "$AFTERMATH_SOURCE" 'let \(meme_fee, quote_fee\) = self\.receive_coins' \
    'combined batched object-owned DAO fee receipt'
if rg -q 'public fun accrue_(meme|quote)_dao_fee' "$AFTERMATH_SOURCE"; then
    fail "Aftermath must expose one combined DAO fee accrual function"
fi
require_pattern "$AFTERMATH_SOURCE" 'locked_lp_amount_before == locked_lp_amount_after' \
    'explicit unchanged Aftermath LP principal guard'
require_pattern "$AFTERMATH_SOURCE" 'self\.accrue_fees\(' \
    'shared creator/protocol DAO fee accrual'
require_pattern "$AFTERMATH_SOURCE" 'events::aftermath_migration_completed' \
    'Aftermath-specific migration emission'
require_pattern "$AFTERMATH_SOURCE" 'public fun set_policy' \
    'admin-pinned Aftermath weighted-pool policy'
require_pattern "$AFTERMATH_SOURCE" 'public fun update_dao_fee' \
    'admin-authorized existing-pool DAO fee update'
require_pattern "$AFTERMATH_SOURCE" 'dao_fee_owner_cap\.set_fee_bps' \
    'locked-cap DAO fee mutation call'
require_pattern "$AFTERMATH_SOURCE" 'self\.pool_id\(\) == dao_fee_pool_id' \
    'DAO fee mutation vault-pool binding'
require_pattern "$AFTERMATH_SOURCE" 'events::aftermath_dao_fee_updated' \
    'replay-complete DAO fee mutation emission'
require_pattern "$AFTERMATH_SOURCE" 'meme_weight \+ policy\.quote_weight == FIXED_ONE' \
    'normalized Aftermath weight policy'
require_pattern "$AFTERMATH_SOURCE" 'events::aftermath_policy_updated' \
    'replay-complete Aftermath policy mutation emission'
if rg -q 'update_fee_recipient|remove_liquidity|withdraw_liquidity|dao_fee_owner_cap\(' "$AFTERMATH_SOURCE"; then
    fail "Aftermath must expose neither recipient mutation nor LP withdrawal"
fi
if rg -q 'lint\(coin_field\)' "$AFTERMATH_SOURCE"; then
    fail "Aftermath position must store LP principal as a Balance"
fi
if rg -q 'dao_fee_amm::(pool|version)::(DaoFeePool|OwnerCap|Version)' "$AFTERMATH_SOURCE"; then
    fail "Aftermath signatures and fields must use imported DAO types"
fi
AFTERMATH_COMPACT_SOURCE="$(tr -d '[:space:]' < "$AFTERMATH_SOURCE")"
if [[ "$AFTERMATH_COMPACT_SOURCE" =~ publicfunmigrate[^{]*(weights|flatness|fee_rate|swap_in_fee|name): ]]; then
    fail "caller-supplied Aftermath economic parameters are forbidden"
fi
AFTERMATH_VAULT_LINE="$(rg -n -m1 'vault::finish' "$AFTERMATH_SOURCE" | cut -d: -f1)"
AFTERMATH_SHARE_LINE="$(rg -n -m1 'public_share_object\(dao_fee_pool\)' "$AFTERMATH_SOURCE" | cut -d: -f1)"
[[ "$AFTERMATH_SHARE_LINE" -gt "$AFTERMATH_VAULT_LINE" ]] || \
    fail "Aftermath DAO pool sharing must follow LP-and-cap vault custody"

require_pattern "$BLUEFIN_SOURCE" 'public struct Witness' 'sealed Bluefin witness'
require_pattern "$BLUEFIN_SOURCE" 'public struct Venue' 'sealed Bluefin venue marker'
require_pattern "$BLUEFIN_SOURCE" 'public fun migrate' 'Bluefin migration'
require_pattern "$BLUEFIN_SOURCE" 'public fun collect_fees' 'Bluefin fee collection'
require_pattern "$BLUEFIN_SOURCE" 'bluefin_config\.pool_creation_fee_amount<Quote>' \
    'Quote creation-fee query'
require_pattern "$BLUEFIN_SOURCE" 'balance::zero\(\)' \
    'zero Quote creation-fee balance'
require_pattern "$BLUEFIN_SOURCE" 'events::migration_completed' \
    'completed migration event emission'
require_pattern "$BLUEFIN_SOURCE" 'self\.accrue_fees\(' 'shared replay-complete fee accrual'
require_pattern "$BLUEFIN_SOURCE" 'effective_tier\(venue_config\)' 'effective Bluefin tier read'
require_pattern "$BLUEFIN_SOURCE" 'source_meme_amount >= source_quote_amount' \
    'Bluefin fixed-side feasibility guard'
require_pattern "$BLUEFIN_SOURCE" \
    'vault::new<Meme, Quote, Venue, Position>' \
    'Bluefin residual custody in the LP vault'

require_pattern "$MMT_SOURCE" 'public struct Witness' 'sealed MMT witness'
require_pattern "$MMT_SOURCE" 'public struct Venue' 'sealed MMT venue marker'
require_pattern "$MMT_SOURCE" 'public fun migrate_meme_x' 'MMT Meme-X migration route'
require_pattern "$MMT_SOURCE" 'public fun migrate_meme_y' 'MMT Meme-Y migration route'
require_pattern "$MMT_SOURCE" 'public fun collect_fees_meme_x' \
    'MMT Meme-X fee collection route'
require_pattern "$MMT_SOURCE" 'public fun collect_fees_meme_y' \
    'MMT Meme-Y fee collection route'
require_pattern "$MMT_SOURCE" 'create_pool::check_coin_order<Meme, Quote>' \
    'MMT Meme-X canonical-order check'
require_pattern "$MMT_SOURCE" 'create_pool::check_coin_order<Quote, Meme>' \
    'MMT Meme-Y canonical-order check'
require_pattern "$MMT_SOURCE" 'create_pool::new<X, Y>' 'MMT pool creation'
require_pattern "$MMT_SOURCE" 'pool\.initialize' 'MMT exact-price initialization'
require_pattern "$MMT_SOURCE" 'pool\.get_friendly_ticks' 'MMT friendly full-range ticks'
require_pattern "$MMT_SOURCE" 'tick_math::min_sqrt_price' 'MMT minimum full-range price'
require_pattern "$MMT_SOURCE" 'tick_math::max_sqrt_price' 'MMT maximum full-range price'
require_pattern "$MMT_SOURCE" 'pool\.open_position' 'MMT position creation'
require_pattern "$MMT_SOURCE" 'pool\.add_liquidity' 'MMT liquidity addition'
require_pattern "$MMT_SOURCE" 'migration_math::minimum_utilized_amount' \
    'MMT one-basis-point minimum utilization'
require_pattern "$MMT_SOURCE" 'pool\.transfer\(\)' 'MMT pool sharing after position creation'
require_pattern "$MMT_SOURCE" 'pool\.collect_fee' 'MMT fee collection'
require_pattern "$MMT_SOURCE" 'events::migration_completed' \
    'MMT completed migration event emission'
require_pattern "$MMT_SOURCE" 'self\.accrue_fees\(' 'MMT shared replay-complete fee accrual'
# Two migration routes plus the test-only default inspector.
MMT_TIER_READ_COUNT="$(rg -o 'effective_tier\(venue_config\)' "$MMT_SOURCE" | wc -l || true)"
[[ "$MMT_TIER_READ_COUNT" -eq 3 ]] || \
    fail "both MMT migration routes must read the pinned tier"
require_pattern "$MMT_SOURCE" \
    'residual_meme.into_balance\(\)' \
    'MMT Meme residual custody in the LP vault'
require_pattern "$MMT_SOURCE" \
    'residual_quote.into_balance\(\)' \
    'MMT Quote residual custody in the LP vault'
require_pattern "$MMT_SOURCE" 'assert_coin_order<Meme, Quote>\(true\);' \
    'MMT Meme-X order assertion before redemption'
require_pattern "$MMT_SOURCE" 'assert_coin_order<Meme, Quote>\(false\);' \
    'MMT Meme-Y order assertion before redemption'

require_pattern "$CETUS_SOURCE" 'public struct Witness' 'sealed Cetus witness'
require_pattern "$CETUS_SOURCE" 'public struct Venue' 'sealed Cetus venue marker'
require_pattern "$CETUS_SOURCE" 'const MAX_PRICE_DEVIATION_BPS: u64 = 50;' \
    'exact 50-bps Cetus adoption limit'

# Each new-pool route owns its selected canonical order, pool key, price, and lock.
require_cetus_public 'migrate_new_meme_a' \
    'assert_canonical_order<Meme,Quote>(true);' 'Meme-A canonical order'
require_cetus_public 'migrate_new_meme_a' \
    'let(tick_spacing,pinned_fee_rate)=effective_tier(venue_config);' 'Meme-A effective tier'
require_cetus_public 'migrate_new_meme_a' \
    'assert!(source_meme_amount>=source_quote_amount,EMemeBelowQuote);' \
    'Meme-A fixed-side feasibility guard'
require_cetus_public 'migrate_new_meme_a' \
    'factory::new_pool_key<Meme,Quote>(tick_spacing)' 'Meme-A pool key'
require_cetus_public 'migrate_new_meme_a' \
    'pool_creator::full_range_tick_range(tick_spacing)' 'Meme-A full-range ticks'
require_cetus_public 'migrate_new_meme_a' \
    'migration_math::sqrt_price_x64(source_meme_amount,source_quote_amount,true,)' \
    'Meme-A balance-derived price'
require_cetus_public 'migrate_new_meme_a' \
    'pool_creator::create_pool_v3<Meme,Quote>(cetus_config,pools,tick_spacing,sqrt_price_x64,b"".to_string(),lower_tick_bits,upper_tick_bits,meme.into_coin(ctx),quote.into_coin(ctx),true,clock,ctx,)' \
    'exact Meme-A pool creation'
require_cetus_public 'migrate_new_meme_a' \
    'lock_and_share<Meme,Quote>(launch_id,position,residual_meme,residual_quote,source_meme_amount,source_quote_amount,sqrt_price_x64,' \
    'Meme-A shared lock'

require_cetus_public 'migrate_new_meme_b' \
    'assert_canonical_order<Meme,Quote>(false);' 'Meme-B canonical order'
require_cetus_public 'migrate_new_meme_b' \
    'let(tick_spacing,pinned_fee_rate)=effective_tier(venue_config);' 'Meme-B effective tier'
require_cetus_public 'migrate_new_meme_b' \
    'assert!(source_meme_amount>=source_quote_amount,EMemeBelowQuote);' \
    'Meme-B fixed-side feasibility guard'
require_cetus_public 'migrate_new_meme_b' \
    'factory::new_pool_key<Quote,Meme>(tick_spacing)' 'Meme-B pool key'
require_cetus_public 'migrate_new_meme_b' \
    'pool_creator::full_range_tick_range(tick_spacing)' 'Meme-B full-range ticks'
require_cetus_public 'migrate_new_meme_b' \
    'migration_math::sqrt_price_x64(source_meme_amount,source_quote_amount,false,)' \
    'Meme-B balance-derived price'
require_cetus_public 'migrate_new_meme_b' \
    'pool_creator::create_pool_v3<Quote,Meme>(cetus_config,pools,tick_spacing,sqrt_price_x64,b"".to_string(),lower_tick_bits,upper_tick_bits,quote.into_coin(ctx),meme.into_coin(ctx),false,clock,ctx,)' \
    'exact Meme-B pool creation'
require_cetus_public 'migrate_new_meme_b' \
    'lock_and_share<Meme,Quote>(launch_id,position,residual_meme,residual_quote,source_meme_amount,source_quote_amount,sqrt_price_x64,' \
    'Meme-B shared lock'

# Each adopted pool must redeem, guard at exactly 50 bps, then mutate once.
require_cetus_public 'migrate_existing_meme_a' \
    'payload.redeem_migration(Witness())' 'Meme-A guarded redemption'
require_cetus_public 'migrate_existing_meme_a' \
    'assert_adopted_tier(venue_config,tick_spacing,fee_rate);' \
    'Meme-A adopted tier pin'
require_cetus_public 'migrate_existing_meme_a' \
    'letpool_sqrt_price=pool.current_sqrt_price();' 'Meme-A adopted-price read'
require_cetus_public 'migrate_existing_meme_a' \
    'letfix_meme=pool_sqrt_price<=derived_sqrt_price;' 'Meme-A affordable side rule'
require_cetus_public 'migrate_existing_meme_a' \
    'if(fix_meme){(source_meme_amount,true)}else{(source_quote_amount,false)};' \
    'Meme-A fixed-side mapping'
require_cetus_public 'migrate_existing_meme_a' \
    'migration_math::assert_price_within_bps(source_meme_amount,source_quote_amount,true,pool_sqrt_price,MAX_PRICE_DEVIATION_BPS,)' \
    'exact Meme-A 50-bps price guard'
require_cetus_public 'migrate_existing_meme_a' \
    'pool::open_position<Meme,Quote>(cetus_config,pool,lower_tick_bits,upper_tick_bits,ctx,)' \
    'exact Meme-A position opening'
require_cetus_public 'migrate_existing_meme_a' \
    'pool::add_liquidity_fix_coin<Meme,Quote>(cetus_config,pool,&mutposition,fixed_amount,fix_amount_a,clock,)' \
    'exact Meme-A fixed-coin addition'
require_cetus_public 'migrate_existing_meme_a' \
    'pool::add_liquidity_pay_amount(&receipt)' 'Meme-A payment query'
require_cetus_public 'migrate_existing_meme_a' \
    'pool::repay_add_liquidity<Meme,Quote>(cetus_config,pool,paid_meme,paid_quote,receipt,)' \
    'exact Meme-A repayment'
require_cetus_public 'migrate_existing_meme_a' \
    'assert!(position.pool_id()==object::id(pool),EPositionPoolMismatch);' \
    'Meme-A position-pool identity'
require_cetus_public 'migrate_existing_meme_a' \
    'lock_and_share<Meme,Quote>(launch_id,position,meme.into_coin(ctx),quote.into_coin(ctx),source_meme_amount,source_quote_amount,pool_sqrt_price,' \
    'Meme-A shared lock'
reject_cetus_pre_guard_mutator 'migrate_existing_meme_a'

require_cetus_public 'migrate_existing_meme_b' \
    'payload.redeem_migration(Witness())' 'Meme-B guarded redemption'
require_cetus_public 'migrate_existing_meme_b' \
    'assert_adopted_tier(venue_config,tick_spacing,fee_rate);' \
    'Meme-B adopted tier pin'
require_cetus_public 'migrate_existing_meme_b' \
    'letpool_sqrt_price=pool.current_sqrt_price();' 'Meme-B adopted-price read'
require_cetus_public 'migrate_existing_meme_b' \
    'letfix_meme=pool_sqrt_price>=derived_sqrt_price;' 'Meme-B affordable side rule'
require_cetus_public 'migrate_existing_meme_b' \
    'if(fix_meme){(source_meme_amount,false)}else{(source_quote_amount,true)};' \
    'Meme-B fixed-side mapping'
require_cetus_public 'migrate_existing_meme_b' \
    'migration_math::assert_price_within_bps(source_meme_amount,source_quote_amount,false,pool_sqrt_price,MAX_PRICE_DEVIATION_BPS,)' \
    'exact Meme-B 50-bps price guard'
require_cetus_public 'migrate_existing_meme_b' \
    'pool::open_position<Quote,Meme>(cetus_config,pool,lower_tick_bits,upper_tick_bits,ctx,)' \
    'exact Meme-B position opening'
require_cetus_public 'migrate_existing_meme_b' \
    'pool::add_liquidity_fix_coin<Quote,Meme>(cetus_config,pool,&mutposition,fixed_amount,fix_amount_a,clock,)' \
    'exact Meme-B fixed-coin addition'
require_cetus_public 'migrate_existing_meme_b' \
    'pool::add_liquidity_pay_amount(&receipt)' 'Meme-B payment query'
require_cetus_public 'migrate_existing_meme_b' \
    'pool::repay_add_liquidity<Quote,Meme>(cetus_config,pool,paid_quote,paid_meme,receipt,)' \
    'exact Meme-B repayment'
require_cetus_public 'migrate_existing_meme_b' \
    'assert!(position.pool_id()==object::id(pool),EPositionPoolMismatch);' \
    'Meme-B position-pool identity'
require_cetus_public 'migrate_existing_meme_b' \
    'lock_and_share<Meme,Quote>(launch_id,position,meme.into_coin(ctx),quote.into_coin(ctx),source_meme_amount,source_quote_amount,pool_sqrt_price,' \
    'Meme-B shared lock'
reject_cetus_pre_guard_mutator 'migrate_existing_meme_b'

# Collection wrappers normalize both orientations through a private Venue path.
require_cetus_public 'collect_fees_meme_a' 'letvenue=Venue();' \
    'private Meme-A venue construction'
require_cetus_public 'collect_fees_meme_a' \
    'collect_position_fees<Meme,Quote,Meme,Quote>(self,&venue,cetus_config,pool,)' \
    'Meme-A collection orientation'
require_cetus_public 'collect_fees_meme_a' \
    'self.accrue_fees(&venue,position_id,meme_fee,quote_fee,' \
    'Meme-A common accrual'
require_cetus_public 'collect_fees_meme_b' 'letvenue=Venue();' \
    'private Meme-B venue construction'
require_cetus_public 'collect_fees_meme_b' \
    'collect_position_fees<Quote,Meme,Meme,Quote>(self,&venue,cetus_config,pool,)' \
    'Meme-B collection orientation'
require_cetus_public 'collect_fees_meme_b' \
    'self.accrue_fees(&venue,position_id,meme_fee,quote_fee,' \
    'Meme-B normalized common accrual'
require_cetus_private 'collect_position_fees' 'venue:&Venue' \
    'borrowed private venue'
require_cetus_private 'collect_position_fees' \
    'self.position_mut<_,_,_,Position>(venue)' \
    'venue-bound position borrow'
require_cetus_private_count 'collect_position_fees' \
    'assert!(self.pool_id()==pool_id,EPositionPoolMismatch);' 2 \
    'vault-pool identity'
require_cetus_private_count 'collect_position_fees' \
    'assert!(position.pool_id()==pool_id,EPositionPoolMismatch);' 2 \
    'position-pool identity'
require_cetus_private 'collect_position_fees' \
    'assert!(liquidity_before>0,EZeroPositionLiquidity);' \
    'positive liquidity'
require_cetus_private 'collect_position_fees' \
    'pool::collect_fee(cetus_config,pool,position,true,)' \
    'exact fee recalculation call'
require_cetus_private 'collect_position_fees' \
    'assert!(liquidity_after==liquidity_before,EPositionLiquidityChanged);' \
    'unchanged liquidity'

# Shared lock is the sole utilization, residual-custody, and event seam.
require_cetus_private 'lock_and_share' \
    'migration_math::assert_residual_within_bps(source_meme_amount,residual_meme_amount,MAX_RESIDUAL_BPS,)' \
    'Meme residual limit'
require_cetus_private 'lock_and_share' \
    'migration_math::assert_residual_within_bps(source_quote_amount,residual_quote_amount,MAX_RESIDUAL_BPS,)' \
    'Quote residual limit'
require_cetus_private 'lock_and_share' \
    'vault::new<Meme,Quote,Venue,Position>(Venue(),pool_id,position,residual_meme.into_balance(),residual_quote.into_balance(),ctx,)' \
    'residual custody in the Cetus vault'
require_cetus_private 'lock_and_share' \
    'events::migration_completed<Meme,Quote,Venue>(' 'direct migration event'
require_cetus_private 'assert_adopted_tier' \
    'tick_spacing==pinned_tick_spacing' 'pinned adopted tick spacing'
require_cetus_private 'assert_adopted_tier' \
    'fee_rate==pinned_fee_rate' 'pinned adopted fee'
require_pattern "$TURBOS_SOURCE" 'public struct Witness' 'sealed Turbos witness'
require_pattern "$TURBOS_SOURCE" 'public struct Venue' 'sealed Turbos venue marker'
require_pattern "$TURBOS_SOURCE" 'const MAX_PRICE_DEVIATION_BPS: u64 = 50;' \
    'exact 50-bps Turbos adoption limit'
require_pattern "$TURBOS_SOURCE" 'math_tick::get_min_tick' \
    'Turbos full-range minimum tick'
require_pattern "$TURBOS_SOURCE" 'math_tick::get_max_tick' \
    'Turbos full-range maximum tick'

# New routes derive the price from redeemed balances and use the selected FeeType.
require_turbos_public 'migrate_new_meme_a' 'fee:&Fee<FeeType>' \
    'Meme-A selected FeeType'
require_turbos_public 'migrate_new_meme_a' \
    'checked_fee_tier(venue_config,fee);' 'Meme-A checked tier'
require_turbos_public 'migrate_new_meme_a' \
    'letlower_tick_bits=tick_bits(lower_magnitude,lower_is_neg);' \
    'Meme-A event tick encoding'
require_turbos_public 'migrate_new_meme_a' \
    'migration_math::sqrt_price_x64(source_meme_amount,source_quote_amount,true,)' \
    'Meme-A balance-derived price'
require_turbos_public 'migrate_new_meme_a' 'full_range_ticks(tick_spacing)' \
    'Meme-A full-range ticks'
require_turbos_public 'migrate_new_meme_a' \
    'pool_factory::deploy_pool_and_mint_with_return_<Meme,Quote,FeeType>(pool_config,fee,sqrt_price_x64,positions,vector[meme.into_coin(ctx)],vector[quote.into_coin(ctx)],lower_magnitude,lower_is_neg,upper_magnitude,upper_is_neg,source_meme_amount,source_quote_amount,minimum_meme_amount,minimum_quote_amount,deadline,clock,versioned,ctx,)' \
    'exact Meme-A new-pool call'
require_turbos_public 'migrate_new_meme_a' \
    'lock_and_share<Meme,Quote>(launch_id,position,residual_meme,residual_quote,' \
    'Meme-A shared lock'
require_turbos_public 'migrate_new_meme_a' \
    'assert_positive_liquidity(&position,positions);' \
    'Meme-A positive position liquidity'

require_turbos_public 'migrate_new_meme_b' 'fee:&Fee<FeeType>' \
    'Meme-B selected FeeType'
require_turbos_public 'migrate_new_meme_b' \
    'checked_fee_tier(venue_config,fee);' 'Meme-B checked tier'
require_turbos_public 'migrate_new_meme_b' \
    'letlower_tick_bits=tick_bits(lower_magnitude,lower_is_neg);' \
    'Meme-B event tick encoding'
require_turbos_public 'migrate_new_meme_b' \
    'migration_math::sqrt_price_x64(source_meme_amount,source_quote_amount,false,)' \
    'Meme-B balance-derived price'
require_turbos_public 'migrate_new_meme_b' 'full_range_ticks(tick_spacing)' \
    'Meme-B full-range ticks'
require_turbos_public 'migrate_new_meme_b' \
    'pool_factory::deploy_pool_and_mint_with_return_<Quote,Meme,FeeType>(pool_config,fee,sqrt_price_x64,positions,vector[quote.into_coin(ctx)],vector[meme.into_coin(ctx)],lower_magnitude,lower_is_neg,upper_magnitude,upper_is_neg,source_quote_amount,source_meme_amount,minimum_quote_amount,minimum_meme_amount,deadline,clock,versioned,ctx,)' \
    'exact Meme-B new-pool call'
require_turbos_public 'migrate_new_meme_b' \
    'lock_and_share<Meme,Quote>(launch_id,position,residual_meme,residual_quote,' \
    'Meme-B shared lock'
require_turbos_public 'migrate_new_meme_b' \
    'assert_positive_liquidity(&position,positions);' \
    'Meme-B positive position liquidity'

# Existing routes redeem, guard at 50 bps, then call only the mint return path.
require_turbos_public 'migrate_existing_meme_a' \
    'migration_math::assert_price_within_bps(source_meme_amount,source_quote_amount,true,pool_sqrt_price,MAX_PRICE_DEVIATION_BPS,)' \
    'exact Meme-A 50-bps price guard'
require_turbos_public 'migrate_existing_meme_a' \
    'checked_pool_tier(venue_config,pool);' 'Meme-A adopted tier check'
require_turbos_public 'migrate_existing_meme_a' \
    'letpool_sqrt_price=pool.get_pool_sqrt_price();' 'Meme-A adopted-price read'
require_turbos_public 'migrate_existing_meme_a' \
    'letlower_tick_bits=tick_bits(lower_magnitude,lower_is_neg);' \
    'Meme-A event tick encoding'
require_turbos_public 'migrate_existing_meme_a' \
    'pool.mint_with_return_<Meme,Quote,FeeType>(positions,vector[meme.into_coin(ctx)],vector[quote.into_coin(ctx)],lower_magnitude,lower_is_neg,upper_magnitude,upper_is_neg,source_meme_amount,source_quote_amount,minimum_meme_amount,minimum_quote_amount,deadline,clock,versioned,ctx,)' \
    'exact Meme-A existing-pool call'
require_turbos_public 'migrate_existing_meme_a' \
    'assert!(position.pool_id()==object::id(pool),EPositionPoolMismatch);' \
    'Meme-A position-pool identity'
require_turbos_public 'migrate_existing_meme_a' \
    'assert_positive_liquidity(&position,positions);' \
    'Meme-A positive position liquidity'
reject_turbos_pre_guard_mutator 'migrate_existing_meme_a'

require_turbos_public 'migrate_existing_meme_b' \
    'migration_math::assert_price_within_bps(source_meme_amount,source_quote_amount,false,pool_sqrt_price,MAX_PRICE_DEVIATION_BPS,)' \
    'exact Meme-B 50-bps price guard'
require_turbos_public 'migrate_existing_meme_b' \
    'checked_pool_tier(venue_config,pool);' 'Meme-B adopted tier check'
require_turbos_public 'migrate_existing_meme_b' \
    'letpool_sqrt_price=pool.get_pool_sqrt_price();' 'Meme-B adopted-price read'
require_turbos_public 'migrate_existing_meme_b' \
    'letlower_tick_bits=tick_bits(lower_magnitude,lower_is_neg);' \
    'Meme-B event tick encoding'
require_turbos_public 'migrate_existing_meme_b' \
    'pool.mint_with_return_<Quote,Meme,FeeType>(positions,vector[quote.into_coin(ctx)],vector[meme.into_coin(ctx)],lower_magnitude,lower_is_neg,upper_magnitude,upper_is_neg,source_quote_amount,source_meme_amount,minimum_quote_amount,minimum_meme_amount,deadline,clock,versioned,ctx,)' \
    'exact Meme-B existing-pool call'
require_turbos_public 'migrate_existing_meme_b' \
    'assert!(position.pool_id()==object::id(pool),EPositionPoolMismatch);' \
    'Meme-B position-pool identity'
require_turbos_public 'migrate_existing_meme_b' \
    'assert_positive_liquidity(&position,positions);' \
    'Meme-B positive position liquidity'
reject_turbos_pre_guard_mutator 'migrate_existing_meme_b'

# Collection is the sole NFT mutator and normalizes A/B to Meme/Quote.
require_turbos_public 'collect_fees_meme_a' 'letvenue=Venue();' \
    'private Meme-A venue construction'
require_turbos_public 'collect_fees_meme_a' \
    'collect_position_fees<Meme,Quote,Meme,Quote,FeeType>(self,&venue,pool,positions,deadline,clock,versioned,ctx,)' \
    'Meme-A collection orientation'
require_turbos_public 'collect_fees_meme_a' \
    'self.accrue_fees(&venue,position_id,meme_fee.into_balance(),quote_fee.into_balance(),' \
    'Meme-A common accrual'
require_turbos_public 'collect_fees_meme_b' 'letvenue=Venue();' \
    'private Meme-B venue construction'
require_turbos_public 'collect_fees_meme_b' \
    'collect_position_fees<Quote,Meme,Meme,Quote,FeeType>(self,&venue,pool,positions,deadline,clock,versioned,ctx,)' \
    'Meme-B collection orientation'
require_turbos_public 'collect_fees_meme_b' \
    'self.accrue_fees(&venue,position_id,meme_fee.into_balance(),quote_fee.into_balance(),' \
    'Meme-B normalized common accrual'
require_turbos_private 'collect_position_fees' 'venue:&Venue' \
    'borrowed private venue'
require_turbos_private 'collect_position_fees' \
    'self.position_mut<_,_,_,TurbosPositionNFT,>(venue)' \
    'venue-bound Turbos NFT borrow'
require_turbos_private_count 'collect_position_fees' \
    'assert!(self.pool_id()==pool_id,EPositionPoolMismatch);' 2 \
    'vault-pool identity'
require_turbos_private_count 'collect_position_fees' \
    'assert!(position.pool_id()==pool_id,EPositionPoolMismatch);' 2 \
    'NFT-pool identity'
require_turbos_private_count 'collect_position_fees' \
    'positions.position_info(position_id.to_address())' 2 \
    'position liquidity reads'
require_turbos_private 'collect_position_fees' \
    'letvault_address=object::id(self).to_address();' \
    'vault address captured before position borrow'
require_turbos_private 'collect_position_fees' \
    'pool.collect_with_return_<X,Y,FeeType>(positions,position,std::u64::max_value!(),std::u64::max_value!(),//Thepinnedinterfacereturnsbothfeecoinsandusesthisrecipient//onlyforattributioninitscollectionevent.vault_address,deadline,clock,versioned,ctx,)' \
    'exact fee-only collection call'
require_turbos_private 'collect_position_fees' \
    'assert!(liquidity_after==liquidity_before,EPositionLiquidityChanged);' \
    'unchanged liquidity'

# The shared lock enforces utilization, routes residuals, and attaches the NFT.
require_turbos_private 'full_range_ticks' \
    'math_tick::get_min_tick(tick_spacing)' 'minimum tick derivation'
require_turbos_private 'full_range_ticks' \
    'math_tick::get_max_tick(tick_spacing)' 'maximum tick derivation'
require_turbos_private 'assert_positive_liquidity' \
    'positions.position_info(object::id(position).to_address())' \
    'created-position liquidity read'
require_turbos_private 'assert_positive_liquidity' \
    'assert!(liquidity>0,EZeroPositionLiquidity);' \
    'created-position liquidity guard'
require_turbos_private 'lock_and_share' \
    'migration_math::assert_residual_within_bps(source_meme_amount,residual_meme_amount,MAX_RESIDUAL_BPS,)' \
    'Meme residual limit'
require_turbos_private 'lock_and_share' \
    'migration_math::assert_residual_within_bps(source_quote_amount,residual_quote_amount,MAX_RESIDUAL_BPS,)' \
    'Quote residual limit'
require_turbos_private 'lock_and_share' \
    'vault::new<Meme,Quote,Venue,TurbosPositionNFT>(Venue(),pool_id,position,residual_meme.into_balance(),residual_quote.into_balance(),ctx,)' \
    'Turbos NFT and residual custody'
require_turbos_private 'lock_and_share' \
    'events::migration_completed<Meme,Quote,Venue>(' 'direct migration event'
require_turbos_private 'checked_fee_tier' \
    'effective_tier(venue_config)' 'effective tier read'
require_turbos_private 'checked_fee_tier' \
    'fee.get_tick_spacing()==tick_spacing' 'pinned tier tick spacing'
require_turbos_private 'checked_pool_tier' \
    'pool.get_pool_tick_spacing()==tick_spacing' 'pinned adopted tick spacing'
require_turbos_private 'checked_pool_tier' \
    '(pool.get_pool_fee()asu64)==fee_rate' 'pinned adopted fee'
require_turbos_private 'tick_bits' \
    '((1u64<<32)-(magnitudeasu64))asu32' 'twos-complement event encoding'
MMT_VENUE_CONSTRUCTION_COUNT="$(rg -o 'let venue = Venue\(\)' "$MMT_SOURCE" | wc -l || true)"
[[ "$MMT_VENUE_CONSTRUCTION_COUNT" -eq 2 ]] || \
    fail "MMT must construct its sealed venue witness for both collection routes"
MMT_POOL_TRANSFER_COUNT="$(rg -o 'pool\.transfer\(\)' "$MMT_SOURCE" | wc -l || true)"
[[ "$MMT_POOL_TRANSFER_COUNT" -eq 1 ]] || \
    fail "MMT must expose exactly one pool-sharing path after position creation"
MMT_ADD_LIQUIDITY_LINE="$(rg -n -m1 'pool\.add_liquidity' "$MMT_SOURCE" | cut -d: -f1)"
MMT_POOL_TRANSFER_LINE="$(rg -n -m1 'pool\.transfer\(\)' "$MMT_SOURCE" | cut -d: -f1)"
[[ "$MMT_POOL_TRANSFER_LINE" -gt "$MMT_ADD_LIQUIDITY_LINE" ]] || \
    fail "MMT pool sharing must follow position creation and liquidity addition"

VENUE_CONSTRUCTION_COUNT="$(rg -o 'let venue = Venue\(\)' "$BLUEFIN_SOURCE" | wc -l || true)"
[[ "$VENUE_CONSTRUCTION_COUNT" -eq 1 ]] || \
    fail "Bluefin must construct its sealed venue witness for collection"

reject_pattern 'dynamic(_object)?_field::remove(_opt)?' \
    'dynamic object-field removal is forbidden'
reject_pattern 'events_wrapper|public struct Event<' \
    'generic adapter event envelopes are forbidden'
reject_pattern 'protocol_treasury|residual_treasury' \
    'address-based residual treasury routing is forbidden'
reject_pattern 'fee_ledger_mut' 'raw fee-ledger mutation is forbidden'
reject_pattern 'remove_liquidity' 'principal removal is forbidden'
reject_pattern 'decrease_liquidity|withdraw_liquidity' 'principal withdrawal is forbidden'
reject_pattern 'close_position' 'position closure is forbidden'
reject_pattern 'burn_position|destroy_position' 'Cetus position destruction is forbidden'
reject_pattern 'gauge|stake_position|staking' 'position gauge staking is forbidden'
if rg -q 'migrate_meme_b|collect_fees_meme_b|meme_is_coin_a' "$BLUEFIN_SOURCE"; then
    fail "Bluefin must use only the deterministic Meme-A/Quote-B orientation"
fi
reject_pattern '(position\.(burn|delete|destroy)|((burn|delete|destroy)[[:space:]]*\([^)]*position))' \
    'position burn or destruction is forbidden'
reject_pattern '(sequence|revision|nonce|schema_version|action_tag):' \
    'application-level event ordering fields are forbidden'

if rg -q 'sui::event::emit' "$SOURCE_DIR" \
    --glob '*.move' --glob '!events.move'; then
    fail "state modules must emit only through typed events helpers"
fi

EVENT_EMISSION_COUNT="$(rg -o 'sui::event::emit' "$EVENTS_SOURCE" | wc -l)"
[[ "$EVENT_EMISSION_COUNT" -eq 9 ]] || \
    fail "events.move must emit exactly nine strongly typed payloads"

POSITION_ATTACHMENT_COUNT="$(rg -o 'dynamic_object_field::add' "$SOURCE_DIR" | wc -l)"
[[ "$POSITION_ATTACHMENT_COUNT" -eq 1 ]] || \
    fail "the common vault must define exactly one position attachment path"

COMPACT_SOURCE="$(sed -n 'p' "$SOURCE_DIR"/*.move | tr -d '[:space:]')"
if [[ "$COMPACT_SOURCE" =~ transfer::(public_)?transfer\([^\)]*position ]]; then
    fail "position transfer is forbidden"
fi
if [[ "$(tr -d '[:space:]' < "$BLUEFIN_SOURCE")" =~ publicfun[^\{]*Position ]]; then
    fail "public Bluefin position exposure is forbidden"
fi

CETUS_COMPACT_SOURCE="$(tr -d '[:space:]' < "$CETUS_SOURCE")"
if [[ "$CETUS_COMPACT_SOURCE" =~ abort0 ]]; then
    fail "production Cetus abort stubs are forbidden"
fi
if [[ "$CETUS_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*Venue([^C]|$) ]]; then
    fail "public or package Cetus venue exposure is forbidden"
fi
if [[ "$COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*cetus::Venue ]]; then
    fail "cross-module Cetus venue exposure is forbidden"
fi
if [[ "$CETUS_COMPACT_SOURCE" =~ publicfun[^\{]*Position ]]; then
    fail "public Cetus position exposure is forbidden"
fi
CETUS_PUBLIC_SIGNATURES="$(rg -U 'public fun (migrate|collect)[^{]+\{' "$CETUS_SOURCE")"
if [[ "$CETUS_PUBLIC_SIGNATURES" =~ (sqrt_price|orientation|meme_is|tick_spacing:|fee_rate:) ]]; then
    fail "caller-supplied Cetus price, orientation, or tier is forbidden"
fi

BLUEFIN_COMPACT_SOURCE="$(tr -d '[:space:]' < "$BLUEFIN_SOURCE")"
[[ "$BLUEFIN_COMPACT_SOURCE" == *'meme,quote,source_meme_amount,true,ctx,)'* ]] || \
    fail "Bluefin must fix the Meme side of pool creation"
[[ "$BLUEFIN_COMPACT_SOURCE" == *'used_meme_amount==source_meme_amount-residual_meme_amount'* ]] || \
    fail "Bluefin must reconcile venue-reported used amounts against residuals"
BLUEFIN_PUBLIC_SIGNATURES="$(rg -U 'public fun (migrate|collect)[^{]+\{' "$BLUEFIN_SOURCE")"
if [[ "$BLUEFIN_PUBLIC_SIGNATURES" =~ (sqrt_price|orientation|meme_is|tick_spacing:|fee_rate:) ]]; then
    fail "caller-supplied Bluefin price, orientation, or tier is forbidden"
fi
if [[ "$BLUEFIN_COMPACT_SOURCE" =~ into_balance|balance::(create|from|withdraw|split) ]]; then
    fail "nonzero Bluefin creation-fee balance construction is forbidden"
fi
if [[ "$BLUEFIN_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*Venue([^C]|$) ]]; then
    fail "public or package Bluefin venue exposure is forbidden"
fi
if [[ "$COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*bluefin::Venue ]]; then
    fail "cross-module Bluefin venue exposure is forbidden"
fi

MMT_COMPACT_SOURCE="$(tr -d '[:space:]' < "$MMT_SOURCE")"
MMT_PUBLIC_SIGNATURES="$(rg -U 'public fun (migrate|collect)[^{]+\{' "$MMT_SOURCE")"
if [[ "$MMT_PUBLIC_SIGNATURES" =~ (sqrt_price|orientation|meme_is|tick_spacing:|fee_rate:) ]]; then
    fail "caller-supplied MMT price, orientation, or tier is forbidden"
fi
if [[ "$MMT_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*Venue([^C]|$) ]]; then
    fail "public or package MMT venue exposure is forbidden"
fi
if [[ "$COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*mmt::Venue ]]; then
    fail "cross-module MMT venue exposure is forbidden"
fi

TURBOS_VENUE_CONSTRUCTION_COUNT="$(rg -o 'let venue = Venue\(\)' "$TURBOS_SOURCE" | wc -l || true)"
[[ "$TURBOS_VENUE_CONSTRUCTION_COUNT" -eq 2 ]] || \
    fail "Turbos must construct its sealed venue witness for both collection routes"
TURBOS_COMPACT_SOURCE="$(tr -d '[:space:]' < "$TURBOS_SOURCE")"
if [[ "$TURBOS_COMPACT_SOURCE" =~ abort0 ]]; then
    fail "production Turbos abort stubs are forbidden"
fi
if [[ "$TURBOS_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*Venue([^C]|$) ]]; then
    fail "public or package Turbos venue exposure is forbidden"
fi
if [[ "$COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*turbos::Venue ]]; then
    fail "cross-module Turbos venue exposure is forbidden"
fi
if [[ "$TURBOS_COMPACT_SOURCE" =~ publicfun[^\{]*TurbosPositionNFT ]]; then
    fail "public Turbos NFT exposure is forbidden"
fi
TURBOS_PUBLIC_SIGNATURES="$(rg -U 'public fun (migrate|collect)[^{]+\{' "$TURBOS_SOURCE")"
if [[ "$TURBOS_PUBLIC_SIGNATURES" =~ (sqrt_price|orientation|meme_is|tick_spacing:|fee_rate:) ]]; then
    fail "caller-supplied Turbos price, orientation, or tier is forbidden"
fi
if [[ "$TURBOS_COMPACT_SOURCE" =~ position_manager::(decrease_liquidity|burn|increase_liquidity) ]]; then
    fail "Turbos principal mutation is forbidden"
fi

echo "Migrator source boundaries passed"
