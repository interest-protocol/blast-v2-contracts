# SuiNS creator-claim boundary

Status: supporting research; ADR 0016 is the accepted design decision
Reviewed: 2026-08-22

## Recommendation

Treat SuiNS as a **recipient resolver**, not as continuing creator authority.

- Resolve the name to its current target address at launch.
- Record that address as the launch's creator identity and permanently freeze that result for the launch; the matching address later claims `CreatorCap<Meme>` once.
- Do not resolve again when fees are claimed. Later SuiNS transfer, retargeting, expiry, or re-registration must not redirect creator fees.
- If SuiNS is only frontend convenience, use the official client resolver and pass the resulting address to the ordinary address-identity path. The dependency-free Blast core needs no SuiNS code or special claim path.
- For atomic resolution and address recording, put SuiNS in a separate adapter/periphery package. The adapter resolves against the shared SuiNS object and calls the ordinary permissionless core launch function with the concrete address. A sealed resolver witness is needed only if a future core version records or promises SuiNS provenance.
- Do not let the core accept a bare `address` as a privileged “SuiNS proof.” A plain address is fine only when creator nomination is already permissionless and SuiNS is UX sugar.

ADR 0016 chooses an on-chain periphery for the launch slice so name validation and address recording can be atomic, while preserving the same dependency-free address-claim path in core.

## 1. Official on-chain resolution

The official SuiNS package README recommends depending only on the core package and gives the basic lookup pattern in its [on-chain integration example](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/packages/suins/README.md). Blast should use the checked form shown in the official integration guide:

```move
let registry = suins.registry<Registry>();
let domain = domain::new(domain_name);
let mut record = registry.lookup(domain);
assert!(record.is_some(), ENameNotFound);
let record = record.extract();
assert!(!record.has_expired(clock), ENameExpired);
let mut target = record.target_address();
assert!(target.is_some(), ETargetNotSet);
let recipient = target.extract();
```

The underlying calls are visible in the pinned official source:

- [`suins::suins::registry<R>`](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/packages/suins/sources/suins.move) returns a read-only reference to the registry stored under the shared `SuiNS` object.
- [`domain::new`](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/packages/suins/sources/domain.move) parses and validates the supplied dot-form string.
- [`registry::lookup`](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/packages/suins/sources/registry.move) returns `Option<NameRecord>` but does not itself enforce expiry.
- [`NameRecord::has_expired`](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/packages/suins/sources/name_record.move) compares the record expiration timestamp with `Clock`.
- `NameRecord::target_address` returns `Option<address>` because a valid name may have no target.

Therefore an on-chain consumer must check all three conditions: record exists, record is currently valid, and target is present. A raw `lookup` result is not sufficient.

The official [SuiNS integration documentation](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/documentation/site/static/markdown/developer.md) makes these checks in its object-transfer example and cautions on-chain integrations to import the core package only because utility packages may be replaced.

### Subnames

The simple official example is sufficient for ordinary node records, including second-level names. Leaf subnames require extra care:

