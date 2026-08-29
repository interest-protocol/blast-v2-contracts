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
require_pattern "$CETUS_SOURCE" 'public fun migrate_new_meme_a' \
    'Cetus new Meme-A migration route'
require_pattern "$CETUS_SOURCE" 'public fun migrate_new_meme_b' \
    'Cetus new Meme-B migration route'
require_pattern "$CETUS_SOURCE" 'public fun migrate_existing_meme_a' \
    'Cetus existing Meme-A migration route'
require_pattern "$CETUS_SOURCE" 'public fun migrate_existing_meme_b' \
    'Cetus existing Meme-B migration route'
require_pattern "$CETUS_SOURCE" 'public fun collect_fees_meme_a' \
    'Cetus Meme-A fee collection route'
require_pattern "$CETUS_SOURCE" 'public fun collect_fees_meme_b' \
    'Cetus Meme-B fee collection route'
require_pattern "$CETUS_SOURCE" 'factory::is_right_order<Meme, Quote>' \
    'Cetus Meme-A canonical-order check'
require_pattern "$CETUS_SOURCE" 'factory::is_right_order<Quote, Meme>' \
    'Cetus Meme-B canonical-order check'
require_pattern "$CETUS_SOURCE" 'pool_creator::full_range_tick_range' \
    'Cetus full-range tick derivation'
require_pattern "$CETUS_SOURCE" 'pool_creator::create_pool_v3' \
    'Cetus new-pool creation'
require_pattern "$CETUS_SOURCE" 'pool::open_position' \
    'Cetus adopted-pool position creation'
require_pattern "$CETUS_SOURCE" 'pool::add_liquidity_fix_coin' \
    'Cetus exact add-liquidity receipt flow'
require_pattern "$CETUS_SOURCE" 'pool::add_liquidity_pay_amount' \
    'Cetus add-liquidity payment query'
require_pattern "$CETUS_SOURCE" 'pool::repay_add_liquidity' \
    'Cetus add-liquidity repayment'
require_pattern "$CETUS_SOURCE" 'migration_math::assert_price_within_bps' \
    'Cetus existing-pool price guard'
require_pattern "$CETUS_SOURCE" 'pool::current_sqrt_price' \
    'Cetus current pool price query'
require_pattern "$CETUS_SOURCE" 'pool::collect_fee' \
    'Cetus fee collection'
require_pattern "$CETUS_SOURCE" 'true,' 'Cetus fee recalculation'
require_pattern "$CETUS_SOURCE" 'migration_math::minimum_utilized_amount' \
    'Cetus one-basis-point minimum utilization'
require_pattern "$CETUS_SOURCE" 'migration_math::assert_residual_within_bps' \
    'Cetus one-basis-point residual assertion'
require_pattern "$CETUS_SOURCE" 'events::migration_completed' \
    'Cetus completed migration event emission'
require_pattern "$CETUS_SOURCE" 'vault::accrue_fees' \
    'Cetus shared replay-complete fee accrual'

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

CETUS_VENUE_CONSTRUCTION_COUNT="$(rg -o 'let venue = Venue\(\)' "$CETUS_SOURCE" | wc -l || true)"
[[ "$CETUS_VENUE_CONSTRUCTION_COUNT" -eq 6 ]] || \
    fail "Cetus must construct its sealed venue witness for all migration and collection routes"
mapfile -t CETUS_REDEEM_LINES < <(rg -n 'payload\.redeem_migration' "$CETUS_SOURCE" | cut -d: -f1)
mapfile -t CETUS_PRICE_GUARD_LINES < <(rg -n 'migration_math::assert_price_within_bps' "$CETUS_SOURCE" | cut -d: -f1)
mapfile -t CETUS_OPEN_POSITION_LINES < <(rg -n 'pool::open_position' "$CETUS_SOURCE" | cut -d: -f1)
[[ "${#CETUS_REDEEM_LINES[@]}" -eq 4 ]] || \
    fail "Cetus must redeem exactly once for every migration route"
[[ "${#CETUS_PRICE_GUARD_LINES[@]}" -eq 2 ]] || \
    fail "Cetus must guard both adoption routes"
[[ "${#CETUS_OPEN_POSITION_LINES[@]}" -eq 2 ]] || \
    fail "Cetus must open one position for each adoption route"
for CETUS_ADOPTION_INDEX in 0 1; do
    CETUS_REDEEM_LINE="${CETUS_REDEEM_LINES[$((CETUS_ADOPTION_INDEX + 2))]}"
    CETUS_PRICE_GUARD_LINE="${CETUS_PRICE_GUARD_LINES[$CETUS_ADOPTION_INDEX]}"
    CETUS_OPEN_POSITION_LINE="${CETUS_OPEN_POSITION_LINES[$CETUS_ADOPTION_INDEX]}"
    [[ "$CETUS_REDEEM_LINE" -lt "$CETUS_PRICE_GUARD_LINE" ]] || \
        fail "Cetus adoption price guard must follow payload redemption"
    [[ "$CETUS_PRICE_GUARD_LINE" -lt "$CETUS_OPEN_POSITION_LINE" ]] || \
        fail "Cetus adoption price guard must precede position mutation"
done

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
