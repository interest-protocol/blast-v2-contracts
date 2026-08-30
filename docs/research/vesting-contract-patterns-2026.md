# Vesting contract patterns, 2026

Reviewed on 2026-08-29. This review selects a small Blast vesting primitive. It
does not copy another protocol's product surface.

## References

| Reference | Relevant behavior | Blast disposition |
| --- | --- | --- |
| [Squads V4](https://github.com/Squads-Protocol/v4) | Multisig execution, transaction timelocks, spending limits, roles, and treasury subaccounts. It is an administration primitive, not a token vesting schedule. | A Squads-controlled address can hold a cap. Vesting math must not depend on Squads. |
| [Historical Memez vesting](https://github.com/interest-protocol/memez-gg/tree/00596fdac4dd11f427c7bc594e566ce36160db93/vesting) | One fully funded linear schedule with `start` and `duration`; separate transferable and fixed-owner object forms. | Keep full funding, balance custody, released accounting, and integer linear math. Replace duplicate forms, transferable-beneficiary semantics, and missing cliff, cadence, and cancellation policy. |
| [Raydium LaunchLab CPI state](https://github.com/raydium-io/raydium-cpi/blob/115df2779d53bacc7db9d0be2773a4b48a6d372b/programs/launch-cpi/src/states.rs#L202-L218) | Launch vesting records total locked amount, cliff period, unlock period, start time, and allocated amount. | Adopt explicit start, cliff, and release cadence. Derive total from custody instead of storing it twice. |
| [Solana Foundation rewards](https://github.com/solana-foundation/rewards/blob/20522ed0bf7a514fcd50f872de90179e0dbbefe6/program/src/utils/vesting_utils.rs#L7-L63) | Immediate, linear, cliff, and cliff-linear schedules. Optional revocation distinguishes return of nonvested tokens from a full clawback. | Ship one cliff-plus-stepped-linear shape. Cancellation preserves vested beneficiary value and returns only unvested value. Reject full clawback. |
| [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui/1.x/vesting-wallet) | Shared, permissionless release to a fixed beneficiary; start, cliff, period, and steps; capability-gated teardown. The July 2026 audit index includes its vesting wallet review. | Adopt the schedule parameters, fixed payout target, permissionless claim, overflow checks, and final remainder release. Keep Blast's implementation focused and dependency-free. |
| [Streamflow vesting](https://docs.streamflow.finance/en/articles/9670413-create-a-vesting-contract) | Product support for initial allocations, cliffs, periodic unlocks, cancellation, recipient changes, batch creation, auto-claim, and tradable contracts. | Treat initial allocation plus linear release as composition, not a new schedule. Keep auto-claim and batching in transaction tooling. Do not add transferability by default. |
| [Hedgey vesting plans](https://hedgey.gitbook.io/hedgey-community-docs/hedgey/vesting-plans) | Linear and periodic schedules with optional revocation, transfer administration, partial claims, and governance delegation. | Keep schedule math independent of governance. Consider a separate governance-bearing position only if a Blast governance system requires locked voting power. |
| [Sablier Lockup v4](https://blog.sablier.com/introducing-vcas-and-lockup-v4-0) | Linear schedules now accept a granularity parameter for fixed-period unlocks; price-gated schedules use oracle inputs. Earlier tranched and dynamic models support irregular checkpoints and nonlinear curves. | The current Blast `linear` parameters already cover fixed-period unlocks. Add checkpoints only for real irregular allocations. Reject oracle-priced and arbitrary-curve vesting until a concrete protocol invariant requires them. |

## Proposed Blast surface

Each schedule is fully funded at creation and contains one coin type. The fixed
parameters are:

- `beneficiary`: the only payout address;
- `start_ms`: the schedule origin;
- `cliff_ms`: the no-release interval measured from `start_ms`;
- `period_ms`: the release cadence;
- `periods`: the number of equal tranches; and
- optional cancellation with a fixed `refund_recipient` and a schedule-bound
  `CancelCap`.

The standard constructors reject a `start_ms` earlier than the current Sui
`Clock`. Offchain tooling mirrors that invariant and warns about transaction
latency; retroactive migrations remain a separate product decision.

The cliff gates the accrued schedule; it does not move the end. At the cliff,
all complete periods since `start_ms` become claimable. Intermediate tranche
calculations round down. The final boundary releases every remaining atomic
unit.

The default is irrevocable. Cancellable schedules support contributor and
service-provider grants. Cancellation pays all vested-and-unclaimed value to
the beneficiary and returns only unvested value. A transferable beneficiary,
full clawback, administrator pause, arbitrary curve, oracle or milestone
trigger, late deposit, and onchain recipient batch are separate products.

## Future module boundary

Keep one `blast_fun_vesting` package. Its first module is `linear`. Calendar
presets such as single unlock, daily, monthly, quarterly, continuous-like,
cliff-linear, and TGE-plus-linear do not require new modules. Constructors and
SDK builders can express them with the existing primitive or with an immediate
transfer plus one schedule.

The second schedule module is `checkpoints`. Callers append increasing absolute
timestamps and cumulative atomic amounts to a linear `Schedule` builder, then
consume it in a vesting constructor. The schedule stores up to 256 entries in an
inline vector and uses binary search for claims. This supports unequal tranches,
multiple cliffs, and irregular token-sale schedules without arbitrary curve
math. Offchain tooling reads the complete bounded vector from canonical object
content and may page it locally.

Keep these outside the vesting package unless a concrete product requires them:

- `merkle_distribution`: lazy creation or claiming for large recipient sets;
- `stream`: mutable, top-up payroll with recipient or position transfer;
- `milestone_escrow`: release authorized by an attestor or dispute process;
- `voting_escrow`: locked-token governance and delegation; and
- `oracle_vesting`: price- or performance-gated release.

These models change distribution, mutability, authority, governance, or oracle
trust. They are not merely vesting schedule shapes and should not enlarge the
audited linear primitive.

## Consensus boundary

Custody, schedule authorization, time-gated release, cancellation settlement,
and released-balance conservation require consensus. Claim previews, end-time
display, calendar formatting, schedule aggregation, and batch transaction
construction are deterministic SDK work.
