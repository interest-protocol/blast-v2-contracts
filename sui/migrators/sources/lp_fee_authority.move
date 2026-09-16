/// Migration-born, revocable authority over creator LP fees held by one migration vault.
///
/// Every migration creates exactly one `Pending` authority from the witness-typed launch
/// payload, so no administrator mints the first capability. The launch's live curve-fee cap
/// holder claims it once, a launch custodian binds pending fees without any cap, and a
/// creator administrator may reissue it for community takeovers until fees are bound. Pending
/// fees of a launch whose creator fees are already custodied are reserved for that custodian.
module blast_fun_migrators::lp_fee_authority;

use blast_admin::acl::AdminWitness;
use blast_fun::{
    creator_authority::CurveFeeCap,
    launch::{Launch, MigrationPayload},
    launchpad_domain::{Self, LAUNCHPAD_DOMAIN},
};
use std::type_name::{Self, TypeName};

// === Errors ===

#[error(code = 0)]
const ELpFeeCapNotLive: vector<u8> = b"LP-fee capability must be the one this vault currently honors.";
#[error(code = 1)]
const ELpFeesLocked: vector<u8> = b"Creator LP fees are permanently bound to a custodian.";
#[error(code = 2)]
const ELpFeeCustodianMismatch: vector<u8> = b"Custodian must be the one creator LP fees are bound to.";
#[error(code = 3)]
const ELpFeeAuthorityNotPending: vector<u8> =
    b"Only a pending LP-fee authority can be claimed or bound without a capability.";
#[error(code = 4)]
const ELpFeesReservedForCustodian: vector<u8> =
    b"Pending creator LP fees are reserved for the launch's creator-fee custodian.";
#[error(code = 5)]
const EInvalidLpFeeCustodian: vector<u8> =
    b"Custodian witness must be a struct type from a package outside the frameworks.";

// === Public Structs ===

/// Revocable authority over the creator LP fees of the vault that records its ID.
public struct LpFeeCap<phantom Meme> has key, store {
    id: UID,
}

/// Who may claim creator LP fees in the one vault that embeds this value.
///
/// `Pending` from migration until the first claim, bind, or reissue; `Cap` for the live
/// revocable capability; terminal `Custodian` once fees are bound forever to the module
/// named by the witness type only it can construct.
public enum LpFeeAuthority<phantom Meme> has drop, store {
    Pending,
    Cap(ID),
    Custodian(TypeName),
}

// === Public Functions ===

/// Deletes an LP-fee capability; destroying the live cap forfeits it until reissue.
public fun destroy_lp_fee_cap<Meme>(self: LpFeeCap<Meme>) {
    let LpFeeCap { id } = self;

    id.delete();
}

// === Package Functions ===

/// Creates the one pending authority for a migration the selected adapter is completing.
public(package) fun new<Meme, Quote, MigrationWitness: drop>(
    _: &MigrationPayload<Meme, Quote, MigrationWitness>,
    _: MigrationWitness,
): LpFeeAuthority<Meme> {
    LpFeeAuthority::Pending
}

/// Mints the migration-born capability once for the launch's live curve-fee cap holder.
public(package) fun claim<Meme, Quote>(
    self: &mut LpFeeAuthority<Meme>,
    launch: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
    ctx: &mut TxContext,
): LpFeeCap<Meme> {
    self.assert_pending();
    launch.assert_curve_fee_cap(curve_fee_cap);

    let lp_fee_cap = LpFeeCap { id: object::new(ctx) };
    *self = LpFeeAuthority::Cap(object::id(&lp_fee_cap));

    lp_fee_cap
}

/// Binds pending fees forever to the custodian module the launch's creator fees are bound to.
public(package) fun lock_pending<Meme, Quote, Custodian: drop>(
    self: &mut LpFeeAuthority<Meme>,
    launch: &Launch<Meme, Quote>,
    custodian: Custodian,
): TypeName {
    self.assert_pending();
    launch.assert_fee_custodian(custodian);

    let custodian = type_name::with_original_ids<Custodian>();
    *self = LpFeeAuthority::Custodian(custodian);

    custodian
}

/// Destroys the live capability and binds fees forever to `custodian`.
public(package) fun lock<Meme, Custodian: drop>(
    self: &mut LpFeeAuthority<Meme>,
    lp_fee_cap: LpFeeCap<Meme>,
    _: Custodian,
): (ID, TypeName) {
    self.assert_cap(&lp_fee_cap);

    let lp_fee_cap_id = object::id(&lp_fee_cap);
    let custodian = custodian_type<Custodian>();
    lp_fee_cap.destroy_lp_fee_cap();
    *self = LpFeeAuthority::Custodian(custodian);

    (lp_fee_cap_id, custodian)
}

