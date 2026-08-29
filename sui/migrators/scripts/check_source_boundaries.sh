#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$PACKAGE_DIR/sources"
VAULT_SOURCE="$SOURCE_DIR/vault.move"
BLUEFIN_SOURCE="$SOURCE_DIR/bluefin.move"
MMT_SOURCE="$SOURCE_DIR/mmt.move"
CETUS_SOURCE="$SOURCE_DIR/cetus.move"
EVENTS_SOURCE="$SOURCE_DIR/events.move"

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

cetus_public_section() {
    local name="$1"

    awk -v start="public fun $name<" '
        index($0, start) == 1 { active = 1 }
        active && index($0, start) != 1 && ($0 ~ /^public fun / || $0 ~ /^fun /) { exit }
        active { print }
    ' "$CETUS_SOURCE"
}

cetus_private_section() {
    local name="$1"

    awk -v start="fun $name" '
        index($0, start) == 1 { active = 1 }
        active && index($0, start) != 1 && $0 ~ /^fun / { exit }
        active { print }
    ' "$CETUS_SOURCE"
}

require_cetus_public() {
    local route="$1"
    local expected="$2"
    local description="$3"
    local compact count

    compact="$(cetus_public_section "$route" | tr -d '[:space:]')"
    count="$(printf '%s' "$compact" | rg -o -F "$expected" | wc -l || true)"
    [[ -n "$compact" && "$count" -eq 1 ]] || \
        fail "Cetus $route missing $description"
}

require_cetus_private() {
    local function="$1"
    local expected="$2"
    local description="$3"
    local compact count

    compact="$(cetus_private_section "$function" | tr -d '[:space:]')"
    count="$(printf '%s' "$compact" | rg -o -F "$expected" | wc -l || true)"
    [[ -n "$compact" && "$count" -eq 1 ]] || \
        fail "Cetus $function missing $description"
}

require_cetus_private_count() {
    local function="$1"
    local expected="$2"
    local required_count="$3"
    local description="$4"
    local compact count

    compact="$(cetus_private_section "$function" | tr -d '[:space:]')"
    count="$(printf '%s' "$compact" | rg -o -F "$expected" | wc -l || true)"
    [[ -n "$compact" && "$count" -eq "$required_count" ]] || \
        fail "Cetus $function missing $description"
}

reject_cetus_pre_guard_mutator() {
    local route="$1"
    local section before_guard call redemption_count

    section="$(cetus_public_section "$route")"
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
            *) fail "Cetus $route mutates a pool before its price guard" ;;
        esac
    done < <(printf '%s' "$before_guard" | rg -o 'pool::[[:alnum:]_]+' | sort -u)

    if printf '%s' "$before_guard" | rg -q 'position::'; then
        fail "Cetus $route mutates a position before its price guard"
    fi
}

[[ -f "$VAULT_SOURCE" ]] || fail "missing sources/vault.move"
[[ -f "$BLUEFIN_SOURCE" ]] || fail "missing sources/bluefin.move"
[[ -f "$MMT_SOURCE" ]] || fail "missing sources/mmt.move"
[[ -f "$CETUS_SOURCE" ]] || fail "missing sources/cetus.move"
[[ -f "$EVENTS_SOURCE" ]] || fail "missing sources/events.move"

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
require_pattern "$EVENTS_SOURCE" 'principal_liquidity_before: u128' \
    'principal liquidity before fee collection'
require_pattern "$EVENTS_SOURCE" 'principal_liquidity_after: u128' \
    'principal liquidity after fee collection'
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

require_pattern "$VAULT_SOURCE" 'public struct LpVault' 'shared LpVault'
require_pattern "$VAULT_SOURCE" 'public struct PositionKey' 'sealed position key type'
require_pattern "$VAULT_SOURCE" 'public\(package\) fun new' 'package-only vault construction'
require_pattern "$VAULT_SOURCE" '_venue: Venue' 'owned venue witness on vault construction'
require_pattern "$VAULT_SOURCE" 'dynamic_object_field::add' 'dynamic object-field position attachment'
require_pattern "$VAULT_SOURCE" 'dynamic_object_field::borrow_mut<' 'typed mutable position borrow'
require_pattern "$VAULT_SOURCE" '_venue: &Venue' 'borrowed venue witness on position access'
require_pattern "$VAULT_SOURCE" 'public fun claim_creator_fees' 'creator fee claim'
require_pattern "$VAULT_SOURCE" 'public fun claim_protocol_fees' 'protocol fee claim'
require_pattern "$VAULT_SOURCE" 'public\(package\) fun accrue_fees' \
    'witness-gated shared fee accrual'
