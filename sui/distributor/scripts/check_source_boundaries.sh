#!/usr/bin/env bash
# Pins the custody, authority and accounting boundaries of the holder distributor.
set -euo pipefail

PACKAGE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SOURCE_DIR="$PACKAGE_DIR/sources"
DISTRIBUTOR_SOURCE="$SOURCE_DIR/blast_fun_distributor.move"
MERKLE_SOURCE="$SOURCE_DIR/merkle.move"

fail() {
    echo "Distributor source boundary failed: $1" >&2
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

require_struct_fields() {
    local name="$1"
    local expected="$2"
    local description="$3"
    local compact

    compact="$(awk -v name="$name" '
        $0 ~ ("^public struct " name "[ <(]") { active = 1 }
        active { print }
        active && /^}/ { exit }
    ' "$DISTRIBUTOR_SOURCE" | tr -d '[:space:]')"
    [[ "$compact" == "$expected" ]] || fail "$description"
}

[[ -f "$DISTRIBUTOR_SOURCE" ]] || fail "the distributor module must exist"
[[ -f "$MERKLE_SOURCE" ]] || fail "the merkle module must exist"

# === Package boundary ===
#
# The distributor is a downstream custodian. It owns no launchpad or migrator
# state, mints no fee capability of its own, and reaches custodied fees only
# through the two upstream claim seams.

for forbidden in acl.move launch.move vault.move lp_fee_authority.move; do
    [[ -e "$SOURCE_DIR/$forbidden" ]] && \
        fail "the distributor must not define a local $forbidden"
done

if rg -n '^public struct (Authority|AdminWitness|SuperAdminCap|CurveFeeCap|LpFeeCap)\b' \
    "$SOURCE_DIR"; then
    fail "fee and administration capabilities must come from their owning packages"
fi

reject_pattern '\bentry fun\b' "the distributor must expose no entry functions"
if rg -q 'public\(package\) fun' "$DISTRIBUTOR_SOURCE"; then
    fail "the custody module must expose no package-visible seam; merkle owns the only one"
fi

# === Custody witness ===
#
# One drop-only, field-less witness is the entire proof of custody. A witness
# with a field, or a public constructor, would let another package claim the
# fees this module is bound to.

require_pattern "$DISTRIBUTOR_SOURCE" '^public struct Witness\(\) has drop;$' \
    "the field-less drop-only custody witness"
if rg -n 'fun (new_witness|witness)\(' "$DISTRIBUTOR_SOURCE"; then
    fail "the custody witness must never be constructible outside this module"
fi
require_exact_count 'Witness()' 6 \
    "custody must be one declaration plus exactly the five bind and claim call sites" \
    <(production_section "$DISTRIBUTOR_SOURCE")

# === Enrollment and collection ===
#
# Enrollment destroys the curve-fee capability before any state exists, so no
# administrator can reassign the fees afterwards. Every launch-facing call pins
# the enrolled launch, and both collection paths must fund custody through the
# single accounting seam.

require_function_body "$DISTRIBUTOR_SOURCE" 'new' \
    'publicfunnew<Meme,Quote>(version:&Version,curve_fee_cap:CurveFeeCap<Meme>,launch:&mutLaunch<Meme,Quote>,package_version:&PackageVersion,ctx:&mutTxContext,):(Distributor<Meme,Quote>,PublisherCap){version.assert_enabled();letcurve_fee_cap_id=object::id(&curve_fee_cap);letlaunch_id=object::id(launch);launch.lock_creator_fees(package_version,curve_fee_cap,Witness());letdistributor=Distributor{id:object::new(ctx),launch:launch_id,meme:balance::zero(),quote:balance::zero(),next_round:0,last_checkpoint:option::none(),};letpublisher=PublisherCap{id:object::new(ctx),distributor:distributor.id.to_inner()};event::emit(Enrolled{distributor:distributor.id.to_inner(),launch:distributor.launch,curve_fee_cap:curve_fee_cap_id,publisher_cap:publisher.id.to_inner(),});(distributor,publisher)}' \
    "distributor::new must check the version, then lock the creator fees before it allocates"

