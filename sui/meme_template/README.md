# Generated Meme package template

This compiler-input package creates one Blast `LaunchTicket` when it is
published. Its one-time witness names the coin type, so each generated
package's currency is its own `<package>::<module>::<WITNESS>` and the Coin
Registry proves at creation that no other instance of it can exist. The SDK
does not fork this source for each launch. It patches the compiled module: it
replaces the reviewed constants, binds the `blast_fun` dependency to the
launchpad's original package ID, and renames this template's `meme` module and
`MEME` witness after the coin's symbol.

The package exposes no public functions. Its initializer passes the witness and
the reviewed constants to `blast_fun::launch_ticket::new`, which mints the
one-billion-token supply, finalizes the native metadata, and returns a key/store
ticket, holding the supply and the treasury and metadata capabilities, that the
initializer transfers to the publisher. The native `Currency` is delivered to
the Coin Registry address; anyone may complete its registration with
`coin_registry::finalize_registration`. The publisher starts the launch by
passing the ticket to one admitted migration adapter's `new`, which takes the
Quote type and the venue's pool tier and calls `launch::new` with the adapter's
own witness. `launch::new` checks that the Meme and Quote differ, that the
Quote and the adapter are admitted, and the decimals against the admitted
allowlist, and
returns a `LaunchInitializer` holding the ticket. The publisher configures the
launch on it, then `launch::finalize` consumes it with the registered currency:
it checks the symbol against its 32-byte bound (so choose a symbol of at most
32 bytes), the supply against the canonical amount, and the sell-burn rate
against the current ceiling, then fixes the supply as fixed or burn-only.

The publication boundary is defined by
[ADR 0051](../../docs/decisions/0051-generated-meme-package-template.md), the
adapter-started launch by
[ADR 0089](../../docs/decisions/0089-migrators-own-post-migration-and-start-launches.md),
and the coin lifecycle by the related accepted ADRs in the
[decision index](../../docs/decisions/README.md). The SDK artifact and its
verification checks own the embedded bytecode hash. This package's source,
manifest, and lockfile own the local implementation and dependency facts.
