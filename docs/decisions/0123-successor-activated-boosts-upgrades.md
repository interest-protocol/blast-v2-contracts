# Successor-activated Boosts upgrades

Status: proposed. Date: 2026-10-24.

## Problem and audit recommendation

M-3 in the repository's Asymptotic audit restatement describes a permanent lock:
old code commits a successor and advances the operational generation without
proving the successor accepts it. Policy narrowing can prevent the required
constant/body change; a wrong build can also cause the mismatch. The same
version check then blocks repair authorization and all versioned user exits.

We follow the recommendation to separate receipt commit from successor-side
activation, preserve repair authorization and remove policy narrowing. We differ
on `make_immutable`: it keeps its current-generation check. Authorizing repair
preserves recovery; destroying upgrade authority removes it. This is a deliberate
refinement agreed with the user and Sol 6.1, not original-auditor approval. The
audit file is a project restatement, not the original Asymptotic report.

## Decision

Native authorization, upgrade and receipt commit remain one transaction. Commit
only consumes the receipt bound to the sealed cap; it neither reads nor changes
Protocol. The native receipt already proves authorization, so commit takes no
redundant administrator witness. Authorization still needs a live typed
UpgradeAdmin witness, but neither authorization nor commit requires an
operational version match.

A separate follow-up transaction calls the successor's activation with a live
UpgradeAdmin witness. Its private PACKAGE_VERSION must equal the stored
operational generation plus one, checked without overflow by the existing
OperationalVersion value. Only then does it advance and emit the existing
OperationalVersionAdvanced event. Remove NEXT_PACKAGE_VERSION and both adapter
policy-narrowing wrappers. Preserve the compatible policy, non-releasable cap
custody and current-generation guard on make_immutable.

Native package versions and operational generations are deliberately independent.
If native v2 fails activation while generation 1 keeps serving, a corrected
native v3 compiles operational generation 2 and activates 1 to 2. A bad or skipped
constant cannot disable the old generation by merely committing an upgrade.
After successful activation, old operational generations fail their ordinary
mutation and exit guards. No automatic fallback to older economics is allowed.

The authority exception is permanent: old authorization bytecode remains callable
but still requires the live immutable ACL. A governance replacement must revoke
the UpgradeAdmin role or account for those callable versions. A generation
cutover alone cannot retire their authority.

## Boundaries and evidence

This is a fresh-publication design under ADR 0115. It cannot remove unsafe public
functions from an already published historical package. No deployment is implied.
Shared admin, core economics and other products' upgrade designs are unchanged.

Activation proves a consecutive compiled generation, not arbitrary code health,
latest installed package identity or exclusive acceptance of a single candidate.
An older unactivated candidate with the same compiled generation remains callable.
A candidate rejected for being ahead can become activatable after a later cutover.
Administrators must record superseded candidates, select only the package ID
reviewed for the current cutover and verify dependent routes.
The make_immutable guard only proves the running code matches current state; it
is not a pending-upgrade or full-health check and cannot restore a burned cap.

Unit tests pin activation, replay/skips/overflow, immutability and guard order.
Runtime evidence must exercise native upgrade/commit, failed activation rollback,
old operation continuity, repair after failed attempts, new activation and old
rejection, live ACL revocation and terminal immutability. Exact execution scope
and remaining gaps accompany the PR. The deployment runbook records the two
transactions, both version values and the review/exits checks.
