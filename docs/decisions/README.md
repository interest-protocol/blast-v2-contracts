# Architecture decision records

Use ADRs for decisions that create durable protocol, authority, storage, ABI, upgrade, dependency,
deployment, or cross-chain commitments.

Name files `NNNN-short-title.md` and use this template:

```markdown
# NNNN: Title

- Status: proposed | accepted | superseded
- Date: YYYY-MM-DD

## Context

What decision is required, including threats, invariants, and constraints.

## Decision

The precise behavior, bounds, authority, and chain-specific mapping.

## Alternatives considered

The serious alternatives and why they were not selected.

## Consequences

Security, composability, operations, upgrades, indexing, and testing impact.

## Verification

Tests, shared vectors, deployment checks, and review evidence required.
```

An ADR records a decision; it does not replace executable invariants or tests.

## Citation rule

Every ADR must cite external ABI facts at an immutable repository revision and
path. A claim that cannot be pinned must be a **named premise with a
falsification test**, never an assertion.

Each ADR carries a `## Sources` table mapping the short refs it uses to full commit hashes.

## Retired records

On 2026-11-05 the owner chose a greenfield start for the launch stack: ADRs whose decisions were
fully superseded (by ADR 0137 and its 2026-11-05 amendment, or by a later ADR) or that described
deleted code were removed. A kept record may still name a retired ADR number in its history; read
that record in Git history, for example `git show 88951fe9:docs/decisions/` lists the files before
the cleanup. The deployment records of the retired lineages went at the same time.

Start with [0137](0137-shared-launch-stack-core-vault-and-venues.md) for the launch stack; the
records below it decide what 0137 does not restate.

## Index

