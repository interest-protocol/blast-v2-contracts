# Admin and signer authority patterns

Status: supporting research; ADRs 0015 and 0017 are the accepted decisions
Reviewed: 2026-08-22

## Recommendation

Blast should use Sui capability objects, not EVM-style stored owner addresses:

- one protocol-wide `SuperAdminCap`, backed by a singleton shared authority registry;
- revocable `AdminCap` objects for routine protocol operations, optionally assigned narrow roles;
- a delayed, cancellable, two-step super-admin transfer that the proposed recipient must accept;
- no `config_id` in a global admin cap;
- one signer-public-key field for X claims, with the empty value meaning claims are disabled;
- no `signer_active` boolean;
- no `signer_key_id` in the first implementation if every rotation must install a different public key and retired keys can never be reused;
- no stored or signed Blast `package_id`; bind the claim to the generated coin's original `TypeName` instead;
- no stored `chain_id` when the signing key is dedicated to one Blast deployment. If the same backend key will be reused across Sui networks, a network discriminator remains necessary because Move cannot obtain one from `TxContext`.

This is deliberately a capability interpretation of OpenZeppelin's safety rules, not a Solidity ownership port.

## Current fields

| Field | What it currently does | Recommendation |
| --- | --- | --- |
| `XClaimConfig.package_id` | Separates otherwise identical signatures issued for different verifier deployments. Sui does **not** automatically add the called package to the bytes checked by `ed25519_verify`. | Remove it from config and the signed message. A dedicated signer key scopes official issuance to this deployment, while the generated coin's original `TypeName` scopes the economic authority. |
| `XClaimConfig.chain_id` | Prevents a signature from being accepted by a verifier using the same key and message state on another network. | Remove it under a strict one-key-per-deployment policy. Keep an immutable network domain only if the same key may be used on more than one network; unlike EVM's `block.chainid`, Sui Move's `TxContext` exposes no chain identifier. |
| `XClaimConfig.signer_public_key` | Defines the only backend authorized to attest an authenticated X claim. | Keep as `vector<u8>` and require exactly 32 bytes while configured. |
| `XClaimConfig.signer_key_id` | It is a signer **generation**, not a key lookup: matching the current value invalidates outstanding signatures after every rotation, including a later return to the same public key. | Remove for the first implementation if rotation must change the public key and a retired key can never be restored. Verification against the current public key already rejects signatures made by the previous key. If key reuse or overlapping keys are ever required, retain this concept but call it `signer_generation` or `revocation_nonce` so its purpose is explicit. |
| `XClaimConfig.signer_active` | Allows immediate revocation without deleting the stored public key. | Remove. Represent the state once: empty key (or `Option<vector<u8>>`) means disabled, and a 32-byte key means enabled. On revoke, clear the key. This avoids contradictory key/boolean states. |
| `AdminCap.config_id` | Prevents a cap issued for one `XClaimConfig` from managing another one. | Remove if, as agreed, the cap governs the whole Blast protocol and production creates one authority/configuration set. Target IDs are appropriate for per-instance caps, not a singleton package authority. |

The minimal X attestation contains only the original meme `TypeName`, X identity
commitment, claimant, and expiry. The fixed Move message type and dedicated
backend key already identify the action; the payload therefore carries no
schema version, action tag, launch id, or Blast package id. This is accepted in
ADR 0017.

## What Memez Fun actually does

