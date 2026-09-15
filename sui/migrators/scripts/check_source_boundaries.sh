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
MIGRATION_MATH_SOURCE="$SOURCE_DIR/migration_math.move"
LP_FEE_AUTHORITY_SOURCE="$SOURCE_DIR/lp_fee_authority.move"
LP_FEE_POLICY_SOURCE="$SOURCE_DIR/lp_fee_policy.move"

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

# Pins one whole function, from declaration through its closing brace, in order.
require_function_body() {
    local source="$1"
    local name="$2"
    local expected="$3"
    local description="$4"
    local compact

    compact="$(move_function_section "$source" "$name" | tr -d '[:space:]')"
    [[ -n "$compact" && "$compact" == "$expected"* ]] || fail "$description"
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

cetus_section() {
    local name="$1"

    move_function_section "$CETUS_SOURCE" "$name"
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

    move_function_section "$TURBOS_SOURCE" "$name"
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
[[ -f "$MIGRATION_MATH_SOURCE" ]] || fail "missing sources/migration_math.move"
[[ -f "$LP_FEE_AUTHORITY_SOURCE" ]] || fail "missing sources/lp_fee_authority.move"
[[ -f "$LP_FEE_POLICY_SOURCE" ]] || fail "missing sources/lp_fee_policy.move"

MIGRATION_MATH_FUNCTION_COUNT="$(rg -c '^public\(package\) fun (sqrt_price_x64|assert_price_within_bps|minimum_utilized_amount|assert_residual_within_bps)\(' "$MIGRATION_MATH_SOURCE" || true)"
[[ "$MIGRATION_MATH_FUNCTION_COUNT" -eq 4 ]] || \
    fail "migration math must expose exactly four package-only operations"
if rg -q '^public fun |^entry fun |^public entry fun ' "$MIGRATION_MATH_SOURCE"; then
    fail "migration math must not expose a public transaction or composition ABI"
fi
require_pattern "$MIGRATION_MATH_SOURCE" \
    'module blast_fun_migrators::migration_math;' \
    'migrator-owned migration math module'
require_pattern "$MIGRATION_MATH_SOURCE" \
    'const BASIS_POINTS_DENOMINATOR: u64 = 10_000;' \
    'module-local basis-points denominator'
if rg -q '\bEInvalidBps\b|assert_valid_bps' "$MIGRATION_MATH_SOURCE" \
    || ! rg -U -q '#\[error\(code = 1\)\]\nconst EInvalidMigrationSeedBalance: vector<u8> = b"Migration seed balances must both be greater than zero\.";' \
    "$MIGRATION_MATH_SOURCE" \
    || ! rg -U -q '#\[error\(code = 2\)\]\nconst EMigrationPriceDeviationExceeded: vector<u8> = b"Observed pool price must remain within the accepted migration seed deviation\.";' \
    "$MIGRATION_MATH_SOURCE" \
    || ! rg -U -q '#\[error\(code = 3\)\]\nconst EMigrationResidualExceeded: vector<u8> = b"Venue residual must remain within the accepted share of migration principal\.";' \
    "$MIGRATION_MATH_SOURCE"; then
    fail "migration math error codes must remain contiguous and bound to their documented failures"
fi
require_pattern "$MIGRATION_MATH_SOURCE" \
    'integer_sqrt\(ratio_q128\(meme_amount, quote_amount, meme_is_coin_a\)\)' \
    'exact Q128 price derivation'
require_pattern "$MIGRATION_MATH_SOURCE" \
    'let max_deviation_bps = max_deviation_bps\.value\(\);' \
    'price-deviation rate read from its validated Bps'
require_pattern "$MIGRATION_MATH_SOURCE" \
    'max_residual_bps\.apply_up\(amount\)' \
    'ceiling residual allowance through the shared Bps unit'
require_pattern "$MIGRATION_MATH_SOURCE" \
    'maximum_residual_amount\(source_amount, max_residual_bps\)' \
    'shared residual allowance'
if rg -q '\b(blast_fun::(constants|errors)|UID|key|Balance|Coin|TxContext|transfer::|events::|RuntimeConfig)\b' \
    "$MIGRATION_MATH_SOURCE"; then
    fail "migration math must remain a pure migrator-owned arithmetic module"
fi
if rg -U -q 'use blast_fun::\{[^}]*migration_math' "$SOURCE_DIR"; then
    fail "venue modules must use migrator-owned migration math"
fi

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
reject_pattern 'protocol_meme_fee_total|creator_meme_fee_total|protocol_quote_fee_total|creator_quote_fee_total' \
    'derivable fee totals are forbidden in migrator events'
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
# LP-fee authority transitions replay from their own events (ADR 0082).
require_pattern "$EVENTS_SOURCE" 'public struct LpFeeCapIssued' \
    'LP-fee capability issuance event'
require_pattern "$EVENTS_SOURCE" 'revoked_lp_fee_cap_id: Option<ID>' \
    'retired LP-fee capability identity on issuance'
require_pattern "$EVENTS_SOURCE" 'public struct LpFeesLocked' \
    'LP-fee custodian lock event'
require_pattern "$EVENTS_SOURCE" 'custodian_id: ID' \
    'terminal LP-fee custodian identity'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(LpFeeCapIssued' \
    'direct strongly typed LP-fee capability issuance emission'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(LpFeesLocked' \
    'direct strongly typed LP-fee lock emission'
rg -U -q 'public struct LpFeesLocked has copy, drop \{\n    vault_id: ID,\n    meme: TypeName,\n    quote: TypeName,\n    lp_fee_cap_id: Option<ID>,\n    custodian_id: ID,\n\}' \
    "$EVENTS_SOURCE" || \
    fail "LpFeesLocked must carry the destroyed cap as Option<ID>, none for a pending bind"
require_pattern "$EVENTS_SOURCE" 'public struct LpFeeCapClaimed has copy, drop' \
    'migration-born LP-fee capability claim event'
rg -U -q 'public struct LpFeeCapClaimed has copy, drop \{\n    vault_id: ID,\n    meme: TypeName,\n    quote: TypeName,\n    lp_fee_cap_id: ID,\n    claimant: address,\n\}' \
    "$EVENTS_SOURCE" || \
    fail "LpFeeCapClaimed must carry vault, types, claimed cap, and claimant"
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(LpFeeCapClaimed' \
    'direct strongly typed LP-fee capability claim emission'
require_exact_count 'events::lp_fee_cap_claimed<Meme, Quote>(' 1 \
    "LP-fee capability claims must be emitted only by vault::claim_lp_fee_cap" \
    "$SOURCE_DIR"/*.move
require_exact_count 'events::lp_fee_cap_issued<Meme, Quote>(' 1 \
    "LP-fee capability issuance must be emitted only by vault::issue_lp_fee_cap" \
    "$SOURCE_DIR"/*.move
require_exact_count 'events::lp_fees_locked<Meme, Quote>(' 2 \
    "LP-fee locks must be emitted only by vault::lock_pending_creator_fees and vault::lock_creator_fees" \
    "$SOURCE_DIR"/*.move
# LP-fee share policy moved from Launchpad and replays from migrator events.
require_pattern "$EVENTS_SOURCE" 'public struct LpProtocolFeeShareChanged\(u64\) has copy, drop;' \
    'migrator-wide LP-fee share change event'
rg -U -q 'public struct ProjectLpProtocolFeeShareSet has copy, drop \{\n    meme: TypeName,\n    protocol_fee_share_bps: u64,\n\}' \
    "$EVENTS_SOURCE" || fail "missing project LP-fee share pin event"
require_pattern "$EVENTS_SOURCE" 'public struct ProjectLpProtocolFeeShareCleared\(TypeName\) has copy, drop;' \
    'project LP-fee share clear event'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(LpProtocolFeeShareChanged\(protocol_fee_share_bps\)\)' \
    'direct strongly typed LP-fee share change emission'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(ProjectLpProtocolFeeShareSet \{' \
    'direct strongly typed project LP-fee share pin emission'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(ProjectLpProtocolFeeShareCleared\(type_name::with_original_ids<Meme>\(\)\)\)' \
    'direct strongly typed project LP-fee share clear emission'
if rg -q '\bLpFeePolicyCreated\b' "$EVENTS_SOURCE"; then
    fail "LP-fee policy creation must stay eventless"
fi
for policy_event in \
    'events::lp_protocol_fee_share_changed(' \
    'events::project_lp_protocol_fee_share_set<Meme>(' \
    'events::project_lp_protocol_fee_share_cleared<Meme>('; do
    require_exact_count "$policy_event" 1 \
        "LP-fee share events must be emitted once, only by lp_fee_policy.move" \
        "$SOURCE_DIR"/*.move
    require_exact_count "$policy_event" 1 \
        "LP-fee share events must be emitted once, only by lp_fee_policy.move" \
        "$LP_FEE_POLICY_SOURCE"
done
require_exact_count 'events::creator_fees_claimed<Meme, Quote>(' 1 \
    "creator LP-fee claims must be emitted only by the shared private drain" \
    "$SOURCE_DIR"/*.move

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

# LP-fee authority is migration-born (ADR 0082): every venue migration creates one
# `Pending` authority from the witness-typed payload and hands it to the vault; the
# launch's curve-fee cap holder claims it, a launch custodian binds pending fees, or a
# creator admin reissues it. Only `lp_fee_authority.move` constructs or writes it, only
# the live cap drains or locks, and a custodian bind is terminal.
require_pattern "$VAULT_SOURCE" '^    lp_fee_authority: LpFeeAuthority<Meme>,$' \
    'embedded LP-fee authority on the shared vault'
require_pattern "$VAULT_SOURCE" '^    lp_fee_authority::\{LpFeeAuthority, LpFeeCap\},$' \
    'LP-fee authority and capability imported from the authority module'
if rg -q '\benum\b' "$VAULT_SOURCE"; then
    fail "vault must not define a local LP-fee authority enum"
fi
require_exact_count 'public enum LpFeeAuthority<phantom Meme> has drop, store {' 1 \
    "LpFeeAuthority must be defined once, in lp_fee_authority.move" \
    "$SOURCE_DIR"/*.move
require_exact_count 'public struct LpFeeCap<phantom Meme> has key, store {' 1 \
    "LpFeeCap must be defined once, in lp_fee_authority.move" \
    "$SOURCE_DIR"/*.move
rg -U -q 'public enum LpFeeAuthority<phantom Meme> has drop, store \{\n    Pending,\n    Cap\(ID\),\n    Custodian\(ID\),\n\}' \
    "$LP_FEE_AUTHORITY_SOURCE" || \
    fail "lp_fee_authority.move must own the Pending/Cap/Custodian authority enum"
rg -U -q 'public struct LpFeeCap<phantom Meme> has key, store \{\n    id: UID,\n\}' \
    "$LP_FEE_AUTHORITY_SOURCE" || \
    fail "lp_fee_authority.move must own the id-only LpFeeCap"
if rg -q 'LpFeeAuthority::|LpFeeCap \{' "$SOURCE_DIR" --glob '!lp_fee_authority.move'; then
    fail "LpFeeAuthority variants and LpFeeCap values may be constructed only in lp_fee_authority.move"
fi
require_exact_count '*self = LpFeeAuthority::' 4 \
    "only claim, lock_pending, lock, and reissue may write LP-fee authority state" \
    <(production_section "$LP_FEE_AUTHORITY_SOURCE")
require_exact_count 'LpFeeCap { id: object::new(ctx) }' 2 \
    "only claim and reissue may mint an LP-fee capability" \
    <(production_section "$LP_FEE_AUTHORITY_SOURCE")
if rg -q 'new_lp_fee_cap[<(]' "$SOURCE_DIR"; then
    fail "LP-fee capabilities must not be issued through a Launchpad new_lp_fee_cap path"
fi
CREATOR_AUTHORITY_REFERENCES="$(rg -o 'creator_authority::[[:alnum:]_:{}]+' "$SOURCE_DIR" | sort | uniq -c | awk '{ print $1 " " $2 }' | tr '\n' ';')"
[[ "$CREATOR_AUTHORITY_REFERENCES" == "1 ${SOURCE_DIR}/lp_fee_authority.move:creator_authority::CurveFeeCap;1 ${SOURCE_DIR}/vault.move:creator_authority::CurveFeeCap;" ]] || \
    fail "Launchpad creator_authority may be referenced only for the CurveFeeCap type in lp_fee_authority and vault"

VAULT_PRODUCTION="$(production_section "$VAULT_SOURCE")"
[[ "$(rg -o 'self\.lp_fee_authority' <<<"$VAULT_PRODUCTION" | wc -l)" -eq 8 ]] && \
    [[ "$(rg -o 'self\.lp_fee_authority\.(claim|assert_not_locked|reissue|lock_pending|lock|assert_cap|assert_custodian)\(' <<<"$VAULT_PRODUCTION" | wc -l)" -eq 8 ]] || \
    fail "vault may touch LP-fee authority only through the authority module's transitions and assertions"
if rg -q 'self\.lp_fee_authority[[:space:]]*=|&mut[[:space:]]+self\.lp_fee_authority' "$VAULT_SOURCE"; then
    fail "vault must not assign or mutably lend LP-fee authority state"
fi
require_exact_count 'PackageVersion' 1 \
    "vault must take only the Migrators generation, never a Launchpad PackageVersion" \
    "$VAULT_SOURCE"
require_pattern "$VAULT_SOURCE" '^    package_version::PackageVersion as MigratorsVersion,$' \
    'Migrators generation imported under its guard alias'
require_exact_count '&AdminWitness<LAUNCHPAD_DOMAIN>' 2 \
    "vault Launchpad authority must be exactly protocol claims and LP-fee capability reissue" \
    <(production_section "$VAULT_SOURCE")
require_exact_count 'admin_witness' 4 \
    "vault admin witnesses may flow only into the protocol-fee ledger claim and LP-fee reissue" \
    <(production_section "$VAULT_SOURCE")
require_exact_count 'self.lp_fee_authority.reissue(admin_witness, ctx)' 1 \
    "vault::issue_lp_fee_cap must be the only LP-fee reissue path" \
    "$SOURCE_DIR"/*.move
require_exact_count 'self.fee_ledger.claim_protocol_fees(admin_witness, ctx)' 1 \
    "vault::claim_protocol_fees must be the only admin-authorized ledger claim" \
    "$SOURCE_DIR"/*.move
require_exact_count 'self.drain_creator_fees(ctx)' 2 \
    "creator LP fees may drain only through the live-cap and custodian claims" \
    "$VAULT_SOURCE"
require_exact_count 'self.fee_ledger.claim_creator_fees(ctx)' 1 \
    "creator ledger withdrawal must stay inside the private drain" \
    "$SOURCE_DIR"/*.move
VAULT_PUBLIC_FUNCTIONS="$(rg -o '^public fun [[:alnum:]_]+' <<<"$VAULT_PRODUCTION" | awk '{ print $3 }' | sort | tr '\n' ' ')"
[[ "$VAULT_PUBLIC_FUNCTIONS" == 'assert_lp_fee_cap claim_creator_fees claim_custodied_creator_fees claim_lp_fee_cap claim_protocol_fees issue_lp_fee_cap lock_creator_fees lock_pending_creator_fees ' ]] || \
    fail "vault must expose exactly its protocol claim and pinned LP-fee authority functions"
require_function_body "$VAULT_SOURCE" 'new' \
    'public(package)funnew<Meme,Quote,Venue:drop,Position:key+store>(_venue:Venue,lp_fee_authority:LpFeeAuthority<Meme>,pool_id:ID,position:Position,protocol_meme_residual:Balance<Meme>,protocol_quote_residual:Balance<Quote>,ctx:&mutTxContext,):ID{letpending_vault=prepare(lp_fee_authority,protocol_meme_residual,protocol_quote_residual,ctx,);pending_vault.finish(_venue,pool_id,position)}' \
    "vault::new must require the migration-born LP-fee authority and forward it to preparation"
require_function_body "$VAULT_SOURCE" 'prepare' \
    'public(package)funprepare<Meme,Quote>(lp_fee_authority:LpFeeAuthority<Meme>,protocol_meme_residual:Balance<Meme>,protocol_quote_residual:Balance<Quote>,ctx:&mutTxContext,):LpVault<Meme,Quote>{LpVault{id:object::new(ctx),pool_id:object::id_from_address(@0x0),lp_fee_authority,protocol_meme_residual,protocol_quote_residual,fee_ledger:fees::new(),}}' \
    "vault::prepare must embed the supplied LP-fee authority unchanged"
require_function_body "$VAULT_SOURCE" 'claim_lp_fee_cap' \
    'publicfunclaim_lp_fee_cap<Meme,Quote>(self:&mutLpVault<Meme,Quote>,migrators_version:&MigratorsVersion,launch:&Launch<Meme,Quote>,curve_fee_cap:&CurveFeeCap<Meme>,ctx:&mutTxContext,):LpFeeCap<Meme>{migrators_version.assert_current();letlp_fee_cap=self.lp_fee_authority.claim(launch,curve_fee_cap,ctx);events::lp_fee_cap_claimed<Meme,Quote>(self.id.to_inner(),object::id(&lp_fee_cap),ctx.sender(),);lp_fee_cap}' \
    "vault::claim_lp_fee_cap must check generation, claim through the authority, emit, and return the cap"
require_function_body "$VAULT_SOURCE" 'issue_lp_fee_cap' \
    'publicfunissue_lp_fee_cap<Meme,Quote>(self:&mutLpVault<Meme,Quote>,migrators_version:&MigratorsVersion,admin_witness:&AdminWitness<LAUNCHPAD_DOMAIN>,recipient:address,ctx:&mutTxContext,){migrators_version.assert_current();self.lp_fee_authority.assert_not_locked();assert!(recipient!=@0x0,EInvalidLpFeeCapRecipient);let(revoked_lp_fee_cap_id,lp_fee_cap)=self.lp_fee_authority.reissue(admin_witness,ctx);letlp_fee_cap_id=object::id(&lp_fee_cap);transfer::public_transfer(lp_fee_cap,recipient);events::lp_fee_cap_issued<Meme,Quote>(self.id.to_inner(),revoked_lp_fee_cap_id,lp_fee_cap_id,recipient,);}' \
    "vault::issue_lp_fee_cap must check generation, terminal lock, and nonzero recipient before role-gated reissue, then deliver and emit"
require_function_body "$VAULT_SOURCE" 'lock_pending_creator_fees' \
    'publicfunlock_pending_creator_fees<Meme,Quote>(self:&mutLpVault<Meme,Quote>,migrators_version:&MigratorsVersion,launch:&Launch<Meme,Quote>,custodian:&UID,){migrators_version.assert_current();letcustodian_id=self.lp_fee_authority.lock_pending(launch,custodian);events::lp_fees_locked<Meme,Quote>(self.id.to_inner(),option::none(),custodian_id);}' \
    "vault::lock_pending_creator_fees must check generation, bind through the authority, and emit a capless lock"
require_function_body "$VAULT_SOURCE" 'lock_creator_fees' \
    'publicfunlock_creator_fees<Meme,Quote>(self:&mutLpVault<Meme,Quote>,migrators_version:&MigratorsVersion,lp_fee_cap:LpFeeCap<Meme>,custodian:&UID,){migrators_version.assert_current();let(lp_fee_cap_id,custodian_id)=self.lp_fee_authority.lock(lp_fee_cap,custodian);events::lp_fees_locked<Meme,Quote>(self.id.to_inner(),option::some(lp_fee_cap_id),custodian_id,);}' \
    "vault::lock_creator_fees must check generation, lock through the authority, and emit the destroyed cap"
require_function_body "$VAULT_SOURCE" 'claim_creator_fees' \
    'publicfunclaim_creator_fees<Meme,Quote>(self:&mutLpVault<Meme,Quote>,migrators_version:&MigratorsVersion,lp_fee_cap:&LpFeeCap<Meme>,ctx:&mutTxContext,):(Coin<Meme>,Coin<Quote>){migrators_version.assert_current();self.lp_fee_authority.assert_cap(lp_fee_cap);self.drain_creator_fees(ctx)}' \
    "vault::claim_creator_fees must assert the live LP-fee cap before draining"
require_function_body "$VAULT_SOURCE" 'claim_custodied_creator_fees' \
    'publicfunclaim_custodied_creator_fees<Meme,Quote>(self:&mutLpVault<Meme,Quote>,migrators_version:&MigratorsVersion,custodian:&UID,ctx:&mutTxContext,):(Coin<Meme>,Coin<Quote>){migrators_version.assert_current();self.lp_fee_authority.assert_custodian(custodian);self.drain_creator_fees(ctx)}' \
    "vault::claim_custodied_creator_fees must match the bound custodian before draining"
require_function_body "$VAULT_SOURCE" 'assert_lp_fee_cap' \
    'publicfunassert_lp_fee_cap<Meme,Quote>(self:&LpVault<Meme,Quote>,lp_fee_cap:&LpFeeCap<Meme>,){self.lp_fee_authority.assert_cap(lp_fee_cap);}' \
    "vault::assert_lp_fee_cap must be a read-only exact live-cap identity assertion"
require_function_body "$VAULT_SOURCE" 'drain_creator_fees' \
    'fundrain_creator_fees<Meme,Quote>(self:&mutLpVault<Meme,Quote>,ctx:&mutTxContext,):(Coin<Meme>,Coin<Quote>){' \
    "vault::drain_creator_fees must stay private"
rg -q '^// Code 4 retired: ' "$VAULT_SOURCE" \
    && rg -q '^// Codes 6 and 7 retired: ' "$VAULT_SOURCE" \
    && rg -U -q '#\[error\(code = 5\)\]\nconst EInvalidLpFeeCapRecipient: vector<u8> = b"LP-fee capability recipient must be a nonzero address\.";' "$VAULT_SOURCE" \
    && ! rg -q '#\[error\(code = [467]\)\]|\bELpFee(CapNotLive|esLocked|CustodianMismatch)\b' "$VAULT_SOURCE" || \
    fail "vault must keep code 5 and leave codes 4, 6, and 7 retired to lp_fee_authority"

# The authority module owns every transition. Its one public function only destroys
# a capability; construction needs the witness-typed payload, and each transition
# checks state before the Launchpad authority it consults.
LP_FEE_AUTHORITY_PRODUCTION="$(production_section "$LP_FEE_AUTHORITY_SOURCE")"
require_pattern "$LP_FEE_AUTHORITY_SOURCE" '^module blast_fun_migrators::lp_fee_authority;$' \
    'migrator-owned LP-fee authority module'
[[ "$(tr -d '[:space:]' <<<"$LP_FEE_AUTHORITY_PRODUCTION")" == *'useblast_admin::acl::AdminWitness;useblast_fun::{creator_authority::CurveFeeCap,launch::{Launch,MigrationPayload},launchpad_domain::{Self,LAUNCHPAD_DOMAIN},};//===Errors==='* ]] || \
    fail "lp_fee_authority.move must import only AdminWitness, CurveFeeCap, Launch, MigrationPayload, and the Launchpad domain"
LP_FEE_AUTHORITY_FUNCTIONS="$(rg -o '^(public(\(package\))? )?(entry )?fun [[:alnum:]_]+' <<<"$LP_FEE_AUTHORITY_PRODUCTION" | sort | tr '\n' ';')"
[[ "$LP_FEE_AUTHORITY_FUNCTIONS" == 'fun assert_pending;fun cap_id;fun custodian_id;public fun destroy_lp_fee_cap;public(package) fun assert_cap;public(package) fun assert_custodian;public(package) fun assert_not_locked;public(package) fun claim;public(package) fun lock;public(package) fun lock_pending;public(package) fun new;public(package) fun reissue;' ]] || \
    fail "lp_fee_authority.move must expose only destroy_lp_fee_cap publicly, its eight package transitions, and three private helpers"
if rg -q 'events::|transfer::|assert_current|PackageVersion|\bentry\b' "$LP_FEE_AUTHORITY_SOURCE"; then
    fail "lp_fee_authority.move must stay an eventless, transferless state module under the vault's guards"
fi
[[ "$(rg -c '#\[error\(code = ' "$LP_FEE_AUTHORITY_SOURCE" || true)" -eq 4 ]] \
    && rg -U -q '#\[error\(code = 0\)\]\nconst ELpFeeCapNotLive: vector<u8> = b"LP-fee capability must be the one this vault currently honors\.";' "$LP_FEE_AUTHORITY_SOURCE" \
    && rg -U -q '#\[error\(code = 1\)\]\nconst ELpFeesLocked: vector<u8> = b"Creator LP fees are permanently bound to a custodian\.";' "$LP_FEE_AUTHORITY_SOURCE" \
    && rg -U -q '#\[error\(code = 2\)\]\nconst ELpFeeCustodianMismatch: vector<u8> = b"Custodian must be the one creator LP fees are bound to\.";' "$LP_FEE_AUTHORITY_SOURCE" \
    && rg -U -q '#\[error\(code = 3\)\]\nconst ELpFeeAuthorityNotPending: vector<u8> =\n    b"Only a pending LP-fee authority can be claimed or bound without a capability\.";' "$LP_FEE_AUTHORITY_SOURCE" || \
    fail "lp_fee_authority error codes must remain contiguous 0-3 and bound to their documented failures"
require_function_body "$LP_FEE_AUTHORITY_SOURCE" 'destroy_lp_fee_cap' \
    'publicfundestroy_lp_fee_cap<Meme>(self:LpFeeCap<Meme>){letLpFeeCap{id}=self;id.delete();}' \
    "lp_fee_authority::destroy_lp_fee_cap must only delete the capability"
require_function_body "$LP_FEE_AUTHORITY_SOURCE" 'new' \
    'public(package)funnew<Meme,Quote,MigrationWitness:drop>(_:&MigrationPayload<Meme,Quote,MigrationWitness>,_:MigrationWitness,):LpFeeAuthority<Meme>{LpFeeAuthority::Pending}' \
    "lp_fee_authority::new must require the witness-typed migration payload and return Pending"
require_function_body "$LP_FEE_AUTHORITY_SOURCE" 'claim' \
    'public(package)funclaim<Meme,Quote>(self:&mutLpFeeAuthority<Meme>,launch:&Launch<Meme,Quote>,curve_fee_cap:&CurveFeeCap<Meme>,ctx:&mutTxContext,):LpFeeCap<Meme>{self.assert_pending();launch.assert_curve_fee_cap(curve_fee_cap);letlp_fee_cap=LpFeeCap{id:object::new(ctx)};*self=LpFeeAuthority::Cap(object::id(&lp_fee_cap));lp_fee_cap}' \
    "lp_fee_authority::claim must assert pending, then the launch's live curve-fee cap, before minting"
require_function_body "$LP_FEE_AUTHORITY_SOURCE" 'lock_pending' \
    'public(package)funlock_pending<Meme,Quote>(self:&mutLpFeeAuthority<Meme>,launch:&Launch<Meme,Quote>,custodian:&UID,):ID{self.assert_pending();launch.assert_fee_custodian(custodian);letcustodian_id=custodian.to_inner();*self=LpFeeAuthority::Custodian(custodian_id);custodian_id}' \
    "lp_fee_authority::lock_pending must assert pending, then the launch's fee custodian, before binding"
require_function_body "$LP_FEE_AUTHORITY_SOURCE" 'lock' \
    'public(package)funlock<Meme>(self:&mutLpFeeAuthority<Meme>,lp_fee_cap:LpFeeCap<Meme>,custodian:&UID,):(ID,ID){self.assert_cap(&lp_fee_cap);letlp_fee_cap_id=object::id(&lp_fee_cap);letcustodian_id=custodian.to_inner();lp_fee_cap.destroy_lp_fee_cap();*self=LpFeeAuthority::Custodian(custodian_id);(lp_fee_cap_id,custodian_id)}' \
    "lp_fee_authority::lock must assert and destroy the live cap before binding a terminal custodian"
require_function_body "$LP_FEE_AUTHORITY_SOURCE" 'reissue' \
    'public(package)funreissue<Meme>(self:&mutLpFeeAuthority<Meme>,admin_witness:&AdminWitness<LAUNCHPAD_DOMAIN>,ctx:&mutTxContext,):(Option<ID>,LpFeeCap<Meme>){self.assert_not_locked();admin_witness.assert_role(launchpad_domain::creator_admin_role());letrevoked_lp_fee_cap_id=self.cap_id();letlp_fee_cap=LpFeeCap{id:object::new(ctx)};*self=LpFeeAuthority::Cap(object::id(&lp_fee_cap));(revoked_lp_fee_cap_id,lp_fee_cap)}' \
    "lp_fee_authority::reissue must assert not-locked, then the creator-admin role, before retiring and minting"
require_function_body "$LP_FEE_AUTHORITY_SOURCE" 'assert_not_locked' \
    'public(package)funassert_not_locked<Meme>(self:&LpFeeAuthority<Meme>){assert!(self.custodian_id().is_none(),ELpFeesLocked);}' \
    "lp_fee_authority::assert_not_locked must reject only a bound custodian"
require_function_body "$LP_FEE_AUTHORITY_SOURCE" 'assert_cap' \
    'public(package)funassert_cap<Meme>(self:&LpFeeAuthority<Meme>,lp_fee_cap:&LpFeeCap<Meme>){assert!(self.cap_id().contains(&object::id(lp_fee_cap)),ELpFeeCapNotLive);}' \
    "lp_fee_authority::assert_cap must be an exact live-cap identity assertion"
require_function_body "$LP_FEE_AUTHORITY_SOURCE" 'assert_custodian' \
    'public(package)funassert_custodian<Meme>(self:&LpFeeAuthority<Meme>,custodian:&UID){assert!(self.custodian_id().contains(&custodian.to_inner()),ELpFeeCustodianMismatch);}' \
    "lp_fee_authority::assert_custodian must be an exact bound-custodian identity assertion"
require_function_body "$LP_FEE_AUTHORITY_SOURCE" 'assert_pending' \
    'funassert_pending<Meme>(self:&LpFeeAuthority<Meme>){assert!(match(self){LpFeeAuthority::Pending=>true,_=>false,},ELpFeeAuthorityNotPending,);}' \
    "lp_fee_authority::assert_pending must stay a private Pending-only assertion"
require_function_body "$LP_FEE_AUTHORITY_SOURCE" 'cap_id' \
    'funcap_id<Meme>(self:&LpFeeAuthority<Meme>):Option<ID>{match(self){LpFeeAuthority::Cap(lp_fee_cap_id)=>option::some(*lp_fee_cap_id),_=>option::none(),}}' \
    "lp_fee_authority::cap_id must stay a private Cap-only read"
require_function_body "$LP_FEE_AUTHORITY_SOURCE" 'custodian_id' \
    'funcustodian_id<Meme>(self:&LpFeeAuthority<Meme>):Option<ID>{match(self){LpFeeAuthority::Custodian(custodian_id)=>option::some(*custodian_id),_=>option::none(),}}' \
    "lp_fee_authority::custodian_id must stay a private Custodian-only read"

# Every venue migration route creates the pending authority immediately before it
# redeems the payload and threads that one value through its shared lock into the vault.
require_exact_count 'lp_fee_authority::new(' 13 \
    "exactly thirteen venue migration routes may create an LP-fee authority" \
    "$SOURCE_DIR"/*.move
require_exact_count 'redeem_migration(' 13 \
    "exactly thirteen venue migration routes may redeem a migration payload" \
    "$SOURCE_DIR"/*.move
MIGRATION_ROUTE_TOTAL=0
AUTHORITY_BEFORE_REDEMPTION='letlp_fee_authority=lp_fee_authority::new\(&payload,Witness\(\)\);let\([a-z_]+,[a-z_]+\)=payload\.redeem_migration\(Witness\(\)\);'
AUTHORITY_INTO_LOCK='lock_and_share(<[[:alnum:]_,]+>)?\(launch_id,lp_fee_authority,'
AUTHORITY_INTO_VAULT='letvault_id=vault::new<Meme,Quote,Venue,[[:alnum:]_]+>\(Venue\(\),lp_fee_authority,pool_id,position,|letpending_vault=vault::prepare<Meme,Quote>\(lp_fee_authority,balance::zero\(\),balance::zero\(\),ctx,\);'
for route_spec in cetus:4 turbos:4 mmt:2 bluefin:1 aftermath:2; do
    IFS=: read -r venue_module expected_routes <<<"$route_spec"
    venue_source="$SOURCE_DIR/${venue_module}.move"
    mapfile -t migration_routes < <(rg -o '^public fun migrate[[:alnum:]_]*' "$venue_source" | awk '{ print $3 }')
    [[ "${#migration_routes[@]}" -eq "$expected_routes" ]] || \
        fail "${venue_module}.move must expose exactly $expected_routes migration routes"
    MIGRATION_ROUTE_TOTAL=$((MIGRATION_ROUTE_TOTAL + ${#migration_routes[@]}))
    require_exact_count '    let lp_fee_authority = lp_fee_authority::new(&payload, Witness());' "$expected_routes" \
        "${venue_module}.move must create one LP-fee authority per migration route" \
        "$venue_source"
    require_exact_count 'payload.redeem_migration(Witness())' "$expected_routes" \
        "${venue_module}.move must redeem once per migration route" \
        "$venue_source"
    # Import, three uses per route, the lock parameter, and the vault argument.
    require_exact_count 'lp_fee_authority' $((3 * expected_routes + 3)) \
        "${venue_module}.move may only create, pass, and hand LP-fee authority to the vault" \
        "$venue_source"
    require_pattern "$venue_source" '^    lp_fee_authority::\{Self, LpFeeAuthority\},$' \
        "${venue_module} LP-fee authority import"
    if rg -q 'lp_fee_authority\.' "$venue_source"; then
        fail "${venue_module}.move must not transition LP-fee authority"
    fi
    for route in "${migration_routes[@]}"; do
        route_compact="$(move_function_section "$venue_source" "$route" | tr -d '[:space:]')"
        [[ "$route_compact" =~ $AUTHORITY_BEFORE_REDEMPTION ]] || \
            fail "${venue_module}::${route} must create LP-fee authority immediately before redeeming"
        [[ "$route_compact" =~ $AUTHORITY_INTO_LOCK ]] || \
            fail "${venue_module}::${route} must pass its LP-fee authority into the shared lock"
    done
    lock_compact="$(move_function_section "$venue_source" 'lock_and_share' | tr -d '[:space:]')"
    [[ "$lock_compact" =~ ^fun\ ?lock_and_share\<[[:alnum:]_,]+\>\(launch_id:ID,lp_fee_authority:LpFeeAuthority\<Meme\>, ]] || \
        fail "${venue_module}::lock_and_share must require the LP-fee authority"
    [[ "$lock_compact" =~ $AUTHORITY_INTO_VAULT ]] || \
        fail "${venue_module}::lock_and_share must hand the LP-fee authority to vault construction"
done
[[ "$MIGRATION_ROUTE_TOTAL" -eq 13 ]] || \
    fail "venue modules must expose exactly thirteen migration routes"
require_exact_count 'vault::new<Meme, Quote, Venue, ' 4 \
    "only the four vault::new venue locks may construct a shared vault" \
    "$SOURCE_DIR"/*.move
require_exact_count 'vault::prepare<Meme, Quote>(' 1 \
    "only the Aftermath lock may prepare a vault" \
    "$SOURCE_DIR"/*.move

# LP-fee share policy moved from Launchpad: a migrator-owned eventless singleton under
# this package's generation and three Launchpad-admin setters.
LP_FEE_POLICY_PRODUCTION="$(production_section "$LP_FEE_POLICY_SOURCE")"
require_pattern "$LP_FEE_POLICY_SOURCE" '^module blast_fun_migrators::lp_fee_policy;$' \
    'migrator-owned LP-fee policy module'
require_pattern "$LP_FEE_POLICY_SOURCE" '^use blast_fun::\{bps::\{Self, Bps\}, launchpad_domain::LAUNCHPAD_DOMAIN\};$' \
    'Launchpad Bps and domain imports only'
require_pattern "$LP_FEE_POLICY_SOURCE" '^use blast_fun_migrators::\{events, package_version::PackageVersion\};$' \
    'Migrators events and generation imports'
if rg -q 'blast_fun::(package_version|events|lp_fee_policy)|runtime_config' "$LP_FEE_POLICY_SOURCE"; then
    fail "lp_fee_policy.move must use the Migrators generation and events, never Launchpad's"
fi
rg -U -q 'public struct LpFeePolicy has key \{\n    id: UID,\n    protocol_fee_share_bps: Bps,\n    project_protocol_fee_shares: Table<TypeName, Bps>,\n\}' \
    "$LP_FEE_POLICY_SOURCE" || \
    fail "lp_fee_policy.move must own the Meme-keyed LP-fee share singleton"
LP_FEE_POLICY_FUNCTIONS="$(rg -o '^(public(\(package\))? )?(entry )?fun [[:alnum:]_]+' <<<"$LP_FEE_POLICY_PRODUCTION" | sort | tr '\n' ';')"
[[ "$LP_FEE_POLICY_FUNCTIONS" == 'fun init;fun new;public fun clear_project_protocol_fee_share;public fun protocol_fee_share;public fun set_project_protocol_fee_share;public fun set_protocol_fee_share;' ]] || \
    fail "lp_fee_policy.move must expose exactly three setters and one share read"
[[ "$(rg -c '#\[error\(code = ' "$LP_FEE_POLICY_SOURCE" || true)" -eq 3 ]] \
    && rg -U -q '#\[error\(code = 0\)\]\nconst EProtocolFeeShareUnchanged: vector<u8> =\n    b"A migrator-wide LP-fee share update must change the active share\.";' "$LP_FEE_POLICY_SOURCE" \
    && rg -U -q '#\[error\(code = 1\)\]\nconst EProjectProtocolFeeShareUnchanged: vector<u8> =\n    b"A project LP-fee share update must change the project.s pinned share\.";' "$LP_FEE_POLICY_SOURCE" \
    && rg -U -q '#\[error\(code = 2\)\]\nconst EProjectProtocolFeeShareMissing: vector<u8> =\n    b"A project LP-fee share clear requires a pinned share\.";' "$LP_FEE_POLICY_SOURCE" || \
    fail "lp_fee_policy error codes must remain contiguous 0-2 and bound to their documented failures"
require_exact_count '_: &AdminWitness<LAUNCHPAD_DOMAIN>' 3 \
    "every LP-fee share setter must take a Launchpad admin witness" \
    <(production_section "$LP_FEE_POLICY_SOURCE")
if rg -q '\b(AdminCap|ProtocolAuthority|RuntimeConfig|FeeLedger|Balance|sequence|schema_version|action_tag|nonce)\b' \
    <<<"$LP_FEE_POLICY_PRODUCTION"; then
    fail "lp_fee_policy.move must hold only share configuration"
fi
require_function_body "$LP_FEE_POLICY_SOURCE" 'init' \
    'funinit(ctx:&mutTxContext){transfer::share_object(new(ctx));}' \
    "lp_fee_policy::init must share one eventless policy"
require_function_body "$LP_FEE_POLICY_SOURCE" 'new' \
    'funnew(ctx:&mutTxContext):LpFeePolicy{LpFeePolicy{id:object::new(ctx),protocol_fee_share_bps:bps::new(0),project_protocol_fee_shares:table::new(ctx),}}' \
    "lp_fee_policy::new must start at a zero share with no project overrides"
require_function_body "$LP_FEE_POLICY_SOURCE" 'set_protocol_fee_share' \
    'publicfunset_protocol_fee_share(self:&mutLpFeePolicy,package_version:&PackageVersion,_:&AdminWitness<LAUNCHPAD_DOMAIN>,protocol_fee_share_bps:Bps,){package_version.assert_current();assert!(protocol_fee_share_bps!=self.protocol_fee_share_bps,EProtocolFeeShareUnchanged,);self.protocol_fee_share_bps=protocol_fee_share_bps;events::lp_protocol_fee_share_changed(protocol_fee_share_bps.value());}' \
    "lp_fee_policy::set_protocol_fee_share must check generation and change before writing and emitting"
require_function_body "$LP_FEE_POLICY_SOURCE" 'set_project_protocol_fee_share' \
    'publicfunset_project_protocol_fee_share<Meme>(self:&mutLpFeePolicy,package_version:&PackageVersion,_:&AdminWitness<LAUNCHPAD_DOMAIN>,protocol_fee_share_bps:Bps,){package_version.assert_current();letmeme=type_name::with_original_ids<Meme>();if(self.project_protocol_fee_shares.contains(meme)){letshare_mut=&mutself.project_protocol_fee_shares[meme];assert!(protocol_fee_share_bps!=*share_mut,EProjectProtocolFeeShareUnchanged,);*share_mut=protocol_fee_share_bps;}else{self.project_protocol_fee_shares.add(meme,protocol_fee_share_bps);};events::project_lp_protocol_fee_share_set<Meme>(protocol_fee_share_bps.value());}' \
    "lp_fee_policy::set_project_protocol_fee_share must check generation and change before pinning and emitting"
require_function_body "$LP_FEE_POLICY_SOURCE" 'clear_project_protocol_fee_share' \
    'publicfunclear_project_protocol_fee_share<Meme>(self:&mutLpFeePolicy,package_version:&PackageVersion,_:&AdminWitness<LAUNCHPAD_DOMAIN>,){package_version.assert_current();letmeme=type_name::with_original_ids<Meme>();assert!(self.project_protocol_fee_shares.contains(meme),EProjectProtocolFeeShareMissing,);self.project_protocol_fee_shares.remove(meme);events::project_lp_protocol_fee_share_cleared<Meme>();}' \
    "lp_fee_policy::clear_project_protocol_fee_share must check generation and presence before clearing and emitting"
require_function_body "$LP_FEE_POLICY_SOURCE" 'protocol_fee_share' \
    'publicfunprotocol_fee_share<Meme>(self:&LpFeePolicy):Bps{letmeme=type_name::with_original_ids<Meme>();if(self.project_protocol_fee_shares.contains(meme)){self.project_protocol_fee_shares[meme]}else{self.protocol_fee_share_bps}}' \
    "lp_fee_policy::protocol_fee_share must prefer the project pin over the migrator-wide share"
if rg -U -q 'use blast_fun::\{[^;]*lp_fee_policy' "$SOURCE_DIR"; then
    fail "LpFeePolicy must be imported from blast_fun_migrators, never from Launchpad"
fi
for policy_consumer in vault bluefin aftermath cetus turbos mmt; do
    rg -U -q 'use blast_fun_migrators::\{[^;]*\n    lp_fee_policy::LpFeePolicy,\n' \
        "$SOURCE_DIR/${policy_consumer}.move" || \
        fail "${policy_consumer}.move must import LpFeePolicy from blast_fun_migrators::lp_fee_policy"
done

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
    count="$(rg -c '_: &AdminWitness<LAUNCHPAD_DOMAIN>,' "$source" || true)"
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
require_pattern "$AFTERMATH_SOURCE" 'pending_vault\.finish' \
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
require_pattern "$AFTERMATH_SOURCE" 'self\.meme_weight \+ self\.quote_weight == FIXED_ONE' \
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
AFTERMATH_VAULT_LINE="$(rg -n -m1 'pending_vault\.finish' "$AFTERMATH_SOURCE" | cut -d: -f1)"
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
    'lock_and_share<Meme,Quote>(launch_id,lp_fee_authority,position,residual_meme,residual_quote,source_meme_amount,source_quote_amount,sqrt_price_x64,' \
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
    'lock_and_share<Meme,Quote>(launch_id,lp_fee_authority,position,residual_meme,residual_quote,source_meme_amount,source_quote_amount,sqrt_price_x64,' \
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
    'migration_math::assert_price_within_bps(source_meme_amount,source_quote_amount,true,pool_sqrt_price,bps::new(MAX_PRICE_DEVIATION_BPS),)' \
    'exact Meme-A 50-bps price guard'
require_cetus_public 'migrate_existing_meme_a' \
    'pool::open_position<Meme,Quote>(cetus_config,pool,lower_tick_bits,upper_tick_bits,ctx,)' \
    'exact Meme-A position opening'
require_cetus_public 'migrate_existing_meme_a' \
    'pool::add_liquidity_fix_coin<Meme,Quote>(cetus_config,pool,&mutposition,fixed_amount,fix_amount_a,clock,)' \
    'exact Meme-A fixed-coin addition'
require_cetus_public 'migrate_existing_meme_a' \
    'receipt.add_liquidity_pay_amount()' 'Meme-A payment query'
require_cetus_public 'migrate_existing_meme_a' \
    'pool::repay_add_liquidity<Meme,Quote>(cetus_config,pool,paid_meme,paid_quote,receipt,)' \
    'exact Meme-A repayment'
require_cetus_public 'migrate_existing_meme_a' \
    'assert!(position.pool_id()==object::id(pool),EPositionPoolMismatch);' \
    'Meme-A position-pool identity'
require_cetus_public 'migrate_existing_meme_a' \
    'lock_and_share<Meme,Quote>(launch_id,lp_fee_authority,position,meme.into_coin(ctx),quote.into_coin(ctx),source_meme_amount,source_quote_amount,pool_sqrt_price,' \
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
    'migration_math::assert_price_within_bps(source_meme_amount,source_quote_amount,false,pool_sqrt_price,bps::new(MAX_PRICE_DEVIATION_BPS),)' \
    'exact Meme-B 50-bps price guard'
require_cetus_public 'migrate_existing_meme_b' \
    'pool::open_position<Quote,Meme>(cetus_config,pool,lower_tick_bits,upper_tick_bits,ctx,)' \
    'exact Meme-B position opening'
require_cetus_public 'migrate_existing_meme_b' \
    'pool::add_liquidity_fix_coin<Quote,Meme>(cetus_config,pool,&mutposition,fixed_amount,fix_amount_a,clock,)' \
    'exact Meme-B fixed-coin addition'
require_cetus_public 'migrate_existing_meme_b' \
    'receipt.add_liquidity_pay_amount()' 'Meme-B payment query'
require_cetus_public 'migrate_existing_meme_b' \
    'pool::repay_add_liquidity<Quote,Meme>(cetus_config,pool,paid_quote,paid_meme,receipt,)' \
    'exact Meme-B repayment'
require_cetus_public 'migrate_existing_meme_b' \
    'assert!(position.pool_id()==object::id(pool),EPositionPoolMismatch);' \
    'Meme-B position-pool identity'
require_cetus_public 'migrate_existing_meme_b' \
    'lock_and_share<Meme,Quote>(launch_id,lp_fee_authority,position,meme.into_coin(ctx),quote.into_coin(ctx),source_meme_amount,source_quote_amount,pool_sqrt_price,' \
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
    'migration_math::assert_residual_within_bps(source_meme_amount,residual_meme_amount,bps::new(MAX_RESIDUAL_BPS),)' \
    'Meme residual limit'
require_cetus_private 'lock_and_share' \
    'migration_math::assert_residual_within_bps(source_quote_amount,residual_quote_amount,bps::new(MAX_RESIDUAL_BPS),)' \
    'Quote residual limit'
require_cetus_private 'lock_and_share' \
    'vault::new<Meme,Quote,Venue,Position>(Venue(),lp_fee_authority,pool_id,position,residual_meme.into_balance(),residual_quote.into_balance(),ctx,)' \
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
    'lock_and_share<Meme,Quote>(launch_id,lp_fee_authority,position,residual_meme,residual_quote,' \
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
    'lock_and_share<Meme,Quote>(launch_id,lp_fee_authority,position,residual_meme,residual_quote,' \
    'Meme-B shared lock'
require_turbos_public 'migrate_new_meme_b' \
    'assert_positive_liquidity(&position,positions);' \
    'Meme-B positive position liquidity'

# Existing routes redeem, guard at 50 bps, then call only the mint return path.
require_turbos_public 'migrate_existing_meme_a' \
    'migration_math::assert_price_within_bps(source_meme_amount,source_quote_amount,true,pool_sqrt_price,bps::new(MAX_PRICE_DEVIATION_BPS),)' \
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
    'migration_math::assert_price_within_bps(source_meme_amount,source_quote_amount,false,pool_sqrt_price,bps::new(MAX_PRICE_DEVIATION_BPS),)' \
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
    'migration_math::assert_residual_within_bps(source_meme_amount,residual_meme_amount,bps::new(MAX_RESIDUAL_BPS),)' \
    'Meme residual limit'
require_turbos_private 'lock_and_share' \
    'migration_math::assert_residual_within_bps(source_quote_amount,residual_quote_amount,bps::new(MAX_RESIDUAL_BPS),)' \
    'Quote residual limit'
require_turbos_private 'lock_and_share' \
    'vault::new<Meme,Quote,Venue,TurbosPositionNFT>(Venue(),lp_fee_authority,pool_id,position,residual_meme.into_balance(),residual_quote.into_balance(),ctx,)' \
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
[[ "$EVENT_EMISSION_COUNT" -eq 15 ]] || \
    fail "events.move must emit exactly fifteen strongly typed payloads"

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

if rg -n \
    'vault::(pending_id|finish)[[:space:]]*\(|pool::add_liquidity_pay_amount[[:space:]]*\(|coin::from_balance[[:space:]]*\(|(bluefin|cetus|mmt|turbos)::(effective_tier_for_testing|set_tier)[[:space:]]*\(|aftermath::(effective_policy_for_testing|set_policy)[[:space:]]*\(' \
    "$SOURCE_DIR" "$PACKAGE_DIR/tests"; then
    fail "functions with a natural first receiver must use Move 2024 dot syntax"
fi

if rg -n \
    'let[[:space:]]+[[:alnum:]_]+:[[:space:]]+&(mut[[:space:]]+)?(AftermathPosition|Tier)' \
    "$SOURCE_DIR" "$PACKAGE_DIR/tests"; then
    fail "local reference types must be inferred from explicit generic arguments"
fi

# === Shared administration boundary ===
#
# Migrators reuses the Launchpad domain for membership only. It must never
# reimplement the reusable ACL, generation arithmetic, or native custody, and it
# must stop treating the Launchpad generation as its own.

for forbidden in acl.move; do
    [[ -e "$SOURCE_DIR/$forbidden" ]] && \
        fail "Migrators must not define a local $forbidden"
done

if rg -n '^public struct (Authority|ProtocolAuthority|SuperAdminCap|AdminCap|AdminWitness)\b' \
    "$SOURCE_DIR"; then
    fail "administration types must come from blast_admin, never from a local copy"
fi

if rg -n 'acl::new\(|fun (grant_admin|revoke_admin|sign_in)\(' "$SOURCE_DIR"; then
    fail "Migrators must not create or manage its own administration domain"
fi

for required in package_marker.move package_version.move package_admin.move; do
    [[ -f "$SOURCE_DIR/$required" ]] || \
        fail "Migrators must own $required"
done

rg -q '^public struct PackageVersion has key \{$' "$SOURCE_DIR/package_version.move" || \
    fail "Migrators must own one canonical generation container"
rg -q 'generation: OperationalVersion<PACKAGE_MARKER>,' "$SOURCE_DIR/package_version.move" || \
    fail "the generation value must be the shared typed value"
rg -q '^const PACKAGE_VERSION: u64 = 1;$' "$SOURCE_DIR/package_version.move" || \
    fail "Migrators must compile its current generation constant"
rg -q '^const NEXT_PACKAGE_VERSION: u64 = 2;$' "$SOURCE_DIR/package_version.move" || \
    fail "Migrators must compile its cutover target constant"
if rg -n '\.checked_add\(|fun activate\(' "$SOURCE_DIR/package_version.move"; then
    fail "generation arithmetic and separate activation belong to blast_admin"
fi

rg -q 'custody: UpgradeCustody<PACKAGE_MARKER>,' "$SOURCE_DIR/package_admin.move" || \
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
CUSTODY_ROLE_ASSERTIONS="$(rg -c 'admin_witness\.assert_role\(launchpad_domain::package_admin_role\(\)\);' \
    "$SOURCE_DIR/package_admin.move" || true)"
[[ "${CUSTODY_ROLE_ASSERTIONS:-0}" -eq 5 ]] || \
    fail "every governed custody transition must assert Launchpad's exported role"

# Every production public function in these modules is a protected mutation,
# except the one read-only live-cap assertion `vault::assert_lp_fee_cap`, whose
# whole body is pinned above as a delegation to `lp_fee_authority::assert_cap`.
# `lp_fee_authority` is package-internal state with only the pinned public
# `destroy_lp_fee_cap`, and `lp_fee_policy` is guarded below. Derive the expected
# total from declarations so adding a route cannot silently inherit a stale
# hand-maintained count, then prove each function takes this package's
# generation and checks it before doing anything else.
for guard_module in vault bluefin aftermath cetus turbos mmt; do
    guard_source="$SOURCE_DIR/${guard_module}.move"
    mapfile -t guarded_functions < <(
        rg -o '^public fun [[:alnum:]_]+' "$guard_source" \
            | awk -v module="$guard_module" '
                $3 ~ /_for_testing$/ { next }
                module == "vault" && $3 == "assert_lp_fee_cap" { next }
                { print $3 }
            '
    )
    expected_guards="${#guarded_functions[@]}"
    actual_guards="$(rg -c '^[[:space:]]+migrators_version\.assert_current\(\);' \
        "$guard_source" || true)"
    [[ "${actual_guards:-0}" -eq "$expected_guards" ]] || \
        fail "${guard_module}.move must assert this package's generation on every protected mutation (found ${actual_guards:-0}, expected $expected_guards)"

    actual_parameters="$(rg -c '^[[:space:]]+migrators_version: &MigratorsVersion,' \
        "$guard_source" || true)"
    [[ "${actual_parameters:-0}" -eq "$expected_guards" ]] || \
        fail "${guard_module}.move must take the Migrators version under that exact name on every guarded mutation"

    for guarded_function in "${guarded_functions[@]}"; do
        guard_section="$(move_function_section "$guard_source" "$guarded_function")"
        guard_signature="${guard_section%%\{*}"
        printf '%s' "$guard_signature" | rg -q \
            'migrators_version:[[:space:]]*&MigratorsVersion,' || \
            fail "${guard_module}::${guarded_function} must take the Migrators version"

        first_statement="$(printf '%s\n' "$guard_section" | awk '
            !body && /\{/ { body = 1; next }
            body {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                sub(/[[:space:]]+$/, "", line)
                if (line == "" || line ~ /^\/\//) next
                print line
                exit
            }
        ')"
        [[ "$first_statement" == 'migrators_version.assert_current();' ]] || \
            fail "${guard_module}::${guarded_function} must assert this package's generation first"
    done
done

# `lp_fee_policy` names this package's own generation `package_version`: each setter
# takes it and checks it first; only the pinned `protocol_fee_share` read is exempt.
mapfile -t policy_guarded_functions < <(
    production_section "$LP_FEE_POLICY_SOURCE" \
        | rg -o '^public fun [[:alnum:]_]+' \
        | awk '$3 != "protocol_fee_share" { print $3 }'
)
[[ "${#policy_guarded_functions[@]}" -eq 3 ]] || \
    fail "lp_fee_policy.move must guard exactly its three setters"
[[ "$(rg -c '^    package_version\.assert_current\(\);' "$LP_FEE_POLICY_SOURCE" || true)" -eq 3 ]] || \
    fail "lp_fee_policy.move must assert this package's generation on every setter"
[[ "$(rg -c '^    package_version: &PackageVersion,' "$LP_FEE_POLICY_SOURCE" || true)" -eq 3 ]] || \
    fail "lp_fee_policy.move must take this package's generation on every setter"
for guarded_function in "${policy_guarded_functions[@]}"; do
    guard_section="$(move_function_section "$LP_FEE_POLICY_SOURCE" "$guarded_function")"
    first_statement="$(printf '%s\n' "$guard_section" | awk '
        !body && /\{/ { body = 1; next }
        body {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "" || line ~ /^\/\//) next
            print line
            exit
        }
    ')"
    [[ "$first_statement" == 'package_version.assert_current();' ]] || \
        fail "lp_fee_policy::${guarded_function} must assert this package's generation first"
done

# In the venue and vault modules `package_version` names the Launchpad object.
# It may be passed through to a composed Launchpad call, but it may never stand
# in for this package's own guard. (`package_admin.move` owns no Launchpad
# input: its `package_version` parameter is this package's own container.)
for guard_module in vault bluefin aftermath cetus turbos mmt; do
    if rg -n '^[[:space:]]+package_version\.assert_current\(\);' \
        "$SOURCE_DIR/${guard_module}.move"; then
        fail "${guard_module}.move must not assert the Launchpad generation as if it were its own"
    fi
done

echo "Migrator source boundaries passed"