| ADR | Title | Status |
| --- | --- | --- |
| [0004](0004-bonding-curve.md) | Constant-product bonding curve | proposed |
| [0021](0021-pure-constant-product-curve-quotes.md) | Pure constant-product curve quotes | **accepted** |
| [0022](0022-dual-asset-fee-ledger-and-claims.md) | Dual-asset fee ledger and capability claims | **accepted; amended by 0088, 0098, and 0105** |
| [0023](0023-generated-coin-supply-and-metadata-custody.md) | Generated coin supply and metadata custody | **accepted** |
| [0024](0024-generated-coin-launch-ticket.md) | Generated coin launch ticket | **accepted** |
| [0026](0026-deferred-sell-burn.md) | Deferred sell burn custody | **accepted** |
| [0028](0028-hot-cold-runtime-configuration.md) | Hot/cold runtime configuration consolidation | **accepted** |
| [0038](0038-standard-method-names.md) | Standard method names for reads, conversions, and wrapper destruction | **accepted** |
| [0041](0041-launch-config-owned-trade-fees.md) | LaunchConfig-owned trade fees | **accepted** |
| [0042](0042-key-only-shared-launch.md) | Key-only shared launch publication | **accepted; amended by 0088** |
| [0047](0047-coin-registry-authoritative-supply-mode.md) | Coin Registry authoritative supply mode | **accepted; supply-mode timing amended by 0088** |
| [0048](0048-sui-package-workspace.md) | Sui package workspace | **accepted** |
| [0051](0051-generated-meme-package-template.md) | Generated Meme package template | **accepted; publish-time immutability amended by 0088; package renamed by 0108** |
| [0053](0053-single-validator-funsui-and-blastsui.md) | Single-validator `funSUI` and `blastSUI` | **accepted; authority and receipt `DisplayCap` custody amended by 0060, 0061, and 0097** |
| [0056](0056-bounded-pending-stake-vector.md) | Bounded pending-stake vector in custody ledgers | **accepted** |
| [0058](0058-eventless-package-initialization.md) | Eventless package initialization | **accepted** |
| [0060](0060-blastsui-metadata-cap-custody.md) | Retain currency and receipt update capabilities in package-admin custody | **accepted** |
| [0061](0061-blastsui-routine-admin-and-composable-package-custody.md) | Routine administration and composable package custody for blastSUI | **accepted** |
| [0064](0064-aftermath-backed-leverage-coins.md) | Aftermath-backed `SUI2L` and `SUI2S` leverage coins | proposed |
| [0065](0065-discoverable-blastsui-treasury-caps.md) | Discoverable blastSUI treasury-cap custody | **accepted** |
| [0070](0070-series-one-versioning-and-role-administration.md) | Series1 operational version and role administration | **superseded** |
| [0071](0071-series-one-vault-issuance.md) | Series1 Vault and dynamic share-currency issuance | **superseded** |
| [0072](0072-series-one-package-capability-custody.md) | Series1 package-capability custody | **superseded** |
| [0073](0073-series-one-adapter-owned-vaults.md) | Series1 core with adapter-owned product Vaults | **accepted** |
| [0074](0074-aftermath-vault-activation-and-health.md) | Aftermath Vault activation and health evidence | **accepted for dependency and raw-field normalization** |
| [0076](0076-native-v2-and-auto-lp.md) | Native V2 and automatic liquidity deposits | **accepted; native DEX parked in `scratch-sui/`; auto-LP now lives in the vault and venues (0137)** |
| [0077](0077-fixed-creator-selected-sell-burn.md) | Fixed creator-selected sell burn | **accepted** |
| [0079](0079-compact-launch-state-and-events.md) | Compact launch state and events before publication | **accepted; amended by 0088** |
| [0080](0080-provider-independent-creator-recipient.md) | Provider-independent creator recipients | **accepted** |
| [0082](0082-revocable-creator-and-lp-fee-capabilities.md) | Revocable curve-fee, metadata, and LP-fee capabilities | **accepted; LP-fee authority superseded by 0088; amended by 0097** |
| [0084](0084-leverage-coin-design-after-perpsplexity-review.md) | Leverage coin design after the Perpsplexity review | proposed |
| [0085](0085-explorer-visible-type-naming.md) | Explorer-visible type naming: every on-chain type names Blast | **accepted** |
| [0086](0086-maintenance-reserve-ceiling.md) | Maintenance reserve ceiling: `max_reserve_bps` of notional, clamped credits, priced-after-release, no admin release | **accepted** |
| [0087](0087-vault-issuance-activated-in-one-transaction.md) | Vault issuance activated in one transaction: `issue` returns a hot-potato issuance, `initialize` returns the Vault, no optional activation fields | **accepted** |
| [0088](0088-reusable-launch-accounting-and-atomic-migration.md) | Reusable launch accounting and atomic migration | **accepted; amended by 0090, 0093, and 0137** |
| [0090](0090-minimal-launchpad-surface.md) | A minimal launchpad surface | **accepted; amended by 0092 and 0093** |
| [0091](0091-fee-split-buyback-and-burn.md) | A burn part in the LP-fee split, bought back by a buyback administrator | **accepted; amended by 0100; amended in place 2026-10-27: buybacks spend an administrator-chosen amount** |
| [0092](0092-creator-picks-the-virtual-quote.md) | The creator picks the virtual Quote reserve; launch config only admits Quotes | **accepted** |
| [0093](0093-optional-opening-round.md) | An optional opening round replaces purchase protection | **accepted** |
| [0095](0095-partner-codes.md) | Partner codes in one immutable package: a share of Blast's fee paid to the named partner on every trade, with a forced seven-day delay on Blast's powers | proposed; amended by 0098, 0106, 0134, and 0137 |
| [0097](0097-one-singleton-acl-with-typed-roles.md) | One singleton ACL with typed roles | **proposed; amended in place 2026-10-02: Publisher read, witness-seeded versions, publication-record gate; amended by 0137** |
| [0098](0098-launch-creation-fee-and-partners.md) | One partner per launch shares the launch's creation, curve, and one-time Meme/Quote migration fees | **accepted; amended by 0105 and 0137** |
| [0099](0099-standalone-overflow-presale.md) | Standalone overflow presales with per-sale caps, proportional fills, LP-gated claims, and refund liveness | **accepted; amended by 0102, 0104, 0110, and 0137** |
| [0100](0100-single-cetus-route-with-checked-retype.md) | One Cetus route per operation, generic over the pool's coin order, with a checked dynamic-field retype | **accepted** |
| [0102](0102-presale-creation-allowlists.md) | Admin-set allowlists of the Quote types and migration witnesses new presales may use | **proposed; amended by 0104 and 0106** |
| [0103](0103-mainnet-only.md) | Mainnet only: no testnet builds, pins, scripts, harness environment, or rehearsals | **accepted** |
| [0104](0104-external-presale-migrators-and-vendor-packages.md) | Public presale creation and migration for external migrators; partner one-off packages under `sui/vendors` | **proposed; amended by 0110; amended by 0137** |
| [0105](0105-permissionless-launch-fee-claims.md) | Permissionless launch fee claims paying the partner and a `RuntimeConfig` treasury the `TreasuryAdmin` rotates | **proposed** |
| [0106](0106-presale-partners.md) | One partner per presale, named at creation, earns a share of Blast's raise share, paid permissionlessly after migration | **proposed; amended by 0110 and 0137** |
| [0108](0108-standalone-coin-template.md) | A standalone coin template with creator-chosen supply, supply mode, and capability recipients; `meme_template` becomes `launch_ticket_template` | **proposed** |
| [0110](0110-presale-initializer-and-early-close.md) | Presales are created through a `PresaleInitializer` hot potato; the hard cap is a sale setting independent of the uncapped phase, and a sale whose hard cap closes it when filled settles as soon as its raise is full | **proposed; amended by 0137** |
| [0112](0112-daily-holder-reward-intervals.md) | Daily holder-reward intervals | **accepted** |
| [0115](0115-venue-policy-from-the-bound-clearing-house.md) | Venue policy read live from the bound clearing house: margin ratios, pause, freeze and oracle routing are venue facts; account checkpoints and lot size stay exact | **accepted** |
| [0118](0118-limit-priced-vault-orders-and-a-widening-unwind-bound.md) | Limit-priced vault orders and a widening unwind bound | **proposed** |
| [0119](0119-execution-priced-order-caps-and-minimum-lot-closes.md) | Execution-priced order caps and minimum-lot closes | **accepted** |
| [0120](0120-priority-gas-for-emergency-reductions-and-unwind.md) | Priority gas for emergency reductions and unwind | **accepted** |
| [0121](0121-reviewed-recovery-after-a-forced-venue-reduction.md) | Reviewed recovery after a forced venue reduction | **accepted** |
| [0122](0122-bounded-profit-realization-before-redemption.md) | Bounded profit realization before redemption | **accepted** |
| [0123](0123-successor-activated-boosts-upgrades.md) | Successor-activated Boosts upgrades | **accepted** |
| [0124](0124-margin-recovery-and-initial-headroom.md) | Margin recovery and initial headroom | **accepted** |
| [0125](0125-small-vault-recovery-within-the-band.md) | Small-vault recovery within the band | **accepted** |
| [0126](0126-capacity-aware-rebalance-progress.md) | Capacity-aware rebalance progress | **accepted** |
| [0127](0127-emergency-rebalance-mark-divergence.md) | Emergency rebalance admission during mark divergence | **accepted** |
| [0128](0128-reserve-aware-rebalance-increases.md) | Reserve-aware rebalance increases | **accepted** |
| [0129](0129-reserve-consistent-emergency-reductions.md) | Reserve-consistent reductions and emergency exposure progress | **accepted** |
| [0130](0130-protected-permissionless-shutdown.md) | Protected permissionless shutdown of a size-locked Boost | **accepted** |
| [0131](0131-funding-consistent-rebalance-preview.md) | Funding-consistent rebalance preview | **accepted** |
| [0132](0132-closed-market-funding-accounting.md) | Book funding settled inside a closed-market unwind | **accepted** |
| [0133](0133-required-order-fill-proof.md) | Require consumption of every order fill receipt | **accepted** |
| [0134](0134-delayed-administration-pause-and-table-acl.md) | Delayed administration, pause, and a Table-backed ACL | proposed; amended by 0137 |
| [0137](0137-shared-launch-stack-core-vault-and-venues.md) | Shared launch stack: core, vault, and venues | proposed; amended 2026-11-05: seven packages, one `blast_migrators` venue package (Cetus and Bluefin) in place of `blast_venues`, the Aftermath DAO vendor as a plain venue, two-call migration, standalone vaults cut, one package witness and one package administration, no repair or policy narrowing, vault immutable after audit; amended by 0138 (sealed treasury caps) |
| [0138](0138-sealed-treasury-caps-and-venue-admissions.md) | Sealed treasury caps and venue admissions | proposed |
| [0139](0139-admin-bounded-auto-lp-compounding.md) | Admin-bounded auto-LP compounding | accepted |
| [0140](0140-upgrade-cap-manager.md) | Digest-bound upgrades and immutability with a fixed 48-hour notice | accepted |