require_pattern "$VAULT_SOURCE" 'events::vault_created' 'vault creation event emission'
require_pattern "$VAULT_SOURCE" 'events::lp_fees_collected' 'LP-fee event emission'
require_pattern "$VAULT_SOURCE" 'events::creator_fees_claimed' 'creator claim event emission'
require_pattern "$VAULT_SOURCE" 'events::protocol_fees_claimed' 'protocol claim event emission'

require_pattern "$BLUEFIN_SOURCE" 'public struct Witness' 'sealed Bluefin witness'
require_pattern "$BLUEFIN_SOURCE" 'public struct Venue' 'sealed Bluefin venue marker'
require_pattern "$BLUEFIN_SOURCE" 'public fun migrate' 'Bluefin migration'
require_pattern "$BLUEFIN_SOURCE" 'public fun collect_fees' 'Bluefin fee collection'
require_pattern "$BLUEFIN_SOURCE" 'config::get_pool_creation_fee_amount<Quote>' \
    'Quote creation-fee query'
require_pattern "$BLUEFIN_SOURCE" 'balance::zero<Quote>\(\)' \
    'zero Quote creation-fee balance'
require_pattern "$BLUEFIN_SOURCE" 'events::migration_completed' \
    'completed migration event emission'
require_pattern "$BLUEFIN_SOURCE" 'vault::accrue_fees' 'shared replay-complete fee accrual'

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
require_pattern "$MMT_SOURCE" 'pool::initialize' 'MMT exact-price initialization'
require_pattern "$MMT_SOURCE" 'pool::get_friendly_ticks' 'MMT friendly full-range ticks'
require_pattern "$MMT_SOURCE" 'tick_math::min_sqrt_price' 'MMT minimum full-range price'
require_pattern "$MMT_SOURCE" 'tick_math::max_sqrt_price' 'MMT maximum full-range price'
require_pattern "$MMT_SOURCE" 'liquidity::open_position' 'MMT position creation'
require_pattern "$MMT_SOURCE" 'liquidity::add_liquidity' 'MMT liquidity addition'
require_pattern "$MMT_SOURCE" 'migration_math::minimum_utilized_amount' \
    'MMT one-basis-point minimum utilization'
require_pattern "$MMT_SOURCE" 'pool::transfer\(pool\)' 'MMT pool sharing after position creation'
require_pattern "$MMT_SOURCE" 'collect::fee' 'MMT fee collection'
require_pattern "$MMT_SOURCE" 'events::migration_completed' \
    'MMT completed migration event emission'
require_pattern "$MMT_SOURCE" 'vault::accrue_fees' 'MMT shared replay-complete fee accrual'
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
    'factory::new_pool_key<Meme,Quote>(tick_spacing)' 'Meme-A pool key'
require_cetus_public 'migrate_new_meme_a' \
    'pool_creator::full_range_tick_range(tick_spacing)' 'Meme-A full-range ticks'
require_cetus_public 'migrate_new_meme_a' \
    'migration_math::sqrt_price_x64(source_meme_amount,source_quote_amount,true,)' \
    'Meme-A balance-derived price'
require_cetus_public 'migrate_new_meme_a' \
    'pool_creator::create_pool_v3<Meme,Quote>(cetus_config,pools,tick_spacing,sqrt_price_x64,string::utf8(b""),lower_tick_bits,upper_tick_bits,meme.into_coin(ctx),quote.into_coin(ctx),true,clock,ctx,)' \
    'exact Meme-A pool creation'
require_cetus_public 'migrate_new_meme_a' \
    'lock_and_share<Meme,Quote>(runtime_config,venue,launch_id,position,residual_meme,residual_quote,' \
    'Meme-A shared lock'

require_cetus_public 'migrate_new_meme_b' \
    'assert_canonical_order<Meme,Quote>(false);' 'Meme-B canonical order'
require_cetus_public 'migrate_new_meme_b' \
    'factory::new_pool_key<Quote,Meme>(tick_spacing)' 'Meme-B pool key'