/// Mints a replacement capability under creator-admin authority and retires any live one.
///
/// Pending fees of a launch whose creator fees are custodied belong to that custodian, which
/// binds them with `lock_pending`; no administrator may redirect them first.
public(package) fun reissue<Meme, Quote>(
    self: &mut LpFeeAuthority<Meme>,
    launch: &Launch<Meme, Quote>,
    admin_witness: &AdminWitness<LAUNCHPAD_DOMAIN>,
    ctx: &mut TxContext,
): (Option<ID>, LpFeeCap<Meme>) {
    self.assert_not_locked();
    assert!(!self.is_pending() || !launch.has_fee_custodian(), ELpFeesReservedForCustodian);
    admin_witness.assert_role(launchpad_domain::creator_admin_role());

    let revoked_lp_fee_cap_id = self.cap_id();
    let lp_fee_cap = LpFeeCap { id: object::new(ctx) };
    *self = LpFeeAuthority::Cap(object::id(&lp_fee_cap));

    (revoked_lp_fee_cap_id, lp_fee_cap)
}

/// Aborts once fees are permanently bound to a custodian.
public(package) fun assert_not_locked<Meme>(self: &LpFeeAuthority<Meme>) {
    assert!(self.custodian().is_none(), ELpFeesLocked);
}

/// Aborts unless `lp_fee_cap` is the live capability.
public(package) fun assert_cap<Meme>(self: &LpFeeAuthority<Meme>, lp_fee_cap: &LpFeeCap<Meme>) {
    assert!(self.cap_id().contains(&object::id(lp_fee_cap)), ELpFeeCapNotLive);
}

/// Aborts unless `Custodian` is the witness fees are bound to.
public(package) fun assert_custodian<Meme, Custodian: drop>(
    self: &LpFeeAuthority<Meme>,
    _: Custodian,
) {
    assert!(
        self.custodian().contains(&type_name::with_original_ids<Custodian>()),
        ELpFeeCustodianMismatch,
    );
}

// === Private Functions ===

fun assert_pending<Meme>(self: &LpFeeAuthority<Meme>) {
    assert!(self.is_pending(), ELpFeeAuthorityNotPending);
}

/// Names the custodian module, rejecting witnesses anyone could construct.
///
/// Primitives and vectors are constructible by every caller, and so are framework types such as
/// `Option`, `String`, and `VecMap`, so a witness must come from a package outside `0x1` and
/// `0x2`. `lock_pending` needs no such check: it copies the launch's already validated custodian.
fun custodian_type<Custodian>(): TypeName {
    let custodian = type_name::with_original_ids<Custodian>();

    assert!(!custodian.is_primitive(), EInvalidLpFeeCustodian);

    let origin = type_name::original_id<Custodian>();

    assert!(origin != @0x1 && origin != @0x2, EInvalidLpFeeCustodian);

    custodian
}

fun is_pending<Meme>(self: &LpFeeAuthority<Meme>): bool {
    match (self) {
        LpFeeAuthority::Pending => true,
        _ => false,
    }
}

fun cap_id<Meme>(self: &LpFeeAuthority<Meme>): Option<ID> {
    match (self) {
        LpFeeAuthority::Cap(lp_fee_cap_id) => option::some(*lp_fee_cap_id),
        _ => option::none(),
    }
}

fun custodian<Meme>(self: &LpFeeAuthority<Meme>): Option<TypeName> {
    match (self) {
        LpFeeAuthority::Custodian(custodian) => option::some(*custodian),
        _ => option::none(),
    }
}

// === Test-Only Functions ===

#[test_only]
/// Creates a pending authority for vault fixtures that do not run a launch migration.
public fun new_for_testing<Meme>(): LpFeeAuthority<Meme> {
    LpFeeAuthority::Pending
}

#[test_only]
/// Records and returns a live capability without launch or administrative authority.
public fun issue_for_testing<Meme>(self: &mut LpFeeAuthority<Meme>, ctx: &mut TxContext): LpFeeCap<Meme> {
    let lp_fee_cap = LpFeeCap { id: object::new(ctx) };
    *self = LpFeeAuthority::Cap(object::id(&lp_fee_cap));
    lp_fee_cap
}

#[test_only]
/// Creates a capability that no vault honors.
public fun new_lp_fee_cap_for_testing<Meme>(ctx: &mut TxContext): LpFeeCap<Meme> {
    LpFeeCap { id: object::new(ctx) }
}

#[test_only]
public fun cap_id_for_testing<Meme>(self: &LpFeeAuthority<Meme>): Option<ID> {
    self.cap_id()
}

#[test_only]
public fun custodian_for_testing<Meme>(self: &LpFeeAuthority<Meme>): Option<TypeName> {
    self.custodian()
}

#[test_only]
public fun is_pending_for_testing<Meme>(self: &LpFeeAuthority<Meme>): bool {
    self.is_pending()
}
