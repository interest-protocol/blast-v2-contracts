# 0091: A burn part in the LP-fee split, bought back by a buyback administrator

- Status: accepted
- Date: 2026-09-24
- Amends: [0089](0089-migrators-own-post-migration-and-start-launches.md)

## Context

The founder asked on 2026-09-24 for a burn part in the creator's LP-fee split and
chose buyback and burn: the burn part's Meme is burned, and its Quote buys Meme
back to burn. A swap priced from the pool alone is not safe to leave
permissionless: in one transaction anyone can push the pool's price, trigger the
swap, and sell back, taking nearly all of the Quote, and a caller-supplied
minimum does not help when the caller is the attacker. The founder ruled that
only a Blast administrator holding a dedicated role triggers the swap, with a
minimum set from an off-chain price.

## Decision

**Split.** `FeeSplit` gains `burn_bps` after `rewards_bps`; the creator, auto-LP,
rewards, burn, and recipient parts sum to 10,000 and apportion together, ties
going to earlier parts. Split updates keep ADR 0089's settle-first rule.

**Collection.** Every collection burns the burn part's Meme at once: through the
Meme `Currency` when the supply is burn-only, otherwise by paying it to `@0x0`,
as migration disposes of the curve remainder. The burn part's Quote waits in the
vault's `burn_quote` balance. Collections therefore take the Meme `Currency`.
`FeesCollected` records `burn_meme` and `burn_quote`.

**Buyback.** `blast_fun_domain` adds the public buyback-admin role, bit 4. Each
venue has one buyback entry per coin order: it takes the vault's whole burn
Quote under a witness carrying that role, swaps it for Meme in the vault's own
pool up to the widest sqrt-price limit both venues accept, and burns the Meme
bought, which must reach the administrator's `min_meme_out`. Quote the pool does
not take waits for the next buyback. `BuybackBurned` records the Quote spent,
the Meme burned, and the Quote still waiting. Cetus swaps through
`flash_swap`/`repay_flash_swap`, repaying exactly the receipt; Bluefin through
`swap`. Both join the pinned venue ABI.

## Consequences

- Burned Meme lowers the supply only for burn-only currencies; for fixed ones it
  is permanently out of circulation at `@0x0`.
- The burn part's Quote depends on a Blast keeper; if none runs, it waits in the
  vault. No other path can spend it.
- The administrator's minimum is the only price protection; the keeper must
  derive it from an external price, not from the pool it trades against.
- Local Move tests cover the vault's split, role, minimum, and burn; the swaps
  run only in the venue fork against real Cetus and Bluefin bytecode.