require_cetus_public 'migrate_new_meme_b' \
    'pool_creator::full_range_tick_range(tick_spacing)' 'Meme-B full-range ticks'
require_cetus_public 'migrate_new_meme_b' \
    'migration_math::sqrt_price_x64(source_meme_amount,source_quote_amount,false,)' \
    'Meme-B balance-derived price'
require_cetus_public 'migrate_new_meme_b' \
    'pool_creator::create_pool_v3<Quote,Meme>(cetus_config,pools,tick_spacing,sqrt_price_x64,string::utf8(b""),lower_tick_bits,upper_tick_bits,quote.into_coin(ctx),meme.into_coin(ctx),true,clock,ctx,)' \
    'exact Meme-B pool creation'
require_cetus_public 'migrate_new_meme_b' \
    'lock_and_share<Meme,Quote>(runtime_config,venue,launch_id,position,residual_meme,residual_quote,' \
    'Meme-B shared lock'

# Each adopted pool must redeem, guard at exactly 50 bps, then mutate once.
require_cetus_public 'migrate_existing_meme_a' \
    'payload.redeem_migration(Witness())' 'Meme-A guarded redemption'
require_cetus_public 'migrate_existing_meme_a' \
    'migration_math::assert_price_within_bps(source_meme_amount,source_quote_amount,true,pool::current_sqrt_price(pool),MAX_PRICE_DEVIATION_BPS,)' \
    'exact Meme-A 50-bps price guard'
require_cetus_public 'migrate_existing_meme_a' \
    'pool::open_position<Meme,Quote>(cetus_config,pool,lower_tick_bits,upper_tick_bits,ctx,)' \
    'exact Meme-A position opening'
require_cetus_public 'migrate_existing_meme_a' \
    'pool::add_liquidity_fix_coin<Meme,Quote>(cetus_config,pool,&mutposition,source_meme_amount,true,clock,)' \
    'exact Meme-A fixed-coin addition'
require_cetus_public 'migrate_existing_meme_a' \
    'pool::add_liquidity_pay_amount(&receipt)' 'Meme-A payment query'
require_cetus_public 'migrate_existing_meme_a' \
    'pool::repay_add_liquidity<Meme,Quote>(cetus_config,pool,paid_meme,paid_quote,receipt,)' \
    'exact Meme-A repayment'
require_cetus_public 'migrate_existing_meme_a' \
    'assert!(position::pool_id(&position)==object::id(pool),EPositionPoolMismatch);' \
    'Meme-A position-pool identity'
require_cetus_public 'migrate_existing_meme_a' \
    'lock_and_share<Meme,Quote>(runtime_config,venue,launch_id,position,meme.into_coin(ctx),quote.into_coin(ctx),' \
    'Meme-A shared lock'
reject_cetus_pre_guard_mutator 'migrate_existing_meme_a'

require_cetus_public 'migrate_existing_meme_b' \
    'payload.redeem_migration(Witness())' 'Meme-B guarded redemption'
require_cetus_public 'migrate_existing_meme_b' \
    'migration_math::assert_price_within_bps(source_meme_amount,source_quote_amount,false,pool::current_sqrt_price(pool),MAX_PRICE_DEVIATION_BPS,)' \
    'exact Meme-B 50-bps price guard'
require_cetus_public 'migrate_existing_meme_b' \
    'pool::open_position<Quote,Meme>(cetus_config,pool,lower_tick_bits,upper_tick_bits,ctx,)' \
    'exact Meme-B position opening'
require_cetus_public 'migrate_existing_meme_b' \
    'pool::add_liquidity_fix_coin<Quote,Meme>(cetus_config,pool,&mutposition,source_quote_amount,true,clock,)' \
    'exact Meme-B fixed-coin addition'
require_cetus_public 'migrate_existing_meme_b' \
    'pool::add_liquidity_pay_amount(&receipt)' 'Meme-B payment query'
require_cetus_public 'migrate_existing_meme_b' \
    'pool::repay_add_liquidity<Quote,Meme>(cetus_config,pool,paid_quote,paid_meme,receipt,)' \
    'exact Meme-B repayment'
require_cetus_public 'migrate_existing_meme_b' \
    'assert!(position::pool_id(&position)==object::id(pool),EPositionPoolMismatch);' \
    'Meme-B position-pool identity'
