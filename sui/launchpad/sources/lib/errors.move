#[allow(unused_const)]
module blast_fun::errors;

// === Errors ===

// Append-only package error registry. Never reuse a retired numeric code.
// These names exist only in test builds and source tooling; production callers use the
// package macros below so the numeric code is inlined at the owning assertion.

// Code 0 retired: administrator membership moved to `blast_admin::acl`.

// Code 1 retired: mutable chain-id validation was removed by ADR 0015.

#[test_only]
/// The X claim signer public key is not 32 bytes.
const EInvalidXClaimPublicKey: u64 = 2;

#[test_only]
/// X claims are disabled because no signer public key is configured.
const EXClaimSignerInactive: u64 = 3;

// Codes 4 and 5 retired with first-config and signer-generation state.

#[test_only]
/// The Ed25519 signature does not verify against the canonical claim bytes.
const EInvalidXClaimSignature: u64 = 6;

// Codes 7 and 8 retired with first-config and signer-generation state.

#[test_only]
/// An address creator identity cannot target the zero address.
const EInvalidCreator: u64 = 9;

#[test_only]
/// An X identity commitment must be exactly 32 bytes.
const EInvalidXIdentityHash: u64 = 10;

#[test_only]
/// An address creator claim included an X attestation.
const EUnexpectedXClaimAttestation: u64 = 11;

// Code 12 retired: consuming CreatorAuthority makes a repeat claim unrepresentable.

// Code 13 retired: the X claimant is now always TxContext::sender.

#[test_only]
/// The X claim attestation has expired.
const EXClaimExpired: u64 = 14;

// Codes 15 through 23 retired: the root-capability lifecycle moved to
// `blast_admin::acl`, which owns its own append-only error registry.

#[test_only]
/// Signer rotation must provide a key different from the current key.
const EXClaimSignerUnchanged: u64 = 24;

#[test_only]
/// An X creator claim did not include its required attestation.
const EMissingXClaimAttestation: u64 = 25;

#[test_only]
/// The transaction sender is not the address creator recorded by the launch.
const ECreatorNotSender: u64 = 26;

#[test_only]
/// X claim call data is not canonical BCS `(u64, vector<u8>)` for a 64-byte signature.
const EInvalidXClaimAttestation: u64 = 27;

// Code 28 retired with the rest of the root-transfer lifecycle.

#[test_only]
/// Meme inventory or virtual quote reserve cannot represent a valid constant-product market.
const EInvalidCurveReserve: u64 = 29;

// Code 30 retired: quote admission owns the minimum migration target.

#[test_only]
/// The quote-asset launch fee exceeds ten percent.
const EInvalidQuoteFeeBps: u64 = 31;

// Code 32 retired: the shared `Bps` constructor owns the inclusive range invariant.

#[test_only]
/// A curve quote requires a nonzero trade input.
const EZeroTradeInput: u64 = 33;

#[test_only]
/// Rounding or fees reduced the user's quoted output to zero.
const EZeroTradeOutput: u64 = 34;

#[test_only]
/// A post-trade curve reserve cannot be represented as u64.
const ECurveReserveOverflow: u64 = 35;

#[test_only]
/// A sell quote requested more real quote than the curve holds.
const ESellBackInvariantViolated: u64 = 36;

#[test_only]
/// The meme-asset launch fee exceeds ten percent.
const EInvalidMemeFeeBps: u64 = 37;

#[test_only]
/// Neither asset has an accrued balance for the presented claim authority.
const ENothingAccrued: u64 = 38;

#[test_only]
/// A fee accrual cannot contain zero meme and zero quote simultaneously.
const EZeroFeeAccrual: u64 = 39;

// Code 40 retired: the shared `Bps` constructor owns the inclusive range invariant.

#[test_only]
/// A protocol-share update supplied the currently active value.
const EProtocolFeeShareUnchanged: u64 = 41;

#[test_only]
/// A quote migration target must contain at least two atomic units.
const EInvalidMigrationQuoteTarget: u64 = 42;

// Code 43 retired: `allow_quote` absorbed quote-target updates as an upsert.

