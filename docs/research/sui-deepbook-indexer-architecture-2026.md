# Sui and DeepBook indexer architecture

- Date: 2026-08-30
- Scope: current Sui custom-indexer guidance and the current DeepBook V3 indexer implementation
- Method: official Sui documentation and source, and the official MystenLabs DeepBook V3 repository
- Source baselines: Sui docs `9b971fa2525fe7de36f8da581ace3634bb2e3fd2`; DeepBook V3 `1c0b5555bb333010abf63aa6e1ce437653f26795`

## Verdict for Blast

Use a **Rust checkpoint indexer** based on `sui-indexer-alt-framework`, with PostgreSQL. Keep the frontend SDK and protocol projections in TypeScript, but do not make the TypeScript SDK responsible for durable chain ingestion.

For production ingestion, use the current Sui-recommended two-phase flow:

1. Backfill and recover from the full-retention Requester Pays GCS checkpoint bucket.
2. At the network tip, restart with a production RPC provider's fullnode gRPC endpoint as both the polling source and `SubscribeCheckpoints` streaming source.

Start Blast with a **sequential pipeline**. It commits checkpoints in order and is easier to reason about. Move to concurrent pipelines only after measurements show that the sequential pipeline cannot keep up. This is also the current Sui recommendation; DeepBook's 51 concurrent event pipelines reflect a mature, high-volume exchange and are not a suitable starting template for Blast. See the current Sui [pipeline decision guidance](https://github.com/MystenLabs/sui/blob/9b971fa2525fe7de36f8da581ace3634bb2e3fd2/docs/content/develop/accessing-data/custom-indexer/pipeline-architecture.mdx#L45-L90).

## Current Sui guidance

Sui's supported custom-indexer path is the Rust `sui-indexer-alt-framework`. It consumes complete, ordered checkpoints and exposes processing and storage interfaces. PostgreSQL with Diesel is the built-in path, but the storage interface is replaceable. Checkpoints include transactions, events, object changes, and effects, so they cover Blast facts that cannot be reconstructed from events alone. See [What Are Custom Indexers?](https://github.com/MystenLabs/sui/blob/9b971fa2525fe7de36f8da581ace3634bb2e3fd2/docs/content/develop/accessing-data/custom-indexer/custom-indexers.mdx#L43-L111) and [Build a Custom Indexer](https://github.com/MystenLabs/sui/blob/9b971fa2525fe7de36f8da581ace3634bb2e3fd2/docs/content/develop/accessing-data/custom-indexer/build.mdx#L55-L100).

The production source guidance is explicit:

- Use `gs://mysten-mainnet-checkpoints-use4` or `gs://mysten-testnet-checkpoints-use4` for full-history backfill and recovery.
- Use production-grade fullnode gRPC polling plus streaming for steady state.
- Streaming is a latency layer, not a complete source. The polling source fills gaps after interruptions.
- The public HTTPS checkpoint stores retain only about 30 days and are for testing, not production recovery or steady state.

