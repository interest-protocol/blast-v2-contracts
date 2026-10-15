# Native leverage Quote composition checks

This test-only consumer package depends on the adapter and launchpad. Neither
production package acquires a dependency on or authority over the other.

`sui move test --lint --warnings-are-errors` runs actual launch construction,
native Quote buy/sell custody, and exact-type admission rejection. Its fixture
Quote comes from `coin::mint_for_testing`, not an Aftermath trade. The
compile-only consumers bind mint → buy, sell → redeem, and mint → redeem
using the returned ClearingHouse again in the same transaction, sharing it
after its final use. They require supported live objects to
execute and are not deployed entrypoints.

Submitted both-direction venue composition, downstream-failure rollback and
terminal trading evidence remain outside the local suite; see the release record.

## Terminal consumer boundary

`sell_and_redeem_shutdown` compiles the launchpad's returned native Vault Quote
directly into the terminal claim ABI, with no venue or oracle objects. The
native long/short buy-sell tests exercise launch custody independently of Vault
lifecycle. Retirement does not add transfer restrictions or alter Quote
admission, pools, or launchpad authority. The helper is a compile-only consumer
contract, not submitted venue evidence.
