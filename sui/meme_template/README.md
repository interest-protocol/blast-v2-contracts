# Generated Meme package template

This compiler-input package creates one Blast `LaunchTicket<MEME>` when it is
published. `MEME` is the package's one-time witness, so the coin type is the
generated package's own `<package>::meme::MEME` and the Coin Registry proves at
creation that no other instance of it can exist. The SDK patches reviewed
constants in the compiled module; it does not fork this source for each launch.

The package exposes no public functions. Its initializer passes the witness and
the reviewed constants to `blast_fun::launch_ticket::new`, which mints the
one-billion-token supply, finalizes the native metadata, and returns a key/store
ticket, holding the supply and the treasury capability, that the initializer
transfers to the publisher. The native `Currency<MEME>` is delivered to the Coin
Registry address; anyone may complete its registration with
`coin_registry::finalize_registration`. The publisher then binds the ticket to
one admitted migration adapter and one Quote through that adapter's binding
function, and the launchpad's `launch::new` consumes the ticket and the
registered currency: it checks the bound adapter and Quote, the decimals against the admitted allowlist, the
supply against the canonical amount, and the sell-burn rate against the current
ceiling, then fixes the supply as fixed or burn-only.

The publication boundary is defined by
[ADR 0051](../../docs/decisions/0051-generated-meme-package-template.md) and the
coin lifecycle by the related accepted ADRs in the
[decision index](../../docs/decisions/README.md). The SDK artifact and its
verification checks own the embedded bytecode hash. This package's source,
manifest, and lockfile own the local implementation and dependency facts.
