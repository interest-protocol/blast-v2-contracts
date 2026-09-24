# 0062: Table-backed quote registry without a protocol cardinality cap

- Status: **accepted**
- Date: 2026-08-31
- Amends: [0001](0001-sui-package-and-module-layout.md), [0011](0011-event-schema-and-replay.md), [0025](0025-quote-whitelist-and-migration-targets.md), [0028](0028-hot-cold-runtime-configuration.md), [0058](0058-eventless-package-initialization.md)
- Preserves: [0027](0027-graduation-economics-and-migration-witnesses.md), [0041](0041-launch-config-owned-trade-fees.md), [0049](0049-audit-hardened-package-version-and-launch-intake.md)

## Context

`LaunchConfig` stores the original type and immutable launch parameters for each
Quote admitted by protocol administration. The first implementation used an
inline `VecMap` capped at 16 entries. That representation made every lookup and
removal linear in the number of admitted quotes and imposed a product limit that
is not required by a launch, asset, or migration invariant.

The repository has no committed Sui publication or deployment record. This is
therefore a pre-publication storage-layout correction. If a deployment exists
outside the repository, this change cannot be released as a compatible upgrade;
it requires a new state type and an authorized migration with old-version
reachability addressed explicitly.

## Decision

Replace `LaunchConfig.quotes` with
`sui::table::Table<TypeName, QuoteParameters>`. Quote admission, update,
lookup, and removal use one dynamic field keyed by the Quote's original
`TypeName` and perform no collection iteration.

The quote registry has no Blast-defined cardinality ceiling. Growth remains
restricted to package-current administrators, each transaction changes at most
one quote, and `disallow_quote` removes the dynamic-field value and makes its
storage rebate recoverable. Native transaction, object, storage, and `u64`
limits still apply; “unlimited” means no protocol-configured quote count.

The singleton has no production destruction path, so admitted children cannot
be stranded by deleting their parent. If such a path is added later, it must
define how every remaining quote child is removed or intentionally retained.

The separate migration-witness `VecSet` remains capped at 16 because launch
migration admits executable adapter identities, not passive quote-policy data.
All quote parameter validation, administrator authorization, event schemas,
launch snapshots, and guard order remain unchanged. The quote-count error and
the `max_quote_assets` constant are removed.

## Consequences

- Adding the seventeenth and later Quote types succeeds while policy and
  authorization checks remain identical.
- Reads and mutations address one dynamic field instead of scanning an inline
  vector.
- The shared `LaunchConfig` object stays small as quote admission grows, while
  each admitted Quote creates separately stored child data.
- Clients cannot enumerate all quotes from the parent object alone. The
  replay-complete `QuoteAllowed`, `QuoteParametersChanged`, and
  `QuoteDisallowed` events remain the canonical enumeration history.
- The `LaunchConfig` datatype layout changes before publication. Existing
  public function signatures and event payload layouts do not change.

## Verification

- A focused test admits 17 distinct Quote types and verifies the resulting
  count.
- Existing tests cover duplicate upsert rejection, parameter updates,
  disallow/re-add behavior, missing Quote rejection, authorization, package
  version precedence, events, and launch snapshots.
- The source boundary requires `Table<TypeName, QuoteParameters>`, rejects the
  retired quote-capacity guard, and keeps the 16-entry migration-witness bound.
