---
name: sui-move-testing
description: Testing for Sui Move invariants, exact aborts, guard precedence, stateful fixtures, arithmetic properties, event replay, adversarial integrations, upgrades, dependencies, and release gates. Use when adding, changing, fixing, or reviewing Move behavior or tests.
---

# Sui Move Testing

Test the invariant and threat surface, not only the happy-path function name.

Target repository instructions, accepted design records, pinned toolchain behavior, and published compatibility commitments take precedence over this standard's examples.

## Build the risk matrix

1. Inventory every changed behavior, invariant, public or entry path, asset,
   authority, lifecycle edge, event, dependency, and upgrade seam. The inventory
   is complete when every production change has a test owner.
2. Mark each risk layer below applicable or inapplicable for every inventoried
   behavior, with a reason for each inapplicable layer.
3. Read every matching specialized reference, then map each applicable risk to
   a direct test, property, structural check, integration check, or release gate.
4. Run the release gates below and use the final completion gate to report the
   result.

## Cover every risk layer

- Pure math: tables, boundaries, monotonicity, inverse dust bounds, and properties.
- Lifecycle: every legal edge and rejection from every illegal source state.
- Authorization: allowed and forbidden actions, rotation, revocation, last-authority destruction or handoff, pause, and version precedence.
- Accounting: reserves, fees, allocations, vesting, burns, and conservation after operations and sequences.
- Adversarial: direct public calls, PTB composition, replay, third-party signature submission, expiry, wrong domain, wrong type or object, slippage, stale or selectable oracle data, callback-like handoffs, randomness selection, duplicate settlement, and hostile assets.
- Events: every payload field and full reducer replay against final state.
- Upgrades: cover compatibility, permitted generic-constraint relaxation,
  initializer non-rerun, old-version safety or operational rejection,
  capability binding, policy narrowing, new-type migration, and dependency
  relinking. Reject incompatible changes to existing public function
  signatures, struct or enum layouts, and abilities.
- Deployment and dependencies: dry run, finality, normalized artifacts, exact pins, and live external ABI checks.

## Load matching references

- **Fixtures:** For `test_scenario`, multi-transaction, or resource-carrying
  setup, read [Stateful fixtures](references/stateful-fixtures.md) completely.
- **Object custody:** For bounded collections, dynamic child storage,
  identity-bearing objects, wrapping, or key-only returned objects, read
  [Object custody and storage tests](references/object-custody-tests.md)
  completely.
- **Adversarial integrations:** For time, oracles, signatures, hostile assets,
  randomness, callback-like composition, or external integrations, read
  [Adversarial integration tests](references/adversarial-integrations.md)
  completely.
- **Event replay:** For events, payloads, indexers, or replay, read
  [Event replay tests](references/event-replay-tests.md) completely.
- **Upgrades and dependencies:** For publication, upgrades, migration,
  activation, dependency relinking, deployed ABI, or fingerprints, read
  [Upgrade and dependency tests](references/upgrade-dependency-tests.md)
  completely.

Read every matching reference for a task. Keep the loaded set to test variants
whose risk appears in the target; a complete review still loads every matching
reference.

## Write direct tests

- Start each test module with `#[test_only] module`.
- Use the production section style with title-cased headings.
- Name each test as a behavioral statement.
- Keep pure math and error-registry tests fixture-free. Pin every package error
  number and stable meaning in the registry test. For module-local
  `#[error(code = N)]` constants, pin the explicit code, raising module, and
  failed-condition message through the repository's supported test or source
  gate.
- Give builders deterministic safe defaults and receiver-style `with_*` modifiers so a test states only its relevant delta.
- Use fixed seeds for random tests and print enough input to reproduce failure.

## Pin exact failures

Never use a bare expected failure:

```move
#[test]
#[expected_failure(
    abort_code = protocol::errors::EInvalidBps,
    location = protocol::bps,
)]
fun constructor_rejects_the_first_value_above_the_limit() {
    bps::new(10_001);
}
```

- Assert the exact intended abort and raising module.
- Reject new bare module-local `u64` error constants in simple packages; verify
  that local errors retain their explicit `#[error(code = N)]` identity and
  descriptive `vector<u8>` message.
- Add pairwise invalid-input tests to pin guard precedence.
- Assert framework errors when the framework is the intended enforcement layer.
- Ensure cleanup cannot make a negative test pass through an unrelated abort.
- When the harness exposes failed transaction effects, snapshot relevant state, assets, and events and prove the aborted path leaves them unchanged.

## Test arithmetic and economics

- Include zero, one, maximum supported values, and just below/at/above every threshold.
- When a domain struct composes a sealed value struct, test the reusable
  invariant at the value struct's construction and mutation boundary. Test each
  domain constructor's additional relationships and at least one composed path;
  do not repeat the same boundary matrix for every enclosing type unless that
  type can bypass or alter the reusable invariant.
- Stress intermediate multiplication even when the final result fits.
- Test the declared rounding beneficiary with one-unit remainders.
- Assert the operation-specific conservation equation after each operation and long sequence.
- Add properties for monotonicity, bounded dust, inverse behavior, and allocation sums.
- Keep shared vectors explicit about units and regenerate them from one formula source; do not hand-edit expected values.
- When replacing custom logic with a pinned framework function or macro, retain boundary, rounding, and exact-abort tests; similarity of names does not prove semantic equivalence.

## Run release gates

Use the exact pinned toolchain. A typical Sui Move gate is:

```bash
sui move build
sui move lint --warnings-are-errors
sui move test --lint
```

Also run repository formatting, source-boundary, dependency-pin, external-ABI,
coverage, and `git diff --check` gates when present. If the pinned coverage tool
misrepresents a branch, use named branch tests and document the limitation
instead of inventing a false metric.

Testing is complete only when every applicable risk in the matrix has passing
evidence, exact failure behavior is pinned, all available gates pass, and every
unavailable or unreliable check is reported.
