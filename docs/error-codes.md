# Blast Fun Sui error codes

This file is the canonical map from a raw Sui Move abort code to its package
macro, raising module, and stable meaning. Keep it synchronized with
[`sui/sources/errors.move`](../sui/sources/errors.move) whenever a code is added.

## Strategy

Package-wide protocol errors use zero-argument
`macro public(package) fun name(): u64` definitions. The macro inlines the
number into the module that owns the invariant, and that module performs the
`assert!` at the check site. `errors.move` contains no assertions or guard
wrappers.

Named `EPascalCase` copies are `#[test_only]`. They document the registry for
source tooling without adding production constants or public ABI. Negative Move
tests use literal numbers in `#[expected_failure]`, because attribute arguments
cannot call a macro. Frontends, SDKs, indexers, and bots should generate or
maintain their mapping from this table and the pinned source, not infer meaning
from a transaction's calling function alone.

Codes are append-only. A retired code remains reserved forever; new codes take
the next unused value and must not fill a retired gap.

## Package error registry

| Code | Macro | Raised from | Meaning |
| ---: | --- | --- | --- |
| 0 | `invalid_admin_cap` | `acl` | The supplied `AdminCap` is not active in the singleton protocol authority. |
| 1 | *(retired)* | — | Mutable chain-id validation removed by ADR 0015. |
| 2 | `invalid_x_claim_public_key` | `x_claim_config` | The X claim signer public key is not 32 bytes. |
| 3 | `x_claim_signer_inactive` | `x_claim_config` | X claims are disabled because no signer public key is configured. |
| 4 | *(retired)* | — | First-config state removed by ADR 0015. |
| 5 | *(retired)* | — | Signer-generation state removed by ADR 0015. |
| 6 | `invalid_x_claim_signature` | `x_claim_config` | Ed25519 verification failed for the canonical claim bytes. |
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
| 24 | `x_claim_signer_unchanged` | `x_claim_config` | Signer rotation supplied the current public key. |
| 25 | `missing_x_claim_attestation` | `creator_authority` | An X creator claim omitted its required attestation. |
| 26 | `creator_not_sender` | `creator_authority` | The sender is not the address creator recorded at launch. |
| 27 | `invalid_x_claim_attestation` | `creator_authority` | X claim call data is not canonical BCS `(u64, vector<u8>)` containing a 64-byte signature. |
| 28 | `super_admin_transfer_unchanged` | `acl` | A root-transfer proposal targeted the already pending recipient. |
| 29 | `invalid_curve_reserve` | `curve` | Meme inventory or virtual quote reserve is zero. |
| 30 | `invalid_terminal_threshold` | `curve` | The real-quote terminal threshold is zero. |
| 31 | `invalid_quote_fee_bps` | `curve` | The quote-asset fee exceeds 10,000 basis points. |
| 32 | `invalid_max_burn_bps` | `curve` | The sell-side maximum burn exceeds 10,000 basis points. |
| 33 | `zero_trade_input` | `curve` | The requested buy or sell input is zero. |
| 34 | `zero_trade_output` | `curve` | The effective meme input or user quote/meme output becomes zero after rounding, burn, or fee. |
| 35 | `curve_reserve_overflow` | `curve` | A post-trade meme or real-quote reserve cannot be represented as `u64`. |
| 36 | `sell_back_invariant_violated` | `curve` | The full sell quote exceeds the real quote held by the curve; the result is rejected rather than clamped. |
| 37 | `invalid_meme_fee_bps` | `curve` | The meme-asset fee exceeds 10,000 basis points. |

The next new package-wide protocol error must use code **38**.
