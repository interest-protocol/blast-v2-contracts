# 0139: Admin-bounded auto-LP compounding

- Status: accepted
- Date: 2026-11-06
- Owner decision: Jose requested private entry plus maximum slippage, chose `AutoLpAdmin`
  over a new oracle policy, and requested consuming and re-sharing the pool to prevent later PTB use.
- Amends: [0137](0137-shared-launch-stack-core-vault-and-venues.md), compounding authority.

## Context

Auto-LP spends fees already allocated to reinvestment. A permissionless caller choosing its own
price bounds could first move the pool price and then approve that price. Private entry alone
does not reject every completed swap sequence. Newly launched assets also lack an independent
on-chain feed; choosing observation windows, bootstrap, freshness and minimum liquidity would be
a separate oracle-policy decision.

## Decision

Use a dedicated shared-ACL role, `blast_core::blast_domain::AutoLpAdmin`. Each venue's compounding
endpoint is non-public `entry` and checks the presented owned administrator cap against the live
ACL inside that call. No public wrapper or witness-taking bypass exists. Other roles confer no
compounding authority. Ordinary collection and settled fee-split application stay permissionless.

The keeper supplies inclusive minimum and maximum Q64.64 sqrt prices in the venue pool's actual
coin order. It must obtain a trusted off-chain reference and convert its maximum price slippage
into sqrt-price bounds with outward rounding. Zero or inverted bounds and a current price outside
them abort before taking vault balances. A same-pool spot quote by itself supplies no independent
reference. The contracts enforce the keeper's approved interval; they do not enforce a global BPS
ceiling, feed freshness or an oracle observation window.

Compounding consumes the shared pool by value, borrows it internally, and re-shares the same object
as its final operation. The Sui native permits a previously shared object to be re-shared to the
same shared owner [S1]. The consumed transaction input cannot be borrowed or moved again in later
PTB commands [S2], including through a duplicate object input. It remains available in subsequent
transactions. This does not prevent preceding swaps or swaps in later transactions. Keep both
trusted authorization and price bounds.

## Alternatives considered

- Permissionless caller-provided bounds do not establish a trusted economic policy.
- Private entry with a borrowed pool alone does not prevent completed swap composition.
- A TWAP or independent oracle requires a separate bootstrap, freshness, liquidity, availability
  and manipulation policy. It is deferred rather than approximated with a spot read.
- Immutability is a separate package-custody decision, not a substitute for safe compounding.

## Consequences

A compromised keeper can choose permissive bounds and damage the waiting auto-LP allocation;
the dedicated role limits authority to compounding but is global across eligible vaults. Revoke
the role or administrator in the ACL to stop its future calls. Keeper downtime delays reinvestment
without blocking fee collection, owner payouts or claims. Failed calls preserve the pool and all
vault balances through transaction rollback.

This changes both entry ABIs. Before enabling a worker, update its transaction builder to supply
the ACL, owned role-bearing cap and independently derived bounds. Treat compounding as the last
use of that pool in a PTB. The launch stack is unpublished, so this replaces its API directly.
It is not a repair mechanism for already-published unguarded bytecode.

## Verification

The native venue-fork lifecycle exercises both actual venue bytecodes. It checks exact inclusive
bounds, malformed and excluded intervals, role revocation before economic validation, collection
without the compounding role, swap-before-compound rollback at stale bounds, successful repeated
compounding after re-sharing, and runtime rejection of a getter after consuming the pool. Fee,
liquidity, residual and event conservation remain asserted by the lifecycle tests. Structural gates
pin the only private entries, their complete signatures and guarded execution order.

## 2026-11-07: Compounding stops by role revocation, not the vault pause bit

Compounding is an administrator-driven economic operation like buybacks, protocol-share changes
and holder-reward publication, but `vault::take_auto_lp` does not check the vault's
`admin_pause_bit`, so a `PauseAdmin<BLAST_VAULT_PACKAGE>` pause stops those operations while a
live `AutoLpAdmin` keeper can still compound. Owner decision after the 7 November 2026 targeted
audit of #225: keep the code as deployed and record the control here. The stop for compounding
is `blast_acl::revoke_role<AutoLpAdmin>` or revoking the keeper's administrator; both take effect
on the keeper's next call and leave collection, claims and payouts untouched. Incident runbooks
that pause the vault package must also revoke the compounding role when the keeper is in doubt.

## Sources

| Ref | Immutable source |
| --- | --- |
| S1 | MystenLabs/sui `51d177ad7d65102fc368b582408f466d97b31548`, [transfer.rs, `share_object`](https://github.com/MystenLabs/sui/blob/51d177ad7d65102fc368b582408f466d97b31548/sui-execution/latest/sui-move-natives/src/transfer.rs#L299): accepts `New` or `SameOwner`. |
| S2 | Same revision, [memory_safety.rs](https://github.com/MystenLabs/sui/blob/51d177ad7d65102fc368b582408f466d97b31548/sui-execution/latest/sui-adapter/src/static_programmable_transactions/typing/verify/memory_safety.rs#L269): rejects use of a moved value; the native fork tests falsify any incompatible runtime premise. |
