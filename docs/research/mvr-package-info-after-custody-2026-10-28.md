# MVR PackageInfo after canonical cap custody

Date: 2026-10-28. Status: research and deployment recommendation; no mainnet transaction or production-source change. Upstream source is pinned to [MystenLabs/mvr `7184d372`](https://github.com/MystenLabs/mvr/tree/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7). Local source reviewed at `f209a9aaa9fff51f6bd68d74d750f55c29d607f6`.

## Finding

**MVR does not generally require redeployment. It requires access to the package's mutable native UpgradeCap when creating PackageInfo.** An accessible cap can create metadata after publication. For this particular release, that access has already been closed: admin/partners destroyed their caps, and the other three caps are private fields of custody defined by the immutable admin package. On the reviewed APIs, fresh publication is the available route if all five canonical packages must have MVR metadata. This is a local feasibility conclusion, not a claim that MVR requires all projects to republish. [Metadata guide](https://www.docs.sui.io/sui-stack/mvr/managing-package-info), [constructor source](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/packages/package_info/sources/package_info.move#L54), [local custody definition](../../sui/admin/sources/upgrade_custody.move), [release evidence](../../deployments/sui/mainnet/2026-10-28-canonical-launch-stack.json).

## Verified upstream requirements

The actual constructor is:

```move
public fun new(cap: &mut UpgradeCap, ctx: &mut TxContext): PackageInfo
```

It records the cap's object ID and current package address. It rejects an all-zero package address, which is the cap's state during an uncommitted native upgrade. There is no alternative constructor accepting a Publisher, a target package's one-time witness, or a bare address. The `PACKAGE_INFO` witness in this module initializes the metadata package's own Publisher; it is not a target-package authorization path. [Exact source](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/packages/package_info/sources/package_info.move#L25).

Creation **does not claim or link a dynamic field on UpgradeCap**, change its upgrade policy, or increment its native package version. It reads the cap, allocates a separate PackageInfo object and a Git-version table, and returns the metadata object. Therefore creating metadata while a fresh cap is at native version 1 remains compatible with Blast custody's initial-version check. [Constructor body](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/packages/package_info/sources/package_info.move#L57), [Blast initial-cap validation](../../sui/admin/sources/upgrade_custody.move).

PackageInfo has `key` without `store`. Use its own transfer function, rather than a generic public transfer or wrapping it in another object's fields:

```move
public fun transfer(info: PackageInfo, to: address)
public fun receive(parent: &mut UID, to_receive: Receiving<PackageInfo>): PackageInfo
```

The documented management model is an owned, indexable metadata object. Direct ownership by the multisig is suitable. Transfer-to-object plus the receive API can support custom access control, but merely wrapping PackageInfo as a stored field is unavailable. [Ownership guide](https://www.docs.sui.io/sui-stack/mvr/managing-package-info), [transfer/receive source](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/packages/package_info/sources/package_info.move#L28).

Metadata and Git-source edits subsequently require `&mut PackageInfo`, **not the UpgradeCap or Publisher**. Creating PackageInfo before destroying the cap therefore preserves subsequent metadata management. The current resolver selects versions from indexed package history using `original_id` and native `package_version`; it does not require a surviving live UpgradeCap. Together, these establish the source-supported immutable flow: create PackageInfo first, then destroy the cap. [Metadata methods](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/packages/package_info/sources/package_info.move#L85), [resolver SQL](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/crates/mvr-api/src/data/resolution_loader.rs#L60), [package-history indexing](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/crates/mvr-indexer/src/handlers/package_handler.rs).

## Package metadata, upgrades, and names are separate

Git metadata is keyed by **Sui native package version**, not Blast operational generation. `git::new(repository: String, path: String, tag: String): GitInfo` creates the repository/subdirectory/revision record. `set_git_versioning(info: &mut PackageInfo, version: u64, git_info: GitInfo)` adds it; replacement requires unsetting that version first. Pin a commit or an intentionally maintained release tag. These fields describe source provenance; the setter itself does not rebuild and verify bytecode. [GitInfo source](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/packages/package_info/sources/partials/git.move), [versioning implementation](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/packages/package_info/sources/package_info.move#L95), [maintainer guidance](https://www.docs.sui.io/sui-stack/mvr/maintainer-practices).

A package upgrade keeps its original package lineage. An unversioned name resolves to the latest indexed native package version; `/1`, `/2`, etc. select a native version explicitly. One PackageInfo can describe that lineage across upgrades; add source metadata for each release rather than creating a new application name. Because resolution follows native publication history, it does not know Blast's separate activation state: an installed but unactivated native upgrade can become the unversioned MVR result. Operational clients should continue using the reviewed activated package/version. [MVR overview](https://www.docs.sui.io/sui-stack/mvr/move-registry), [resolution implementation](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/crates/mvr-api/src/data/resolution_loader.rs#L60), [Blast activation procedure](../../deployments/README.md).

The name registry lives on mainnet. Registration checks the SuiNS registration and expiration, returns an `AppCap`, and later attaches a PackageInfo:

```move
public fun register(
    registry: &mut MoveRegistry, nft: &SuinsRegistration,
    name: String, clock: &Clock, ctx: &mut TxContext,
): AppCap
public fun assign_package(
    registry: &mut MoveRegistry, cap: &mut AppCap, info: &PackageInfo,
)
```

**Attaching a mainnet package is permanent.** The record stores the PackageInfo ID, package address, and cap ID, and rejects a second assignment. A native upgrade in the same lineage is supported; an independent republish creates a different lineage and cannot replace this binding. Other-network pointers and descriptive app metadata remain separately manageable. AppCap and PackageInfo ownership are distinct authorities; safe custody of one does not transfer the other. Setting PackageInfo's `default` metadata alone does not register a name; reverse resolution requires the name to actually target that package. [Name guide](https://www.docs.sui.io/sui-stack/mvr/mvr-names), [registry signatures](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/packages/mvr/sources/move_registry.move#L74), [permanent assignment](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/packages/mvr/sources/app_record.move#L79).

## Local feasibility and recommended fresh sequence

The [release record](../../deployments/sui/mainnet/2026-10-28-canonical-launch-stack.json) records immutable admin and partners and sealed upgradeable launchpad, migrators and presale. The [custody module](../../sui/admin/sources/upgrade_custody.move) provides authorization/commit/restriction/destruction operations and a Publisher reference, but no public mutable cap accessor. Its private fields are defined by immutable admin. Upgrading a consumer wrapper cannot reach through those private fields to implement `package_info::new`. A Publisher-based workaround is absent from the reviewed metadata API. Therefore this is not repairable merely by adding metadata helpers to an upgradeable wrapper or using its governance authority.

| Current package | Native cap state | Add missing PackageInfo through supported public paths? |
| --- | --- | --- |
| Admin | Destroyed when published immutably | No; fresh lineage required |
| Partners | Destroyed when published immutably | No; fresh lineage required |
| Launchpad | Inside private `UpgradeCustody` in shared PackageAdmin | No mutable-cap access; fresh lineage required |
| Migrators | Inside private `UpgradeCustody` in shared PackageAdmin | No mutable-cap access; fresh lineage required |
| Presale | Inside private `UpgradeCustody` in shared PackageAdmin | No mutable-cap access; fresh lineage required |

This table describes missing metadata under the reviewed normal public APIs and current immutable custody implementation. It does not claim recovery through a future MVR API or a protocol change is impossible.

If a fresh canonical lineage is chosen, the sequence should be:

1. Publish admin and partners with a PTB that creates PackageInfo from each fresh cap **before** `package::make_immutable` consumes it. The existing publish-and-burn scripts need that ordering change.
2. Publish launchpad, migrators and presale. Before sealing their raw caps, create each PackageInfo and then call the existing custody wrapper in the follow-up PTB. Creating metadata leaves their caps at native version 1 and policy 0.
3. Populate each native version-1 source record with the exact repository subdirectory and published source revision; transfer PackageInfo ownership to `0x818d6d7026632f82367a9ca2413a5bb28aeec2a1b8dedca919ef812577b4d0a2`. Keep the existing SuperAdmin recipient at that same multisig. Metadata ownership and protocol governance remain independent.
4. Verify all new package identities, custody, governance and metadata objects; choose available SuiNS-backed MVR names. Register and attach those names only after accepting the canonical lineage, then transfer the AppCaps to the multisig.

The contracts need no source dependency on MVR merely to perform these external PTB calls. The only required constructor input is their raw cap, so offchain deployment tooling can compose the metadata module and custody module. The existing immutable admin could technically serve new consumers because it does not itself need an MVR helper; republishing admin is necessary only if admin itself must have PackageInfo (and consequently produces a fresh dependent stack).

## Execution checks and remaining limits

- On 2026-10-28, the mainnet resolver returned implementation `0xc88768f8b26581a8ee1bf71e6a6ec0f93d4cc6460ebb66a31b94d64de8105c98` for `@mvr/metadata`. A read-only `sui move --client.env mainnet summary --package-id <implementation> --bytecode --output-directory <evidence>` inspection confirmed that its public `new` constructor takes `&mut 0x2::package::UpgradeCap` and `&mut 0x2::tx_context::TxContext`; its function list contains no alternative constructor. The PackageInfo type origin remains `0x0f6b71233780a3f362137b44ac219290f4fd34eb81e0cb62ddf4bb38d1f9a3a1`. The resolver response and decoded bytecode summaries are retained in the release's operations artifacts. This confirms the cap-access requirement against the deployed ABI, in addition to the upstream source review. [Live resolver](https://mainnet.mvr.mystenlabs.com/v1/resolution/@mvr/metadata), [deployment JSON](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/scripts/package-info.mainnet.json), [generated binding](https://github.com/MystenLabs/mvr/blob/7184d3724a6fdb9d34b7478c7e0fa2b1367990d7/app/src/contracts/mvr_metadata/package_info.ts#L28).
- The immutable-after-metadata result is supported by the reviewed constructor, setter and resolver source. A transaction simulation with the currently deployed metadata implementation should confirm the intended publish/create/burn or create/wrap composition before broadcast. The research request does not itself authorize a new mainnet transaction.
- No SuiNS namespace, availability, existing irreversible app binding, multisig signing ability, or metadata object pre-existence was asserted by this research. Check these against mainnet before committing a name.
- MVR latest-version resolution follows native upgrades, not Blast activation. Decide how SDK/app callers pin reviewed active releases before adopting unversioned MVR call targets.
