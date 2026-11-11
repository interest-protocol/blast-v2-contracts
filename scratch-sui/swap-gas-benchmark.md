# Continuous-fee swap gas at 128 steps

Keep the 128-step cap for a single core swap. The original cap benchmark's
most expensive successful case used 979,500 computation units, 19.59% of
the 5,000,000-unit transaction ceiling at the measured protocol version.
Hooks and multiple swaps share that ceiling with the rest of their
transaction and need a complete route simulation.

## Results

All 30 measured swaps succeeded. Values below are charged computation units.
Full crossings reached the 128th initialized boundary with both input and
price-limit distance remaining. For a partial final step, the first 127
boundaries were crossed and the final price landed strictly between the
127th and 128th boundaries. The terminal columns show the maximum over
the tested input budgets.

| Pool layout | Quote to asset, 128 crossings | Asset to quote, 128 crossings | Quote to asset, partial step 128 | Asset to quote, partial step 128 |
| --- | ---: | ---: | ---: | ---: |
| Initialized ticks one tick apart | 350,600 | 426,400 | 445,000 | 549,600 |
| Dense ticks near the fee cap | 355,500 | 422,700 | 460,700 | 542,700 |
| Paid steps across the uncapped fee range | 373,800 | 493,600 | 492,800 | 647,000 |
| Wide final interval across the fee reference | 357,900 | 438,100 | 715,600 | 886,800 |
| Wide final interval at a lower absolute price and larger input | — | 438,100 | — | **979,500** |
| 64 zero-liquidity gaps interleaved with 64 funded ranges | 57,600 | 118,500 | — | — |

The maximum was a downward swap with `4,285,483,291,889,460,965` input atoms.
The first 127 paid crossings were eight ticks apart. The last step searched
for the affordable input across a 56,904-tick interval, passing the reference
and reaching the capped part of the fee curve. The simulation wrote 130
existing objects including the gas and fixture treasury objects. Its storage
charge was 350,876,800 MIST, with 348,516,345 MIST rebated. At the observed
mainnet reference price of 100 MIST per computation unit, the simulated
computation charge would be 0.09795 SUI. With identical storage effects, the
net charge would be about 0.10031 SUI. A signed replay on the local chain also
succeeded, at 970,500 computation units. The reference observation uses the
chain clock, so the signed replay can follow a different search sequence.

Zero-liquidity steps advance the tick cursor and skip continuous-fee pricing.
A paid crossing that needs the second pricing probe spends more than 90% of
the remaining input: the first probe already tried the net budget at the
maximum admitted fee. Such crossings can occur at most 20 times with a
`u64` input. The search only occurs on the terminal step, because it starts
after the full-budget probe fails and can only select a price short of the
step target. The original measurements leave 4,020,500 computation units
above that benchmark's largest observed charge. A formal VM gas bound across
all reachable states remains unverified.

## Wide multiplication and division

The 979,500-unit swap above took the checked-multiplication path throughout.
To measure the fallback, a separate asset-to-quote fixture started at tick
zero with 128 consecutive initialized ticks below it. The high-liquidity
version used `2^65` liquidity and `2^61` input atoms. Each full crossing
triggered one wide division in the price inverse. Both tokens were locally
minted fixtures to fund the positions at that liquidity. The control used
`2^54` liquidity and `10^16` input atoms.

| Full PTB | Seven 24-bit limbs | Adaptive limbs | Savings |
| --- | ---: | ---: | ---: |
| Control, 128 crossings without wide division | 426,500 | 426,500 | 0 |
| Wide division on all 128 crossings | 449,200 | 430,100 | 19,100 |
| High liquidity, partial fill on step 128 | 617,700 | 591,500 | 26,200 |

The two full-crossing fixtures were 22,700 units apart before the change,
about 177 units per crossing in this setup. Liquidity and amounts differ
between those fixtures, so the direct measure of the optimization is the
before-and-after comparison on each row. Price, spend, LP fees, output,
storage charge, and rebate matched exactly within each pair.

The faster path uses two 80-bit limbs when the multiplicand and divisor each
fit in 175 bits. Wider operands use four or six 30-bit limbs, selected by the
multiplier width. The Z3 model checks that both radices preserve the same
quotient and remainder and that each partial dividend fits in `u256`. The
terminal remainder still determines the requested rounding direction.

