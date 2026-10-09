# Presale mainnet end-to-end verification

Status (2026-10-09): every ticket passed on the fresh publication `0x2d30…1fd0`, which signs in
through the shared `blast_admin` ACL, except E2E-017's second phase, which can run after
2026-10-16T00:46:38Z (`node e2e/presale-mainnet/run.ts e017 finish` in the SDK, branch
`e2e/presale-acl-redeploy`). The run added E2E-036 to E2E-041: early close when filled, a full sale
held to its end, overflow until the hard cap starts, the `PresaleInitializer` gates, Aftermath
DAO-pool vendor sales in both coin orders, and a vault without a presale. E2E-023 now exercises
the ACL and a real dependency-only upgrade. Evidence and findings:
[`deployments/sui/mainnet/2026-10-09-blast-presale-e2e.json`](../deployments/sui/mainnet/2026-10-09-blast-presale-e2e.json).
The 2026-10-04 run on `0x76cb…8400` is
[`2026-10-04-blast-presale-e2e.json`](../deployments/sui/mainnet/2026-10-04-blast-presale-e2e.json).

Goal: exercise every public `blast_presale` function and every abort condition users can hit,
on the real mainnet package (the deployment record each run names),
with real transactions. Unit tests already cover the math; this run proves the deployed bytecode,
the venues (Bluefin, Cetus), the vesting package, and the SDK builders work together on chain.

## Decisions (owner, 2026-10-04)

| # | Decision |
| --- | --- |
| D1 | Run on the production package. Test sales stay in its event history; the indexer and web hide sales whose Quote is `TEST_SUI`, plus the E2E-011 SUI sale. |
| D2 | Cetus sales raise SUI in very small amounts. Cetus reserves a SUI pair only at tick spacing 200 and rejects `TEST_SUI` (E2E-003). |
| D3 | The test Quote is `TEST_SUI` (symbol `TSUI`, 9 decimals), valued like SUI. |
| D4 | Keep the current `AdminCap`; E2E-023 is skipped. |
| D5 | Successful steps are real transactions; expected failures are simulated against mainnet state and must abort with the named module and code. |
| D6 | Scale limits (64 token and 64 raise recipients, 16 fee recipients at once) are out of scope; every core path is tested end to end. |

## Layout

- `sui/presale_testkit/` (this repo): a separate Move package, never a dependency of production.
  `tsui` module: the `TSUI` currency through the Coin Registry, its `TreasuryCap` in a shared
  `Faucet`, and `faucet::mint(faucet, amount, ctx): Coin<TSUI>` for anyone. `sale_tokens` module:
  one `key` marker type per scenario (`SaleA` … `SaleP`), each with a function that calls
  `coin_registry::new_currency<T>` and `finalize`, sharing `Currency<T>` and returning a zero-supply
  `TreasuryCap<T>`. The creating transaction shares the `Currency`, so presale creation is a second
  transaction.
- Runner (SDK repo, `e2e/presale-mainnet/`): TypeScript on the SDK's `PresaleTransactions`, so
  the SDK builders are verified too. One file per scenario plus shared helpers. Each run writes an
  evidence file with every digest, emitted event, balance before and after, and pass/fail per check.
- Evidence summary: `deployments/sui/mainnet/<date>-blast-presale-e2e.json` (this repo).

## Conventions for every scenario

- Wallets: the deployer (holds `AdminCap`, `SuperAdminCap`), a separate fee destination, a creator,
  six participants `P1`–`P6`, a relayer with no commitment, and recipients `R1`–`R3`. Ephemeral
  wallets get small SUI for gas and `TSUI` from the faucet; their keys stay out of git.
- Windows: commitment windows of 3–10 minutes, uncapped phases a few minutes in, vesting with
  30-second cliffs and periods. The liquidity window cannot be under seven days
  (`MIN_LIQUIDITY_WINDOW_MS`), so only E2E-017 waits for it.
- Keeper path: `settle` and the venue's `migrate` in one PTB, as DEPLOYING.md step 7 runs it.
- Negative checks are submitted as real transactions and must fail with the named abort code and
  module. Each costs only gas.
- Every scenario checks: conservation (Quote in = refunds + Blast + recipients + LP + residuals;
  supply = buyers + LP + Blast + recipients), event fields against the SDK reducer's projection,
  and the sale token's `Currency` supply state (`Fixed` or `BurnOnly`, alternating across sales).

## Tickets

### Foundation

**E2E-001 Testkit package.** Write `sui/presale_testkit` as above. Unit-test `mint` and one
sale-token creation. Publish to mainnet (immutable is fine: test-only). Record IDs.
Done when: `TSUI` mints from any wallet and one `SaleA` currency shares with zero supply.

