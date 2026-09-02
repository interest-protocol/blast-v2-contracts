# 0012: Flywheel feature dispositions

- Status: proposed
- Date: 2026-08-22
- Amended by: [0041](0041-launch-config-owned-trade-fees.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `cetus@ddfbdeb` | `ddfbdeba174319998b012de876ab7ec23c3ab0bc` | CetusProtocol/cetus-contracts |
| `bluefin@91ce930` | `91ce930575b2aa3decab9b7e129b8002deba80c1` | fireflyprotocol/bluefin-spot-contract-interface |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |

Market context for current launchpad fee mechanics is **secondary-source** — 2026 trade coverage of
Pump.fun's dynamic-fee and creator-fee-sharing changes, read 2026-08-22. It is labelled as such wherever
used, and no contract-side claim below rests on it. Every feasibility claim cites a pinned repository.

## Context

`../engineering-principles.md` gives complexity a budget: no mode, role, setter, adapter, or abstraction
without the invariant or product requirement it serves. This ADR ranks candidate growth features and
disposes of each. A feature with no measurable metric, or one requiring unbounded state, is **rejected**,
not deferred.

## Decision

| # | Feature | Mechanism | Metric | Abuse case | Complexity | Disposition |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Creator LP fee stream | `LpVault` holds the venue position; fees collected via `pool::collect_fee` (`bluefin@91ce930:sources/pool.move:593`) and venue equivalents, split to creator and protocol | creator fee revenue per graduated launch; share of creators returning for a second launch | creator wash-trades their own pool to farm fees they partly fund — bounded, since they pay the full swap fee to earn a fraction | **low** — the vault already exists in [ADR 0010](0010-migration-and-venue-adapters.md) | **accept** |
| 2 | Bounded fee-sharing splits | `CreatorCap` holder assigns fractions across a bounded recipient set | fraction of launches using a split; recipient count distribution | none material; the split only divides what the creator already earns | **low** if bounded | **defer** — ADR 0022 ships one transferable authority and composable claims first |
| 3 | Quote-asset diversity as distribution | candidate quote types are decided at the launch boundary | launches per distinct quote type; share of launches with a non-default quote | a project launches against an illiquid quote it controls, making graduation price meaningless | **not yet bounded** | **defer** — ADR 0023 reopens quote admission and rejects regulated/legacy support as an assumed default |
| 4 | Graduation-linked dynamic fee | would reuse the progress ramp already derived for sell-side burn ([ADR 0003](0003-treasury-cap-lifetime-and-burn.md)) | fee revenue per launch versus flat fee; completion rate of launches reaching threshold | timing trades around the ramp and obscuring the configured launch rate | **low**, but multiplies fee-vector states | **reject for initial launchpad** — fixed admin-configured Quote/Meme rates are auditable; revisit only in a separate accepted fee-policy ADR |
| 5 | RevShare campaigns | [ADR 0009](0009-referrals-and-revshare.md) epoch settlement, with campaigns defined off-chain | claimed fraction per epoch; referred volume per campaign | sybil at the attribution layer, addressed by session-bound attribution and the challenge window, **not** by the Merkle root | **medium** — a separate package already specified | **accept**, gated on the attribution service being operable |
| 6 | Creator-configurable curve parameters | let creators pick `V`, `T`, or `MAX_BURN_BPS` per launch | — | a creator picks parameters that make the curve trivially exploitable for insiders | **medium** — every vector becomes per-launch, and differential testing multiplies | **reject for now**; revisit only with a bounded parameter lattice and per-cell vectors |
| 7 | On-chain leaderboards or holder counts | maintain rankings or holder sets in contract state | — | trivially gamed by splitting addresses | **high** — an unbounded persistent collection, prohibited by `../../AGENTS.md` | **reject** — belongs in the indexer, which already has the data from [ADR 0011](0011-event-schema-and-replay.md) |
| 8 | Auto-buyback from protocol fees | route a share of accrued fees into buying the meme on the graduated pool | — | sandwiching a predictable protocol buy | **medium-high** — puts the protocol on the taker side of a venue it does not control, adding a venue dependency to the fee path | **reject for now**; the mechanism is plausible but unspecified here, and it needs its own ADR and threat model before any claim is made about it |
| 9 | Per-launch `Display` cards | `Display<Launch<M,Q>>` per instantiation | — | none | **medium** — one shared object and one cap per launch, forever; depends on premise **P12** | **reject for now** — D-opt2 in [ADR 0001](0001-sui-package-and-module-layout.md); revisit as D-opt3 at migration only |
| 10 | Creator token allocation with vesting | reserve a share of supply for the creator on a schedule | — | an allocation obtained below market price is an unpriced transfer from later buyers | **medium** — a whole vesting subsystem | **reject for now**; [ADR 0006](0006-fees-and-launch-paths.md) B2 gives creators the same exposure at the honest price |

### Invariants each accepted feature must not break

The accepted LP fee feature carries a full authority row, bound and event in
[ADR 0007](0007-acl-pause-and-versioning.md) (`collect LP fees`) and reducer coverage in
[ADR 0011](0011-event-schema-and-replay.md) (`LpFeesCollected`). It does not ship without them.

| Feature | Must not break |
| --- | --- |
| 1 Creator LP fee stream | LP position stays locked; fee collection cannot withdraw principal; no path returns the position to an EOA; each adapter aborts unless principal is unchanged and `LpFeesCollected.principal_liquidity` records the verified final value |
| 2 Fee-sharing splits | deferred until a separate allocation module fixes its recipient bound, share conservation, rounding, and update lifecycle |
| 3 Quote diversity | pair immutability; risk snapshot immutability |
| 5 RevShare campaigns | `MAX_EPOCH_LEAVES`, `MAX_EPOCH_FUNDED`, `MAX_OPEN_EPOCHS`; funding conservation |

## Alternatives considered

**Accept everything and gate by configuration.** Rejected: a shipped-but-disabled mechanism is still
public bytecode with a permanent ABI, and on Sui old versions remain callable.

**Defer all growth features until after launch.** Rejected: features 1 and 3 cost nothing extra because
the mechanisms already exist for other reasons, and declining them would waste work already specified.

**Adopt the market's dynamic-fee design directly.** Rejected as a basis for a contract decision: the
evidence is secondary-source trade reporting, sufficient for product context and insufficient for an
economic commitment. Feature 4 instead reuses a mechanism Blast has already derived and vectored.

## Consequences

- Four features ship with the core because their mechanisms already exist; one ships subject to an
  operational gate.
- Five are rejected with reasons that name the invariant or cost driving the rejection, so a future
  proposal starts from a stated bar rather than from scratch.
- Any future fee-recipient bound and the dynamic-fee ramp constants require separate approval.

## Verification

- Feature 1: LP-lock test — no path transfers the position out of `LpVault`; fee collection leaves
  principal unchanged; collection before migration aborts `ENotMigrated`; collection without the
  `CreatorCap` aborts `ENotAuthorized`; the `LpFeesCollected` reducer reconciles with vault balances.
- Feature 2: deferred; ADR 0022 tests the global configurable protocol/creator split and composable
  cap-holder claim that ship in the initial ledger.
- Feature 3: deferred until the initial quote admission rule is accepted with launch state.
- Feature 4: ramp tests at every boundary, plus a ceiling test at maximum progress.
- Feature 5: covered by [ADR 0009](0009-referrals-and-revshare.md) tests.
- Rejected features: an inventory test asserting no public function implements them, so a rejection is
  enforced rather than remembered.
