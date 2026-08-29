# 0042: Key-only shared launch publication

- Status: accepted
- Date: 2026-08-28
- Amends: [0001](0001-sui-package-and-module-layout.md) and
  [0040](0040-normalized-launch-state-intake.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| — | No external ABI fact introduced | — |

## Context

`Launch<Meme, Quote>` is the consensus owner of reserves, fee obligations,
pending burn, immutable launch policy, and one-time creator custody. Future
permissionless trades and claims must therefore mutate one top-level shared
object. The initial implementation gave `Launch` both `key` and `store` and
returned it from `launch::new` without a package-owned sharing surface.

The `store` ability is unnecessary and too permissive for this role. It lets an
external caller place a launch inside another object or use framework public
transfer operations. Blast instead requires every launch to become directly
addressable shared state.

## Decision

`Launch<Meme, Quote>` has `key` as its only ability. It cannot be nested in an
external object or passed to framework `public_transfer` or
`public_share_object`.

`launch::new` continues to return the newly constructed key-only launch. A new
public function consumes and shares it:

```move
public fun share<Meme, Quote>(self: Launch<Meme, Quote>) {
    transfer::share_object(self);
}
```

The generated launch PTB calls `new`, performs any approved composition on the
owned value, and then calls `share`. Because the value has neither `drop` nor
`store` and Blast exposes no transfer or destruction path, a successful PTB
cannot leave the launch owned or nested.

`share` emits no separate application event. `LaunchCreated` already records
the complete initial launch fact, and the transaction is atomic: that event is
not committed if the returned linear value is not consumed. Native object-owner
metadata is authoritative for the shared-object transition.

## Alternatives considered

**Share inside `launch::new`.** Rejected: returning the owned value preserves a
narrow composition window and follows the package's constructor-first method
style while still forcing publication before transaction completion.

**Keep `store` and let callers use framework public sharing.** Rejected: it also
permits public transfer and arbitrary nesting, neither of which serves the
launch lifecycle.

**Add an owned-launch transfer function.** Rejected: launch ownership is not an
authority model, and future public operations require shared access.

## Consequences

- Each completed launch is a top-level shared object.
- Launch reserves and accounting cannot be hidden inside caller-owned storage.
- The public ABI gains one consuming `share` function and no transfer function.
- Constructor composition remains possible within the creation PTB.
- `LaunchCreated` remains the sole initial application event.

## Verification

- Structural checks require `key` as the launch's only ability and exactly one
  package-owned `transfer::share_object` call.
- A scenario test constructs, shares, and takes the launch as a shared object in
  the next transaction while preserving its complete snapshot.
- Warning-as-error lint, full Move tests, coverage, and source-boundary checks
  remain required.
