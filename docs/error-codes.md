# Blast Fun Sui error codes

This file is the canonical map from a raw Sui Move abort code to its package
macro, raising module, and stable meaning. Keep it synchronized with
[`sui/launchpad/sources/lib/errors.move`](../sui/launchpad/sources/lib/errors.move)
whenever a code is added.

## Strategy

Package-wide protocol errors use zero-argument
`macro public(package) fun name(): u64` definitions. The macro inlines the
number into the module that owns the invariant, and that module performs the
`assert!` at the check site. `errors.move` contains no assertions or guard
wrappers.

Named `EPascalCase` copies are `#[test_only]`. They document the registry for
source tooling without adding production constants or public ABI. Negative Move
tests use literal numbers in `#[expected_failure]`, because attribute arguments
cannot call a macro, and always pin `location = blast_fun::<raising module>` so
an unrelated abort with the same number cannot satisfy the expectation.
Frontends, SDKs, indexers, and bots should generate or
maintain their mapping from this table and the pinned source, not infer meaning
from a transaction's calling function alone.

Codes are append-only. A retired code remains reserved forever; new codes take
the next unused value and must not fill a retired gap.

## Package error registry

| Code | Macro | Raised from | Meaning |
| ---: | --- | --- | --- |
| 0 | `invalid_admin_cap` | `acl` | The supplied `AdminCap` is not active in the singleton protocol authority. |
| 1 | *(retired)* | — | Mutable chain-id validation removed by ADR 0015. |
| 2 | `invalid_x_claim_public_key` | `runtime_config` | The X claim signer public key is not 32 bytes. |
| 3 | `x_claim_signer_inactive` | `runtime_config` | X claims are disabled because no signer public key is configured. |
| 4 | *(retired)* | — | First-config state removed by ADR 0015. |
| 5 | *(retired)* | — | Signer-generation state removed by ADR 0015. |
| 6 | `invalid_x_claim_signature` | `runtime_config` | Ed25519 verification failed for the canonical claim bytes. |
| 7 | *(retired)* | — | First-config state removed by ADR 0015. |
| 8 | *(retired)* | — | Signer-generation state removed by ADR 0015. |
| 9 | `invalid_creator` | `creator_authority` | An address creator identity targeted the zero address. |
| 10 | `invalid_x_identity_hash` | `creator_authority` | The X identity commitment is not exactly 32 bytes. |
| 11 | `unexpected_x_claim_attestation` | `creator_authority` | An address creator claim included an X attestation. |
| 12 | *(retired)* | — | Claimed-state boolean removed by ADR 0019; consuming `CreatorAuthority` now makes repeat claims unrepresentable. |
| 13 | *(retired)* | — | The X claimant is now always `TxContext::sender`. |
| 14 | `x_claim_expired` | `creator_authority` | The X claim attestation expired. |
| 15 | `invalid_super_admin_cap` | `acl` | The supplied `SuperAdminCap` is no longer the active root capability. |
| 16 | `invalid_admin_recipient` | `acl` | A routine administrator targeted the zero address. |
| 17 | `admin_capacity_reached` | `acl` | The bounded active-admin registry is full. |
| 18 | `invalid_super_admin_recipient` | `acl` | A root transfer targeted zero or the current sender. |
| 19 | `no_pending_super_admin_transfer` | `acl` | No pending root transfer exists. |
| 20 | `not_pending_super_admin_recipient` | `acl` | The sender is not the proposed root recipient. |
| 21 | `super_admin_transfer_not_ready` | `acl` | The seven-day root-transfer delay has not elapsed. |
| 22 | `super_admin_transfer_time_overflow` | `acl` | The root-transfer ready timestamp would overflow `u64`. |
| 23 | `super_admin_cap_still_active` | `acl` | The currently active root capability cannot be destroyed. |
| 24 | `x_claim_signer_unchanged` | `runtime_config` | Signer rotation supplied the current public key. |
| 25 | `missing_x_claim_attestation` | `creator_authority` | An X creator claim omitted its required attestation. |
| 26 | `creator_not_sender` | `creator_authority` | The sender is not the address creator recorded at launch. |
| 27 | `invalid_x_claim_attestation` | `creator_authority` | X claim call data is not canonical BCS `(u64, vector<u8>)` containing a 64-byte signature. |
| 28 | `super_admin_transfer_unchanged` | `acl` | A root-transfer proposal targeted the already pending recipient. |
| 29 | `invalid_curve_reserve` | `curve` | Meme inventory or virtual quote reserve is zero. |
| 30 | `invalid_terminal_threshold` | `curve` | The real-quote terminal threshold is zero. |
| 31 | `invalid_quote_fee_bps` | `launch_config` | The cold quote-asset trade fee exceeds 1,000 basis points. |
| 32 | *(retired)* | — | Sell-burn range validation is owned by the shared `Bps` constructor under code 75. |
| 33 | `zero_trade_input` | `curve` | The requested buy or sell input is zero. |
| 34 | `zero_trade_output` | `curve` | The effective meme input or user quote/meme output becomes zero after rounding, burn, or fee. |
| 35 | `curve_reserve_overflow` | `curve` | A post-trade meme or real-quote reserve cannot be represented as `u64`. |
| 36 | `sell_back_invariant_violated` | `curve` | The full sell quote exceeds the real quote held by the curve; the result is rejected rather than clamped. |
| 37 | `invalid_meme_fee_bps` | `launch_config` | The cold meme-asset trade fee exceeds 1,000 basis points. |
| 38 | `nothing_accrued` | `fees` | Neither asset has an accrued balance for the presented creator or protocol claim authority. |
| 39 | `zero_fee_accrual` | `fees` | A fee accrual supplied zero meme and zero quote balances. |
| 40 | *(retired)* | — | Protocol-share range validation is owned by the shared `Bps` constructor under code 75. |
| 41 | `protocol_fee_share_unchanged` | `runtime_config` | A protocol fee-share update supplied the currently active value. |
| 42 | `invalid_migration_quote_target` | `launch_config` | A quote migration target was zero. |
| 43 | *(retired)* | — | Reserved after `allow_quote` absorbed quote-target updates. |
| 44 | *(retired)* | — | Quote admission moved to a Table without a protocol cardinality cap. |
| 45 | `quote_not_allowed` | `launch_config` | The quote type is not admitted for new launches. |
| 46 | *(retired)* | — | Quote updates now compare the complete virtual/terminal pair under code 65. |
| 47 | `invalid_quote_migration_fee_bps` | `launch_config` | The Quote migration-fee rate exceeds 500 basis points. |
| 48 | `invalid_protocol_meme_graduation_fee_bps` | `launch_config`, `launch` | The Protocol Meme graduation fee rate exceeds 1,000 basis points. |
| 49 | `graduation_defaults_unchanged` | `launch_config` | A graduation-default update supplied the complete active triple. |
| 50 | `migration_witness_already_allowed` | `launch_config` | The migration witness type is already admitted for future launches. |
| 51 | `migration_witness_capacity_reached` | `launch_config` | The bounded migration-witness whitelist is full. |
| 52 | `migration_witness_not_allowed` | `launch_config` | The migration witness type is not admitted for future launches. |
| 53 | `invalid_upgrade_cap` | `package_admin` | The supplied `UpgradeCap` does not authorize the original Blast package. |
| 54 | `invalid_package_digest` | `package_admin` | The Sui package digest is not exactly 32 bytes. |
| 55 | *(retired)* | — | Premature governance cutover removed by ADR 0034. |
| 56 | `invalid_package_publisher` | `package_admin` | The supplied `Publisher` was not claimed by Blast's canonical package module. |
| 57 | `upgrade_policy_not_more_restrictive` | `package_admin` | The requested UpgradeCap policy is equal to or looser than the current policy. |
| 58 | *(retired)* | — | Premature governance cutover removed by ADR 0034. |
| 59 | `invalid_meme_liquidity_provision_bps` | `launch_config`, `launch` | The destination-pool Meme provision rate is zero or exceeds 9,999 basis points. |
| 60 | `invalid_meme_supply_partition_bps` | `launch_config`, `launch` | Protocol Meme graduation fee plus pool provision leaves no positive rate for curve inventory. |
| 61 | *(retired)* | — | Caller-configurable Meme decimals removed by ADR 0036; generated currencies always use nine decimals. |
| 62 | `zero_meme_liquidity_provision` | `launch` | A positive destination-pool provision rate rounded to zero Meme atomic units. |
| 63 | `zero_meme_curve_inventory` | `launch` | Rounded protocol Meme graduation fee and pool provision consumed the complete initial Meme balance. |
| 64 | `invalid_virtual_quote` | `launch_config` | A Quote policy supplied a zero virtual Quote reserve. |
| 65 | `quote_parameters_unchanged` | `launch_config` | A Quote-policy update supplied the complete active virtual/terminal parameter pair. |
| 66 | `creator_authority_unavailable` | `launch` | The launch no longer contains its one-time creator authority and native metadata capability. |
| 67 | `trade_fee_defaults_unchanged` | `launch_config` | A trade-fee update supplied the complete active Quote/Meme rate pair. |
| 68 | `package_version_mismatch` | `package_version` | The shared package cutover rejects this bytecode generation or a nonconsecutive activation. |
| 69 | *(retired)* | — | Redundant per-Launch version removed by ADR 0045. |
| 70 | `invalid_launch_lifecycle` | `launch` | The launch lifecycle does not permit the requested trade or migration. |
| 71 | `slippage_exceeded` | `launch` | The exact returned trade output is below the caller's minimum. |
| 72 | `invalid_migration_witness` | `launch` | The requested migrator witness type was not selected by the launch. |
| 73 | *(retired)* | — | The sealed `LaunchTicket` constructor makes an unknown Meme supply mode unreachable. |
| 74 | `package_version_overflow` | `package_version` | The shared package-version counter cannot advance beyond `u64`. |
| 75 | `invalid_bps` | `bps` | A basis-points value exceeds the inclusive 0 through 10,000 range. |
| 76 | `invalid_meme_quote_pair` | `launch` | A launch selected the generated Meme type as its own Quote type. |
| 77 | `invalid_initial_meme_supply` | `launch` | A launch ticket did not contain the canonical generated Meme supply. |
| 78 | `invalid_migration_witness_type` | `launch_config` | A migration witness was a primitive or vector type instead of an adapter-defined struct. |
| 79 | *(moved)* | — | Seed-balance validation moved to `blast_fun_migrators::migration_math` under ADR 0069; this launchpad code remains reserved. |
| 80 | *(moved)* | — | Price-deviation validation moved to `blast_fun_migrators::migration_math` under ADR 0069; this launchpad code remains reserved. |
| 81 | *(moved)* | — | Residual validation moved to `blast_fun_migrators::migration_math` under ADR 0069; this launchpad code remains reserved. |

The next new package-wide protocol error must use code **82**.

## Other Sui packages

Sui scopes an abort code to the package that raised it, so each independently
deployed Blast package keeps its own append-only registry with an independent
numeric space:

| Package | Registry | Codes in use |
| --- | --- | ---: |
| `blast_fun_migrators` | [`sui/migrators/README.md`](../sui/migrators/README.md#migration-math-errors) | Module-local registries; migration math uses 0 through 3 |
| `blast_leverage_series_one` | [`sui/leverage_coins/series_one/README.md`](../sui/leverage_coins/series_one/README.md) | 0–37, 40–61, 64, and 74; retired gaps remain reserved |
| `blast_leverage_aftermath` | [`sui/leverage_coins/aftermath_adapter/README.md`](../sui/leverage_coins/aftermath_adapter/README.md) | 0 through 10 |

A frontend, SDK, or indexer must map an abort by package and raising module
first, then by code.