See [Checkpoint Data Sources](https://github.com/MystenLabs/sui/blob/9b971fa2525fe7de36f8da581ace3634bb2e3fd2/docs/content/develop/accessing-data/custom-indexer/indexer-data-integration.mdx#L45-L122).

Each pipeline stores a `checkpoint_hi_inclusive` watermark: the highest checkpoint for which all prior data has committed without gaps. On restart, the framework resumes at that watermark plus one. Concurrent pipelines may commit data out of order, but the watermark advances only across a contiguous completed range. See the [watermark contract](https://github.com/MystenLabs/sui/blob/9b971fa2525fe7de36f8da581ace3634bb2e3fd2/docs/content/develop/accessing-data/custom-indexer/pipeline-architecture.mdx#L102-L150) and the framework's [resume logic](https://github.com/MystenLabs/sui/blob/3c0f387ebb40b8be292d3b7bd3f5bee8ad226d33/crates/sui-indexer-alt-framework/src/lib.rs#L49-L67).

Direct TypeScript gRPC ingestion is possible, but it is a lower-level path. Sui's TypeScript client documents that live subscriptions do not resume: a consumer must persist its last position, open and buffer a new subscription, list the missed range, then drain the buffer. The Rust framework already owns this ingestion, backpressure, watermark, and recovery machinery. See the official [TypeScript gRPC subscription recovery guide](https://sdk.mystenlabs.com/sui/clients/grpc#recovering-missed-data).

## What DeepBook actually runs

DeepBook's indexer is Rust 2021. It depends on `sui-indexer-alt-framework`, Tokio, Diesel/Diesel Async, `sui-pg-db`, BCS, and Prometheus. Its lockfile fixes framework version `1.68.1` at Sui commit `3c0f387ebb40b8be292d3b7bd3f5bee8ad226d33`. See its [indexer Cargo manifest](https://github.com/MystenLabs/deepbookv3/blob/1c0b5555bb333010abf63aa6e1ce437653f26795/crates/indexer/Cargo.toml#L1-L35) and [lockfile](https://github.com/MystenLabs/deepbookv3/blob/1c0b5555bb333010abf63aa6e1ce437653f26795/Cargo.lock#L8385-L8430).

The binary registers 51 independent concurrent pipelines: 21 core DeepBook handlers and 30 margin handlers. Each handler receives a full checkpoint, scans its executed transactions, filters by package involvement, decodes matching Move events from BCS, and maps them to database rows. See [pipeline registration](https://github.com/MystenLabs/deepbookv3/blob/1c0b5555bb333010abf63aa6e1ce437653f26795/crates/indexer/src/main.rs#L258-L454) and the shared [handler macro](https://github.com/MystenLabs/deepbookv3/blob/1c0b5555bb333010abf63aa6e1ce437653f26795/crates/indexer/src/handlers/mod.rs#L88-L156).

DeepBook writes append-oriented event tables to PostgreSQL through Diesel. Event coordinates become an `event_digest`; event tables use that value as a primary key, and commits use `ON CONFLICT DO NOTHING`, making replayed inserts idempotent. See the [event metadata and insert path](https://github.com/MystenLabs/deepbookv3/blob/1c0b5555bb333010abf63aa6e1ce437653f26795/crates/indexer/src/handlers/mod.rs#L9-L65) and [event table keys](https://github.com/MystenLabs/deepbookv3/blob/1c0b5555bb333010abf63aa6e1ce437653f26795/crates/schema/migrations/2025-03-19-104023_deepbook/up.sql#L3-L51).

The deployed shape is two Rust services around one PostgreSQL schema:

```text
checkpoint sources -> deepbook-indexer -> PostgreSQL <- deepbook-server -> REST clients
                                                ^              |
                                                |              +-> Sui gRPC for live reads
                                                +-> materialized views
```

The API is a separate Axum server. Most routes query PostgreSQL, while order-book, supply, fee, summary, and health routes also use Sui gRPC. Its `/status` endpoint compares every pipeline watermark with the latest onchain checkpoint. See the [server dependencies](https://github.com/MystenLabs/deepbookv3/blob/1c0b5555bb333010abf63aa6e1ce437653f26795/crates/server/Cargo.toml#L9-L45), [route split](https://github.com/MystenLabs/deepbookv3/blob/1c0b5555bb333010abf63aa6e1ce437653f26795/crates/server/src/server.rs#L400-L478), and [watermark health check](https://github.com/MystenLabs/deepbookv3/blob/1c0b5555bb333010abf63aa6e1ce437653f26795/crates/server/src/server.rs#L484-L570).

One important limitation: DeepBook production mode hard-codes the public `checkpoints.mainnet.sui.io` or `checkpoints.testnet.sui.io` remote store, with optional gRPC streaming supplied separately. Local sandbox mode reads checkpoint files. This differs from the newer Sui production guidance, which rejects the 30-day public HTTPS stores as production backfill or recovery sources. Copy DeepBook's pipeline and service separation, not this source default. See [DeepBook source selection](https://github.com/MystenLabs/deepbookv3/blob/1c0b5555bb333010abf63aa6e1ce437653f26795/crates/indexer/src/main.rs#L93-L220) and [its store constants](https://github.com/MystenLabs/deepbookv3/blob/1c0b5555bb333010abf63aa6e1ce437653f26795/crates/indexer/src/lib.rs#L9-L12).

## Blast-specific architecture

Use three boundaries:

1. **Rust ingestion:** full checkpoints, package/version filtering, BCS decoding, transaction effects, changed-object ownership, idempotency, and committed checkpoint watermarks.
2. **PostgreSQL projections:** raw canonical facts plus frontend read models. Write one checkpoint and its projection changes atomically in the initial sequential pipeline.
3. **Thin read API:** discovery, trades, charts, rankings, positions, and migration history. It may be TypeScript if that best fits the web team; it does not need to share the indexer's language.

Do not duplicate Blast economics independently in Rust. Freeze event BCS layouts and integer test vectors as cross-language artifacts. The Rust indexer decodes canonical chain facts and applies tested reducers; the TypeScript SDK remains the authority for client transaction construction and previews. Run the same replay fixtures through both implementations where their projections overlap.

The first implementation ticket should prove one end-to-end slice: GCS/local checkpoint input -> one sequential launchpad pipeline -> atomic raw-event and launch projection writes -> restart from watermark -> one read endpoint. Add gRPC streaming only after the backfill and restart path passes.