// Code 44 retired: Table-backed quote admission has no protocol cardinality cap.

#[test_only]
/// The quote type is not admitted for new launches.
const EQuoteNotAllowed: u64 = 45;

// Code 46 retired: Quote updates now compare the complete virtual/terminal pair.

#[test_only]
/// The graduation share of gross terminal Quote exceeds five percent.
const EInvalidQuoteMigrationFeeBps: u64 = 47;

#[test_only]
/// The graduation share of initial Meme supply exceeds ten percent.
const EInvalidProtocolMemeGraduationFeeBps: u64 = 48;

#[test_only]
/// A graduation-default update supplied the complete active triple.
const EGraduationDefaultsUnchanged: u64 = 49;

#[test_only]
/// The migration witness type is already admitted for future launches.
const EMigrationWitnessAlreadyAllowed: u64 = 50;

#[test_only]
/// The bounded migration-witness whitelist is full.
const EMigrationWitnessCapacityReached: u64 = 51;

#[test_only]
/// The migration witness type is not admitted for future launches.
const EMigrationWitnessNotAllowed: u64 = 52;

// Codes 53 and 54 retired: native capability intake and digest validation moved
// to `blast_admin::upgrade_custody`.

// Code 55 retired: the premature governance cutover was removed by ADR 0034.

#[test_only]
/// The supplied Publisher was not claimed by Blast's canonical package module.
const EInvalidPackagePublisher: u64 = 56;

// Code 57 retired: policy narrowing moved to `blast_admin::upgrade_custody`.

// Code 58 retired: the premature governance cutover was removed by ADR 0034.

#[test_only]
/// Destination-pool Meme provision must be between one and 9,999 basis points.
const EInvalidMemeLiquidityProvisionBps: u64 = 59;

#[test_only]
/// Protocol Meme graduation fee plus pool provision leaves no positive curve share.
const EInvalidMemeSupplyPartitionBps: u64 = 60;

// Code 61 retired: caller-configurable Meme decimals were removed by ADR 0036.

// Codes 62 and 63 retired: configured partition bounds plus canonical supply
// guarantee positive provision and curve inventory.

#[test_only]
/// A Quote policy's virtual reserve must be nonzero.
const EInvalidVirtualQuote: u64 = 64;

#[test_only]
/// A Quote policy update supplied the complete active parameter pair.
const EQuoteParametersUnchanged: u64 = 65;

#[test_only]
/// The launch no longer contains its one-time creator authority and metadata capability.
const ECreatorAuthorityUnavailable: u64 = 66;

#[test_only]
/// A trade-fee update supplied the complete active rate pair.
const ETradeFeeDefaultsUnchanged: u64 = 67;

// Code 68 retired: generation comparison moved to
// `blast_admin::operational_version`.

// Code 69 retired: the redundant per-Launch version was removed by ADR 0045.

#[test_only]
/// The launch lifecycle does not permit the requested operation.
const EInvalidLaunchLifecycle: u64 = 70;

#[test_only]
/// The returned user amount is below the caller's minimum.
const ESlippageExceeded: u64 = 71;

#[test_only]
/// The requested migration witness type is not the launch-selected type.
const EInvalidMigrationWitness: u64 = 72;

// Code 73 retired: LaunchTicket construction makes an unknown supply mode unreachable.

// Code 74 retired: generation arithmetic moved to
// `blast_admin::operational_version`.

#[test_only]
/// A basis-points value exceeds one hundred percent.
const EInvalidBps: u64 = 75;

#[test_only]
/// A launch cannot use the generated Meme type as its own Quote type.
const EInvalidMemeQuotePair: u64 = 76;

#[test_only]
/// A launch ticket does not contain the canonical generated Meme supply.
const EInvalidInitialMemeSupply: u64 = 77;

#[test_only]
/// A migration witness must be a non-primitive adapter-defined struct type.
const EInvalidMigrationWitnessType: u64 = 78;

// Codes 79 through 81 moved with migration arithmetic to blast_fun_migrators by ADR 0069.

// Code 82 retired when positive migration principal moved to quote admission.