## Open premises

These ADRs depend on facts that require a live external-integration check. Each is named in the ADR
that depends on it, with a falsification test, and none is treated as established until that test
passes.

| Premise | Question | Owning ADR |
| --- | --- | --- |
| P15 | Can every supported login return an immutable provider subject that the backend securely maps to exactly one Blast account without email-based auto-linking? | [0080](0080-provider-independent-creator-recipient.md) |
| P16 | Does the deployed Aftermath ABI support the complete same-transaction account, cap-custody, and session flow? | [0064](0064-aftermath-backed-leverage-coins.md) |
| P17 | Can the adapter reproduce Aftermath equity, signed fixed-point rounding, and each exact funding settlement in atomic USDC? | [0064](0064-aftermath-backed-leverage-coins.md) |
| P18 | Does the custom position IMR remain an effective floor through market changes and liquidation? | [0064](0064-aftermath-backed-leverage-coins.md) |
| P19 | Does the minimum external checkpoint detect every material liquidation, ADL, settlement, order, and collateral mutation? | [0064](0064-aftermath-backed-leverage-coins.md) |
| P20 | Which risk-reduction and settlement operations remain live in every Aftermath pause, freeze, stale-oracle, and settlement mode? | [0064](0064-aftermath-backed-leverage-coins.md) |

## Consolidated utility packages

| ADR | Decision | Status |
| --- | --- | --- |
| [0052](0052-stepped-linear-vesting.md) | Stepped-linear vesting | accepted |
| [0055](0055-global-vesting-package-and-checkpoints.md) | Global vesting package and checkpoints | accepted |
| [0135](0135-utility-contracts-consolidation.md) | Utility contracts consolidation | accepted |
