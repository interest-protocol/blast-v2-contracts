# Blast launch lineage search — 2026-09-22

## Scope

This read-only search covers the proposed coordinated redesign of
`blast_fun`, `blast_fun_migrators`, `blast_fun_distributor`, and the generated
Meme template. It does not publish, upgrade, submit a transaction, or claim
that unrelated venue packages are unpublished.

- Repository revision inspected: `94e9a5419bac7d1860136ee32273a1802d5becf9`
- Working tree: dirty before this search with unrelated leverage and Aftermath
  adapter changes; those files were not used as publication evidence.
- Sui CLI: `sui 1.77.2-51d177ad7d65`
- Configured networks: mainnet `35834a8a`, testnet `4c78adac`, devnet, and
  local; active environment was mainnet.
- Configured public address checked:
  `0x52ecee5e58e2f3a7461cc604f4efcc3b68031e4715456d821e3a2719b0593600`.

## Reproduction

Run from the contracts repository root:

```bash
git rev-parse HEAD
sui --version
sui client envs --json
sui client active-address
find deployments -mindepth 2 -type f -print
rg -n 'published-id|published_at|published-at' \
  sui/{launchpad,migrators,distributor,meme_template}/Move.lock
rg -n '^published-at|^[[:space:]]*(blast_fun|blast_fun_migrators|blast_fun_distributor|meme_template)[[:space:]]*=' \
  sui/{launchpad,migrators,distributor,meme_template}/Move.toml
sui client --client.env mainnet objects \
  0x52ecee5e58e2f3a7461cc604f4efcc3b68031e4715456d821e3a2719b0593600 \
  --json
sui client --client.env testnet objects \
  0x52ecee5e58e2f3a7461cc604f4efcc3b68031e4715456d821e3a2719b0593600 \
  --json
sui client --client.env devnet objects \
  0x52ecee5e58e2f3a7461cc604f4efcc3b68031e4715456d821e3a2719b0593600 \
  --json
```

Observed results:

- `deployments/` contained no normalized package or object record before this
  evidence file; only its runbook existed.
- None of the four package lockfiles contained a published package identifier.
- Each package manifest used its placeholder named address:
  `blast_fun = "0x0"`, `blast_fun_migrators = "0x0"`,
  `blast_fun_distributor = "0x0"`, and `meme_template = "0x0"`.
- Repository searches found no affected package ID, `UpgradeCap`, shared object
  ID, publication transaction, or deployment artifact.
- Each gRPC-backed `sui client objects` query returned `[]`, so the configured
  address owned no object on any configured public network.

The initial `suix_getOwnedObjects` and `suix_queryTransactionBlocks` attempts
returned JSON-RPC error `-32601`, so they are retained only as evidence that the
legacy interface is retired. The successful search used the supported GraphQL
endpoints:

| Network | Endpoint | Returned chain identifier |
| --- | --- | --- |
| mainnet | `https://graphql.mainnet.sui.io/graphql` | `4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S` |
| testnet | `https://graphql.testnet.sui.io/graphql` | `69WiPg3DAQiwdxfncX6wYQ2siKwAe6L9BZthQea3JNMD` |
| devnet | `https://graphql.devnet.sui.io/graphql` | `7KxLWpyumffD9mTxi77V2yotqXZ8rV2RewDjZM3ZhH7u` |

For each endpoint, the following read-only request was sent with `NET` replaced
by the network name:

```bash
curl -sS --max-time 30 \
  -H 'content-type: application/json' \
  --data '{"query":"query { chainIdentifier objects(first: 50, filter: { owner: \"0x52ecee5e58e2f3a7461cc604f4efcc3b68031e4715456d821e3a2719b0593600\", type: \"0x2::package::UpgradeCap\" }) { nodes { address version digest asMoveObject { contents { json } } } pageInfo { hasNextPage endCursor } } transactions(first: 50, filter: { sentAddress: \"0x52ecee5e58e2f3a7461cc604f4efcc3b68031e4715456d821e3a2719b0593600\" }) { nodes { digest transactionJson } pageInfo { hasNextPage endCursor } } }"}' \
  "https://graphql.NET.sui.io/graphql"
```

All three responses contained no GraphQL errors, `objects.nodes = []`,
`objects.pageInfo.hasNextPage = false`, `transactions.nodes = []`, and
`transactions.pageInfo.hasNextPage = false`. Thus the address owns no
`0x2::package::UpgradeCap` and has no publication or other sent transaction on
any configured public network. The repository search found no other deployer
or candidate package/object identifier. Placeholder `0x0` manifest values are
not candidate IDs and were not treated as chain objects.

## Conclusion and falsification gate

Repository and supported network evidence establish the pre-publication
baseline for every known deployer and candidate identifier: the four affected
packages have placeholder addresses, no recorded publication, no owned
`UpgradeCap`, no shared-object identifier, and no publication transaction.
Implementation may proceed only as one coordinated pre-publication lineage.

This is a falsifiable conclusion, not proof about unknown keys or unrecorded
checkouts. Repeat the same repository, gRPC, and GraphQL search immediately
before publication. If any affected lineage is then found, stop: ADR 0088 does
not authorize mutation of its stored layouts. A separate migration/cutover ADR
and upgrade test plan are required.
