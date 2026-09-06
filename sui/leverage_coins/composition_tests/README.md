# Native leverage Quote composition checks

This test-only consumer package depends on the adapter and launchpad. Neither
production package acquires a dependency on or authority over the other.

`sui move test --lint --warnings-are-errors` runs actual launch construction,
native Quote buy/sell custody, and exact-type admission rejection. Its fixture
Quote comes from `coin::mint_for_testing`, not an Aftermath trade. The two
compile-only functions bind the public mint → buy and sell → redeem signatures
without receipt currencies or wrappers. They require supported live objects to
execute and are not deployed entrypoints.

Submitted both-direction venue composition, downstream-failure rollback and
terminal trading evidence remain outside the local suite; see the release record.