require_function_body "$DISTRIBUTOR_SOURCE" 'collect_curve_fees' \
    'publicfuncollect_curve_fees<Meme,Quote>(self:&mutDistributor<Meme,Quote>,version:&Version,launch:&mutLaunch<Meme,Quote>,package_version:&PackageVersion,ctx:&mutTxContext,){version.assert_enabled();assert!(object::id(launch)==self.launch,EWrongSource);let(meme,quote)=launch.claim_custodied_creator_fees(package_version,Witness(),ctx);self.accrue(object::id(launch),meme,quote);}' \
    "collect_curve_fees must pin the enrolled launch before it claims"

require_function_body "$DISTRIBUTOR_SOURCE" 'collect_lp_fees' \
    'publicfuncollect_lp_fees<Meme,Quote>(self:&mutDistributor<Meme,Quote>,version:&Version,vault:&mutLpVault<Meme,Quote>,migrators_version:&MigratorsVersion,ctx:&mutTxContext,){version.assert_enabled();let(meme,quote)=vault.claim_custodied_creator_fees(migrators_version,Witness(),ctx);self.accrue(object::id(vault),meme,quote);}' \
    "collect_lp_fees must claim only through the vault's custodian seam"

require_function_body "$DISTRIBUTOR_SOURCE" 'lock_lp_fees' \
    'publicfunlock_lp_fees<Meme,Quote>(self:&Distributor<Meme,Quote>,version:&Version,vault:&mutLpVault<Meme,Quote>,migrators_version:&MigratorsVersion,launch:&Launch<Meme,Quote>,){version.assert_enabled();assert!(object::id(launch)==self.launch,EWrongSource);vault.lock_pending_creator_fees(migrators_version,launch,Witness());}' \
    "lock_lp_fees must pin the enrolled launch before it binds pending fees"

require_function_body "$DISTRIBUTOR_SOURCE" 'lock_lp_fees_with_cap' \
    'publicfunlock_lp_fees_with_cap<Meme,Quote>(self:&Distributor<Meme,Quote>,version:&Version,vault:&mutLpVault<Meme,Quote>,migrators_version:&MigratorsVersion,launch:&Launch<Meme,Quote>,lp_fee_cap:LpFeeCap<Meme>,){version.assert_enabled();assert!(object::id(launch)==self.launch,EWrongSource);vault.lock_creator_fees(migrators_version,lp_fee_cap,Witness());}' \
    "lock_lp_fees_with_cap must pin the enrolled launch before it destroys the capability"

require_function_body "$DISTRIBUTOR_SOURCE" 'accrue' \
    'funaccrue<Meme,Quote>(self:&mutDistributor<Meme,Quote>,source:ID,meme:Coin<Meme>,quote:Coin<Quote>,){letmeme_amount=meme.value();letquote_amount=quote.value();letmeme_total=self.meme.join(meme.into_balance());letquote_total=self.quote.join(quote.into_balance());event::emit(FeesCollected{distributor:self.id.to_inner(),source,meme_amount,quote_amount,meme_total,quote_total,});}' \
    "accrue must join both balances into custody and report the resulting totals"

require_exact_count 'self.accrue(' 2 \
    "collection must reach custody only through the single accounting seam" \
    <(production_section "$DISTRIBUTOR_SOURCE")

# === Version and pause ===

require_function_body "$DISTRIBUTOR_SOURCE" 'assert_enabled' \
    'funassert_enabled(self:&Version){assert!(self.version==VERSION,EWrongVersion);assert!(!self.paused,EPaused);}' \
    "assert_enabled must reject retired bytecode before it reports a pause"

require_function_body "$DISTRIBUTOR_SOURCE" 'migrate' \
    'publicfunmigrate(self:&mutVersion,_:&AdminCap){assert!(self.version<VERSION,ENotUpgrade);self.version=VERSION;}' \
    "migrate must move forward only, and must never clear the pause"

require_function_body "$DISTRIBUTOR_SOURCE" 'set_paused' \
    'publicfunset_paused(self:&mutVersion,_:&AdminCap,paused:bool){assert!(self.version==VERSION,EWrongVersion);assert!(self.paused!=paused,EUnchangedPause);self.paused=paused;event::emit(PauseChanged{paused});}' \
    "set_paused must reject a no-op transition and emit the change"

require_exact_count 'version.assert_enabled();' 7 \
    "every value-moving entry point must be pausable" \
    <(production_section "$DISTRIBUTOR_SOURCE")