require_cetus_public 'migrate_existing_meme_b' \
    'lock_and_share<Meme,Quote>(runtime_config,venue,launch_id,position,meme.into_coin(ctx),quote.into_coin(ctx),' \
    'Meme-B shared lock'
reject_cetus_pre_guard_mutator 'migrate_existing_meme_b'

# Collection wrappers normalize both orientations through a private Venue path.
require_cetus_public 'collect_fees_meme_a' 'letvenue=Venue();' \
    'private Meme-A venue construction'
require_cetus_public 'collect_fees_meme_a' \
    'collect_position_fees<Meme,Quote,Meme,Quote>(self,&venue,cetus_config,pool,)' \
    'Meme-A collection orientation'
require_cetus_public 'collect_fees_meme_a' \
    'vault::accrue_fees<Meme,Quote,Venue>(self,&venue,position_id,meme_fee,quote_fee,' \
    'Meme-A common accrual'
require_cetus_public 'collect_fees_meme_b' 'letvenue=Venue();' \
    'private Meme-B venue construction'
require_cetus_public 'collect_fees_meme_b' \
    'collect_position_fees<Quote,Meme,Meme,Quote>(self,&venue,cetus_config,pool,)' \
    'Meme-B collection orientation'
require_cetus_public 'collect_fees_meme_b' \
    'vault::accrue_fees<Meme,Quote,Venue>(self,&venue,position_id,meme_fee,quote_fee,' \
    'Meme-B normalized common accrual'
require_cetus_private 'collect_position_fees' 'venue:&Venue' \
    'borrowed private venue'
require_cetus_private 'collect_position_fees' \
    'vault::borrow_position_mut<Meme,Quote,Venue,Position>(self,venue,)' \
    'venue-bound position borrow'
require_cetus_private_count 'collect_position_fees' \
    'assert!(vault::pool_id(self)==pool_id,EPositionPoolMismatch);' 2 \
    'vault-pool identity'
require_cetus_private_count 'collect_position_fees' \
    'assert!(position::pool_id(position)==pool_id,EPositionPoolMismatch);' 2 \
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

# Shared lock is the sole utilization, residual, treasury, and event seam.
require_cetus_private 'lock_and_share' \
    'runtime_config.protocol_treasury()' 'live treasury read'
require_cetus_private 'lock_and_share' \
    'migration_math::assert_residual_within_bps(source_meme_amount,residual_meme_amount,MAX_RESIDUAL_BPS,)' \
    'Meme residual limit'
require_cetus_private 'lock_and_share' \
    'migration_math::assert_residual_within_bps(source_quote_amount,residual_quote_amount,MAX_RESIDUAL_BPS,)' \
    'Quote residual limit'
require_cetus_private 'lock_and_share' \
    'used_meme_amount>=migration_math::minimum_utilized_amount(source_meme_amount,MAX_RESIDUAL_BPS,)' \
    'Meme utilization limit'
require_cetus_private 'lock_and_share' \
    'used_quote_amount>=migration_math::minimum_utilized_amount(source_quote_amount,MAX_RESIDUAL_BPS,)' \
    'Quote utilization limit'
require_cetus_private 'lock_and_share' \
    'transfer::public_transfer(residual_meme,protocol_treasury);' \
    'Meme treasury transfer'
require_cetus_private 'lock_and_share' \
    'transfer::public_transfer(residual_quote,protocol_treasury);' \
    'Quote treasury transfer'
require_cetus_private 'lock_and_share' \
    'events::migration_completed<Meme,Quote,Venue>(' 'direct migration event'

MMT_VENUE_CONSTRUCTION_COUNT="$(rg -o 'let venue = Venue\(\)' "$MMT_SOURCE" | wc -l || true)"
[[ "$MMT_VENUE_CONSTRUCTION_COUNT" -eq 4 ]] || \
    fail "MMT must construct its sealed venue witness for both creation and collection routes"
MMT_POOL_TRANSFER_COUNT="$(rg -o 'pool::transfer\(pool\)' "$MMT_SOURCE" | wc -l || true)"
[[ "$MMT_POOL_TRANSFER_COUNT" -eq 1 ]] || \
    fail "MMT must expose exactly one pool-sharing path after position creation"
