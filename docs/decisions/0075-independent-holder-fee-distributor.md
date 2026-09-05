# Independent holder fee distributor

Accepted for implementation on 2026-09-05 following the user's request for an
optional, separate package that consumes the creator capability and distributes
fees to wallet holders. Publication remains subject to release verification.

## Decision

Add `blast_fun_distributor`, depending on the existing launchpad and migrators.
Neither dependency changes. Enrollment consumes `CreatorCap<Meme>` into a
sealed dynamic object field of a shared `Distributor<Meme, Quote>` so its
original ID remains independently discoverable. There is no cap removal,
borrow, mutable UID, arbitrary payout, or distribution cancellation API.

Issue one transferable `PublisherCap` bound to that distributor. Its owner
authorizes funded Merkle rounds through native Sui transaction signatures;
multisig ownership requires no custom signature verifier. Transferring this cap
rotates publishing authority, but does not expose the creator cap or alter old
rounds. The publisher can misallocate all unallocated rewards; this trust is
explicit. Independent accounting review and public manifests are operational
controls, not cryptographic proof of historical balances.

Anyone can collect creator fees from a typed curve or LP vault. Both assets go
into distributor custody. A source ID in the funding event identifies which
source was collected; collection does not grant or bind a new authority.
The existing coin-typed creator capability is the authority boundary. LP vault
provenance is verified off-chain against migration events before bot collection.
Protocol fees and LP principal are never claimed.

Publishing consumes an explicit budget for each asset into an independent
shared round. It checks the bound publisher cap, expected monotonically
increasing round number, checkpoint interval, root length, allocation-manifest
digest, leaf-count bound and available funds. Intervals are contiguous after
the first round; each represents holdings after the start checkpoint until the
end checkpoint. At most 65,536 leaves and 16 proof siblings are allowed per
round, with an inline bitmap of at most 256 u256 words. Retain rounds permanently
for claims and audit, including after payment. No expiry or administrative sweep.

Claims bind the distributor ID, round number, positional leaf index,
beneficiary and both amounts using domain-separated BCS and Blake2b-256.
The unique distributor ID and typed round separate instances and assets; roots
are authorized on the target Sui chain through ordinary transaction signatures,
not portable signed messages. Nodes and leaves use different prefix bytes.
The tree duplicates the last node at odd levels. A claim checks index, proof
depth, digest sizes, replay bitmap and available balances, then transfers both
nonzero payouts directly to the beneficiary. A bot can submit proofs without
holding publisher authority. SDK manifests contain all proofs for independent
self-claim and relaying. Their encoding is pinned by cross-language vectors.

## Off-chain accounting

Provide a standalone TypeScript keeper path in the SDK, using the pinned Sui
gRPC checkpoint balance-change API. That API includes address-owned coin and
address-accumulator deltas. Replay complete checkpoints from the coin's creation,
require contiguous sequence/digest links and nonnegative balances, aggregate by
address, exclude configured custody addresses, and integrate balance × elapsed
milliseconds. The checkpoint's resulting balance applies until the next
checkpoint. Amounts and weights are integers. Allocate each available asset
proportionally, round down, keep dust in distributor custody, and omit zero
payouts. Publish nothing when eligible weight or payable budgets are zero.

The keeper persists checkpoint journals in bounded batches before their matching
ledger watermark, alongside public round manifests; unsigned
transaction output supports external or multisig signing. Permissionless delivery
uses on-chain claim bitmap state, so retries and another keeper cannot double pay.
Historical LP fee timing is not reconstructed: distributions allocate fees
collected and budgeted for the closed interval. Delayed collection and publisher
availability remain operational assumptions.

## Upgrade and release posture

This is a new, unpublished package. On 2026-09-05 the user superseded the
initial immutable-release proposal with simple upgradeability: the owner keeps
the native UpgradeCap; existing launchpad admins control a separate distributor
version-and-pause singleton. There is no package-admin wrapper, policy-management
API, second ACL, timelock, or custom signature mechanism. This explicitly differs
from core's wrapped upgrade-cap policy. The owner can upgrade custody behavior;
cap custody is visible but must not be advertised as irrevocable.

A single key-only PackageVersion object is created by the publication initializer.
Enrollment, collection, round funding, and claims first check the compiled
operational version, then pause. A launchpad AdminWitness authorizes pause/resume
and activation. The witness is obtained from the active core ACL in the same PTB;
the distributor does not link its own administrative recovery to core's old
package-version guard. Activation accepts only stored version + 1 equal to the
new build's compiled constant, preserving pause. It cannot choose an arbitrary
version, skip a generation, or roll back. Native upgrade completion and operational
activation remain separate steps. Additive/dependency-only upgrades that leave
guarded semantics unchanged retain the operational version.

Pause deliberately stops all economic transitions, including existing funded
claims, to contain a payout bug. Resuming restores those claims without altering
roots, balances, or replay state. No cancellation or sweep is added. Claims remain
independent of publisher availability and core collection state, but depend on the
active distributor generation being unpaused. The admin can withhold resumption;
this liveness trust is explicit.

Repair uses a compatible upgrade of the same package lineage, followed by admin
activation when guarded behavior changes. Deploying a fresh independent package
does not move existing creator caps or funded rounds. Existing stored layouts and
public signatures must be preserved by future compatible upgrades. Before a core
version cutover, relink and verify distributor curve collection against that core
generation; preserving its UpgradeCap leaves this repair route available.
No live publication, upgrade, or capability transfer is part of this task.

## Verification

Require actual creator-cap enrollment and curve collection tests; cap binding,
funding conservation, proof domain, recipient, replay, bounds and event tests;
SDK/Move vectors; holder transfer and checkpoint replay tests; transaction
construction and state-decoding tests; package build/lint/tests and SDK checks; pause/resume, admin authentication,
version precedence, overflow and exact-next activation tests.
Mainnet LP collection and explorer-visible child custody need live release
evidence because venue interfaces contain link stubs.
