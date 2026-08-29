# Migration adapters

This directory contains independently deployed, venue-specific Move packages.
Each adapter gets its own child directory, manifest, lockfile, tests, dependency
review, and release record. Adapters depend on the launchpad core; the launchpad
core never imports an adapter.

Each release must link its guarded `launch::migrate` call to the currently
active core package generation. The adapter may call the deliberately ungated
`launch::redeem_migration` only after the guarded core call returns its typed
payload in the same transaction.