MMT_ADD_LIQUIDITY_LINE="$(rg -n -m1 'liquidity::add_liquidity' "$MMT_SOURCE" | cut -d: -f1)"
MMT_POOL_TRANSFER_LINE="$(rg -n -m1 'pool::transfer\(pool\)' "$MMT_SOURCE" | cut -d: -f1)"
[[ "$MMT_POOL_TRANSFER_LINE" -gt "$MMT_ADD_LIQUIDITY_LINE" ]] || \
    fail "MMT pool sharing must follow position creation and liquidity addition"

VENUE_CONSTRUCTION_COUNT="$(rg -o 'let venue = Venue\(\)' "$BLUEFIN_SOURCE" | wc -l || true)"
[[ "$VENUE_CONSTRUCTION_COUNT" -eq 2 ]] || \
    fail "Bluefin must construct its sealed venue witness for creation and collection"

reject_pattern 'dynamic_object_field::remove(_opt)?' \
    'dynamic object-field removal is forbidden'
reject_pattern 'events_wrapper|public struct Event<' \
    'generic adapter event envelopes are forbidden'
reject_pattern 'fee_ledger_mut' 'raw fee-ledger mutation is forbidden'
reject_pattern 'remove_liquidity' 'principal removal is forbidden'
reject_pattern 'close_position' 'position closure is forbidden'
reject_pattern 'burn_position|destroy_position' 'Cetus position destruction is forbidden'
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
[[ "$EVENT_EMISSION_COUNT" -eq 5 ]] || \
    fail "events.move must emit exactly five strongly typed payloads"

POSITION_ATTACHMENT_COUNT="$(rg -o 'dynamic_object_field::add' "$SOURCE_DIR" | wc -l)"
[[ "$POSITION_ATTACHMENT_COUNT" -eq 1 ]] || \
    fail "the common vault must define exactly one position attachment path"

COMPACT_SOURCE="$(sed -n 'p' "$SOURCE_DIR"/*.move | tr -d '[:space:]')"
if [[ "$COMPACT_SOURCE" =~ transfer::(public_)?transfer\([^\)]*position ]]; then
    fail "position transfer is forbidden"
fi
if [[ "$COMPACT_SOURCE" =~ publicfun[^\{]*Position ]]; then
    fail "public Bluefin position exposure is forbidden"
fi

CETUS_COMPACT_SOURCE="$(tr -d '[:space:]' < "$CETUS_SOURCE")"
if [[ "$CETUS_COMPACT_SOURCE" =~ abort0 ]]; then
    fail "production Cetus abort stubs are forbidden"
fi
if [[ "$CETUS_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*Venue ]]; then
    fail "public or package Cetus venue exposure is forbidden"
fi
if [[ "$COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*cetus::Venue ]]; then
    fail "cross-module Cetus venue exposure is forbidden"
fi
if [[ "$CETUS_COMPACT_SOURCE" =~ publicfun[^\{]*Position ]]; then
    fail "public Cetus position exposure is forbidden"
fi
CETUS_PUBLIC_SIGNATURES="$(rg -U 'public fun [^{]+\{' "$CETUS_SOURCE")"
if [[ "$CETUS_PUBLIC_SIGNATURES" =~ (sqrt_price|orientation|meme_is) ]]; then
    fail "caller-supplied Cetus price or orientation is forbidden"
fi

BLUEFIN_COMPACT_SOURCE="$(tr -d '[:space:]' < "$BLUEFIN_SOURCE")"
if [[ "$BLUEFIN_COMPACT_SOURCE" =~ into_balance|balance::(create|from|withdraw|split) ]]; then
    fail "nonzero Bluefin creation-fee balance construction is forbidden"
fi
if [[ "$BLUEFIN_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*Venue ]]; then
    fail "public or package Bluefin venue exposure is forbidden"
fi
if [[ "$COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*bluefin::Venue ]]; then
    fail "cross-module Bluefin venue exposure is forbidden"
fi

MMT_COMPACT_SOURCE="$(tr -d '[:space:]' < "$MMT_SOURCE")"
if [[ "$MMT_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*Venue ]]; then
    fail "public or package MMT venue exposure is forbidden"
fi
if [[ "$COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*mmt::Venue ]]; then
    fail "cross-module MMT venue exposure is forbidden"
fi

echo "Migrator source boundaries passed"
