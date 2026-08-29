# `su` package house style for Blast Sui Move

Status: canonical implementation-style research; error, event-wrapper, and constants guidance applied 2026-08-23
Reviewed: 2026-08-23
Primary source: [`interest-protocol/su-lending@a3552af11a531717378b6337a174f9340d1099dc`](https://github.com/interest-protocol/su-lending/tree/a3552af11a531717378b6337a174f9340d1099dc)
Scope: [`packages/su`](https://github.com/interest-protocol/su-lending/tree/a3552af11a531717378b6337a174f9340d1099dc/packages/su), its first-party tests, and the repository configuration/docs that define how that package is maintained

The reviewed SHA is the commit currently reached by the repository's `main` branch. All external links
below are immutable permalinks to that SHA. Blast source comparisons refer to the current local files and
must be rechecked after implementation changes.

## Executive alignment rules

These are the high-confidence `su` patterns Blast should treat as its Move house style:

1. **The diagnostic `errors` module returns codes; it does not perform assertions.** Define each
   package-wide protocol error as `macro public(package) fun name(): u64 { N }`. Put the corresponding
   `assert!(condition, errors::name!())` or `abort errors::name!()` at the invariant's owning source
   location. `su::errors` contains neither `const E...` declarations nor `assert_*` wrappers
   ([source](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/errors.move#L1-L183)).
   Blast deliberately adds Memez-style `#[test_only]` named copies of the numbers for its source/test
   registry; they are not production constants and do not change the caller-local macro pattern.
2. **Domain assertion helpers are different from error wrappers.** A receiver-owned helper is appropriate
   when it encapsulates private domain state: `MarketCap.assert_market`, `AdminWitness.assert_has_role`,
   `InterestRateModel.assert_kinked`, and `Market.assert_operational` are examples
   ([market authority](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market_authority.move#L30-L42),
   [ACL](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_acl.move#L178-L203),
   [IRM](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/irm.move#L121-L164),
   [market](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L1005-L1051)).
   A helper that merely receives a precomputed `bool` and hides an error code belongs nowhere.
3. **Use receiver-style dot syntax for natural receivers.** State transitions read as
   `market.supply(...)`, `cap.assert_market(market.id())`, `clock.timestamp_ms()`, and
   `coin.into_balance()`. Constructors and operations without a natural receiver stay module-qualified.
   Add a `public use fun ... as Type.method` alias only when it materially improves the external API
   ([oracle alias](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_oracle.move#L162-L179),
   [cap aliases](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market_authority.move#L17-L38)).
4. **Split diagnostics from state logic.** Event schemas and package-only emitters live in `events.move`;
   call sites mutate first and then call a small named emitter. Error-code assignment lives in
   `errors.move`; call sites own guard ordering
   ([event types and snapshots](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/events.move#L7-L359),
   [emitters](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/events.move#L360-L759)).
5. **Capabilities express authority and bind only to the domain they govern.** `AdminCap` contains only
   its `UID`; revocability comes from the shared ACL registry. The per-market `MarketCap` carries market
   and oracle IDs because it intentionally governs exactly those two objects
   ([ACL types](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_acl.move#L8-L26),
   [market authority](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market_authority.move#L7-L42)).
6. **Fail cheap and preserve deterministic abort precedence.** Operational/lock/version/pause guards
   come first, followed by zero/bounds/liquidity/identity checks, then accrual or price work, then
   transition math, mutation, event emission, and returned assets. Dedicated tests pin that order
   ([market call sites](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L310-L593),
   [guard-order tests](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/tests/market_guard_tests.move#L458-L871)).
7. **Return composable owned values.** Market/oracle/cap constructors return their objects; sharing and
   transfer are explicit separate operations except for deliberate package initialization delivery
   ([market constructor](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L163-L232),
   [ACL initialization and admin constructor](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_acl.move#L28-L69)).
8. **Keep production visibility narrow and testing visibility explicit.** Cross-module internals are
   `public(package)`; private helpers are unqualified `fun`; test constructors, field snapshots, and
   mutation hooks are placed under `// === Test-Only Functions ===` and annotated `#[test_only]`
   ([IRM test API](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/irm.move#L275-L305),
   [market test API](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L1107-L1194)).
9. **Bound persistent collections and the loops they drive.** `Oracle.feeds` is capped at eight and the
   optional liquidator set at 256; duplicate inserts do not consume capacity
   ([oracle bound](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_oracle.move#L13-L15),
   [oracle insertion](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_oracle.move#L181-L201),
   [market bound](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L65-L72),
   [market insertion](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L276-L303)).
10. **Keep the core dependency-free.** The `su` manifest has no declared external dependency; the Pyth
    adapter is a separate package that depends inward on core. The lockfile pins the framework revisions
    used for each environment
    ([manifest](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/Move.toml#L1-L10),
    [lockfile](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/Move.lock#L1-L41),
    [repository package map](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/AGENTS.md#L3-L30)).
11. **Centralize protocol constants and reuse the pinned standard library.** `su::constants` exposes
    package-wide values as lower-snake-case `macro public(package)` accessors rather than redeclaring
    them in state modules. Blast must also check its pinned MoveStdlib before adding primitive bounds or
    utility code: integer modules already provide `max_value!`, `min`, `max`, `checked_*`, `div_ceil`,
    `mul_div`, and bounded iteration macros, while `vector` provides traversal, mapping, filtering,
    search, fold, and predicate macros
    ([`su::constants`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/constants.move#L1-L27),
    [pinned `u64`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/move-stdlib/sources/u64.move),
    [pinned `vector`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/move-stdlib/sources/vector.move)).

## Module inventory and responsibility boundaries

| Module | Responsibility and visible design |
| --- | --- |
| [`su`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su.move#L1-L18) | Package OTW and publisher claim only. Initialization is private; test initialization is test-only. |
| [`su_acl`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_acl.move#L1-L246) | Shared ACL, `SuperAdminCap`, `AdminCap`, ephemeral `AdminWitness`, role bitmap, admin revocation, delayed root rotation. |
| [`su_market_authority`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market_authority.move#L1-L42) | Small shared authority type placed outside market/oracle to avoid a module cycle; package-only constructor and binding assertions. |
| [`su_market`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L1-L1194) | Primary shared state, positions, supply/borrow/collateral/liquidation/flash transitions, admin setters, version/pause, pure math, test seams. |
| [`su_oracle`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_oracle.move#L1-L354) | Bounded feed configuration, report hot potato, exact feed-set/freshness/deviation validation, aggregation, adapter-facing UID seam. |
| [`irm`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/irm.move#L1-L305) | Validated public model constructors; package-only computation and variant assertion; private bounded math. |
| [`su_upgrade`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_upgrade.move#L1-L121) | Wraps only the protocol's `UpgradeCap`, gates every action with a role witness, supports policy narrowing and irreversible immutability. |
| [`errors`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/errors.move#L1-L183) | Package-wide numeric error macro registry, grouped by concern. No assertions and no state. |
| [`events`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/events.move#L1-L988) | Public event/snapshot schemas, package-only constructors and emitters, test-only collection/field inspection. |
| [`events_wrapper`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/events_wrapper.move#L1-L22) | Generic `Event<T>` envelope and one package emitter; test-only unwrap. This is infrastructure for event collection, not domain state. |
| [`constants`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/constants.move#L1-L27) | Package-wide compile-time values exposed as macros (`wad`, time scale, admin delay). |
| [`roles`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/roles.move#L1-L10) | Append-only role bit-index registry, also exposed as package macros. |
| [`type_utils`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/type_utils.move#L1-L8) | One package macro for defining-ID `TypeName`, used for stable type identity. |
| [`i256`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/i256.move#L1-L228) | Self-contained signed math value type. Unlike protocol errors, it uses module-local named `#[error]` constants because its namespace and tests are local. |

The package is layered by responsibility rather than by a generic `Config` abstraction. State lives with
the lifecycle it governs, and a small authority module is extracted only to break a real dependency cycle.
The external price adapter remains outside core. That is the package-boundary precedent Blast should use,
not the exact lending module list.

## File organization, headings, visibility, and naming

### Section headings and order

`su` modules use explicit `// === ... ===` headings. The exact heading is responsibility-specific rather
than a single rigid vocabulary, but the recurring order is:

1. module documentation, module declaration, and grouped `use` declarations;
2. constants;
3. public types/structs/models;
4. initialization or public constructors;
5. public functions grouped by business responsibility;
6. public aliases;
7. package constructors/functions/consumers;
8. private functions;
9. test-only functions.

The clearest examples are [`irm.move`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/irm.move#L11-L26),
[`su_oracle.move`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_oracle.move#L13-L84),
and [`su_market.move`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L45-L167).
Headings are title-cased (`Public Types`, `Package Functions`, `Private Functions`, `Test-Only Functions`).
Large public modules further divide public functions by product operation rather than dumping them into
one undifferentiated section
([market sections](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L137-L167)).

### Visibility

- Public transaction/composition surfaces use `public fun`.
- Cross-module core internals use `public(package) fun`.
- Same-module implementation details use plain `fun`.
- Test surfaces are explicitly `#[test_only]`; test modules themselves begin with `#[test_only] module`
  ([production test seam](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_oracle.move#L339-L354),
  [test module](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/tests/oracle_tests.move#L1-L16)).
- A public struct's fields remain private to its defining module. Public constructors control legal values;
  test-only constructors provide malformed values only when a negative test needs them
  ([oracle types/constructors](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_oracle.move#L17-L68),
  [oracle test constructors](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_oracle.move#L339-L354)).

### Naming and receiver syntax

- Modules/files and functions use lower snake case; types use UpperCamelCase.
- Capabilities end in `Cap`; ephemeral authorization proofs end in `Witness`; hot potatoes use nouns such
  as `Request`, `Price`, `LiquidationReceipt`, and `FlashLoan`
  ([ACL types](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_acl.move#L8-L26),
  [market hot potatoes](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L108-L135)).
- Public parameters put the primary receiver first, the authorizing cap/witness immediately after it,
  domain values next, and `Clock`/`TxContext` last
  ([admin setters](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L804-L865),
  [oracle admin functions](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_oracle.move#L173-L233)).
- Constructors are `new` when the module has one primary constructed type, and use descriptive names when
  variants or presets matter (`new_kinked`, `new_adaptive_curve`, `leader_mode`)
  ([IRM constructors](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/irm.move#L50-L119),
  [price-mode constructors](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_oracle.move#L56-L68)).
- Math names encode rounding direction (`to_shares_down`, `to_assets_up`, `mul_div_up`)
  ([math helpers](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L1072-L1105)).

## Error architecture and abort semantics

### Canonical package-error form

The exact `su` form is:

```move
macro public(package) fun invalid_admin(): u64 {
    1
}
```

The caller owns the guard:

```move
assert!(acl.is_admin(admin), su::errors::invalid_admin!());
```

See [`errors::invalid_admin`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/errors.move#L9-L11)
and its inline callers in [`su_acl`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_acl.move#L71-L100).
The macro inlines the numeric value into the caller, avoids a runtime function call, preserves the calling
module as the abort location, and leaves guard precedence visible where reviewers need it. The repository's
canonical error document states that the raw numeric code is the stable SDK/indexer/bot contract and that
new codes append without renumbering published meanings
([strategy](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/docs/error-codes.md#L12-L43),
[registry policy](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/docs/error-codes.md#L45-L58)).

There are no error constants or test-only error getters in `su::errors`. Because an attribute cannot name
these macros, core `#[expected_failure]` declarations use numeric literals with an adjacent macro-name
comment and the docs table is the human/tool mapping. Self-contained math/adapter modules may instead use
module-local named `#[error]` constants when package-wide uniqueness is unnecessary
([test guidance](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/docs/test-conventions.md#L24-L33),
[two-namespace decision](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/docs/error-codes.md#L12-L38)).

### Where assertion helpers are legitimate

The source still has `assert_*` helpers, but they live with the private representation they protect:

- `AdminWitness.assert_has_role` owns the private role bitmap.
- `MarketCap.assert_market` / `.assert_oracle` own the private target IDs.
- `InterestRateModel.assert_kinked` owns private enum matching.
- `Market.assert_operational` composes the market's private lock/version/pause guards in a deliberate
  order.

Those helpers are domain APIs. They receive the typed domain object, inspect its private internals, and
centralize an invariant. They are not interchangeable with an `errors::assert_valid(bool)` wrapper
([ACL helper](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_acl.move#L178-L203),
[market helpers](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L1005-L1051)).

### Lint consequence

The macro strategy triggers `abort_without_constant`, so `su` documents narrow, intentional suppressions.
The source applies module-level suppressions only where the macro expansion requires them and function-level
suppressions for deliberate sharing
([source annotations](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L1-L4),
[tooling rationale](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/docs/move-tooling.md#L9-L32)).
Blast should first run its pinned compiler after adopting macros, then add only the suppressions that compiler
actually requires, each with the same adjacent rationale.

## Events and replay

`su` keeps event data types away from the state-transition modules. State code calls descriptive
package-only functions such as `events::borrowed(...)`; only `events.move` constructs the event value.
This prevents event fields from being packed ad hoc at multiple mutation sites
([borrow emitter](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/events.move#L646-L667),
[borrow call site](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L497-L548)).

The event payloads are designed for event-only replay:

- `MarketState` carries all mutable aggregate accounting fields.
- `AccountState` carries post-transition position accounting.
- `PriceSnapshot` records the exact oracle value consumed.
- Mutation events include the stable market/position identity and the post-transition snapshots.
- Interest accrual emits even on state-clock advances that produce zero interest.

These invariants and their regression tests are explicitly documented in the first-party
[`event-replay.md`](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/docs/event-replay.md#L1-L64).
Test-only `collect`, `collect_one`, and `*_fields` helpers keep event schemas inspectable without publishing
getters into production bytecode
([test event API](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/events.move#L761-L988),
[ACL event assertions](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/tests/acl_tests.move#L26-L99)).

`events_wrapper::Event<T>` is how this repository makes generic event collection and unwrapping uniform
([wrapper](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/events_wrapper.move#L1-L22)).
The important house rule is the schema/emitter/test split and replay completeness. Blast accepted the
resulting on-chain `Event<T>` envelope as part of its event ABI on 2026-08-23 and now routes every payload
through the wrapper.

## Authority, capability, and upgrade security

### Global ACL

`su_acl` creates one shared `Acl` and transfers one `SuperAdminCap` during module initialization. A routine
`AdminCap` has only a `UID`; the ACL maps its ID-address to a `u128` role bitmap. `sign_in` verifies current
registry membership and returns a drop-only `AdminWitness` snapshot. Revoking the registry entry makes a
still-existing cap unable to sign in
([types/init](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_acl.move#L8-L55),
[admin lifecycle/sign-in](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_acl.move#L57-L118),
[revocation test](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/tests/acl_tests.move#L184-L203)).

Role numbers are centralized as package macros and must never reuse a bit
([roles registry](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/lib/roles.move#L1-L10)).
The super admin creates/revokes admins and changes roles; routine economic/upgrade calls borrow an
`AdminWitness` and check the required role locally
([role changes](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_acl.move#L57-L101),
[protocol fee role check](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L804-L822)).

### Per-instance authority

`MarketCap` carries `market` and `oracle` IDs because one cap intentionally administers that exact pair.
The type is in a third module so both market and oracle can depend on it without depending on each other.
Its constructor is package-only; its public destroy function is irreversible and emits the affected market
([module rationale and implementation](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market_authority.move#L1-L42)).
This is the rule for deciding whether a cap stores a target ID: store it for deliberately per-instance
authority, not for a protocol-global admin capability.

### Root rotation

The reviewed `su` source stages a recipient and start epoch in `SuperAdminCap`, requires a seven-epoch
delay, and lets the current cap holder finish by transferring the same cap to the staged recipient
([rotation](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_acl.move#L120-L172)).
It does **not** require recipient acceptance and has no named cancellation path. Blast's already-accepted
delayed, cancellable, recipient-accepted rotation is intentionally stronger and should not regress merely
to copy this source. The reusable `su` lessons are singleton root authority, explicit pending state, delayed
handoff, stable events, and exact negative tests.

### Upgrade authority

`su_upgrade::new` verifies that a supplied `UpgradeCap` belongs to the defining package ID of the `SU`
marker before wrapping it. Every authorize/commit/policy/finalization action checks the protocol-admin role;
policy can only be narrowed, and `make_immutable` consumes the wrapper irreversibly
([upgrade implementation](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_upgrade.move#L9-L102),
[upgrade tests](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/tests/packages_tests.move#L18-L90)).
The package ID is used here because it proves custody of the correct upgrade authority. That is not
precedent for redundantly storing a package ID in unrelated protocol config or signed claim data.

Per-market version and pause are embedded in `Market`; cap-gated migration/pause paths validate lock,
version, and cap before mutation. Receipt-settlement paths remain available while paused so an in-flight hot
potato cannot be stranded
([market migration/pause](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L234-L274),
[settlement paths](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L709-L802),
[upgrade policy](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/docs/upgradeability.md#L11-L34)).

## Security and precondition ordering

The recurring public-transition sequence is:

```text
receiver lifecycle guard
→ authority / identity binding
→ cheap zero, bounds, and available-balance checks
→ accrual / oracle resolution / expensive math
→ compute final transition values
→ mutate storage and balances
→ emit post-transition event
→ return owned values
```

Examples:

- `supply` checks operational state and zero input before `accrue`, then rejects zero minted shares before
  accounting mutation and emission
  ([source](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L310-L334)).
- `withdraw_collateral` checks operational state, zero amount, market liquidity, and position binding before
  accrual/price/health work; it computes prospective totals before committing them
  ([source](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L435-L493)).
- Oracle report destruction validates request identity and exact report count before iterating, then validates
  each timestamp before aggregation, applies a deviation circuit breaker, emits the resolved price, and
  returns the sealed `Price`
  ([source](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_oracle.move#L116-L160)).
- Admin setters check lock/version, authority, and bounds before accrual or mutation. `set_irm` validates both
  the stored and incoming variant, accrues under the old model, then installs and emits the new model
  ([source](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L804-L865)).
- Flash initiation checks all amounts and both balance constraints before setting the reentrancy-style lock;
  settlement checks receipt identity and both repayment obligations before joining balances or clearing the
  lock
  ([source](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L728-L802)).

The first-party test suite explicitly calls this “fail-fast guard ordering” and pins exact abort codes for
overlapping invalid inputs
([tests](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/tests/market_guard_tests.move#L458-L871)).

One source detail should **not** be generalized: `borrow` updates totals/account shares before calling
`assert_healthy` ([source](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/sources/su_market.move#L497-L548)).
Move abort rollback keeps storage atomic, but Blast's local validation-before-mutation rule is easier to audit:
compute proposed totals and position shares into locals, validate health against those values, then commit.
Use `su` as the guard-precedence reference, not as permission to move state writes ahead of a fallible check.

## Test organization and verification gates

At the reviewed SHA, `packages/su/tests` contains 204 `#[test]` cases, three `#[random_test]` properties,
and 117 exact `expected_failure` cases. The important patterns are:

- every test module is `#[test_only]`;
- equality uses `assert_eq!`, predicates use bare `assert!`;
- protocol macro errors use exact numeric expected failures with the macro name in a comment;
- tests are grouped by product behavior and guard family with the same `// === ... ===` headings;
- a fluent `MarketBuilder` provides safe defaults and `with_*` receiver setters so each test states only its
  delta
  ([builder](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/tests/test_market.move#L1-L130));
- boundary tests enumerate zero, one unit, maximums, exact health thresholds, one-over thresholds, collection
  limits, wrong object identities, pause/version/lock states, and repayment shortfalls
  ([guard suite](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/tests/market_guard_tests.move#L43-L962));
- randomized properties check conservation/rounding relationships instead of random examples
  ([math properties](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/tests/math_tests.move#L186-L225));
- emitted payloads are collected and field-asserted, not merely checked for existence
  ([ACL lifecycle test](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/tests/acl_tests.move#L26-L99),
  [event replay contract](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/docs/event-replay.md#L34-L64)).

The package uses Move edition 2024 and no manifest dependency. `Published.toml` records mainnet package IDs,
version, toolchain `1.74.1`, and upgrade-capability metadata
([manifest](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/Move.toml#L1-L10),
[publish record](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/packages/su/Published.toml#L1-L12)).
CI installs exactly Sui `1.74.1`, then unconditionally runs `sui move build`, `sui move lint`, and
`sui move test` for core
([workflow](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/.github/workflows/checks.yml#L28-L67)).
Blast must keep its own newer pinned toolchain rather than copy the old version, but should preserve the
three independent gates and make warnings fatal under its own release policy.

## Current Blast delta and recommended order of work

### P0 — replace the error assertion-wrapper design (resolved 2026-08-23)

Blast [`sui/launchpad/sources/lib/errors.move`](../../sui/launchpad/sources/lib/errors.move) now exposes package numeric macros and no
assertion wrappers. `acl.move`, `runtime_config.move`, and `creator_authority.move` perform each assertion
at the owning invariant.
Blast retains Memez-style named copies only as `#[test_only]` source-registry constants, while production
uses the same literal-returning macro form as `su`:

```move
// errors.move
macro public(package) fun invalid_creator(): u64 { 9 }

// creator_authority.move
assert!(creator != @0x0, errors::invalid_creator!());
```

Do not reintroduce assertion functions in `errors.move`. Keep typed domain helpers such as ACL authority checks only
when they inspect private authority state; those helpers themselves must assert with an error macro in their
owning module.

The existing “retired” gaps are not required by the `su` precedent unless those meanings were actually
published. `su` freezes deployed numeric meanings; it does not reserve every abandoned pre-publication draft
([registry rationale](https://github.com/interest-protocol/su-lending/blob/a3552af11a531717378b6337a174f9340d1099dc/docs/error-codes.md#L45-L58)).
Blast should make one explicit pre-deployment decision: either preserve the drafted numbers as an already
agreed SDK contract or compact them once before freezing. Never renumber after publication.

### P1 — standardize structure and dot syntax

Current Blast already has dedicated `errors`, `events`, `acl`, `runtime_config`, and
`creator_authority` modules and uses
receiver syntax in many places. Align the remaining surface with the source conventions:

- title-case section names (`Public Types`, `Package Functions`, `Private Functions`, `Test-Only Functions`);
- group imports by root instead of one line per imported member when readability improves;
- keep `ctx` last and `Clock` immediately before it;
- use receiver syntax for natural first parameters and reserve module syntax for constructors;
- do not add public getters solely for tests; keep all inspection/malformed-value seams `#[test_only]` at the
  end of the module.

### P0 — centralize constants and reuse framework utilities (resolved 2026-08-23)

Blast [`sui/launchpad/sources/lib/constants.move`](../../sui/launchpad/sources/lib/constants.move) now owns all current production
protocol limits, delays, cryptographic byte lengths, schema values, and attestation-layout values as
package macros. `acl.move` and `creator_authority.move` no longer declare production constants. Derived
offsets and total lengths are computed from primitive registry values instead of repeating magic numbers.

The former local `MAX_U64` duplicate was removed. Root-transfer timestamp arithmetic now uses the pinned
standard library's `checked_add` and preserves Blast's explicit overflow error through `Option::destroy_or!`.
Before adding future helpers or bounds, inspect the pinned integer/vector modules first; use package code
only where the framework does not express the protocol-specific operation clearly.

### P1 — add event payload and replay tests (wrapper seam resolved 2026-08-23)

Blast's [`events.move`](../../sui/launchpad/sources/lib/events.move) follows the schema/emitter split and uses completed-fact
names more consistently than `su`. `events_wrapper::Event<T>`, test-only collection/unwrapping, and payload
field accessors are now implemented, with an authority-creation payload regression test. Continue adding
exact payload assertions for admin changes, root rotation, signer rotation/revocation, and creator-cap claims;
event existence alone does not freeze a replay contract.

### P1 — retain Blast's deliberate security improvements

Do not overwrite accepted Blast decisions where they are stronger or product-specific:

- keep the delayed, cancellable, recipient-accepted super-admin transfer rather than `su`'s current-holder
  finish flow;
- keep completed-fact event names (`AdminGranted`, `AdminRevoked`, `SuperAdminTransferred`) instead of copying
  `NewAdmin` / `RevokeAdmin` / `FinishSuperAdminTransfer` literally;
- keep X verification and creator-cap rules in their own minimal domain; `su` has no equivalent signed
  offchain-identity claim;
- keep validation before mutation even where one `su_market` path relies on Move rollback after an early
  write;
- keep Blast's own Sui compiler/framework pin.

### P2 — decide composability at each owned-object creation seam

`su_acl::new_admin` returns `AdminCap` and lets the caller transfer/store/compose it, while Blast's current
`grant_admin` transfers directly to a recipient. The `su` default is to return new owned values; direct
delivery is reserved for deliberate initialization or entry-style endpoints. Review `AdminCap` and
`CreatorCap<Meme>` creation under that rule. If a function's product contract is specifically “deliver this
cap to the resolved recipient,” document the direct transfer as intentional; otherwise return the cap.

## Patterns to adopt, adapt, and reject

| Treatment | Pattern |
| --- | --- |
| Adopt | Package constants as lower-snake package macros; pinned-standard-library helpers before local utilities; numeric package error macros; inline owning assertions; domain-only assertion helpers; receiver syntax; explicit sections; capability suffixes; bounded collections; package-only internals; test-only seams; exact abort-precedence tests; dedicated event schema/emitter module; replay payload tests; core/adapter dependency direction. |
| Adapt | ACL role bitmap only if Blast needs multiple roles; per-object version/pause only where Blast's lifecycle requires it; source toolchain commands using Blast's pinned version. |
| Reject | Error assertion wrappers; copying lending storage/error numbers; storing a package ID in unrelated config because upgrade custody checks one; regressing to one-step root transfer; command-tense event names where Blast has completed facts; relying on rollback to justify avoidable mutation before validation; copying broad lint suppressions without reproducing the pinned-compiler need. |

## Review checklist for the next Blast Move pass

- [x] `errors.move` contains package code macros and test-only registry constants;
      `rg 'assert!|public\(package\) fun assert_' errors.move` is empty.
- [x] Every current aborting guard is visible inline in its owning function or in a typed helper owned by the private
      representation.
- [x] Error numbers and meanings have one documented append-only registry; publication is the freeze point.
- [x] Every current production module uses title-cased responsibility/visibility sections and omits empty sections.
- [x] Production protocol constants live in `constants.move`; primitive maxima and common utilities are
      taken from the pinned MoveStdlib instead of redeclared.
- [ ] Natural receivers use dot syntax; constructor calls remain module-qualified.
- [ ] `Clock` and `TxContext` are last; the authority follows the primary object.
- [ ] All cheap authorization/identity/bounds/deadline checks precede signature verification, BCS work,
      mutation, transfer, and event emission.
- [ ] New owned caps are returned unless delivery is a named endpoint contract.
- [x] Event helpers are package-only; the wrapper, collection seam, and authority-creation payload are tested.
- [ ] Add field assertions for the remaining current admin, signer, and creator-cap payloads.
- [ ] Persistent collections and loops have explicit on-chain maxima and boundary tests.
- [x] Build, lint-with-fatal-warnings, tests, exact aborts, and current event replay tests pass under Blast's pinned
      Sui toolchain.