## Exact-input search on the final step

Both variants used adaptive wide division and the same continuous-fee quote.
On a rejected quote, the new search uses the fee excess and maximum fee
slope to discard budgets that cannot afford the fill. It quotes the highest
remaining budget with the original Q96 arithmetic. The first affordable
quote selects the same endpoint as bisection, including on price plateaus.
[Equivalence and probe bound](continuous-fee-proof.md).

The paired runs used protocol 141 and gas model 15. All 20 partial fills
used less computation, and all 18 boundary, step-cap, and zero-liquidity
controls used the same computation. Every pair matched on final Q96 price,
input spent, LP fee, output, storage charge, and storage rebate.

| Full PTB | Bisection | Bounded search | Computation units saved |
| --- | ---: | ---: | ---: |
| Dense ticks, quote to asset | 445,000 | 382,200 | 62,800 (14.1%) |
| Dense ticks, asset to quote | 549,600 | 466,300 | 83,300 (15.2%) |
| Uncapped fee range, asset to quote | 647,000 | 516,900 | 130,100 (20.1%) |
| Wide final interval, quote to asset | 607,100 | 376,400 | 230,700 (38.0%) |
| Wide final interval, asset to quote | 734,400 | 479,100 | 255,300 (34.8%) |
| Wide final interval at a lower absolute price, asset to quote | 795,300 | 485,200 | 310,100 (39.0%) |
| Reference crossing, including a warm-up swap in the same PTB | 1,456,000 | 989,700 | 466,300 (32.0%) |

The one-swap fixtures started with the fee reference equal to the pool
price. The lower-price fixture started at tick −100,000, crossed 127
boundaries spaced eight ticks apart, and had a final interval ending at
tick −156,000. For the wide-interval fixtures the table shows the input
budget three quarters of the way between the 127th and 128th boundaries'
gross spend. The reference-crossing pair warmed the reference and made
the measured swap in the same PTB so both variants used the same clock
timestamp. Its paired 127-crossing control cost 902,400 units with either
search.

## Reproduce

The target was Sui mainnet epoch 1308 on 2026-11-11, protocol 141 and gas
model 15. The benchmark ran the worktree's Move code on a disposable local
chain built from the Sui `mainnet-v1.83.1` binary. It matched mainnet's gas
model, computation ceiling, rounding configuration, and storage pricing.
The local reference gas price was 1,000 MIST. The table divides each
`computationCost` by that price. [Sui release](https://github.com/MystenLabs/sui/releases/tag/mainnet-v1.83.1), [gas model](https://docs.sui.io/develop/transaction-payment/gas-in-sui), [epoch RPC](https://docs.sui.io/develop/accessing-data/grpc/using-grpc).

1. Start a protocol-141 localnet with a funded wallet and a gas coin of at
   least `30_000_000_000_000_000` MIST for pool funding. Configure `dex-local`
   in the wallet's `client.yaml` to use the loopback fullnode address.
2. Test-publish staged copies of `blast_admin` and `blast_fun_dex` with the
   local environment and a common ephemeral publication file. Set the staged
   admin package's `blast_acl_root` to the funded wallet and remove its live
   publication metadata from the staged copy. Save the DEX publish effects as
   `dex.json`. Publish a fixture `token::TOKEN` currency with a treasury cap
   owned by the same wallet and save its publish effects as `token.json`.
3. Call `package_admin::wrap` for the DEX publication and upgrade capability
   and `blast_acl::grant_admin` for the wallet in the same PTB. Save those
   effects as `wrap.json`. Grant the operator `UnpauseAdmin<BLAST_FUN_DEX>`,
   sign in with that role, and unpause with mask `7`.
4. With those JSON files and `client.yaml` in a fresh artifacts directory,
   run `python3 scripts/benchmark_dex_swap_gas.py ARTIFACTS --sui SUI --grpcurl GRPCURL --gas-price 1000`.
   The runner provisions pools at 1,000 ppm base fee, 100,000 ppm cap,
   and 100,000 ppm sensitivity. It measures input preparation, swap begin,
   execution, settlement, and both coin transfers in one PTB using gRPC
   simulation with transaction checks enabled. It excludes fixture setup and
   warm-up transactions from the results.
