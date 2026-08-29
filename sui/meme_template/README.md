# Blast generated Meme package template

This compiler-input package creates one Blast `LaunchTicket<MEME>` when it is
published. Its initializer sends the ticket to the publishing address. The
ticket's creator identity is selected independently of that publisher.

Do not copy or edit this source for each launch. The Blast SDK embeds its
compiled `meme.mv` and patches these bytecode slots in the browser:

- module name, witness name, symbol, name, description, and icon URL;
- one 32-byte creator identity payload and `CREATOR_IS_X`;
- `BURNABLE`; and
- `SELL_BURN_BPS`, from 0 through 10,000.

When `CREATOR_IS_X` is false, the payload is decoded as a Sui address. When it
is true, the same 32 bytes are passed as an X identity hash. Both paths are in
the one reviewed compiled module; the SDK patches constants, not instructions.

The SDK also replaces the compiled module's single non-system dependency with
Blast's original package ID. It publishes with dependencies `0x1`, `0x2`, and
the active Blast package object, then makes the new package immutable.

For local verification, this package depends on `../launchpad`:

```bash
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

The expected `meme.mv` SHA-256 is
`6747a1c0711a6ff8b94f7fc3f015f462e7ce11ec4b2d58ff2b2bd416357309c1`.
After an intentional source or toolchain change, rebuild the module, update the
SDK's embedded artifact and hash, and rerun both repositories' checks.