**E2E-002 Runner scaffold.** Wallet generation and funding, faucet minting, `waitUntil(ms)`
against the on-chain clock, `expectAbort(tx, module, code)`, balance snapshots, event capture,
evidence writer, and a spend guard that stops the run past the D5 budget.
Done when: a dry scenario (mint, transfer, snapshot) writes a valid evidence file.

**E2E-003 Feasibility probes (dry runs only).** Read Bluefin's
`config::get_pool_creation_fee_amount<SUI>`; confirm SUI's Cetus permission pair and pick the
tick spacing; locate Bluefin and Cetus swap entry points on their current packages; dry-run one
Bluefin and one Cetus creation; estimate gas and storage per scenario.
Done when: D2 and D5 are confirmed with numbers.

**E2E-004 Admin setup.** With the `AdminCap`: allow `TSUI` and `SUI` quotes and the `cetus` and
`bluefin` witnesses. Negative: repeat each (`EAllowanceUnchanged`); create a sale with an
unlisted Quote (`EQuoteNotAllowed`) and, after delisting one witness, with that venue
(`EMigrationWitnessNotAllowed`), then relist it.

### Sale scenarios (Bluefin with TSUI unless noted)

**E2E-010 Open sale with a hard cap.** Open policy plus `uncapped_for_eligible(half the window)`
and `set_hard_cap(half the window, false)`. Before the phase: commits within caps; over cap aborts `EWalletCapExceeded`;
below minimum aborts `EBelowMinimumCommitment`; a new wallet past `max_participants` aborts
`EParticipantCapacityReached`; zero aborts `EZeroCommitment`; `commit_allowlisted` aborts
`EWrongEligibilityPolicy`. In the phase: a commit larger than what is left is partly accepted and
the excess comes back in the same transaction; a commit below the minimum that exactly fills the
raise is accepted; the next commit aborts `EPresaleFilled`. Settle, migrate, claim: tokens only,
zero refund, and the last claim takes the rounding remainder.

**E2E-011 Open sale with overflow, migrated to Cetus (SUI).** Caps sum to well over the raise; no
uncapped phase. Settle reports the refundable overflow. Commit after end aborts `EPresaleEnded`;
settle twice aborts `EInvalidLifecycle`. Cetus migrate with the coin types swapped aborts
`EInvalidCoinOrder`, with a wrong pair `EWrongCoinPair`. Claims: pro-rata tokens plus overflow
refund, one relayed by the relayer (payment still goes to the participant), a second claim aborts
`ENoCommitment`, a non-participant aborts `ENoCommitment`. `claim_migration_residuals` with the
`PresaleCap` (wrong cap aborts `EWrongPresaleCap`; second call aborts `ENoMigrationResiduals`).

**E2E-012 Allowlist with a hard cap, wallets topping up.** Merkle allowlist of tiered caps built
by the SDK, plus `uncapped_for_eligible(starts_after)` and `set_hard_cap(starts_after, false)`. Wallets commit in several steps
up to their cap. Aborts: wrong proof, wrong index, wrong cap, unlisted wallet
(`EInvalidEligibilityProof`); top-up quoting a different cap than the first commit
(`EInvalidEligibilityProof`); over cap (`EWalletCapExceeded`); `commit_open` and
`commit_uncapped` (`EWrongEligibilityPolicy`, `EUncappedPhaseNotOpen`). In the phase, listed
wallets exceed their caps up to the hard cap. Migrate and claim.

**E2E-013 Allowlist that opens to anyone after a deadline.** Allowlist plus
`uncapped_for_anyone(starts_after, max_participants, min)` and no hard cap. Before the phase an
unlisted wallet's `commit_uncapped` aborts `EUncappedPhaseNotOpen`; after it, unlisted wallets
commit at least the minimum (below aborts `EBelowMinimumCommitment`) up to the phase's participant
bound (`EParticipantCapacityReached`). Ends in overflow; claims at one common fill rate.

**E2E-014 Scheduled start and per-sale fee update.** Share with `start_ms` ahead of now. Commits
before the start abort `EPresaleNotStarted`. `set_protocol_fees` before the start changes all four
rates: check `ProtocolFeesChanged` amounts against `token_allocation` and the LP Quote; the same
rates again abort `EProtocolFeesUnchanged`; a raise share leaving the LP nothing aborts
`EInvalidRaiseAllocation`; after the start it aborts `EPresaleStarted`. Migrate and check
`ProtocolFeesPaid` against the updated rates.

**E2E-015 Global fee policy and destination.** `set_fees` to nonzero rates (unchanged aborts
`EFeesUnchanged`; raise 10,000 or token above 9,998 aborts `EInvalidFees`). A sale created before
keeps its snapshot; one created after takes the new rates. `set_destination` to the fee wallet
(zero or same address aborts `EInvalidDestination`); both sales then pay the new destination at
migration and fee collection.

