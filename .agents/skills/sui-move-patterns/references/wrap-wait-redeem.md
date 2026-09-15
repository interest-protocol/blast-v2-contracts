# Wrap–Wait–Redeem

Use this pattern when an asset is valid and valuable now but cannot enter pooled
accounting or back a fungible claim until a live eligibility condition becomes
true.

## Accounting model

Let:

- `PendingPosition` be the actual accepted linear asset;
- `PendingReceipt` hold that asset while it remains outside pooled backing;
- `Vault` contain only assets admitted to the fungible claim's accounting;
- redemption consume the receipt, adopt the live asset, and mint the claim
  atomically.

The accounting boundary is:

```text
pending receipt backing is not pooled backing
pending receipt backing creates no fungible liability
fungible liability is minted only as the eligible asset joins pooled backing
```

Store the real asset in the receipt. A numeric IOU, cached value, symbol, epoch,
or route does not preserve custody and must not become the source of truth for
redemption.

## Lifecycle

1. Validate that the asset is acceptable but currently ineligible for pooled
   accounting. Reject invalid assets instead of wrapping them.
2. Seal the asset in `PendingReceipt` and derive its claim domain and eligibility
   boundary from canonical inputs.
3. Keep the asset outside vault reserves, exchange-rate state, and fungible
   supply while the receipt is outstanding.
4. At redemption, recheck live eligibility, pause state, package version, claim
   domain, revocation, and destination acceptance as applicable.
5. Synchronize the destination vault before pricing.
6. Consume the receipt, derive value from the live underlying asset, adopt the
   asset into backing, update accounting, and mint the fungible claim atomically
   with the protocol's conservative rounding direction.

## Receipt boundary

- Do not give the receipt `drop`; it represents a custody obligation.
- Use `key` when the receipt must persist across transactions.
- Omit `store` when transfer, wrapping, or public sharing must remain
  module-controlled. Include it only when a freely transferable bearer claim is
  intentional.
- Seal construction and extraction inside the owning module. Do not accept a
  caller-supplied eligibility epoch or type label as authority.
- Prefer `PendingReceipt<phantom Claim>` when static typing is sufficient. Use a
  stored `TypeName` only when one non-generic receipt representation is a real
  requirement, and choose its package-identity semantics deliberately.

Cached fields may support display and indexing, but live canonical state and the
inner asset control accounting. Define whether the receipt is bearer-owned,
sender-bound, or transferable, and ensure every landing or transfer path matches
that policy.

## Split and join

If receipts can split or join:

- perform the operation on the underlying asset;
- preserve the exact claim domain and eligibility metadata;
- require every underlying compatibility condition before joining;
- refresh cached display or index fields from the resulting asset;
- enforce minimum viable pieces and conservation across all outputs.

Do not merge receipts merely because their cached labels match.

## Liveness and failure model

Document whether pause, revocation, package activation, or destination shutdown
can delay redemption. A non-droppable receipt can become a trapped claim if
every exit is gated. Preserve an accepted recovery or exit path, or state the
governance delay as part of the economic contract.

Use this pattern only for a genuine cross-transaction wait. Use a staged
constructor when an incomplete value must not leave one PTB. Use a no-ability
handoff when an adapter must settle in the same PTB.

## Verification obligations

Test:

- receipt creation for a valid but ineligible asset;
- rejection of invalid assets rather than wrapping them;
- successful redemption after eligibility and rejection before it;
- wrong claim domain, destination, pause state, and package version;
- no change to pooled backing, exchange rate, or fungible supply at issuance;
- live-value accounting and conservative rounding at redemption;
- split/join conservation, mismatch rejection, and minimum pieces;
- transfer and landing behavior implied by the receipt's abilities;
- liveness or explicit recovery under pause, revocation, and upgrades.