# === Published layouts ===
#
# Indexers replay these payloads positionally. Reordering or retyping a field
# silently rewrites history for every consumer.

require_struct_fields 'Distributor' \
    'publicstructDistributor<phantomMeme,phantomQuote>haskey{id:UID,launch:ID,meme:Balance<Meme>,quote:Balance<Quote>,next_round:u64,last_checkpoint:Option<u64>,}' \
    "the distributor custody layout is published state"
require_struct_fields 'PublisherCap' \
    'publicstructPublisherCaphaskey,store{id:UID,distributor:ID,}' \
    "the publisher capability must stay bound to one distributor"
require_struct_fields 'Enrolled' \
    'publicstructEnrolledhascopy,drop{distributor:ID,launch:ID,curve_fee_cap:ID,publisher_cap:ID,}' \
    "the enrollment event payload is a replay boundary"
require_struct_fields 'FeesCollected' \
    'publicstructFeesCollectedhascopy,drop{distributor:ID,source:ID,meme_amount:u64,quote_amount:u64,meme_total:u64,quote_total:u64,}' \
    "the fee-collection event payload is a replay boundary"
require_struct_fields 'RewardPaid' \
    'publicstructRewardPaidhascopy,drop{round:ID,index:u64,beneficiary:address,meme_amount:u64,quote_amount:u64,meme_remaining:u64,quote_remaining:u64,}' \
    "the payout event payload is a replay boundary"

# === Error registry ===
#
# Error codes are an append-only public interface; renumbering one silently
# changes what every existing client believes went wrong.

expected_errors="$(cat <<'EOF'
#[error(code = 0)]
#[error(code = 1)]
#[error(code = 2)]
#[error(code = 3)]
#[error(code = 4)]
#[error(code = 5)]
#[error(code = 6)]
#[error(code = 7)]
#[error(code = 8)]
#[error(code = 9)]
#[error(code = 10)]
#[error(code = 11)]
#[error(code = 12)]
#[error(code = 13)]
#[error(code = 14)]
#[error(code = 15)]
EOF
)"
actual_errors="$(rg -o '^#\[error\(code = [0-9]+\)\]' "$DISTRIBUTOR_SOURCE")"
[[ "$actual_errors" == "$expected_errors" ]] || \
    fail "distributor error codes must remain contiguous 0-15 in their published order"

require_pattern "$DISTRIBUTOR_SOURCE" \
    'const EWrongSource: vector<u8> = b"Curve must match the enrolled launch\.";' \
    "the pinned wrong-source message"
require_pattern "$DISTRIBUTOR_SOURCE" \
    'const EWrongPublisher: vector<u8> = b"Publisher capability belongs to another distributor\.";' \
    "the pinned wrong-publisher message"

# === Claim integrity ===
#
# A leaf commits the distributor, round and index, so a proof cannot be replayed
# into another round, and the claimed bitmap must be set before funds move.

require_pattern "$DISTRIBUTOR_SOURCE" \
    '\*&mut self\.claimed\[word\] = self\.claimed\[word\] \| bit;' \
    "the claimed bit must be recorded before payment"
if ! rg -Uq '\*&mut self\.claimed\[word\] = self\.claimed\[word\] \| bit;\n[[:space:]]*if \(meme_amount > 0\)' \
    "$DISTRIBUTOR_SOURCE"; then
    fail "the claimed bit must be set before either transfer"
fi
require_pattern "$DISTRIBUTOR_SOURCE" 'const MAX_LEAVES: u64 = 65_536;' \
    "the pinned maximum leaf count"
require_pattern "$MERKLE_SOURCE" 'public\(package\) fun leaf\(' \
    "the domain-separated leaf constructor"

# === Test-only leakage ===
#
# No test-only helper may hand out custody, a capability, or an arbitrary
# balance in a production build.

if rg -Uq 'fun [a-z_]*_for_testing[^{]*\)[[:space:]]*:[[:space:]]*(&mut|Distributor<|Round<|PublisherCap)' \
    "$DISTRIBUTOR_SOURCE"; then
    fail "test-only helpers must not hand out custody, publication authority or mutable state"
fi
if rg -n 'public fun [a-z_]+_for_testing' <(production_section "$DISTRIBUTOR_SOURCE"); then
    fail "test-only helpers must live below the test-only section marker"
fi

echo "Distributor source boundaries passed"
