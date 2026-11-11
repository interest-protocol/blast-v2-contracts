# 0141: Blast SUI stakes across a short delayed validator list

- Status: proposed
- Date: 2026-11-11
- Amends: [0053](0053-single-validator-funsui-and-blastsui.md) (one fixed pool, unwind-only
  terminal state)
- Follows: [0136](0136-blast-sui-custody-before-activation-and-delayed-administration.md)

## Context

ADR 0053 bound the vault to one staking pool for its whole life. A validator leaving the active
set closed deposits for good. Partners also want to be staked to, and the owner settled that
being a partner means being listed as a validator: no partner registry and no fee share in this
package.

The package is unpublished, so its layouts, events and errors change in place.

## Decision

**List.** `Vault.validators` is a `DelayedSet<ValidatorKey, ID>` of staking pools, capped by
`constants::max_validators!()` across admitted and pending together. `ValidatorAdmin` schedules
an admission, which waits its delay because it routes user funds. Anyone applies it once ready,
with the pool proven active and current; applying emits a custody snapshot that includes the
pool without refreshing the others. Removal is immediate, because reducing risk is never
delayed: it unwinds both positions in the same call and re-delegates the SUI. `unpause` refuses
while the validator delay is unguarded or an admission is pending.

**Picks.** `mint_fun_sui` and `request_blast_sui` take a listed `pool_id`. A pick directs that
deposit's stake and nothing else: there is one pooled blastSUI and yield is shared. A pick can
never move SUI that was already idle.

**Custody.** Each ledger holds liquid SUI and one position per listed pool. `pool_rates` caches
one rate per pool, and its keys always equal the admitted members. A pool is either a member
with positions or gone, so there is no retiring state and no unwind-only vault.

**Routing is the vault's, never the caller's.** Idle SUI splits evenly when each eligible pool
gets the native minimum, and otherwise goes to the smallest position. Exits take liquid, then
pending by principal, then active by `active_sui`, largest first, ties by list order.

**Departure.** A pool has departed when its validator address left the active set, or when it has
no raw entry this epoch while another listed pool has one. Only safe mode leaves every pool
without an entry, so a lone gap means the address now runs a different pool. This closes ADR
0053's address-reuse residual whenever a second pool exists. With one listed pool the pool stays
stale, and `remove_validator` is the way out.

**Claims** need every listed pool at the current epoch, because a stale pool understates blast
assets and would over-mint. A removed pool's receipt cannot be claimed; native cancel stays open.

**Fun safety.** One redemption touches at most `N = max_validators` positions and loses at most
the native margin `m` on each. `fun_exit_low_water_mist` is `2·N·m`, written against the
compile-time cap so a change in the live count cannot invalidate it. The sweep recomputes the
surplus after every pool, because decrementing by the moved value could over-sweep.

## Accepted risks

- **Shared yield with a user pick.** A depositor can stake to a high-commission validator it
  operates and still share everyone's yield. Commission is not readable on chain at the pinned
  framework. The controls are the admission delay, immediate removal, and off-chain alerting.
- **Coupled exits.** Move has no catch, so a native abort on any one pool during refresh blocks
  every exit until an upgrade. More pools widen this.
- **Stake migration.** A listed validator can pull stake toward itself up to parity with the
  largest pool, by minting with its own pick and redeeming from the largest. funSUI redemption
  is free, so this costs only gas; blastSUI costs its fee. Solvency is unaffected. Curation is
  the control.
- **Concentration** is per pool. When the last member leaves, deposits stop and exits continue.

## Consequences

The cap bounds the worst-case work inside every exit, so raising it needs the worst-case gas
measured again at a mainnet-sized active set and `fun_exit_low_water_mist` re-derived.
