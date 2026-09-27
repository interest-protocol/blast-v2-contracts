# 0094: One role per administrator action

- Status: accepted; role bits, checks, and gate map superseded by
  [0097](0097-one-singleton-acl-with-typed-roles.md), which keeps this grouping as types
- Date: 2026-09-25
- Amends: [0082](0082-revocable-creator-and-lp-fee-capabilities.md) and
  [0091](0091-fee-split-buyback-and-burn.md)

## Context

The launchpad and the migrators share one `BLAST_FUN_DOMAIN` authority. Package
custody, creator reassignment, and buyback each asserted a role, but every other
administrator action accepted any live `AdminWitness`, including one with no
role. Any registered administrator could therefore set trade fees and fee
shares, admit Quotes and migration adapters, replace the account-claim signer,
set Blast's allocation and payout destination, claim Blast's fees, and publish
holder-reward rounds. On 2026-09-25 the owner asked that every administrator
function carry a specific role, so that no administrator holds another's
privileges.

## Decision

**Roles.** `blast_fun_domain` defines one single-bit role per concern:

| Bit | Role | Actions |
| --- | --- | --- |
| 1 | package admin | authorize, commit, and seal upgrades in both packages |
| 2 | creator admin | reassign a launch's curve-fee and metadata caps |
| 4 | buyback admin | buy back and burn with a vault's burn Quote |
| 8 | treasury admin | claim Blast's curve and LP residual fees; set Blast's allocation and the LP-fee payout destination |
| 16 | fee admin | set the curve trade fees, Blast's curve-fee share, and the default and per-coin LP-fee shares |
| 32 | listing admin | admit or remove Quotes and Meme decimals |
| 64 | adapter admin | admit or remove migration adapters |
| 128 | claim-signer admin | replace or revoke the account-claim signer |
| 256 | rewards admin | publish holder-reward rounds |

Treasury and fee are split so that whoever sets Blast's rates cannot move or
redirect Blast's money. Adapters are split from listings because an admitted
adapter receives the liquidity of every launch that picks it. The claim signer
is split from creator admin because it is a backend key rotation, not a
community takeover.

**Checks.** Every administrator action asserts exactly its role, right after the
package-generation check and before any other validation. The buyback entries
reach their role through `vault::take_buyback_quote`. An administrator may hold
several roles, and root still grants and revokes each bit (ADR 0070's model).
Sign-in with no role authorizes nothing.

**Visibility.** Following ADR 0090, a role getter is public only when the
migrators assert it: package, buyback, treasury, fee, and rewards. Creator,
listing, adapter, and claim-signer are `public(package)`.

## Consequences

- A compromised administrator reaches only the actions of the roles on its cap.
- Operators need an explicit grant per role; deployments grant roles by concern
  instead of relying on membership.
- The launchpad and migrator source gates pin the function-to-role map through
  `sui/launchpad/scripts/admin_roles.awk`, so a new function that takes the
  domain's witness fails until it is mapped.

## Verification

- Each role-gated action has a Move test that an administrator holding every
  other bit aborts with `EAdminRoleNotGranted`.
- `blast_fun_domain_tests` pins the nine role values.
- Both source gates reject a missing, extra, late, or swapped role assertion.