- [`name_record::new_leaf`](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/packages/suins/sources/name_record.move) stores a sentinel expiration and the parent NFT ID.
- The [official subname documentation](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/documentation/site/static/markdown/developer.md#subnames) states that leaf names have no NFT and derive validity/control from their active parent.
- Registry code verifies parent existence, parent NFT identity, and parent expiry when replacing or managing leaf records. A leaf stores the sentinel expiration `0`, so a generic consumer that only calls `leaf_record.has_expired(clock)` rejects it rather than reproducing that parent-validity rule.

Blast should either restrict its first on-chain adapter to non-leaf names or implement and test parent validation explicitly. Frontend/full-node resolution can rely on the official Sui API resolver for supported names.

## Off-chain resolution

Official Sui clients expose name resolution directly. The current [`@mysten/suins` README](https://github.com/MystenLabs/ts-sdks/blob/03fe26bfefd998203faf7767f3fa107dc484117d/packages/suins/README.md) directs applications to `resolveNameServiceAddress`; the official GraphQL query resolves `address(name: $name) { address }` in [`nameService.graphql`](https://github.com/MystenLabs/ts-sdks/blob/03fe26bfefd998203faf7767f3fa107dc484117d/packages/sui/src/graphql/queries/nameService.graphql).

For Blast's permissionless direct-creator flow, this is enough:

1. The frontend resolves and displays the exact target address.
2. The user confirms the launch transaction with that address.
3. Core records that address as the only permitted claimant.
4. That address later claims the typed creator cap without an X attestation.

This does not prove on chain that the address came from SuiNS, but no proof is needed when the launcher is already permitted to nominate any non-zero creator address. The name is only input assistance.

If a name can retarget between the frontend query and execution, the transaction still records the exact address the user signed. If the product instead promises “the target at execution time,” use the on-chain adapter so resolution and address recording are atomic.

## 2. Separate periphery with a dependency-free core

This package split is technically sound:

```text
SuiNS core package
        ↑ dependency
blast_fun_suins  ─────────→  blast_fun core
                              (no SuiNS dependency)
```

The adapter can accept `&SuiNS`, `String`, and `&Clock`, resolve the current target, and pass only the resolved address into the permissionless core launch function.

Because a Blast launcher may nominate any nonzero creator address, SuiNS
resolution does not grant a privilege and core does not need a witness or
allowlist merely to accept that address. A sealed witness boundary becomes
necessary only if core later records or promises that the address was
cryptographically resolved from SuiNS at execution time.

If a future product requirement makes SuiNS provenance privileged core state,
the security boundary matters because [`public(package)` is callable only from the same package](https://move-book.com/reference/functions/#publicpackage-visibility), so it is unavailable to a separately published adapter. A safe conditional design would be:

1. The adapter defines a zero-field `SuinsResolverWitness` whose constructor is private to the adapter module.
2. Blast's shared authority state allowlists the witness type by `TypeName`.
3. A core function such as `new_external_attestation<W: drop>(authority, W, address)` verifies that `W` is an authorized resolver type and returns the sealed core `CreatorAttestation` value.
4. The adapter supplies its private witness and passes the returned attestation to the single core launch function.
5. Core consumes the attestation and records its embedded address as the launch's one permitted future claimant.

Callers can invoke the adapter, but they cannot fabricate its witness. An arbitrary downstream package cannot get its own witness accepted because core checks the allowlist.

Alternative boundaries are possible, but these are unsafe:

- **Bare address marked as SuiNS-resolved:** forgeable by any caller.
- **Unvalidated generic witness:** any package can declare its own witness type.
- **Public raw-address attestation constructor:** callers can simply call the constructor.
- **An immutable capability object anyone can borrow:** possession no longer proves the adapter performed resolution.

If SuiNS is merely UX resolution, omit all of this machinery and use the address-identity path.

## 3. Transfer, expiry, and retargeting semantics

SuiNS is a mutable pointer rather than an identity-to-address ownership proof:

- [`SuinsRegistration`](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/packages/suins/sources/suins_registration.move) has `key, store`, so the registration NFT is transferable. Its current owner controls updates by supplying the owned NFT.
- [`controller::set_target_address`](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/packages/suins/sources/controller.move) accepts any `Option<address>` after checking that the supplied NFT matches the current record and is not expired.
- [`registry::set_target_address`](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/packages/suins/sources/registry.move) changes the forward target immediately and invalidates an old reverse record when necessary.
- The official integration documentation explicitly says not to use SuiNS NFT ownership as resolution: the NFT is the capability to change the target, and the target may be any address.
- Normal records are invalid for authorization once the current time exceeds their expiration timestamp. The 30-day grace period in [`constants.move`](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/packages/suins/sources/constants.move) delays re-registration; it does not make an expired record valid for target updates or consumer authorization. [`registry::assert_nft_is_authorized`](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/packages/suins/sources/registry.move) explicitly ignores grace and requires both record and NFT to be unexpired.
- After grace, a new buyer can replace the record. The record's NFT ID can change and the newly created target starts empty.

These semantics make claim-time re-resolution inappropriate for Blast creator fees. It would let a post-launch NFT sale or target update redirect authority away from the creator selected at launch. It would also make fee rights disappear or change when the name expires and is re-registered.

Launch-time freezing gives deterministic behavior:

- current target becomes the only address permitted to claim `CreatorCap<Meme>` once;
- later name changes have no effect;
- the cap can still be transferred deliberately by its owner under ordinary Sui object rules;
- migration does not change the creator authority because it remains bound to `Meme` and cap possession.

## 4. Reproducible package revisions

Primary source reviewed:

| Component | Immutable source revision | Published/network information |
| --- | --- | --- |
| SuiNS contracts | [`692a12c02260fd4abecf1630d33db819e4bcadef`](https://github.com/MystenLabs/suins-contracts/tree/692a12c02260fd4abecf1630d33db819e4bcadef) | Its checked-in [`packages/suins/Move.lock`](https://github.com/MystenLabs/suins-contracts/blob/692a12c02260fd4abecf1630d33db819e4bcadef/packages/suins/Move.lock) records original/latest v5 IDs: mainnet `0xd22b...08f0` / `0x5580...2003`; testnet `0x22fa...dd93` / `0x40ee...172e`. |
| Official TypeScript SDK | [`03fe26bfefd998203faf7767f3fa107dc484117d`](https://github.com/MystenLabs/ts-sdks/tree/03fe26bfefd998203faf7767f3fa107dc484117d) | [`constants.ts`](https://github.com/MystenLabs/ts-sdks/blob/03fe26bfefd998203faf7767f3fa107dc484117d/packages/suins/src/constants.ts) records mainnet/testnet SuiNS shared object IDs `0x6e0d...2871` and `0x3003...e5a3`. |
| Blast's pinned Sui framework | [`06734f6ff0af45d8632a14a4dc4b100197f6b1a2`](https://github.com/MystenLabs/sui/tree/06734f6ff0af45d8632a14a4dc4b100197f6b1a2) | Already pinned in Blast `Move.lock`. |

The current SuiNS manifest names the mutable `framework/mainnet` branch rather than an immutable Sui commit. At review time that branch resolved to `51d177ad7d65102fc368b582408f466d97b31548`, but that observation is not a pin contained in the SuiNS repository.

For an adapter package, pin:

```toml
suins = {
  git = "https://github.com/MystenLabs/suins-contracts.git",
  rev = "692a12c02260fd4abecf1630d33db819e4bcadef",
  subdir = "packages/suins"
}
```

and override its Sui dependency to an exact commit selected by the adapter's top-level package. Do not accept `framework/mainnet` in the final lockfile. Because current SuiNS source records compiler `1.61.2` while Blast currently pins an earlier framework commit, perform a compile/link compatibility test before choosing whether the adapter can stay on Blast's `06734...` framework or must move to the current exact framework revision.

The documentation also publishes stable integration tags `releases/mainnet/core/v3` and `releases/testnet/core/v2`; their peeled commits are [`4fb9b9c...`](https://github.com/MystenLabs/suins-contracts/tree/4fb9b9c9c2c3d2d13a7b28f9fe1124c3907cb820) and [`da23ab4...`](https://github.com/MystenLabs/suins-contracts/tree/da23ab4b417727d09e95b5ec7b326204bf608fb9). Those tags are older than current v5 source. New work should pin the reviewed current commit unless deployment compatibility forces the documented release tag.

## 5. Enum and call-data construction in pinned Move 2024

In the Move 2024 compiler pinned by Blast:

- a public struct's **type** is visible outside its module, but its fields can only be packed or unpacked by the defining module;
- a public enum's **type** is visible outside its module, but its variants and variant fields can only be constructed or matched by the defining module.

The official Move reference states these enum rules directly in [Enumerations: Visibility](https://move-book.com/reference/enums/#visibility). The exact pinned compiler tests also reject external access to an enum variant in [`enum_visibility.snap`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/tests/move_2024/matching/enum_visibility.snap) and external struct destructuring in [`struct_visibility.snap`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/external-crates/move/crates/move-compiler/tests/move_2024/matching/struct_visibility.snap).

Sui's PTB verifier adds a second constraint. A transaction `Pure` input may contain primitives, vectors of permitted pure types, `Option` of a permitted pure type, `ID`, and standard strings; it rejects custom datatypes. See the pinned [`primitive_serialization_layout`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/sui-execution/v3/sui-adapter/src/static_programmable_transactions/typing/verify/input_arguments.rs) implementation.

These rules support the accepted one-function claim interface:

```move
public fun claim_creator_cap<Meme>(
    launch: &mut Launch<Meme>,
    config: &RuntimeConfig,
    x_attestation: Option<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
): CreatorCap<Meme>
```

The generated package constructs a validated
`CreatorIdentity::{Address(address), X(vector<u8>)}` through a public Move
function and supplies it to launch-ticket creation; it is not a raw PTB `Pure`
input. Package code converts it into the coin-typed linear authority stored by
the launch. Claim callers can construct `None` for an address claim or
`Some(vector<u8>)` for the canonical X call-data envelope using ordinary PTB
pure inputs. The launch extracts and consumes its single stored
`CreatorAuthority<Meme>` and returns the resulting cap; it does not restore an
authority after a successful claim.

A custom `XClaimAttestation` struct would be a worse transaction boundary because
wallets could not inject it as a raw pure value and would need a public Move
constructor. The primitive optional envelope keeps the ABI directly callable
without exposing enum variants or an unchecked custom-value constructor.