#[test_only]
/// The creator-selected sell burn exceeds fifty percent.
const EInvalidSellBurnBps: u64 = 83;

#[test_only]
/// A completed trade reduced the curve's constant product.
const EConstantProductInvariantDecreased: u64 = 84;

macro public(package) fun invalid_x_claim_public_key(): u64 {
    2
}

macro public(package) fun x_claim_signer_inactive(): u64 {
    3
}

macro public(package) fun invalid_x_claim_signature(): u64 {
    6
}

macro public(package) fun invalid_creator(): u64 {
    9
}

macro public(package) fun invalid_x_identity_hash(): u64 {
    10
}

macro public(package) fun unexpected_x_claim_attestation(): u64 {
    11
}

macro public(package) fun x_claim_expired(): u64 {
    14
}

macro public(package) fun x_claim_signer_unchanged(): u64 {
    24
}

macro public(package) fun missing_x_claim_attestation(): u64 {
    25
}

macro public(package) fun creator_not_sender(): u64 {
    26
}

macro public(package) fun invalid_x_claim_attestation(): u64 {
    27
}

macro public(package) fun invalid_curve_reserve(): u64 {
    29
}

macro public(package) fun invalid_quote_fee_bps(): u64 {
    31
}

// Error code 32 is retired and must not be reused.

macro public(package) fun zero_trade_input(): u64 {
    33
}

macro public(package) fun zero_trade_output(): u64 {
    34
}

macro public(package) fun curve_reserve_overflow(): u64 {
    35
}

macro public(package) fun sell_back_invariant_violated(): u64 {
    36
}

macro public(package) fun invalid_meme_fee_bps(): u64 {
    37
}

macro public(package) fun nothing_accrued(): u64 {
    38
}

macro public(package) fun zero_fee_accrual(): u64 {
    39
}

// Error code 40 is retired and must not be reused.

macro public(package) fun protocol_fee_share_unchanged(): u64 {
    41
}

macro public(package) fun invalid_migration_quote_target(): u64 {
    42
}

// Error code 43 is retired and must not be reused.

// Error code 44 is retired and must not be reused.

macro public(package) fun quote_not_allowed(): u64 {
    45
}

// Error code 46 is retired and must not be reused.

macro public(package) fun invalid_quote_migration_fee_bps(): u64 {
    47
}

macro public(package) fun invalid_protocol_meme_graduation_fee_bps(): u64 {
    48
}

macro public(package) fun graduation_defaults_unchanged(): u64 {
    49
}

macro public(package) fun migration_witness_already_allowed(): u64 {
    50
}

macro public(package) fun migration_witness_capacity_reached(): u64 {
    51
}

macro public(package) fun migration_witness_not_allowed(): u64 {
    52
}

// Error codes 53, 54 and 55 are retired and must not be reused.

macro public(package) fun invalid_package_publisher(): u64 {
    56
}

// Error codes 57 and 58 are retired and must not be reused.

macro public(package) fun invalid_meme_liquidity_provision_bps(): u64 {
    59
}

macro public(package) fun invalid_meme_supply_partition_bps(): u64 {
    60
}

// Error code 61 is retired and must not be reused.

macro public(package) fun invalid_virtual_quote(): u64 {
    64
}

macro public(package) fun quote_parameters_unchanged(): u64 {
    65
}

macro public(package) fun creator_authority_unavailable(): u64 {
    66
}

macro public(package) fun trade_fee_defaults_unchanged(): u64 {
    67
}

macro public(package) fun invalid_launch_lifecycle(): u64 {
    70
}

macro public(package) fun slippage_exceeded(): u64 {
    71
}

macro public(package) fun invalid_migration_witness(): u64 {
    72
}

macro public(package) fun invalid_bps(): u64 {
    75
}

macro public(package) fun invalid_meme_quote_pair(): u64 {
    76
}

macro public(package) fun invalid_initial_meme_supply(): u64 {
    77
}

macro public(package) fun invalid_migration_witness_type(): u64 {
    78
}

macro public(package) fun invalid_sell_burn_bps(): u64 {
    83
}

macro public(package) fun constant_product_invariant_decreased(): u64 {
    84
}
