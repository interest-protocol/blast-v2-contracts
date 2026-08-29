#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$PACKAGE_DIR/sources"
VAULT_SOURCE="$SOURCE_DIR/vault.move"
BLUEFIN_SOURCE="$SOURCE_DIR/bluefin.move"
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
reject_pattern 'migrate_meme_b|collect_fees_meme_b|meme_is_coin_a' \
    'Bluefin must use only the deterministic Meme-A/Quote-B orientation'
reject_pattern 'into_balance|balance::(create|from|withdraw|split)' \
    'nonzero creation-fee balance construction is forbidden'
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

BLUEFIN_COMPACT_SOURCE="$(tr -d '[:space:]' < "$BLUEFIN_SOURCE")"
if [[ "$BLUEFIN_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*Venue ]]; then
    fail "public or package Bluefin venue exposure is forbidden"
fi
if [[ "$COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*bluefin::Venue ]]; then
    fail "cross-module Bluefin venue exposure is forbidden"
fi

echo "Migrator source boundaries passed"
