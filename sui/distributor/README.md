# Holder fee distributor

Optional, independent Sui package for redirecting creator fees to wallet holders.
The existing launchpad and migrators remain unchanged. Enrollment takes the
launch's existing `CreatorCap<Meme>` by value and retains it as a discoverable
child object. It does not destroy the cap or mint a replacement.

```mermaid
flowchart LR
  Curve[Curve creator fees] --> D[Distributor owns CreatorCap]
  LP[LP vault creator fees] --> D
  Indexer[Checkpoint holder accounting] --> Manifest[Public allocation manifest]
  Manifest --> Publisher[PublisherCap owner signs round]
  D --> Round[Funded Merkle round]
  Publisher --> Round
  Round -->|Anyone relays proof| Holder[Committed holder address]
```

The publisher authorizes recipients and amounts; it cannot withdraw the creator
cap or withdraw coins through a separate administrator API. **The publisher can
still assign unallocated rewards to itself in a new round.** Use a multisig and
independent accounting review to reduce this trust. Merkle proofs enforce the
published allocation, not the truth of off-chain holder accounting.

Both Meme and Quote fees are supported. Each round reserves its full declared
budget and has a permanent claim bitmap. Claims pay recipients directly, require
no staking or holder signature, and cannot pay the same leaf twice. A holder can
self-claim if the bot stops, while rewards are active and unpaused. Publishing another round cannot change old claims.
There is no expiry, cancellation, cap extraction, or recovery sweep. An incorrect
root or excess reserved budget cannot be recovered through the current API.

## Public interface

| Operation | Authority | Result |
| --- | --- | --- |
| `new` + `share` | Existing CreatorCap owner | Shared distributor; separately delivered PublisherCap |
| `collect_curve_fees` | Anyone | Both creator fee assets enter distributor custody |
| `collect_lp_fees` | Anyone | Accrued LP creator fees enter distributor custody |
| `publish_round` + `share_round` | Bound PublisherCap owner | Independently funded shared round |
| `claim` | Anyone with allocation proof | Nonzero coins transfer to committed beneficiary |

Hold PublisherCap at an address, normally a Sui multisig. Ownership uses normal
transaction signatures; no server-message signature verifier is needed. Transfer
PublisherCap to rotate authority. Destroying or losing it prevents future rounds.
Permissionless collectors and relayers need only gas.

Events: `Enrolled`, `FeesCollected`, `RoundPublished`, `RewardPaid`. The SDK's
`getDistributorCreatorCap` resolves the actual dynamic child and checks its type;
the enrollment event links its original ID to the distributor. `CreatorCapKey()`
has BCS bytes `00` (Move's unit-struct dummy boolean).

## Accounting and operation

See the SDK's `docs/holder-distributor.md` for enrollment, checkpoint replay,
unsigned publishing transactions, and restartable airdrops. The default policy
weights direct address balances by milliseconds held between checkpoints,
starting at enrollment. It excludes configured custody addresses and zero address.
LP positions and balances held inside other contracts are not beneficial-owner
balances under this policy. Exchange custody requires an explicit eligibility
policy; it does not identify each exchange customer.

Distribute the assets actually collected for the interval. This implementation
does not attribute every historical fee to the exact trade that generated it.
Collect venue fees into the LP vault before collecting the vault's creator share;
existing SDK venue collectors compose with this package in a transaction.
Verify vault provenance against the launch's migration event.

## Verification and release

```sh
sui move test --path sui/distributor --build-env testnet --lint
sui move build --path sui/distributor --build-env testnet
sui move lint --path sui/distributor --build-env testnet --warnings-are-errors
```

`docs/vectors/holder-rewards.json` is the fixed Move/SDK commitment vector.
Tests cover actual creator-cap enrollment and curve fee collection, sharing and
publisher-cap transfer, funding, replay, recipients, contiguous intervals, maximum
65,536-leaf bitmap/proof, and native payout event bytes. The production ABI exposes
no cap borrow, mutable UID, or coin-returning withdrawal.

## Pause and upgrades

This package implements no administration of its own. It reuses the Launchpad
administration domain for membership and owns only its operational generation,
its pause policy, and its sealed framework custody. One revocation in the
Launchpad authority removes this package's pause authority immediately.

The package creates one shared `package_version::PackageVersion` at publication,
holding the generation value beside `paused`. A live Launchpad-domain admin
signs in through `blast_admin::acl::sign_in` and passes the returned
`AdminWitness<LAUNCHPAD_DOMAIN>` to `set_paused`; generic membership is enough
and no role is required. Pause blocks enrollment, both fee-collection paths, new
rounds, and existing claims. Resume leaves all claim roots, funds, and replay
bits intact. Every economic transition rejects retired bytecode **before** it
checks pause or touches funds, so stale code never reports a pause error. The
version singleton has no public constructor or reset path.

The native UpgradeCap is not owner-held. `package_admin::wrap` seals this
package's Publisher and its never-upgraded cap in `UpgradeCustody`, and no path
returns, transfers, or borrows either capability. Upgrade authorization, policy
narrowing, immutability, and the commit-and-advance finalizer additionally
require the package-admin role that Launchpad exports.

A governed upgrade is one transaction: authorize the digest, run the native
Upgrade command, then call `package_admin::commit_upgrade_and_advance`, which
commits the receipt to the same sealed cap and advances to exactly the next
compiled generation. There is no separate activation step. The advance preserves
the pause value, and package custody stays reachable while rewards are paused so
an emergency stop never blocks the upgrade that repairs it.

The product `PublisherCap` that authorizes round publication is a separate,
transferable capability. It never enters framework custody, and round
authorization stays independent of Launchpad administration.

This package is **unpublished**. Before accepting real creator caps:

- Verify the selected deployed launchpad/migrator generation and every venue route
  with live simulation. Interface link stubs do not establish live LP compatibility.
- Verify compatible upgrades, commit-and-advance cutover, and resumption on the
  target network. Record the shared authority, PackageVersion, and PackageAdmin
  IDs. Coordinate core cutovers with a tested dependency relink for creator-fee
  collection.
- Verify child custody in an explorer, measure maximum-round transaction gas and
  object size under target-chain limits, and publish manifests/accounting durably.

No package publication, mainnet transaction, or UpgradeCap destruction is included
in local implementation. See [ADR 0075](../../docs/decisions/0075-independent-holder-fee-distributor.md).