The pinned Memez Fun commit is [`00596fd`](https://github.com/interest-protocol/memez-gg/tree/00596fdac4dd11f427c7bc594e566ce36160db93). Its checked-in [`fun/Move.lock`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/Move.lock) resolves `InterestAccessControl` to commit [`91e2f4f`](https://github.com/interest-protocol/interest-mvr/tree/91e2f4f83626c1cb924bac246932574501c21bf8/access-control/contracts), so that dependency is part of the pinned review.

### Singleton and capabilities

[`memez::memez`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/memez/sources/memez.move) consumes the `MEMEZ` one-time witness to create one shared `ACL<MEMEZ>` and one owned `SuperAdmin<MEMEZ>`. The production transfer delay is seven epochs.

The access-control implementation is in [`access_control.move`](https://github.com/interest-protocol/interest-mvr/blob/91e2f4f83626c1cb924bac246932574501c21bf8/access-control/contracts/sources/access_control.move):

- `SuperAdmin<T>` is the root capability.
- `Admin<T>` is an owned, transferable delegated capability containing only its `UID`; it has no configuration ID.
- `ACL<T>` registers each admin by the admin object's ID-address and stores a `u128` role bitmap.
- The super-admin creates admins, grants/removes roles, and revokes admins from the registry.
- `sign_in` checks current registry membership and returns a drop-only `AdminWitness<T>` containing the role bitmap.
- Memez configuration setters borrow `&AdminWitness<MEMEZ>` and do not bind an admin to each configuration object; see [`config.move`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/config.move).

The reason this is safe without config IDs is the singleton `ACL<MEMEZ>` established by the one-time witness. The phantom protocol marker provides the authority domain.

### Memez super-admin transfer

Memez stores `new_admin`, `start`, and `delay` in `SuperAdmin<T>`. The current holder starts a transfer; after the epoch delay, the current holder consumes the cap and sends it to the stored recipient. Starting again replaces the pending recipient.

This is delayed rotation, but it is **not** a full two-step acceptance policy: the recipient never calls an acceptance function, there is no explicit cancellation function/event, and the current holder completes the transfer. Blast should take Memez's singleton root/delegated-admin split, but improve the transfer flow with explicit recipient acceptance and cancellation.

Memez also keeps ACL diagnostics separate in [`events.move`](https://github.com/interest-protocol/interest-mvr/blob/91e2f4f83626c1cb924bac246932574501c21bf8/access-control/contracts/sources/events.move) and [`errors.move`](https://github.com/interest-protocol/interest-mvr/blob/91e2f4f83626c1cb924bac246932574501c21bf8/access-control/contracts/sources/errors.move).

## OpenZeppelin comparison

The current stable OpenZeppelin source reviewed is [Contracts v5.7.0, commit `cab1993`](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/cab19933c33c2ad1d4c7a84864a3601dddfd16f3).

- [`Ownable2Step`](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.7.0/contracts/access/Ownable2Step.sol) records a pending owner and requires that address to call `acceptOwnership`. The current owner can replace the proposal or cancel it by proposing the zero address.
- [`AccessControl`](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.7.0/contracts/access/AccessControl.sol) separates operational roles from the role authorized to grant and revoke them.
- [`AccessControlDefaultAdminRules`](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.7.0/contracts/access/extensions/AccessControlDefaultAdminRules.sol) restricts the default admin to one account, requires a two-step transfer, enforces a delay, allows cancellation, requires explicit acceptance, and stages delay changes so shortening a delay cannot bypass the current protection.
- OpenZeppelin's [official access-control guide](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.7.0/docs/modules/ROOT/pages/access-control.adoc) recommends `AccessControlDefaultAdminRules` because the default admin can manage all roles and therefore carries exceptional risk.

For Blast, `AccessControlDefaultAdminRules` is the better behavioral reference than plain `Ownable2Step`: it combines a single root, roles, delay, cancellation, and acceptance.

EVM ownership stores an address and checks `msg.sender` because that is the EVM authority model. In Sui, the equivalent root should be an owned capability object whose ID is recognized by shared authority state. Routine authority should be separate revocable admin capabilities.

## Sui translation

Official framework source demonstrates when an embedded target ID is and is not necessary:

- [`TreasuryCap<T>`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/coin.move) is unique and type-bound, so it needs no separate coin/config ID.
- [`TokenPolicyCap<T>`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/token.move) and [`TransferPolicyCap<T>`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/kiosk/transfer_policy.move) contain a policy ID because multiple policy instances can exist for one type and the cap manages one of them.
- [`UpgradeCap`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/package.move) contains a package ID because it is non-generic and different instances manage different packages.

That supports a simple rule: embed a target ID only when several same-typed target instances can exist. A singleton, package-wide Blast authority should not carry `config_id`.

Sui's [`type_name::with_original_ids<T>()`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/move-stdlib/sources/type_name.move) returns a canonical fully qualified type name whose package components use original IDs across upgrades. ADR 0017 uses that value for the unique meme coin domain instead of signing a separate Blast package field.

Sui clients expose a chain identifier off chain through the [official Core API](https://sdk.mystenlabs.com/sui/clients/core), but the on-chain [`TxContext`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/tx_context.move) exposes sender, transaction digest, epoch, timestamps, and gas data—not a chain identifier. A Move verifier cannot simply read the network ID from Sui.

### Proposed authority state

A Sui-native design can use:

```move
public struct ProtocolAuthority has key {
    id: UID,
    super_admin_cap_id: ID,
    admins: VecSet<ID>,
    pending_super_admin: Option<PendingSuperAdmin>,
}

public struct SuperAdminCap has key { id: UID }
public struct AdminCap has key, store { id: UID }
public struct AdminWitness() has drop
```

The super-admin cap manages only root functions: creating/revoking admins and
beginning/cancelling root transfer. The first implementation has one bounded
routine-admin class; narrower roles can be added only when the operation matrix
requires them. `sign_in` checks a registered `AdminCap` directly against the
singleton registry and returns the drop-only witness. Routine feature functions
borrow that witness and therefore do not need either ACL storage or the cap in
their own interfaces.

For root rotation:

1. The current registered `SuperAdminCap` proposes a non-zero recipient and a `ready_at_ms` value.
2. The current super-admin can cancel or replace the proposal before acceptance.
3. After the delay, only the proposed recipient can accept, verified with `tx_context::sender`.
4. Acceptance creates/transfers a new root cap and updates `super_admin_cap_id`; that registry update immediately invalidates the old cap.
5. Every root operation checks that the supplied cap ID equals the registry's current root ID.

The registry check in step 5 is necessary because the accepting recipient cannot consume an owned cap still held by the previous administrator. Updating the recognized ID is the Sui equivalent of replacing OpenZeppelin's stored owner.

For delegated admins, Blast adopts the Memez/SU sign-in boundary. `acl::sign_in`
checks current registry membership and creates a unit `AdminWitness` whose only
ability is `drop`; there is no role bitmap to snapshot because Blast currently
has one protocol-wide routine-admin role. The witness cannot cross transaction
boundaries, although the same borrowed witness may authorize several ordered
commands in one atomic programmable transaction. Revocation prevents every
future sign-in.

ADR 0018 applies that rule through separate state-owning modules. `acl.move`
owns live membership and witness construction. `x_claim_config.move` owns the
shared backend key and accepts only `&AdminWitness` for signer
rotation/revocation. `creator_authority.move` owns the signed X message and the
one-time `CreatorCap<Meme>` issuance transition. Future fee withdrawal consumes
the typed creator capability and does not depend on ACL or the backend key again.

Do not expose irreversible super-admin destruction/renunciation in the first release. It can permanently disable recovery and role administration. If later required for decentralization, make it an explicit delayed operation with its own event and tests.

## Signer rotation policy

Recommended first-release invariants:

1. The signer key is either empty or exactly 32 bytes.
2. Empty means X claims are disabled.
3. Initial configuration and every rotation require a non-empty key different from the currently configured key.
4. Revocation clears the key.
5. A retired key may never be reused.
6. The backend key is dedicated to Blast X-claim attestations for one deployment.
7. Attestations have a short expiry and remain one-time at the launch assignment level.

Under those rules, neither `signer_active` nor `signer_key_id` adds authorization power. If rule 5 or 6 changes, add an explicit signed `signer_generation`/`revocation_nonce` or deployment/network domain before allowing the change.

EIP-712 explains why the earlier design included chain and verifier fields: its optional domain contains `chainId` and `verifyingContract` to separate otherwise identical signed structures; see the [primary specification](https://eips.ethereum.org/EIPS/eip-712). That is a useful threat-model concept, but it does not require copying those values into mutable Sui config when a dedicated key and derivable package identity already provide the desired scope.
