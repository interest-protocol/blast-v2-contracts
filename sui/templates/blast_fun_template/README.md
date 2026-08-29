# Blast generated Meme package template

This package creates one Blast `LaunchTicket<MEME>` when it is published. Its
initializer sends the ticket to the publishing address.

Before publication, edit these values in `sources/meme.move`:

- symbol, name, description, and icon URL;
- `BURNABLE`; and
- `SELL_BURN_BPS`, from 0 through 10,000.

The default creator identity is the publishing address. To bind the launch to an
X identity, replace `creator_authority::new_address(launcher)` with
`creator_authority::new_x(<32-byte-stable-user-id-hash>)` during generation.

For local verification, this package depends on `../../launchpad`:

```bash
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

Before a production publish, resolve the dependency to the intended deployed
Blast package. Do not publish the local launchpad dependency with the generated
Meme package.
