#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$PACKAGE_DIR/sources"
VAULT_SOURCE="$SOURCE_DIR/vault.move"
BLUEFIN_SOURCE="$SOURCE_DIR/bluefin.move"
CETUS_SOURCE="$SOURCE_DIR/cetus.move"
EVENTS_SOURCE="$SOURCE_DIR/blast_events.move"
VENUE_CONFIG_SOURCE="$SOURCE_DIR/venue_config.move"
MIGRATION_MATH_SOURCE="$SOURCE_DIR/migration_math.move"

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

[[ -f "$VAULT_SOURCE" ]] || fail "missing sources/vault.move"
[[ -f "$BLUEFIN_SOURCE" ]] || fail "missing sources/bluefin.move"
[[ -f "$CETUS_SOURCE" ]] || fail "missing sources/cetus.move"
[[ -f "$EVENTS_SOURCE" ]] || fail "missing sources/blast_events.move"
[[ -f "$VENUE_CONFIG_SOURCE" ]] || fail "missing sources/venue_config.move"
[[ -f "$MIGRATION_MATH_SOURCE" ]] || fail "missing sources/migration_math.move"

# === Release adapter matrix ===
#
# Cetus and Bluefin are the release's only adapters. An adapter reaches the launchpad migration
# seams (ticket binding, the treasury-capability borrow, begin and complete migration, router
# collection, and the settled route update) only by constructing its own sealed `Witness()`, so the
# matrix is exactly the modules that declare a witness and call those seams. Each completes its
# migration into a vault it prepares, attaches its position to, and shares; only Cetus needs a local
# normalized venue interface. A future adapter extends this matrix explicitly.
matrix_witness_modules=""
matrix_seam_modules=""
for source in "$SOURCE_DIR"/*.move; do
    module="$(basename "$source" .move)"
    facts="$(move_facts "$source")"
    [[ "$facts" != *MALFORMED* ]] || fail "the Move reader rejected ${module}.move"
    if awk -F'\t' '$1 == "TYPE" && $2 == "Witness" { found = 1 } END { exit !found }' <<<"$facts"; then
        matrix_witness_modules+="$module"$'\n'
    fi
    if awk -F'\t' '$1 == "NORM" { print $2 }' <<<"$facts" | rg -q \
        '(\.|::)(bind_migration_witness|treasury_cap_mut|begin_migration|complete_migration|collect|settle_and_update_routes)(<[^>(]*>)?\('; then
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
    completion_body="$(move_facts "$SOURCE_DIR/${module}.move" \
        | awk -F'\t' '$1 == "FN" && $6 == 0 && index($10, "complete_migration(") > 0 { print $10 }' \
        | tr -d '[:space:]')"
    in_order 'vault::prepare(' '.attach(&Venue(),' '.complete_migration(' '.share(&Venue())' \
        <<<"$completion_body" || \
        fail "${module} must complete migration once, into a vault it prepares, attaches, and then shares"
done
[[ "$(find "$PACKAGE_DIR/interfaces" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" \
    == 'cetus ' ]] || \
    fail "Cetus must be the only local venue interface; an excluded venue keeps no interface"

# Migration math is the venues' shared seed-price derivation and nothing else.
[[ "$(rg -c '^public\(package\) fun ' "$MIGRATION_MATH_SOURCE" || true)" -eq 1 ]] \
    && rg -q '^public\(package\) fun sqrt_price_x64\(' "$MIGRATION_MATH_SOURCE" || \
    fail "migration math must expose exactly its package-only seed-price derivation"
if rg -q '^public fun |^entry fun |^public entry fun ' "$MIGRATION_MATH_SOURCE"; then
    fail "migration math must not expose a public transaction or composition ABI"
fi
require_pattern "$MIGRATION_MATH_SOURCE" \
    'module blast_fun_migrators::migration_math;' \
    'migrator-owned migration math module'
[[ "$(rg -o '^#\[error\(code = [0-9]+\)\]' "$MIGRATION_MATH_SOURCE" | tr '\n' ' ')" \
        == '#[error(code = 0)] ' ]] \
    && rg -U -q '#\[error\(code = 0\)\]\nconst EInvalidMigrationSeedBalance: vector<u8> = b"Migration seed balances must both be greater than zero\.";' \
        "$MIGRATION_MATH_SOURCE" || \
    fail "migration math must use code 0 for its seed-balance failure"
require_pattern "$MIGRATION_MATH_SOURCE" \
    'integer_sqrt\(ratio_q128\(meme_amount, quote_amount, meme_is_coin_a\)\)' \
    'exact Q128 price derivation'
if rg -q '\b(blast_fun::(constants|errors)|UID|key|Balance|Coin|TxContext|transfer::|blast_events::|RuntimeConfig)\b' \
    "$MIGRATION_MATH_SOURCE"; then
    fail "migration math must remain a pure migrator-owned arithmetic module"
fi
if rg -U -q 'use blast_fun::\{[^}]*migration_math' "$SOURCE_DIR"; then
    fail "venue modules must use migrator-owned migration math"
fi

require_pattern "$EVENTS_SOURCE" 'public struct VaultCreated' 'vault creation event'
require_pattern "$EVENTS_SOURCE" 'public struct ProtocolFeesClaimed' 'protocol residual claim event'
require_pattern "$EVENTS_SOURCE" 'type_name::with_original_ids<Venue>' 'venue type facts'
require_pattern "$EVENTS_SOURCE" 'type_name::with_original_ids<Meme>' 'Meme type facts'
require_pattern "$EVENTS_SOURCE" 'type_name::with_original_ids<Quote>' 'Quote type facts'
require_pattern "$EVENTS_SOURCE" 'position_id: ID' 'stable position identity'
reject_pattern 'protocol_meme_fee_total|creator_meme_fee_total|protocol_quote_fee_total|creator_quote_fee_total' \
    'derivable fee totals are forbidden in migrator events'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(VaultCreated' \
    'direct strongly typed vault event emission'
require_pattern "$EVENTS_SOURCE" 'sui::event::emit\(ProtocolFeesClaimed' \
    'direct strongly typed protocol-claim event emission'
require_pattern "$EVENTS_SOURCE" 'public struct VenueTierUpdated' 'sealed venue tier mutation event'
require_exact_count 'blast_events::protocol_fees_claimed<Meme, Quote>(' 1 \
    "protocol residual claims must be emitted only by vault::claim_protocol_fees" \
    "$SOURCE_DIR"/*.move

# The vault is ledger-free (ADR 0088): it custodies one position and the protocol migration
# residuals, and every recurring LP fee leaves through the launch's `FeeRouter` in the transaction
# that collects it. Pinning the whole layout, the residual-only constructor, the one public claim,
# the immutable-reference reads, and the absence of any object-owned coin receipt keeps a new vault
# from carrying a second fee path.
VAULT_FACTS="$(move_facts "$VAULT_SOURCE")"
[[ "$VAULT_FACTS" != *MALFORMED* ]] || fail "the Move reader rejected vault.move"
[[ "$(move_production_type LpVault <<<"$VAULT_FACTS")" \
    == 'struct LpVault<phantom Meme, phantom Quote> has key { id: UID, pool_id: ID, protocol_meme_residual: Balance<Meme>, protocol_quote_residual: Balance<Quote>, }' ]] || \
    fail "LpVault must hold only its position key space, the pool binding, and the protocol residuals"
[[ "$(awk -F'\t' '$1 == "FN" && $2 == "prepare" { print $3 ":" $9 }' <<<"$VAULT_FACTS")" \
    == 'package:fun prepare<Meme, Quote>( protocol_meme_residual: Balance<Meme>, protocol_quote_residual: Balance<Quote>, ctx: &mut TxContext, ): LpVault<Meme, Quote>' ]] || \
    fail "vault::prepare must be package-only and take only the protocol residual balances"
[[ "$(awk -F'\t' '$1 == "FN" && $3 == "public" && $6 == 0 { print $2 }' <<<"$VAULT_FACTS" \
    | LC_ALL=C sort | tr '\n' ' ')" \
    == 'claim_protocol_fees pool_id position_id protocol_meme_residual protocol_quote_residual ' ]] \
    && [[ "$(awk -F'\t' '$1 == "FN" && $3 == "public" && $6 == 0 && $2 != "claim_protocol_fees" { print $9 }' \
        <<<"$VAULT_FACTS" | LC_ALL=C sort | tr '\n' ';')" \
        == 'fun pool_id<Meme, Quote>(self: &LpVault<Meme, Quote>): ID;fun position_id<Meme, Quote, Venue>(self: &LpVault<Meme, Quote>): Option<ID>;fun protocol_meme_residual<Meme, Quote>(self: &LpVault<Meme, Quote>): u64;fun protocol_quote_residual<Meme, Quote>(self: &LpVault<Meme, Quote>): u64;' ]] || \
    fail "the protocol residual claim must be the vault's only public mutation; its public reads take the vault immutably"
if rg -q 'transfer::(public_)?receive|Receiving<' "$SOURCE_DIR"; then
    fail "migrators must not receive object-owned coins; LP fees leave only through the router"
fi
if rg -U -q 'blast_fun::\{[^}]*\bfees\b|blast_fun::fees\b|creator_authority::' "$SOURCE_DIR"; then
    fail "migrators must not embed Launchpad's curve-fee ledger or consult creator fee authority"
fi
require_pattern "$VAULT_SOURCE" 'public struct PositionKey' 'sealed position key type'
require_pattern "$VAULT_SOURCE" 'dynamic_object_field::add' 'dynamic object-field position attachment'
require_pattern "$VAULT_SOURCE" 'self\.id\.dynamic_object_field_mut' 'typed mutable position borrow'
require_pattern "$VAULT_SOURCE" '_venue: &Venue' 'borrowed venue witness on position access'
VAULT_VENUE_GUARD_COUNT="$(rg -o 'self\.id\.has_dynamic_object_field' "$VAULT_SOURCE" | wc -l || true)"
[[ "$VAULT_VENUE_GUARD_COUNT" -eq 3 ]] || \
    fail "vault share and immutable/mutable position borrows must guard the sealed venue key"
require_pattern "$VAULT_SOURCE" 'protocol_meme_residual\.withdraw_all' \
    'protocol Meme residual claim'
require_pattern "$VAULT_SOURCE" 'protocol_quote_residual\.withdraw_all' \
    'protocol Quote residual claim'
require_pattern "$VAULT_SOURCE" 'blast_events::vault_created' 'vault creation event emission'
# T-013: VaultCreated is a direct event emitted only after the pool binding and position custody
# it records are written.
vault_attach_body="$(move_facts "$VAULT_SOURCE" \
    | awk -F'\t' '$1 == "FN" && $2 == "attach" && $6 == 0 { print $10 }' | tr -d '[:space:]')"
in_order 'self.pool_id=pool_id;' 'self.id.add_dynamic_object_field(' 'blast_events::vault_created<' \
    <<<"$vault_attach_body" || fail "VaultCreated must follow the pool binding and position attachment"
require_exact_count 'PackageVersion' 1 \
    "vault must take only the Migrators generation, never a Launchpad PackageVersion" \
    "$VAULT_SOURCE"
require_pattern "$VAULT_SOURCE" 'package_version::PackageVersion as MigratorsVersion' \
    'Migrators generation imported under its guard alias'
require_exact_count '&AdminWitness<BLAST_FUN_DOMAIN>' 1 \
    "vault Launchpad authority must be exactly the protocol residual claim" \
    <(production_section "$VAULT_SOURCE")
[[ "$(rg -o '^#\[error\(code = [0-9]+\)\]' "$VAULT_SOURCE" | tr '\n' ' ')" \
        == '#[error(code = 0)] #[error(code = 1)] #[error(code = 2)] ' ]] || \
    fail "vault errors must be sequential from zero"

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
require_pattern "$VENUE_CONFIG_SOURCE" 'blast_events::venue_tier_updated<Venue>' \
    'sealed tier mutation emission'
require_pattern "$VENUE_CONFIG_SOURCE" 'public\(package\) fun add_policy<Key:' \
    'sealed-key package-only policy installation'
require_pattern "$VENUE_CONFIG_SOURCE" 'public\(package\) fun has_policy<Key:' \
    'sealed-key package-only policy presence read'
require_pattern "$VENUE_CONFIG_SOURCE" 'public\(package\) fun policy<Key:' \
    'sealed-key package-only policy read'
require_pattern "$VENUE_CONFIG_SOURCE" 'public\(package\) fun add_object<Key: copy \+ drop \+ store, Object: key \+ store>' \
    'sealed-key package-only object custody'
require_pattern "$VENUE_CONFIG_SOURCE" 'public\(package\) fun has_object<Key:' \
    'sealed-key package-only object presence read'
require_pattern "$VENUE_CONFIG_SOURCE" 'public\(package\) fun object<Key:' \
    'sealed-key package-only object read'
# Venue entries are write-once: the only mutable borrow of a config entry is the tier pin.
[[ "$(move_facts "$VENUE_CONFIG_SOURCE" \
    | awk -F'\t' '$1 == "FN" && $6 == 0 && $10 ~ /_field_mut/ { print $2 }')" \
    == 'set_tier' ]] || \
    fail "venue entries must be write-once; only the tier pin may borrow a config entry mutably"
VENUE_TIER_SETTER_COUNT=0
for source in "$BLUEFIN_SOURCE" "$CETUS_SOURCE"; do
    rg -q 'public fun set_tier' "$source" || \
        fail "every venue module must expose its admin tier pin"
    count="$(rg -c '_: &AdminWitness<BLAST_FUN_DOMAIN>,' "$source" || true)"
    VENUE_TIER_SETTER_COUNT=$((VENUE_TIER_SETTER_COUNT + ${count:-0}))
done
[[ "$VENUE_TIER_SETTER_COUNT" -eq 2 ]] || \
    fail "every venue tier pin must take a live core admin witness exactly once"
require_pattern "$BLUEFIN_SOURCE" 'public struct Witness' 'sealed Bluefin witness'
require_pattern "$BLUEFIN_SOURCE" 'public struct Venue' 'sealed Bluefin venue marker'
# Bluefin has exactly one binding, one atomic migrate route, one collection entry, and one settled
# update entry. The binding only delegates to the core; migration begins, creates and funds the
# pool, attaches the venue position, completes once, then shares the vault and the pool; and every
# fee exit goes through the Launchpad router.
bluefin_facts="$(move_facts "$BLUEFIN_SOURCE")"
[[ "$bluefin_facts" != *MALFORMED* ]] || fail "the Move reader rejected bluefin.move"
bluefin_public="$(awk -F'\t' '$1 == "FN" && $3 == "public" && $6 == 0 { print $2 }' <<<"$bluefin_facts" \
    | sort | tr '\n' ' ')"
[[ "$bluefin_public" == 'bind collect_fees migrate set_tier settle_and_update_routes ' ]] || \
    fail "Bluefin must expose exactly bind, migrate, collect_fees, settle_and_update_routes, and set_tier"
bluefin_body() {
    awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name { print $10 }' <<<"$bluefin_facts" \
        | tr -d '[:space:]' | sed 's/,)/)/g'
}
[[ "$(bluefin_body bind)" == 'ticket.bind_migration_witness<Meme,Quote,Witness>(config,Witness());' ]] || \
    fail "bluefin::bind must only bind the sealed witness through the core"
bluefin_migrate_body="$(bluefin_body migrate)"
in_order \
    'migrators_version.assert_current();' \
    'venue_config.tier<Venue>()' \
    'launch.begin_migration(package_version,Witness())' \
    'pool::create_pool_and_get_object<Meme,Quote,SUI>(' \
    'creation_fee.into_balance()' \
    'pool::open_position(' \
    'pool::add_liquidity_with_fixed_amount(' \
    'vault.attach(&Venue(),position.pool_id(),position)' \
    'vault.position<_,_,_,Position>(&Venue())' \
    'vault.pending_residuals()' \
    'launch.complete_migration(' \
    'vault.share(&Venue())' \
    'pool.share_pool_object()' \
    <<<"$bluefin_migrate_body" || \
    fail "Bluefin migrate must begin, create, fund, attach, complete once, then share vault and pool"
[[ "$bluefin_migrate_body" == *'letfix_meme=source_meme>=source_quote;'* \
    && "$bluefin_migrate_body" == *'if(fix_meme)source_memeelsesource_quote,fix_meme)'* ]] || \
    fail "Bluefin migrate must fix Meme when its atoms are at least the Quote atoms, else Quote"
[[ "$(bluefin_body collect_fees)" == *'router.collect(package_version,policy,Witness(),object::id(self),object::id(pool),position_id,meme_fee,quote_fee,ctx)'* ]] || \
    fail "Bluefin collection must pay the collected position through the router binding"
[[ "$(bluefin_body settle_and_update_routes)" == *'router.settle_and_update_routes(package_version,policy,router_config_cap,Witness(),object::id(self),object::id(pool),position_id,meme_fee,quote_fee,proposed,ctx)'* ]] || \
    fail "Bluefin settled updates must pay the collected position through the router binding"
in_order \
    'self.position_mut<_,_,_,Position>(&Venue());' \
    'assert!(position.pool_id()==object::id(pool),EPositionPoolMismatch);' \
    'let(_,_,meme_fee,quote_fee)=pool::collect_fee(clock,bluefin_config,pool,position);' \
    '(object::id(position),meme_fee,quote_fee)' \
    <<<"$(bluefin_body collect_position_fees)" || \
    fail "Bluefin collection must check the custodied position's pool once, before the venue call"
[[ "$(rg -o '^#\[error\(code = [0-9]+\)\]' "$BLUEFIN_SOURCE" | tr '\n' ' ')" == '#[error(code = 0)] ' ]] \
    && rg -U -q '#\[error\(code = 0\)\]\nconst EPositionPoolMismatch: ' "$BLUEFIN_SOURCE" || \
    fail "Bluefin must use code 0 for its position-pool check"

require_pattern "$CETUS_SOURCE" 'public struct Witness' 'sealed Cetus witness'
require_pattern "$CETUS_SOURCE" 'public struct Venue' 'sealed Cetus venue marker'
# Cetus has one binding, its tier pin, and one migrate, collection, and settled-update entry per
# coin ordering. Binding reserves pool creation before any Meme can leave the ticket: it keeps an
# existing reservation, checks that Cetus registers the effective tier, mints the Meme type's cap
# only while none is held, then registers and records the pair at that tick spacing. Each migrate
# route creates the pair's pool only with that cap at the reserved tick spacing, prices it from the
# handed-off balances in its own coin order, fixes Meme when its atoms are at least the Quote atoms
# (else Quote), and completes into a new vault; every fee exit pays the collected position through
# the Launchpad router.
cetus_facts="$(move_facts "$CETUS_SOURCE")"
[[ "$cetus_facts" != *MALFORMED* ]] || fail "the Move reader rejected cetus.move"
cetus_public="$(awk -F'\t' '$1 == "FN" && $3 == "public" && $6 == 0 { print $2 }' <<<"$cetus_facts" \
    | LC_ALL=C sort | tr '\n' ' ')"
[[ "$cetus_public" == 'bind collect_fees_meme_a collect_fees_meme_b migrate_meme_a migrate_meme_b set_tier settle_and_update_routes_meme_a settle_and_update_routes_meme_b ' ]] || \
    fail "Cetus must expose exactly bind, set_tier, and one migrate, collect, and settled-update route per coin order"
cetus_body() {
    awk -F'\t' -v name="$1" '$1 == "FN" && $2 == name && $6 == 0 { print $10 }' <<<"$cetus_facts" \
        | tr -d '[:space:]' | sed 's/,)/)/g'
}
in_order \
    'migrators_version.assert_current();' \
    'ticket.bind_migration_witness<_,Quote,_>(config,Witness());' \
    'if(venue_config.has_policy(ReservationKey<Meme,Quote>()))return;' \
    'let(tick_spacing,fee_rate)=venue_config.effective_tier();' \
    'assert!(config::get_fee_rate(tick_spacing,cetus_config)==fee_rate,ETierMismatch);' \
    'if(!venue_config.has_object(CreationCapKey<Meme>())){letpool_creation_cap=factory::mint_pool_creation_cap(cetus_config,pools,ticket.treasury_cap_mut(config,Witness()),ctx);venue_config.add_object(CreationCapKey<Meme>(),pool_creation_cap);};' \
    'factory::register_permission_pair<Meme,Quote>(cetus_config,pools,tick_spacing,' \
    'venue_config.add_policy(ReservationKey<Meme,Quote>(),tick_spacing);' \
    'blast_events::cetus_pool_reserved<Meme,Quote>(' \
    <<<"$(cetus_body bind)" || \
    fail "cetus::bind must keep a reservation, check the effective tier, mint the cap once, then register and record the pair"
for side in a b; do
    if [[ "$side" == a ]]; then
        coin_order='Meme,Quote' meme_is_coin_a='true' fix_coin_a='meme_amount>=quote_amount'
        coins='meme.into_coin(ctx),quote.into_coin(ctx)' outputs='position,residual_meme,residual_quote'
        fees='meme_fee,quote_fee'
    else
        coin_order='Quote,Meme' meme_is_coin_a='false' fix_coin_a='meme_amount<quote_amount'
        coins='quote.into_coin(ctx),meme.into_coin(ctx)' outputs='position,residual_quote,residual_meme'
        fees='quote_fee,meme_fee'
    fi
    in_order \
        'migrators_version.assert_current();' \
        "assert!(factory::is_right_order<${coin_order}>(),EInvalidCoinOrder);" \
        'lettick_spacing=venue_config.reserved_tick_spacing<Meme,Quote>();' \
        'let(tick_lower,tick_upper)=pool_creator::full_range_tick_range(tick_spacing);' \
        'let(meme,quote,migration)=launch.begin_migration(package_version,Witness());' \
        'letmeme_amount=meme.value();letquote_amount=quote.value();' \
        "let(${outputs})=pool_creator::create_pool_v3_with_creation_cap<${coin_order}>(cetus_config,pools,venue_config.pool_creation_cap<Meme>(),tick_spacing,migration_math::sqrt_price_x64(meme_amount,quote_amount,${meme_is_coin_a}),b\"\".to_string(),tick_lower,tick_upper,${coins},${fix_coin_a},clock,ctx);" \
        'launch.complete_into_vault(package_version,router,policy,currency,migration,meme_amount,quote_amount,position,residual_meme,residual_quote,ctx);' \
        <<<"$(cetus_body "migrate_meme_${side}")" || \
        fail "cetus::migrate_meme_${side} must create its own coin order's pool with the reserved cap at the reserved tick spacing, fix the side with more atoms, and complete into a vault"
    [[ "$(cetus_body "collect_fees_meme_${side}")" == "migrators_version.assert_current();let(position_id,${fees})=self.collect_position_fees(cetus_config,pool);router.collect(package_version,policy,Witness(),object::id(self),object::id(pool),position_id,meme_fee,quote_fee,ctx);" ]] || \
        fail "cetus::collect_fees_meme_${side} must pay the collected position through the router binding"
    [[ "$(cetus_body "settle_and_update_routes_meme_${side}")" == "migrators_version.assert_current();let(position_id,${fees})=self.collect_position_fees(cetus_config,pool);router.settle_and_update_routes(package_version,policy,router_config_cap,Witness(),object::id(self),object::id(pool),position_id,meme_fee,quote_fee,proposed,ctx);" ]] || \
        fail "cetus::settle_and_update_routes_meme_${side} must pay the collected position through the router binding"
done
in_order \
    'letpool_id=position.pool_id();' \
    'letliquidity=position.liquidity();' \
    'vault::prepare(residual_meme.into_balance(),residual_quote.into_balance(),ctx);' \
    'vault.attach(&Venue(),pool_id,position);' \
    'let(residual_meme,residual_quote)=vault.pending_residuals();' \
    'launch.complete_migration(package_version,router,policy,currency,migration,Witness(),&vault,pool_id,vault.position<_,_,_,Position>(&Venue()),meme_amount-residual_meme.value(),quote_amount-residual_quote.value(),residual_meme,residual_quote,liquidity,ctx);' \
    'vault.share(&Venue());' \
    <<<"$(cetus_body complete_into_vault)" || \
    fail "Cetus must record as supplied exactly what the venue did not return as residual"
in_order \
    'self.position<_,_,_,Position>(&Venue());' \
    'assert!(position.pool_id()==object::id(pool),EPositionPoolMismatch);' \
    'let(fee_a,fee_b)=pool::collect_fee(cetus_config,pool,position,true);' \
    '(object::id(position),fee_a,fee_b)' \
    <<<"$(cetus_body collect_position_fees)" || \
    fail "Cetus collection must check the custodied position's pool once, before the venue call"
[[ "$(rg -o '^#\[error\(code = [0-9]+\)\]' "$CETUS_SOURCE" | tr '\n' ' ')" \
    == '#[error(code = 0)] #[error(code = 1)] #[error(code = 2)] ' ]] \
    && rg -U -q '#\[error\(code = 0\)\]\nconst ETierMismatch: ' "$CETUS_SOURCE" \
    && rg -U -q '#\[error\(code = 1\)\]\nconst EInvalidCoinOrder: ' "$CETUS_SOURCE" \
    && rg -U -q '#\[error\(code = 2\)\]\nconst EPositionPoolMismatch: ' "$CETUS_SOURCE" || \
    fail "Cetus must use sequential codes 0-2 for tier, coin order, and position-pool checks"
# Both adapters share one public parameter order, so a caller builds every venue's migrate,
# collect, and settled-update call the same way: the subject, both generations, the router, its
# policy, and (for a settled update) the router configuration capability, then venue inputs.
adapter_prefix='migrators_version: &MigratorsVersion, package_version: &PackageVersion, router: &mut FeeRouter<Meme, Quote>, policy: &LpFeePolicy,'
for entry in bluefin:migrate cetus:migrate_meme_a cetus:migrate_meme_b \
    bluefin:collect_fees cetus:collect_fees_meme_a cetus:collect_fees_meme_b \
    bluefin:settle_and_update_routes cetus:settle_and_update_routes_meme_a cetus:settle_and_update_routes_meme_b; do
    case "${entry#*:}" in
        migrate*) expected="( launch: &mut Launch<Meme, Quote>, ${adapter_prefix} currency: &mut Currency<Meme>," ;;
        collect*) expected="( self: &mut LpVault<Meme, Quote>, ${adapter_prefix}" ;;
        *) expected="( self: &mut LpVault<Meme, Quote>, ${adapter_prefix} router_config_cap: &RouterConfigCap<Meme, Quote>," ;;
    esac
    signature="$(move_facts "$SOURCE_DIR/${entry%%:*}.move" \
        | awk -F'\t' -v name="${entry#*:}" '$1 == "FN" && $2 == name && $6 == 0 { print $9 }')"
    [[ "$signature" == *"$expected"* ]] || \
        fail "${entry%%:*}::${entry#*:} must take the shared adapter parameter order"
done

reject_pattern 'dynamic(_object)?_field::(remove(_opt)?|replace)' \
    'dynamic object-field removal or replacement is forbidden'
reject_pattern 'events_wrapper|public struct Event<' \
    'generic adapter event envelopes are forbidden'
reject_pattern 'protocol_treasury|residual_treasury' \
    'address-based residual treasury routing is forbidden'
reject_pattern 'remove_liquidity' 'principal removal is forbidden'
reject_pattern 'decrease_liquidity|withdraw_liquidity' 'principal withdrawal is forbidden'
reject_pattern 'close_position' 'position closure is forbidden'
reject_pattern 'burn_position|destroy_position' 'Cetus position destruction is forbidden'
reject_pattern 'gauge|stake_position|staking' 'position gauge staking is forbidden'
if rg -q 'fun [a-z_]*_meme_b\b|meme_is_coin_a' "$BLUEFIN_SOURCE"; then
    fail "Bluefin must use only the deterministic Meme-A/Quote-B orientation"
fi
reject_pattern '(position\.(burn|delete|destroy)|((burn|delete|destroy)[[:space:]]*\([^)]*position))' \
    'position burn or destruction is forbidden'
reject_pattern '(sequence|revision|nonce|schema_version|action_tag):' \
    'application-level event ordering fields are forbidden'

if rg -q 'sui::event::emit' "$SOURCE_DIR" \
    --glob '*.move' --glob '!blast_events.move'; then
    fail "state modules must emit only through typed events helpers"
fi

EVENT_EMISSION_COUNT="$(rg -o 'sui::event::emit' "$EVENTS_SOURCE" | wc -l)"
[[ "$EVENT_EMISSION_COUNT" -eq 4 ]] || \
    fail "blast_events.move must emit exactly four strongly typed payloads"

# Two object custody paths exist: the vault's position attachment and `VenueConfig`'s object API,
# whose only caller stores the Meme type's Cetus pool-creation capability while binding.
[[ "$(rg -c 'dynamic_object_field::add' "$SOURCE_DIR" | LC_ALL=C sort | tr '\n' ' ')" \
    == "$SOURCE_DIR/vault.move:1 $SOURCE_DIR/venue_config.move:1 " ]] || \
    fail "only the vault's position attachment and VenueConfig's object API may add a dynamic object field"
[[ "$(rg -c '\.add_object\(' "$SOURCE_DIR" || true)" == "$CETUS_SOURCE:1" ]] \
    && rg -q 'venue_config\.add_object\(CreationCapKey<Meme>\(\), ' "$CETUS_SOURCE" || \
    fail "only cetus::bind may store an object in VenueConfig, and only the Meme type's pool-creation capability"

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
CETUS_PUBLIC_SIGNATURES="$(rg -U 'public fun (bind|migrate|collect|settle)[^{]+\{' "$CETUS_SOURCE" || true)"
if [[ "$CETUS_PUBLIC_SIGNATURES" =~ (sqrt_price|orientation|meme_is|tick_spacing:|fee_rate:) ]]; then
    fail "caller-supplied Cetus price, orientation, or tier is forbidden"
fi
# Only the reserved capability creates the pool: never an unreserved creation, an adopted existing
# pool, or a released reservation.
[[ "$(rg -c 'pool_creator::create_pool_v3_with_creation_cap<' "$CETUS_SOURCE" || true)" -eq 2 ]] || \
    fail "each Cetus migration route must create its pool with the reserved capability"
if rg -q 'create_pool_v3[[:space:]]*[<(]|open_position|add_liquidity|unregister_permission_pair|policy_mut' \
    "$CETUS_SOURCE"; then
    fail "Cetus must neither create unreserved, adopt a pool, nor release a reservation"
fi
[[ "$(rg -c 'ticket\.treasury_cap_mut\(config, Witness\(\)\)' "$CETUS_SOURCE" || true)" -eq 1 ]] || \
    fail "the Cetus capability must be minted once from the bound ticket's lent treasury capability"

BLUEFIN_COMPACT_SOURCE="$(tr -d '[:space:]' < "$BLUEFIN_SOURCE")"
BLUEFIN_PUBLIC_SIGNATURES="$(rg -U 'public fun (migrate|collect|settle)[^{]+\{' "$BLUEFIN_SOURCE" || true)"
if [[ "$BLUEFIN_PUBLIC_SIGNATURES" =~ (sqrt_price|orientation|meme_is|tick_spacing:|fee_rate:|amount|liquidity) ]]; then
    fail "caller-supplied Bluefin price, orientation, tier, or amount is forbidden"
fi
# The caller's SUI coin is the whole creation fee; Bluefin enforces the exact configured amount.
[[ "$(rg -o 'into_balance' "$BLUEFIN_SOURCE" | wc -l)" -eq 1 ]] \
    && [[ "$BLUEFIN_COMPACT_SOURCE" == *'creation_fee:Coin<SUI>,'* ]] \
    && [[ "$bluefin_migrate_body" == *',creation_fee.into_balance(),ctx);'* ]] \
    && ! [[ "$BLUEFIN_COMPACT_SOURCE" =~ balance::(zero|create|from|withdraw|split)|creation_fee\.(split|balance_mut) ]] || \
    fail "the Bluefin creation fee must be the caller's whole SUI coin"
if [[ "$BLUEFIN_COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*Venue([^C]|$) ]]; then
    fail "public or package Bluefin venue exposure is forbidden"
fi
if [[ "$COMPACT_SOURCE" =~ public(\(package\))?fun[^\{]*bluefin::Venue ]]; then
    fail "cross-module Bluefin venue exposure is forbidden"
fi

if rg -n \
    'vault::(pending_id|finish)[[:space:]]*\(|pool::add_liquidity_pay_amount[[:space:]]*\(|coin::from_balance[[:space:]]*\(|(bluefin|cetus)::(effective_tier_for_testing|set_tier)[[:space:]]*\(|(^|[^.[:alnum:]_])collect_position_fees[[:space:]]*\(' \
    "$SOURCE_DIR" "$PACKAGE_DIR/tests"; then
    fail "functions with a natural first receiver must use Move 2024 dot syntax"
fi

if rg -n \
    'let[[:space:]]+[[:alnum:]_]+:[[:space:]]+&(mut[[:space:]]+)?Tier\b' \
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

for required in blast_fun_migrators.move package_version.move package_admin.move; do
    [[ -f "$SOURCE_DIR/$required" ]] || \
        fail "Migrators must own $required"
done

rg -q '^public struct PackageVersion has key \{$' "$SOURCE_DIR/package_version.move" || \
    fail "Migrators must own one canonical generation container"
rg -q 'generation: OperationalVersion<BLAST_FUN_MIGRATORS>,' "$SOURCE_DIR/package_version.move" || \
    fail "the generation value must be the shared typed value"
rg -q '^const PACKAGE_VERSION: u64 = 1;$' "$SOURCE_DIR/package_version.move" || \
    fail "Migrators must compile its current generation constant"
rg -q '^const NEXT_PACKAGE_VERSION: u64 = 2;$' "$SOURCE_DIR/package_version.move" || \
    fail "Migrators must compile its cutover target constant"
if rg -n '\.checked_add\(|fun activate\(' "$SOURCE_DIR/package_version.move"; then
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
CUSTODY_ROLE_ASSERTIONS="$(rg -c 'admin_witness\.assert_role\(blast_fun_domain::package_admin_role\(\)\);' \
    "$SOURCE_DIR/package_admin.move" || true)"
[[ "${CUSTODY_ROLE_ASSERTIONS:-0}" -eq 2 ]] || \
    fail "every governed custody transition must assert Launchpad's exported role"
# Venues gate callers by package version and launchpad cutovers advance its version, so this
# package must always be able to relink (ADR 0088): nothing may destroy its UpgradeCap. Every
# commit also advances the generation, and an additive or dependency-only upgrade cannot change the
# generation constants, so narrowing the policy would freeze the package at its next upgrade.
if rg -n '\bmake_immutable\b|\brestrict_to_' "$SOURCE_DIR"; then
    fail "the migrators package stays upgradeable under the compatible policy: no path may narrow its policy or make it immutable"
fi

# Every production public function in these modules is a protected mutation, except
# `bluefin::bind`, whose whole body is pinned above as the core's admitted ticket binding, and the
# vault's getters, whose names and exact signatures are pinned above. The getter exemption is
# limited to the vault: elsewhere a function with only immutable parameters can still create a
# value, such as a sealed witness. Derive the expected total from declarations so adding a route
# cannot silently inherit a stale hand-maintained count, then prove each function takes this
# package's generation and checks it before doing anything else.
for guard_module in vault bluefin cetus; do
    guard_source="$SOURCE_DIR/${guard_module}.move"
    guard_facts="$(move_facts "$guard_source")"
    [[ "$guard_facts" != *MALFORMED* ]] || fail "the Move reader rejected ${guard_module}.move"
    read_only_getters=" $(awk -F'\t' -v module="$guard_module" '
        module == "vault" && $1 == "FN" && $3 == "public" && $6 == 0 {
            parameters = substr($9, index($9, "(") + 1)
            parameters = substr(parameters, 1, index(parameters, ")") - 1)
            if (parameters !~ /&mut / && parameters !~ /: [A-Za-z]/) print $2
        }
    ' <<<"$guard_facts" | tr '\n' ' ')"
    mapfile -t guarded_functions < <(
        rg -o '^public fun [[:alnum:]_]+' "$guard_source" \
            | awk -v module="$guard_module" -v read_only="$read_only_getters" '
                $3 ~ /_for_testing$/ { next }
                module == "bluefin" && $3 == "bind" { next }
                index(read_only, " " $3 " ") > 0 { next }
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

# In the venue and vault modules `package_version` names the Launchpad object.
# It may be passed through to a composed Launchpad call, but it may never stand
# in for this package's own guard. (`package_admin.move` owns no Launchpad
# input: its `package_version` parameter is this package's own container.)
for guard_module in vault bluefin cetus; do
    if rg -n '^[[:space:]]+package_version\.assert_current\(\);' \
        "$SOURCE_DIR/${guard_module}.move"; then
        fail "${guard_module}.move must not assert the Launchpad generation as if it were its own"
    fi
done

# T-009's provider-conformance fixture models the only safe cross-package collection shape: only
# the sealed wrapper calls core collection and settlement, and its witness never escapes.
ROUTE_UPDATE_ADAPTER_TEST="$PACKAGE_DIR/tests/route_update_adapter_tests.move"
[[ -f "$ROUTE_UPDATE_ADAPTER_TEST" ]] || fail "missing T-009 sealed route-update adapter fixture"
[[ "$(rg -c -F 'router.collect(' "$ROUTE_UPDATE_ADAPTER_TEST")" -eq 1 ]] || \
    fail "only the sealed adapter wrapper may call launchpad collection"
[[ "$(rg -c -F '.settle_and_update_routes(' "$ROUTE_UPDATE_ADAPTER_TEST")" -eq 1 ]] || \
    fail "only the sealed adapter wrapper may call launchpad route settlement"
if rg -n 'public fun .*AdapterSettlementWitness|fun .*\):[[:space:]]*AdapterSettlementWitness|return .*AdapterSettlementWitness' \
    "$ROUTE_UPDATE_ADAPTER_TEST"; then
    fail "adapter witness must not escape through a constructor or return API"
fi

# T-010's cross-package conformance adapter begins, attaches the child position, completes, and
# shares the vault immediately afterward, and exposes no protected return. Only order anchors are
# pinned, on whitespace-free text so formatting cannot change the verdict.
ATOMIC_MIGRATION_TEST="$PACKAGE_DIR/tests/atomic_migration_tests.move"
[[ -f "$ATOMIC_MIGRATION_TEST" ]] || fail "missing T-010 atomic migration adapter fixture"
atomic_facts="$(move_facts "$ATOMIC_MIGRATION_TEST")"
[[ "$atomic_facts" != *MALFORMED* ]] || fail "the Move reader rejected the atomic migration fixture"
atomic_public="$(awk -F'\t' '$1 == "FN" && $3 == "public" { print $2 ":" $9 }' <<<"$atomic_facts")"
atomic_body="$(awk -F'\t' '$1 == "FN" && $2 == "mock_adapter_with" { print $10 }' <<<"$atomic_facts" \
    | tr -d '[:space:]' | sed 's/,)/)/g')"
atomic_after_completion="${atomic_body#*launch.complete_migration(}"

[[ "$atomic_public" == mock_adapter:* && "$atomic_public" != *$'\n'* && "$atomic_public" != *'):'* ]] || \
    fail "the atomic fixture's only public function must be the unit-returning mock_adapter"
in_order \
    'launch.begin_migration(' \
    'pending_vault.attach(' \
    'pending_vault.position<' \
    'pending_vault.pending_residuals()' \
    'launch.complete_migration(' \
    'pending_vault.share<' \
    'transfer::share_object(pool)' \
    <<<"$atomic_body" \
    && [[ "${atomic_after_completion#*);}" == pending_vault.share\<* ]] || \
    fail "atomic adapter must begin, attach, borrow canonical custody, complete once, then share the vault immediately"

# No public migrator function, in any source or the atomic fixture, may hand out a linear migration
# value, a raw balance, a position, a vault, or router configuration authority.
protected_returners="$(for file in "$SOURCE_DIR"/*.move "$ATOMIC_MIGRATION_TEST"; do move_facts "$file"; done \
    | awk -F'\t' '
        $1 == "MALFORMED" { print "MALFORMED" }
        $1 == "FN" && $3 == "public" && $6 == 0 && index($9, "):") > 0 {
            if (substr($9, index($9, "):") + 2) ~ /(^|[^A-Za-z0-9_])(Migration|Balance|RouterConfigCap|LpVault|Position|Pool|PoolCreationCap)([^A-Za-z0-9_]|$)/) print $2
        }')"
[[ -z "$protected_returners" ]] || \
    fail "public functions must not return linear migration values, balances, custody objects, or router caps: $protected_returners"

echo "Migrator source boundaries passed"