**E2E-016 Underfunded sale.** Raise not reached. Settle cancels it; every participant claims a
full refund and no tokens (one claim relayed). `destroy_cap` succeeds (with another sale's cap it
aborts `EWrongPresaleCap`); migrate aborts `EInvalidLifecycle`. The supply stays locked and the
`Currency` stays sealed.

**E2E-017 Funded but never migrated (seven-day wait).** Start this first. Fund, settle, do not
migrate. Before the deadline `cancel_unlaunched` aborts `ELiquidityDeadlineNotReached`; after it,
anyone cancels, everyone gets a full refund, and migrating then aborts `EInvalidLifecycle`.

**E2E-018 Vesting.** Token recipients and raise recipients, some vested (30 s cliff, 30 s period,
4 periods) and some paid at once. Migration shares one vesting schedule per vested share and emits
its ID. Claim from each schedule before the cliff (nothing), at each step, and after the end
(everything); the unvested shares arrive in the migration transaction. Invalid terms abort
`EInvalidVestingTerms` at construction.

**E2E-019 Bluefin specifics.** Migrating with the wrong creation fee fails in Bluefin; with a
sale configured for Cetus, `bluefin::migrate` aborts `EWrongMigrationWitness`; collecting from a
different pool aborts `EPositionPoolMismatch`. A 33-byte symbol aborts `ESymbolTooLong` and a bad
tier `EInvalidTier` at creation. The migrator becomes Bluefin pool manager (ADR 0088).

### After migration

**E2E-020 Swaps and LP-fee split.** Large round-trip swaps on the E2E-010 Bluefin pool (TSUI is
free to mint) and modest ones on the E2E-011 Cetus pool. The relayer calls `collect_fees`. Check:
Blast's share rounded up to the destination; each fee recipient paid by largest remainder; the
holder share kept in the vault; collecting again with no new fees moves nothing and emits nothing.

**E2E-021 Vault LP-fee rates.** `set_protocol_lp_fees` mid-life (unchanged aborts
`EProtocolLpFeesUnchanged`); fees accrued before the change are split at the new rates when
collected, and the creator's split of the rest is unchanged.

**E2E-022 Holder rewards.** Publish round 0 from the vault's holder share with an SDK-built root;
beneficiaries claim, one relayed; double claim aborts `EAlreadyClaimed`; bad proof `EInvalidProof`;
index out of range `EInvalidIndex`. Publishing round 0 again aborts `EWrongRound`, a gap in
checkpoints `EInvalidInterval`, a past deadline `EInvalidClaimDeadline`. Closing before the
deadline aborts `EClaimsStillOpen`; after it, anyone closes and the remainder returns to the vault.

**E2E-023 Admin authority (D4).** `replace_admin_cap` with the `SuperAdminCap`; the old cap then
aborts `EInvalidAdminCap` on any admin call; `revoke_admin_cap` stops all admin calls; a second
revoke aborts `ENoAdminCap`; replace again to restore. Record the final `AdminCap` ID.

**E2E-024 Creation validation.** One transaction per rule, each expected to abort: same type for
token and Quote (`EInvalidAssetPair`), minted supply (`EInitialSupplyNotZero`), zero raise,
allocations not totalling 10,000 BPS, duplicate or zero recipients, more than 16 fee recipients,
vested fee share, LP window under seven days, unreachable open raise, unseedable price, uncapped
phase outside the window.

**E2E-025 Delisting does not strand live sales.** Delist `TSUI` while E2E-013 is open; it still
commits, settles, migrates, and collects. New `TSUI` sales abort `EQuoteNotAllowed`.

**E2E-027 Open-to-anyone phase under a hard cap, Bluefin with real SUI.** Two SUI-quoted
Bluefin sales (the launch configuration): an open policy and an allowlist, each with an
open-to-anyone phase under a hard cap. New wallets commit at the phase minimum; the commit
that fills the raise is partly accepted and its excess returned; the next is refused.

**E2E-028 Holder rewards on a Cetus vault.** A round on the E2E-011 vault (SUI), funded from
its LP fees: one claim paid, a double claim refused, the unclaimed rest returned on close.

**E2E-029 Holder-reward distribution algorithm.** Real holding history on the E2E-027 vault (a
transfer, a buy, a sell), replayed checkpoint by checkpoint through the SDK ledger from the
token's registration, weighted from vault creation, cross-checked against an independent
replay of the token's transactions, then allocated, published, and paid to every holder.

### Close-out

**E2E-030 Teardown and record.** Delist `TSUI`; restore the launch fee rates and destination;
write the evidence summary; send blast-infra the package's real migration-era events (T-043
currently hand-encodes them) and the list of test sale IDs to hide.

## Order

E2E-001 → 002 → 003 → decisions D1–D5 → 004 → 017 (starts the seven-day clock) → 010–016,
018–019 in any order → 020–022 on migrated sales → 025 → 023 → 024 → 030.
