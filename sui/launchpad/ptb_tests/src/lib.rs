//! In-memory programmable-transaction harness for the launchpad migration seam.
//!
//! Packages are compiled with the pinned `sui` CLI (offline, linked through an ephemeral
//! pubfile) and published into a deterministic `simulacrum` chain. Nothing touches a network.
//!
//! Run from this directory, whose `rust-toolchain.toml` pins the compiler the Sui crates need:
//! `cd sui/launchpad/ptb_tests && cargo test`.
//!
//! The venue-fork tests also insert a committed mainnet snapshot (`fork/`) of real venue
//! packages and objects at their real IDs; see `fork`, `tests/venue_fork.rs`, and
//! `tests/presale_venue_fork.rs`.

#[cfg(feature = "fork-coverage")]
pub mod coverage;
pub mod fork;
pub mod measure;

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    process::Command,
    sync::Mutex,
};

use anyhow::{Context, Result, bail, ensure};
use base64::Engine;
use move_binary_format::CompiledModule;
use move_core_types::{account_address::AccountAddress, identifier::Identifier, language_storage::StructTag};
use rand::{SeedableRng, rngs::StdRng};
use simulacrum::Simulacrum;
use sui_types::{
    base_types::{ObjectID, SuiAddress},
    crypto::AccountKeyPair,
    effects::{TransactionEffects, TransactionEffectsAPI},
    error::ExecutionError,
    event::Event,
    execution_status::{ExecutionFailureStatus, ExecutionStatus},
    gas_coin::MIST_PER_SUI,
    move_package::UpgradeCap,
    object::{Object, Owner},
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{
        Argument, ObjectArg, ProgrammableTransaction, SharedObjectMutability,
        Transaction, TransactionData,
    },
};

/// The Sui revision `Cargo.toml` pins for the simulator. The CLI that compiles the packages must
/// be built from the same revision, or bytecode and framework could disagree.
const PINNED_SUI_REVISION: &str = "51d177ad7d65";
pub const TEST_GENESIS_RECIPIENT: &str = "0xa";
/// The upgrade delay each package's `package_admin::wrap` applies at publication.
pub const PUBLICATION_UPGRADE_DELAY_MS: u64 = 172_800_000;

/// Keep fixture output with its checkout even when Cargo's compiler cache is shared.
pub fn test_work_dir() -> PathBuf {
    crate_dir().join("target/ptb-fixtures")
}

/// Compiled modules and the on-chain packages they link against.
#[derive(Clone)]
pub struct CompiledPackage {
    pub modules: Vec<Vec<u8>>,
    pub dependencies: Vec<ObjectID>,
}

/// `sui move build` writes each package's `build/` directory, so concurrent tests build in turn.
static BUILD_LOCK: Mutex<()> = Mutex::new(());

/// Compiles `package` offline. `published` maps local dependency sources to the IDs they were
/// published at in the simulator, so the bytecode links against those IDs.
pub fn build(package: &Path, published: &[(&Path, ObjectID)], work: &Path) -> Result<CompiledPackage> {
    let _build = BUILD_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let _genesis = GenesisFixture::configure(package)?;
    let mut command = sui_move_build(package, work)?;
    command.args(["--dump", "-e", "mainnet", "--no-tree-shaking"]);
    if !published.is_empty() {
        let mut pubfile = String::from("build-env = \"mainnet\"\nchain-id = \"35834a8a\"\n");
        for (source, id) in published {
            pubfile.push_str(&format!(
                "\n[[published]]\nsource = {{ local = \"{}\" }}\npublished-at = \"{id}\"\noriginal-id = \"{id}\"\nversion = 1\n",
                source.canonicalize()?.display(),
            ));
        }
        let name = package.file_name().context("package directory name")?.to_string_lossy();
        let path = work.join(format!("Pub.{name}.toml"));
        std::fs::write(&path, pubfile)?;
        command.arg("--pubfile-path").arg(path);
    }
    let output = command.output().context("run the sui CLI")?;
    if !output.status.success() {
        bail!(
            "building {} failed:\n{}\n{}",
            package.display(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }
    let dump: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    let engine = base64::engine::general_purpose::STANDARD;
    let modules = dump["modules"]
        .as_array()
        .context("dump modules")?
        .iter()
        .map(|module| Ok(engine.decode(module.as_str().context("module")?)?))
        .collect::<Result<_>>()?;
    let dependencies = dump["dependencies"]
        .as_array()
        .context("dump dependencies")?
        .iter()
        .map(|id| Ok(ObjectID::from_hex_literal(id.as_str().context("dependency")?)?))
        .collect::<Result<_>>()?;

    Ok(CompiledPackage { modules, dependencies })
}

/// Compiled root modules whose local dependencies still sit at the build's placeholder addresses.
pub struct UnlinkedPackage {
    modules: Vec<CompiledModule>,
    placeholders: BTreeMap<String, AccountAddress>,
}

/// Compiles `package` offline and resets its root address for publication, while linking
/// external venue packages at their pinned `published-at` IDs, which a pubfile cannot name. Each
/// dependency in `local` compiles at a placeholder address that `UnlinkedPackage::link` replaces
/// with the ID it was published at in the simulator.
pub fn build_unlinked(package: &Path, local: &[&str], work: &Path) -> Result<UnlinkedPackage> {
    let _build = BUILD_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let manifest = std::fs::read_to_string(package.join("Move.toml"))?;
    let name = manifest
        .lines()
        .find_map(|line| line.strip_prefix("name = \""))
        .and_then(|rest| rest.strip_suffix('"'))
        .context("package name")?;
    let _genesis = GenesisFixture::configure(package)?;
    let mut command = sui_move_build(package, work)?;
    let output = command
        .args(["-e", "mainnet", "--install-dir"])
        .arg(work)
        .output()
        .context("run the sui CLI")?;
    if !output.status.success() {
        bail!(
            "building {} failed:\n{}\n{}",
            package.display(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }
    let bytecode = work.join("build").join(name).join("bytecode_modules");
    let read = |directory: &Path| -> Result<Vec<CompiledModule>> {
        let mut modules = Vec::new();
        for entry in std::fs::read_dir(directory)? {
            let path = entry?.path();
            if path.extension().is_some_and(|extension| extension == "mv") {
                modules.push(CompiledModule::deserialize_with_defaults(&std::fs::read(path)?)?);
            }
        }
        modules.sort_by_key(|module| module.self_id());
        Ok(modules)
    };
    let mut modules = read(&bytecode)?;
    // Published.toml resolves this root at its historical mainnet address. A simulator
    // publication needs zero-address root modules, including their mutual references.
    let root = *modules.first().context("root modules")?.self_id().address();
    for module in &mut modules {
        ensure!(*module.self_id().address() == root, "one root package address");
        for address in &mut module.address_identifiers {
            if *address == root {
                *address = AccountAddress::ZERO;
            }
        }
    }
    let mut placeholders = BTreeMap::new();
    for dependency in local {
        let module = read(&bytecode.join("dependencies").join(dependency))?
            .into_iter()
            .next()
            .with_context(|| format!("{dependency} modules"))?;
        placeholders.insert(dependency.to_string(), *module.self_id().address());
    }

    Ok(UnlinkedPackage { modules, placeholders })
}

impl UnlinkedPackage {
    /// Rewrites each placeholder to the ID `published` gives its dependency and returns the
    /// package ready to publish against `dependencies`.
    pub fn link(&self, published: &[(&str, ObjectID)], dependencies: Vec<ObjectID>) -> Result<CompiledPackage> {
        let mut replacements = BTreeMap::new();
        for (name, id) in published {
            let placeholder = self.placeholders.get(*name).with_context(|| format!("placeholder for {name}"))?;
            replacements.insert(*placeholder, AccountAddress::from(*id));
        }
        ensure!(replacements.len() == self.placeholders.len(), "every local dependency needs an ID");
        let modules = self
            .modules
            .iter()
            .map(|module| {
                let mut module = module.clone();
                for address in module.address_identifiers.iter_mut() {
                    if let Some(id) = replacements.get(address) {
                        *address = *id;
                    }
                }
                let mut bytes = Vec::new();
                module.serialize_with_version(module.version, &mut bytes)?;
                Ok(bytes)
            })
            .collect::<Result<_>>()?;

        Ok(CompiledPackage { modules, dependencies })
    }
}

/// Compile simulator packages with an explicit nonzero genesis recipient, restoring the sources.
/// `blast_core` declares `blast_treasury`, and a build rejects one named address with two values,
/// so the root manifest and core's are rewritten together.
/// Callers hold BUILD_LOCK until compilation completes.
struct GenesisFixture { originals: Vec<(PathBuf, String)> }
impl GenesisFixture {
    fn configure(package: &Path) -> Result<Self> {
        let mut manifests = vec![package.join("Move.toml")];
        for declaring in ["core"] {
            let manifest = sui_dir().join(declaring).join("Move.toml");
            if !manifests.iter().any(|path| same_file(path, &manifest)) {
                manifests.push(manifest);
            }
        }
        let mut fixture = Self { originals: Vec::new() };
        for path in manifests {
            let original = std::fs::read_to_string(&path)?;
            let rewritten = with_test_treasury(&original);
            if rewritten != original {
                std::fs::write(&path, rewritten)?;
                fixture.originals.push((path, original));
            }
        }
        Ok(fixture)
    }
}
/// The manifest with `blast_treasury` set to `TEST_GENESIS_RECIPIENT`, whatever address it names.
fn with_test_treasury(manifest: &str) -> String {
    const KEY: &str = "blast_treasury = \"";
    let Some(start) = manifest.find(KEY).map(|index| index + KEY.len()) else {
        return manifest.to_owned();
    };
    let end = start + manifest[start..].find('"').expect("blast_treasury value is quoted");
    format!("{}{TEST_GENESIS_RECIPIENT}{}", &manifest[..start], &manifest[end..])
}

impl Drop for GenesisFixture {
    fn drop(&mut self) {
        for (path, original) in &self.originals {
            std::fs::write(path, original).expect("restore genesis fixture manifest");
        }
    }
}

fn same_file(left: &Path, right: &Path) -> bool {
    matches!((left.canonicalize(), right.canonicalize()), (Ok(left), Ok(right)) if left == right)
}

/// `<presale>::blast_presale_package::BLAST_PRESALE_PACKAGE`, the presale's one-time witness (OTW) in
/// `blast_admin`'s generic types.
pub fn presale_otw(presale: ObjectID) -> Result<sui_types::TypeTag> {
    Ok(sui_types::parse_sui_type_tag(&format!("{presale}::blast_presale_package::BLAST_PRESALE_PACKAGE"))?)
}

/// The role type a presale call takes: `UpgradeAdmin`, `PauseAdmin`, `UnpauseAdmin` and
/// `PackageCancelAdmin` are `blast_admin`'s generic package roles over `BLAST_PRESALE_PACKAGE`;
/// every other role is `blast_core::blast_domain`'s.
pub fn presale_role(admin: ObjectID, core: ObjectID, presale: ObjectID, role: &str) -> Result<sui_types::TypeTag> {
    let otw = format!("{presale}::blast_presale_package::BLAST_PRESALE_PACKAGE");
    let tag = match role {
        "UpgradeAdmin" | "PauseAdmin" | "UnpauseAdmin" => format!("{admin}::package_admin::{role}<{otw}>"),
        "PackageCancelAdmin" => format!("{admin}::package_admin::CancelAdmin<{otw}>"),
        _ => format!("{core}::blast_domain::{role}"),
    };
    Ok(sui_types::parse_sui_type_tag(&tag)?)
}

/// Appends `creation_policy::unpause`, which clears `bits` only while every presale delay, the
/// core treasury's delay and the package's upgrade delay are guarded.
#[allow(clippy::too_many_arguments)]
pub fn append_presale_unpause(
    h: &Harness,
    b: &mut ProgrammableTransactionBuilder,
    presale: ObjectID,
    package_admin: ObjectID,
    version: ObjectID,
    witness: Argument,
    creation_policy: ObjectID,
    fee_policy: ObjectID,
    treasury: ObjectID,
    bits: u8,
) -> Result<()> {
    let creation_policy = b.obj(h.shared(creation_policy, false))?;
    let version = b.obj(h.shared(version, true))?;
    let package_admin = b.obj(h.shared(package_admin, false))?;
    let fee_policy = b.obj(h.shared(fee_policy, false))?;
    let treasury = b.obj(h.shared(treasury, false))?;
    let bits = b.pure(bits)?;
    call(b, presale, "creation_policy", "unpause", vec![], vec![creation_policy, version, witness, package_admin, fee_policy, treasury, bits]);
    Ok(())
}

/// `<blast>::blast_fun::BLAST_FUN`, the launchpad's one-time witness (OTW) in `blast_admin`'s generic types.
pub fn launchpad_otw(blast: ObjectID) -> Result<sui_types::TypeTag> {
    Ok(sui_types::parse_sui_type_tag(&format!("{blast}::blast_fun::BLAST_FUN"))?)
}

/// The role type a launchpad call takes: `UpgradeAdmin`, `PauseAdmin`, `UnpauseAdmin` and
/// `PackageCancelAdmin` (the upgrade-action cancel role) are `blast_admin`'s generic package roles
/// over `BLAST_FUN`; every other role is `blast_core::blast_domain`'s.
pub fn launchpad_role(admin: ObjectID, core: ObjectID, blast: ObjectID, role: &str) -> Result<sui_types::TypeTag> {
    let tag = match role {
        "UpgradeAdmin" | "PauseAdmin" | "UnpauseAdmin" => format!("{admin}::package_admin::{role}<{blast}::blast_fun::BLAST_FUN>"),
        "PackageCancelAdmin" => format!("{admin}::package_admin::CancelAdmin<{blast}::blast_fun::BLAST_FUN>"),
        _ => format!("{core}::blast_domain::{role}"),
    };
    Ok(sui_types::parse_sui_type_tag(&tag)?)
}

/// Appends `launch_config::unpause`, which clears `bits` only while every launchpad delay, the
/// core treasury's delay and the package's upgrade delay are guarded.
#[allow(clippy::too_many_arguments)]
pub fn append_launchpad_unpause(
    h: &Harness,
    b: &mut ProgrammableTransactionBuilder,
    blast: ObjectID,
    package_admin: ObjectID,
    version: ObjectID,
    witness: Argument,
    runtime: ObjectID,
    config: ObjectID,
    treasury: ObjectID,
    bits: u8,
) -> Result<()> {
    let config = b.obj(h.shared(config, false))?;
    let runtime = b.obj(h.shared(runtime, false))?;
    let package_admin = b.obj(h.shared(package_admin, false))?;
    let version = b.obj(h.shared(version, true))?;
    let treasury = b.obj(h.shared(treasury, false))?;
    let bits = b.pure(bits)?;
    call(b, blast, "launch_config", "unpause", vec![], vec![config, version, witness, package_admin, runtime, treasury, bits]);
    Ok(())
}

/// Advance the simulator through the administrative delay, then execute public apply calls.
pub fn apply_admin_changes(
    h: &mut Harness,
    changes: Vec<(ObjectID, &str, &str, Vec<sui_types::TypeTag>, ObjectID, ObjectID)>,
) -> Result<()> {
    h.sim.advance_clock(std::time::Duration::from_millis(172_800_000));
    let mut b = ProgrammableTransactionBuilder::new();
    let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    for (package, module, function, types, object, version) in changes {
        let object = b.obj(h.shared(object, true))?;
        let version = b.obj(h.shared(version, false))?;
        call(&mut b, package, module, function, types, vec![object, version, clock]);
    }
    h.execute(b.finish())?.assert_success();
    Ok(())
}

/// A `sui move build` command under the pinned CLI and an offline client config.
fn sui_move_build(package: &Path, work: &Path) -> Result<Command> {
    let binary = std::env::var("SUI_BINARY").unwrap_or_else(|_| "sui".into());
    let version = Command::new(&binary).arg("--version").output().context("run the sui CLI")?;
    let version = String::from_utf8_lossy(&version.stdout);
    ensure!(
        version.contains(PINNED_SUI_REVISION),
        "`{binary} --version` is {}; the harness needs revision {PINNED_SUI_REVISION}",
        version.trim(),
    );
    std::fs::create_dir_all(work)?;
    let client = work.join("client.yaml");
    std::fs::write(
        &client,
        "---\nkeystore:\n  File: ~\nenvs:\n  - alias: offline\n    rpc: \"http://127.0.0.1:1\"\n    ws: ~\n    basic_auth: ~\nactive_env: offline\nactive_address: \"0x0000000000000000000000000000000000000000000000000000000000000000\"\n",
    )?;
    let mut command = Command::new(&binary);
    command.arg("move").arg("--client.config").arg(&client).arg("build").arg("--path").arg(package);

    Ok(command)
}

// === blast_admin delayed-module mirrors (BCS field order) ===
//
// Every key is a zero-field positional struct such as `TradeFeesKey()`, which Move compiles with
// one `dummy_field: bool`, so each `key` is one BCS byte.

/// The `blast_admin` modules that emit delayed lifecycle events: settings in `delayed`, one-shot
/// actions in `delayed_action`, allowlists in `delayed_set` and keyed values in `delayed_map`.
/// Their event names are distinct, so a name alone selects one module's event.
pub const DELAYED_MODULES: [&str; 4] = ["delayed", "delayed_action", "delayed_set", "delayed_map"];

/// Whether `module` is one of `blast_admin`'s delayed modules.
pub fn is_delayed_module(module: &str) -> bool {
    DELAYED_MODULES.contains(&module)
}

/// Mirrors `blast_admin::delayed::Proposal<T>`.
#[derive(serde::Deserialize, serde::Serialize, Debug, Clone, PartialEq)]
pub struct Proposal<T> {
    pub value: T,
    pub delay_ms: u64,
    pub ready_at_ms: u64,
}

/// Mirrors `blast_admin::delayed_action::Change<A>`.
#[derive(serde::Deserialize, serde::Serialize, Debug, Clone, PartialEq)]
pub enum Change<A> {
    Action(A),
    Delay,
}

/// Mirrors `blast_admin::delayed::Delayed<K, T>`.
#[derive(serde::Deserialize, serde::Serialize, Debug, Clone, PartialEq)]
pub struct Delayed<T> {
    pub owner: ObjectID,
    pub key: bool,
    pub value: T,
    pub delay_ms: u64,
    pub pending: Option<Proposal<T>>,
}

/// Mirrors `blast_admin::delayed::PendingDelay`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct PendingDelay {
    pub delay_ms: u64,
    pub ready_at_ms: u64,
}

/// Mirrors `blast_admin::delayed_set::DelayedSet<K, E>`, its `VecSet` and `VecMap` flattened.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct DelayedSet<E> {
    pub owner: ObjectID,
    pub key: bool,
    pub members: Vec<E>,
    pub delay_ms: u64,
    pub admissions: Vec<(E, PendingDelay)>,
    pub pending_delay: Option<PendingDelay>,
}

/// A `RuntimeConfig` in BCS field order: claim signers and protocol fee share.
pub type RuntimeConfigContents = (ObjectID, DelayedSet<Vec<u8>>, Delayed<u64>);

/// A `LaunchConfig` in BCS field order: meme decimals, the admitted quote type names, trade fees
/// (quote, meme), admitted venues, protocol allocation (meme, quote), Blast's LP-fee share of new
/// vaults (meme, quote), creation fee, and the accepted partners' `PartnerList` (owner and its
/// `Table` (id, size)).
pub type LaunchConfigContents = (
    ObjectID,
    Vec<u8>,
    Vec<String>,
    Delayed<(u64, u64)>,
    DelayedSet<String>,
    Delayed<(u64, u64)>,
    Delayed<(u64, u64)>,
    Delayed<u64>,
    (ObjectID, (ObjectID, u64)),
);

/// A `blast_vault::blast_vault_package::VaultRegistry` in BCS field order: its id and the
/// listed venue and issuer witnesses.
pub type VaultRegistryContents = (ObjectID, DelayedSet<String>);

/// A `blast_admin::package_version::PackageVersion<M>` in BCS field order: id, defined pause
/// bits, paused bits, the unpause witness type and the version.
pub type GenericPackageVersionContents = (ObjectID, u8, u8, String, u64);

/// Mirrors `blast_admin::delayed_action::DelayedAction<K, A>`.
#[derive(serde::Deserialize, serde::Serialize, Debug, Clone, PartialEq)]
pub struct DelayedAction<A> {
    pub owner: ObjectID,
    pub key: bool,
    pub delay_ms: u64,
    pub pending: Option<Proposal<Change<A>>>,
}

/// Mirrors `blast_vault::vault::RoundTerms`, the terms a vault's round-publication slot holds until
/// anyone publishes the round.
#[derive(serde::Deserialize, serde::Serialize, Debug, Clone, PartialEq)]
pub struct RoundTerms {
    pub number: u64,
    pub start_checkpoint: u64,
    pub end_checkpoint: u64,
    pub root: Vec<u8>,
    pub manifest_digest: Vec<u8>,
    pub leaf_count: u64,
    pub meme_amount: u64,
    pub quote_amount: u64,
    pub gas_reserve_amount: u64,
    pub claim_window_duration_ms: u64,
    pub expected_treasury: SuiAddress,
}

/// Mirrors `blast_core::fee_split::Destination`; its BCS tag is the variant index.
#[derive(serde::Deserialize, serde::Serialize, Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum Destination {
    Address(SuiAddress),
    Owner,
    AutoLp,
    HolderRewards,
    Burn,
}

/// Mirrors `blast_core::fee_split::Route`; its `Bps` is one `u64`.
#[derive(serde::Deserialize, serde::Serialize, Debug, Clone, PartialEq)]
pub struct Route {
    pub destination: Destination,
    pub bps: u64,
}

/// Mirrors `blast_core::fee_split::FeeSplit`: routes in apportionment order.
#[derive(serde::Deserialize, serde::Serialize, Debug, Clone, Default, PartialEq)]
pub struct FeeSplit {
    pub routes: Vec<Route>,
}

impl FeeSplit {
    pub fn new(routes: impl IntoIterator<Item = (Destination, u64)>) -> Self {
        Self { routes: routes.into_iter().map(|(destination, bps)| Route { destination, bps }).collect() }
    }

    /// Every collection wholly to one address.
    pub fn single(destination: SuiAddress) -> Self {
        Self::new([(Destination::Address(destination), 10_000)])
    }

    /// The weight of the route to `destination`, zero when the split has none.
    pub fn bps_of(&self, destination: &Destination) -> u64 {
        self.routes.iter().find(|route| route.destination == *destination).map_or(0, |route| route.bps)
    }

    /// Builds the split through `blast_core`'s public constructors, as a client would, with every
    /// value its own pure input.
    pub fn arg(&self, b: &mut ProgrammableTransactionBuilder, core: ObjectID) -> Result<Argument> {
        let mut routes = Vec::new();
        for route in &self.routes {
            let destination = match &route.destination {
                Destination::Address(address) => {
                    let address = b.pure_bytes(bcs::to_bytes(address)?, true);
                    call(b, core, "fee_split", "address_destination", vec![], vec![address])
                }
                Destination::Owner => call(b, core, "fee_split", "owner_destination", vec![], vec![]),
                Destination::AutoLp => call(b, core, "fee_split", "auto_lp_destination", vec![], vec![]),
                Destination::HolderRewards => call(b, core, "fee_split", "holder_rewards_destination", vec![], vec![]),
                Destination::Burn => call(b, core, "fee_split", "burn_destination", vec![], vec![]),
            };
            let bps = unique_bps(b, core, route.bps)?;
            routes.push(call(b, core, "fee_split", "route", vec![], vec![destination, bps]));
        }
        let route_type = sui_types::parse_sui_type_tag(&format!("{core}::fee_split::Route"))?;
        let routes = b.command(sui_types::transaction::Command::make_move_vec(Some(route_type.into()), routes));
        Ok(call(b, core, "fee_split", "new", vec![], vec![routes]))
    }
}

/// A `blast_core::bps::Bps` from its own pure input, never shared with an equal value.
pub fn unique_bps(b: &mut ProgrammableTransactionBuilder, core: ObjectID, value: u64) -> Result<Argument> {
    let value = b.pure_bytes(bcs::to_bytes(&value)?, true);
    Ok(call(b, core, "bps", "new", vec![], vec![value]))
}

/// Mirrors each package's `package_admin::UpgradeAction`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub enum UpgradeAction {
    Upgrade(Vec<u8>),
    MakeImmutable,
}

/// A `PackageAdmin` in BCS field order: id, sealed Publisher, `Option<UpgradeCap>` (none once
/// immutable) and the upgrade `DelayedAction`.
pub type PackageAdminContents = (ObjectID, (ObjectID, String, String), Vec<UpgradeCap>, DelayedAction<UpgradeAction>);

/// Mirrors `blast_admin::delayed::DelayedScheduled<K, T>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct DelayedScheduled<T> {
    pub owner: ObjectID,
    pub key: bool,
    pub value: T,
    pub delay_ms: u64,
    pub ready_at_ms: u64,
}

/// Mirrors `blast_admin::delayed::DelayedApplied<K, T>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct DelayedApplied<T> {
    pub owner: ObjectID,
    pub key: bool,
    pub previous_value: T,
    pub value: T,
    pub delay_ms: u64,
}

/// Mirrors `blast_admin::delayed_action::ActionScheduled<K, A>` and `ActionCancelled<K, A>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct ActionScheduled<A> {
    pub owner: ObjectID,
    pub key: bool,
    pub change: Change<A>,
    pub delay_ms: u64,
    pub ready_at_ms: u64,
}

/// Mirrors `blast_admin::delayed_action::ActionApplied<K, A>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct ActionApplied<A> {
    pub owner: ObjectID,
    pub key: bool,
    pub change: Change<A>,
    pub delay_ms: u64,
}

/// Mirrors `blast_admin::delayed_set::SetChange<E>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub enum SetChange<E> {
    Admission(E),
    Delay,
}

/// Mirrors `blast_admin::delayed_set::SetScheduled<K, E>` and `SetCancelled<K, E>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct SetScheduled<E> {
    pub owner: ObjectID,
    pub key: bool,
    pub change: SetChange<E>,
    pub delay_ms: u64,
    pub ready_at_ms: u64,
}

/// Mirrors `blast_admin::delayed_set::SetApplied<K, E>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct SetApplied<E> {
    pub owner: ObjectID,
    pub key: bool,
    pub change: SetChange<E>,
    pub delay_ms: u64,
}

/// Everything one executed transaction produced.
pub struct Outcome {
    pub transaction: Transaction,
    pub effects: TransactionEffects,
    pub error: Option<ExecutionError>,
    pub events: Vec<Event>,
}

impl Outcome {
    pub fn assert_success(&self) -> &Self {
        assert!(
            self.effects.status().is_ok(),
            "transaction failed: {:?} {:?}",
            self.effects.status(),
            self.error
        );
        self
    }

    /// Whether this transaction consumed the input `id`: deleted it, or wrapped it into another
    /// object.
    pub fn consumed(&self, id: ObjectID) -> bool {
        let effects = &self.effects;
        effects.deleted().iter().any(|object| object.0 == id)
            || effects.wrapped().iter().any(|object| object.0 == id)
            || effects.unwrapped_then_deleted().iter().any(|object| object.0 == id)
    }

    /// IDs of created objects whose type is `module::name`.
    pub fn created(&self, harness: &Harness, module: &str, name: &str) -> Vec<ObjectID> {
        self.effects
            .created()
            .into_iter()
            .map(|(object, _)| object.0)
            .filter(|id| harness.is_type(*id, module, name))
            .collect()
    }

    /// Payload bytes of the events whose type is `module::name`, whatever its type arguments. Blast
    /// packages emit their payload structs directly, with no envelope.
    pub fn events_of(&self, module: &str, name: &str) -> Vec<&[u8]> {
        self.events
            .iter()
            .filter(|event| event.type_.module.as_str() == module && event.type_.name.as_str() == name)
            .map(|event| event.contents.as_slice())
            .collect()
    }

    /// Contents of the `<name>` lifecycle events of `blast_admin`'s delayed modules keyed by
    /// `key_module::key_name`, in native order. The primitives emit these bare, generic in the
    /// owner's key type.
    pub fn delayed_events(&self, name: &str, key_module: &str, key_name: &str) -> Vec<&[u8]> {
        self.events
            .iter()
            .filter(|event| {
                is_delayed_module(event.type_.module.as_str())
                    && event.type_.name.as_str() == name
                    && matches!(
                        event.type_.type_params.first(),
                        Some(sui_types::TypeTag::Struct(key))
                            if key.module.as_str() == key_module && key.name.as_str() == key_name
                    )
            })
            .map(|event| event.contents.as_slice())
            .collect()
    }

    /// Decodes `delayed_events` into a mirror, which must consume each payload exactly.
    pub fn delayed<T: serde::de::DeserializeOwned>(
        &self, name: &str, key_module: &str, key_name: &str,
    ) -> Result<Vec<T>> {
        self.delayed_events(name, key_module, key_name)
            .into_iter()
            .map(|bytes| bcs::from_bytes(bytes).with_context(|| format!("decode {name}<{key_module}::{key_name}>")))
            .collect()
    }

    /// Type names of the events `package` emitted itself, in native order. Lifecycle events of
    /// `blast_admin`'s delayed modules and its pause and version events carry a `package` type
    /// argument but are emitted by `blast_admin`, so they are not listed; read them with
    /// `delayed_events` or `events_of`.
    pub fn payload_names(&self, package: ObjectID) -> Vec<String> {
        self.events
            .iter()
            .filter(|event| ObjectID::from(event.type_.address) == package)
            .map(|event| event.type_.name.to_string())
            .collect()
    }

    /// Canonical coin type and value of every coin this transaction created for `owner`, sorted.
    pub fn coins_created_for(&self, harness: &Harness, owner: SuiAddress) -> Vec<(String, u64)> {
        let mut coins: Vec<_> = self
            .effects
            .created()
            .into_iter()
            .filter(|(_, created_owner)| *created_owner == Owner::AddressOwner(owner))
            .map(|(object, _)| {
                let coin = harness.object(object.0);
                let tag = coin.coin_type_maybe().expect("coin").to_canonical_string(true);
                (tag, coin.get_coin_value_unsafe())
            })
            .collect();
        coins.sort();
        coins
    }
}

/// Every Move object's type and contents, plus the address-owned object IDs of the watched
/// addresses. A failed transaction must leave this unchanged.
#[derive(Debug, PartialEq, Eq)]
pub struct Snapshot {
    objects: BTreeMap<ObjectID, (StructTag, Vec<u8>)>,
    owned: BTreeMap<SuiAddress, Vec<ObjectID>>,
}

pub struct Harness {
    pub sim: Simulacrum<StdRng>,
    pub sender: SuiAddress,
    key: AccountKeyPair,
    gas: ObjectID,
    /// The shared registries that launch, presale and vault IDs derive from. Every creation or
    /// migration takes one mutably, so a failed one still bumps its version; `assert_rolled_back`
    /// watches each for unchanged contents.
    registries: Vec<ObjectID>,
    #[cfg(feature = "fork-coverage")]
    replay: coverage::ReplayEngine,
}

impl Harness {
    pub fn new() -> Result<Self> {
        let mut sim = Simulacrum::new_with_rng(StdRng::seed_from_u64(0xB1A57));
        let (sender, key, gas) = sim.funded_account(1_000 * MIST_PER_SUI)?;
        Ok(Self {
            sim,
            sender,
            key,
            gas: gas.0,
            registries: Vec::new(),
            #[cfg(feature = "fork-coverage")]
            replay: coverage::ReplayEngine::default(),
        })
    }

    pub fn gas_id(&self) -> ObjectID {
        self.gas
    }

    /// Records the one shared derived-ID registry of `module::name` that `publication` created,
    /// so every rollback assertion also watches it, and returns its ID.
    pub fn derived_registry(&mut self, publication: &Outcome, module: &str, name: &str) -> Result<ObjectID> {
        let registry = publication.created(self, module, name);
        ensure!(registry.len() == 1 && self.object(registry[0]).is_shared(), "publication shares one {name}");
        if !self.registries.contains(&registry[0]) {
            self.registries.push(registry[0]);
        }
        Ok(registry[0])
    }

    pub fn object(&self, id: ObjectID) -> Object {
        self.sim
            .store()
            .get_object(&id)
            .cloned()
            .unwrap_or_else(|| panic!("object {id} is missing"))
    }

    pub fn contents(&self, id: ObjectID) -> Vec<u8> {
        self.object(id).data.try_as_move().expect("Move object").contents().to_vec()
    }

    pub fn is_type(&self, id: ObjectID, module: &str, name: &str) -> bool {
        self.object(id)
            .data
            .try_as_move()
            .map(|object| {
                let tag: StructTag = object.type_().clone().into();
                tag.module.as_str() == module && tag.name.as_str() == name
            })
            .unwrap_or(false)
    }

    /// Writes `object` into the store as is, at its own ID and version.
    pub fn insert(&mut self, object: Object) {
        self.sim.store_mut().update_objects(BTreeMap::from([(object.id(), object)]), vec![]);
    }

    pub fn owned_by(&self, owner: SuiAddress) -> Vec<Object> {
        self.sim.store().owned_objects(owner).cloned().collect()
    }

    pub fn owned_of_type(&self, owner: SuiAddress, module: &str, name: &str) -> Vec<ObjectID> {
        self.owned_by(owner)
            .into_iter()
            .map(|object| object.id())
            .filter(|id| self.is_type(*id, module, name))
            .collect()
    }

    pub fn shared(&self, id: ObjectID, mutable: bool) -> ObjectArg {
        let Owner::Shared { initial_shared_version } = self.object(id).owner().clone() else {
            panic!("object {id} is not shared");
        };
        ObjectArg::SharedObject {
            id,
            initial_shared_version,
            mutability: if mutable {
                SharedObjectMutability::Mutable
            } else {
                SharedObjectMutability::Immutable
            },
        }
    }

    pub fn owned(&self, id: ObjectID) -> ObjectArg {
        ObjectArg::ImmOrOwnedObject(self.object(id).compute_object_reference())
    }

    pub fn execute(&mut self, pt: ProgrammableTransaction) -> Result<Outcome> {
        let gas = self.object(self.gas).compute_object_reference();
        let data = TransactionData::new_programmable(
            self.sender,
            vec![gas],
            pt,
            50 * MIST_PER_SUI,
            self.sim.reference_gas_price(),
        );
        let transaction = Transaction::from_data_and_signer(data, vec![&self.key]);
        #[cfg(feature = "fork-coverage")]
        let trace = self.replay.run(&self.sim, &transaction)?;
        let (effects, error) = self.sim.execute_transaction(transaction.clone())?;
        #[cfg(feature = "fork-coverage")]
        if let Some(trace) = trace {
            trace.save(&self.sim, &effects)?;
        }
        let events = self
            .sim
            .store()
            .get_transaction_events(effects.transaction_digest())
            .map(|events| events.data.clone())
            .unwrap_or_default();

        Ok(Outcome { transaction, effects, error, events })
    }

    /// Simulates the configured capability owner for fixture setup, without its private key.
    /// Ownership checks still run; this provides no evidence about real root signatures.
    pub fn impersonate_cap_owner(&mut self, cap: ObjectID, pt: ProgrammableTransaction) -> Result<Outcome> {
        let sender = self.object(cap).owner().get_address_owner_address()?;
        let funded = self.sim.request_gas(sender, 100 * MIST_PER_SUI)?;
        ensure!(funded.status().is_ok(), "fund capability owner");
        let gas = funded.created().into_iter()
            .find_map(|(object, owner)| (owner == Owner::AddressOwner(sender)).then_some(object))
            .context("capability owner's gas")?;
        let data = TransactionData::new_programmable(
            sender, vec![gas], pt, 50 * MIST_PER_SUI, self.sim.reference_gas_price(),
        );
        let transaction = Transaction::from_data(data, vec![]);
        #[cfg(feature = "fork-coverage")]
        let trace = self.replay.run(&self.sim, &transaction)?;
        let (effects, error) = self.sim.execute_transaction_impersonating(transaction.clone())?;
        #[cfg(feature = "fork-coverage")]
        if let Some(trace) = trace {
            trace.save(&self.sim, &effects)?;
        }
        let events = self.sim.store().get_transaction_events(effects.transaction_digest())
            .map(|events| events.data.clone()).unwrap_or_default();

        Ok(Outcome { transaction, effects, error, events })
    }

    /// Publishes upgradeably and keeps the UpgradeCap with the sender.
    pub fn publish(&mut self, package: CompiledPackage) -> Result<(ObjectID, Outcome)> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let cap = builder.publish_upgradeable(package.modules, package.dependencies);
        builder.transfer_arg(self.sender, cap);
        let outcome = self.execute(builder.finish())?;
        outcome.assert_success();
        let published = outcome.effects.published_packages();
        ensure!(published.len() == 1, "expected one published package");

        Ok((published[0], outcome))
    }

    /// Seals the launchpad's publication in `blast_admin`'s generic PackageAdmin and configures initial
    /// admission; operations remain paused until release (see `unpause_launchpad`). `venue` is the
    /// one venue witness type admitted; `core` is the `blast_core` package whose `Bps` the
    /// launchpad's settings take and whose `blast_domain` roles they require.
    #[allow(clippy::too_many_arguments)]
    pub fn wrap_launchpad(&mut self, package: ObjectID, publication: &Outcome, admin: ObjectID, admin_publication: &Outcome,
        core: ObjectID, quote: sui_types::TypeTag, venue: sui_types::TypeTag,
    ) -> Result<(ObjectID, ObjectID)> {
        assert!(publication.created(self, "package_version", "PackageVersion").is_empty());
        let config_id = publication.created(self, "launch_config", "LaunchConfig")[0];
        let runtime_id = publication.created(self, "runtime_config", "RuntimeConfig")[0];
        let bootstrap = publication.created(self, "package_version", "Publication");
        let cap = publication.created(self, "package", "UpgradeCap");
        assert_eq!(bootstrap.len(), 1);
        assert_eq!(cap.len(), 1);
        // The publication pins the package witness; the version starts at 1 only at wrap.
        let (bootstrap_id, publisher, valid_pause_bits, unpause_witness):
            (ObjectID, (ObjectID, String, String), u8, String) = bcs::from_bytes(&self.contents(bootstrap[0]))?;
        let expected_version = 1u64;
        assert_eq!(valid_pause_bits, 7, "the launchpad defines Create, Trading and Migrate");
        assert!(unpause_witness.ends_with("::blast_fun::PackageWitness"), "{unpause_witness}");
        let cap_contents = self.contents(cap[0]);
        let mut builder = ProgrammableTransactionBuilder::new();
        let bootstrap_arg = builder.obj(self.owned(bootstrap[0]))?;
        let cap_arg = builder.obj(self.owned(cap[0]))?;
        call(&mut builder, admin, "package_admin", "wrap", vec![launchpad_otw(package)?], vec![bootstrap_arg, cap_arg]);
        let outcome = self.execute(builder.finish())?;
        outcome.assert_success();
        assert_eq!(outcome.effects.deleted().iter().map(|object| object.0).collect::<Vec<_>>(), vec![bootstrap_id]);
        // The simulator retains wrapped objects in its cache; transaction effects establish custody.
        assert_eq!(outcome.effects.wrapped().iter().map(|object| object.0).collect::<Vec<_>>(), cap);
        let version = outcome.created(self, "package_version", "PackageVersion");
        assert_eq!(version.len(), 1);
        let package_admin = outcome.created(self, "package_admin", "PackageAdmin");
        assert_eq!(package_admin.len(), 1);
        self.shared(package_admin[0], false);
        let (admin_id, sealed_publisher, sealed_caps, upgrade) = self.package_admin(package_admin[0])?;
        assert!(upgrade.pending.is_none(), "fresh custody has no scheduled action");
        assert_eq!(upgrade.delay_ms, PUBLICATION_UPGRADE_DELAY_MS, "publication starts at the 48-hour upgrade delay");
        assert_eq!(upgrade.owner, package_admin[0]);
        assert_eq!(admin_id, package_admin[0]);
        assert_eq!(sealed_publisher, publisher);
        assert_eq!(sealed_caps.len(), 1);
        assert_eq!(bcs::to_bytes(&sealed_caps[0])?, cap_contents);
        let (version_id, valid, paused, witness, active_version): GenericPackageVersionContents =
            bcs::from_bytes(&self.contents(version[0])).context("decode fresh PackageVersion")?;
        assert_eq!((version_id, valid, paused, witness, active_version),
            (version[0], 7, 7, unpause_witness, expected_version));
        let (_, signers, _): RuntimeConfigContents =
            bcs::from_bytes(&self.contents(runtime_id)).context("decode fresh RuntimeConfig")?;
        assert!(signers.members.is_empty() && signers.admissions.is_empty(), "publication admits no claim signer");
        assert_eq!(signers.delay_ms, 0, "publication starts the signer delay at zero");
        let config_cap = self.configuration_admin(admin, admin_publication, core, "blast_domain", &["ListingAdmin", "VenueAdmin", "FeeAdmin", "TreasuryAdmin", "ClaimSignerAdmin"])?;
        let mut b = ProgrammableTransactionBuilder::new();
        let config = b.obj(self.shared(config_id, true))?;
        let version_arg = b.obj(self.shared(version[0], false))?;
        let clock = b.obj(self.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
        let listing = self.configuration_witness(&mut b, admin, admin_publication, config_cap, core, "blast_domain", "ListingAdmin")?;
        let adapter = self.configuration_witness(&mut b, admin, admin_publication, config_cap, core, "blast_domain", "VenueAdmin")?;
        let allowed = b.pure(true)?;
        call(&mut b, package, "launch_config", "set_quote_allowed", vec![quote], vec![config, version_arg, listing, allowed]);
        // At the zero publication delay a venue's schedule and apply share one PTB.
        call(&mut b, package, "launch_config", "schedule_venue", vec![venue.clone()], vec![config, version_arg, adapter, clock]);
        call(&mut b, package, "launch_config", "apply_venue", vec![venue], vec![config, version_arg, clock]);
        let delay = b.pure(172_800_000u64)?;
        call(&mut b, package, "launch_config", "schedule_venue_delay", vec![], vec![config, version_arg, adapter, delay, clock]);
        call(&mut b, package, "launch_config", "apply_venue_delay", vec![], vec![config, version_arg, clock]);
        self.execute(b.finish())?.assert_success();
        // Raise every remaining publication delay from zero to 48 hours, keeping each published
        // value, through ordinary ACL roles: at zero applied delay schedule and apply share a PTB.
        // `launch_config::unpause` refuses while any delay is unguarded.
        let (_, _, _, trade_fees, _, allocation, lp_fees, creation_fee, _): LaunchConfigContents =
            bcs::from_bytes(&self.contents(config_id)).context("decode LaunchConfig")?;
        let (_, _, fee_share): RuntimeConfigContents =
            bcs::from_bytes(&self.contents(runtime_id)).context("decode RuntimeConfig")?;
        let mut b = ProgrammableTransactionBuilder::new();
        let config_arg = b.obj(self.shared(config_id, true))?;
        let runtime = b.obj(self.shared(runtime_id, true))?;
        let version_arg = b.obj(self.shared(version[0], false))?;
        let clock = b.obj(self.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
        let fee = self.configuration_witness(&mut b, admin, admin_publication, config_cap, core, "blast_domain", "FeeAdmin")?;
        let treasury_role = self.configuration_witness(&mut b, admin, admin_publication, config_cap, core, "blast_domain", "TreasuryAdmin")?;
        let signer_role = self.configuration_witness(&mut b, admin, admin_publication, config_cap, core, "blast_domain", "ClaimSignerAdmin")?;
        let bps = |b: &mut ProgrammableTransactionBuilder, value: u64| -> Result<Argument> {
            let value = b.pure(value)?;
            Ok(call(b, core, "bps", "new", vec![], vec![value]))
        };
        let quote_fee = bps(&mut b, trade_fees.value.0)?;
        let meme_fee = bps(&mut b, trade_fees.value.1)?;
        let meme_allocation = bps(&mut b, allocation.value.0)?;
        let quote_allocation = bps(&mut b, allocation.value.1)?;
        let meme_lp_fee = bps(&mut b, lp_fees.value.0)?;
        let quote_lp_fee = bps(&mut b, lp_fees.value.1)?;
        let share = bps(&mut b, fee_share.value)?;
        let creation_fee = b.pure(creation_fee.value)?;
        let delay = b.pure(PUBLICATION_UPGRADE_DELAY_MS)?;
        call(&mut b, package, "launch_config", "schedule_trade_fees", vec![], vec![config_arg, version_arg, fee, quote_fee, meme_fee, delay, clock]);
        call(&mut b, package, "launch_config", "apply_trade_fees", vec![], vec![config_arg, version_arg, clock]);
        call(&mut b, package, "launch_config", "schedule_protocol_allocation", vec![], vec![config_arg, version_arg, treasury_role, meme_allocation, quote_allocation, delay, clock]);
        call(&mut b, package, "launch_config", "apply_protocol_allocation", vec![], vec![config_arg, version_arg, clock]);
        call(&mut b, package, "launch_config", "schedule_protocol_lp_fees", vec![], vec![config_arg, version_arg, fee, meme_lp_fee, quote_lp_fee, delay, clock]);
        call(&mut b, package, "launch_config", "apply_protocol_lp_fees", vec![], vec![config_arg, version_arg, clock]);
        call(&mut b, package, "launch_config", "schedule_creation_fee", vec![], vec![config_arg, version_arg, fee, creation_fee, delay, clock]);
        call(&mut b, package, "launch_config", "apply_creation_fee", vec![], vec![config_arg, version_arg, clock]);
        call(&mut b, package, "runtime_config", "schedule_protocol_fee_share", vec![], vec![runtime, version_arg, fee, share, delay, clock]);
        call(&mut b, package, "runtime_config", "apply_protocol_fee_share", vec![], vec![runtime, version_arg, clock]);
        call(&mut b, package, "runtime_config", "schedule_creator_claim_signer_delay", vec![], vec![runtime, version_arg, signer_role, delay, clock]);
        call(&mut b, package, "runtime_config", "apply_creator_claim_signer_delay", vec![], vec![runtime, version_arg, clock]);
        self.execute(b.finish())?.assert_success();
        let (_, _, _, trade_fees, venues, allocation, lp_fees, creation_fee, (partners_owner, _)): LaunchConfigContents =
            bcs::from_bytes(&self.contents(config_id)).context("decode configured LaunchConfig")?;
        let (_, signers, fee_share): RuntimeConfigContents =
            bcs::from_bytes(&self.contents(runtime_id)).context("decode configured RuntimeConfig")?;
        ensure!(partners_owner == config_id, "the launch config owns its partner list");
        let applied = [trade_fees.delay_ms, allocation.delay_ms, lp_fees.delay_ms, creation_fee.delay_ms,
            fee_share.delay_ms];
        let pending = [trade_fees.pending.is_some(), allocation.pending.is_some(), lp_fees.pending.is_some(),
            creation_fee.pending.is_some(), fee_share.pending.is_some()];
        ensure!(applied.iter().all(|delay| *delay == PUBLICATION_UPGRADE_DELAY_MS) && !pending.contains(&true),
            "every launchpad setting waits the 48-hour delay with nothing pending");
        ensure!(venues.members.len() == 1, "the launch config admits the one venue");
        for set in [(venues.delay_ms, venues.admissions.len(), venues.pending_delay.is_some()),
            (signers.delay_ms, signers.admissions.len(), signers.pending_delay.is_some())] {
            ensure!(set == (PUBLICATION_UPGRADE_DELAY_MS, 0, false), "every launchpad set waits 48 hours with nothing pending");
        }
        Ok((version[0], package_admin[0]))
    }

    /// Releases `bits` of the launchpad through the real ACL: grants a fresh `AdminCap` the
    /// generic `UnpauseAdmin<BLAST_FUN>` and calls `launch_config::unpause`, which needs every
    /// launchpad delay and the core treasury's guarded, without advancing the Clock.
    #[allow(clippy::too_many_arguments)]
    pub fn unpause_launchpad(&mut self, blast: ObjectID, admin: ObjectID, publication: &Outcome,
        version: ObjectID, package_admin: ObjectID, runtime: ObjectID, config: ObjectID, treasury: ObjectID, bits: u8,
    ) -> Result<()> {
        let role = launchpad_role(admin, ObjectID::ZERO, blast, "UnpauseAdmin")?;
        let cap = self.grant_roles(admin, publication, std::slice::from_ref(&role))?;
        let clock_before = self.contents(sui_types::SUI_CLOCK_OBJECT_ID);
        let mut b = ProgrammableTransactionBuilder::new();
        let witness = self.sign_in_as(&mut b, admin, publication, cap, role)?;
        append_launchpad_unpause(self, &mut b, blast, package_admin, version, witness, runtime, config, treasury, bits)?;
        self.execute(b.finish())?.assert_success();
        assert_eq!(self.contents(sui_types::SUI_CLOCK_OBJECT_ID), clock_before);
        Ok(())
    }

    /// Creates a real ACL administrator for initial zero-delay configuration.
    pub fn configuration_admin(&mut self, admin: ObjectID, publication: &Outcome, package: ObjectID,
        domain: &str, roles: &[&str],
    ) -> Result<ObjectID> {
        let roles = roles
            .iter()
            .map(|role| Ok(sui_types::parse_sui_type_tag(&format!("{package}::{domain}::{role}"))?))
            .collect::<Result<Vec<_>>>()?;
        self.grant_roles(admin, publication, &roles)
    }

    /// Grants a fresh `AdminCap` for the sender each role type in `roles` through the configured
    /// root, as production administration does.
    pub fn grant_roles(&mut self, admin: ObjectID, publication: &Outcome, roles: &[sui_types::TypeTag]) -> Result<ObjectID> {
        let acl = publication.created(self, "blast_acl", "ACL")[0];
        let root = publication.created(self, "blast_acl", "SuperAdminCap")[0];
        let mut b = ProgrammableTransactionBuilder::new();
        let acl_arg = b.obj(self.shared(acl, true))?;
        let root_arg = b.obj(self.owned(root))?;
        let recipient = b.pure(self.sender)?;
        call(&mut b, admin, "blast_acl", "grant_admin", vec![], vec![acl_arg, root_arg, recipient]);
        let granted = self.impersonate_cap_owner(root, b.finish())?;
        granted.assert_success();
        let cap = granted.created(self, "blast_acl", "AdminCap")[0];
        let mut b = ProgrammableTransactionBuilder::new();
        let acl_arg = b.obj(self.shared(acl, true))?;
        let root_arg = b.obj(self.owned(root))?;
        let cap_id = b.pure(cap)?;
        for role in roles {
            call(&mut b, admin, "blast_acl", "grant_role", vec![role.clone()], vec![acl_arg, root_arg, cap_id]);
        }
        self.impersonate_cap_owner(root, b.finish())?.assert_success();
        Ok(cap)
    }

    pub fn configuration_witness(&self, b: &mut ProgrammableTransactionBuilder, admin: ObjectID,
        publication: &Outcome, cap: ObjectID, package: ObjectID, domain: &str, role: &str,
    ) -> Result<Argument> {
        let role = sui_types::parse_sui_type_tag(&format!("{package}::{domain}::{role}"))?;
        self.sign_in_as(b, admin, publication, cap, role)
    }

    /// Signs `cap` in to the ACL as `role`; the witness authorizes only that role.
    pub fn sign_in_as(&self, b: &mut ProgrammableTransactionBuilder, admin: ObjectID, publication: &Outcome,
        cap: ObjectID, role: sui_types::TypeTag,
    ) -> Result<Argument> {
        let acl = publication.created(self, "blast_acl", "ACL")[0];
        let acl_arg = b.obj(self.shared(acl, false))?;
        let cap_arg = b.obj(self.owned(cap))?;
        Ok(call(b, admin, "blast_acl", "sign_in", vec![role], vec![acl_arg, cap_arg]))
    }

    /// Wraps the vault package's publication with its never-upgraded cap through `blast_admin`'s
    /// generic custody. The package version starts fully paused and the registry admits no venue
    /// at a zero admission delay, so nothing is released yet (see `release_vault`).
    pub fn wrap_vault(&mut self, admin: ObjectID, vault: ObjectID, publication: &Outcome) -> Result<VaultStack> {
        let registry = [self.derived_registry(publication, "blast_vault_package", "VaultRegistry")?];
        let (registry_id, venues): VaultRegistryContents = bcs::from_bytes(&self.contents(registry[0]))?;
        ensure!(registry_id == registry[0] && venues.members.is_empty() && venues.delay_ms == 0,
            "publication lists no venue at a zero admission delay");
        let bootstrap = publication.created(self, "package_version", "Publication");
        let cap = publication.created(self, "package", "UpgradeCap");
        ensure!(bootstrap.len() == 1 && cap.len() == 1, "one publication and one upgrade cap");
        ensure!(self.object(bootstrap[0]).owner().get_address_owner_address()? == self.sender, "the publisher keeps the publication");
        let otw = sui_types::parse_sui_type_tag(&format!("{vault}::blast_vault_package::BLAST_VAULT_PACKAGE"))?;
        let mut b = ProgrammableTransactionBuilder::new();
        let bootstrap_arg = b.obj(self.owned(bootstrap[0]))?;
        let cap_arg = b.obj(self.owned(cap[0]))?;
        call(&mut b, admin, "package_admin", "wrap", vec![otw], vec![bootstrap_arg, cap_arg]);
        let wrapped = self.execute(b.finish())?;
        wrapped.assert_success();
        ensure!(wrapped.effects.deleted().iter().any(|object| object.0 == bootstrap[0]), "wrap consumes the publication");
        ensure!(wrapped.effects.wrapped().iter().map(|object| object.0).collect::<Vec<_>>() == cap, "custody seals the cap");
        let version = wrapped.created(self, "package_version", "PackageVersion");
        let package_admin = wrapped.created(self, "package_admin", "PackageAdmin");
        ensure!(version.len() == 1 && package_admin.len() == 1);
        ensure!(self.object(version[0]).is_shared() && self.object(package_admin[0]).is_shared());
        let (_, valid, paused, unpause_witness, stored_version): GenericPackageVersionContents =
            bcs::from_bytes(&self.contents(version[0])).context("decode the vault PackageVersion")?;
        ensure!((valid, paused, stored_version) == (1, 1, 1), "the vault version starts fully paused at version 1");
        ensure!(unpause_witness.ends_with("::blast_vault_package::PackageWitness"), "{unpause_witness}");
        self.assert_publication_upgrade_delay(package_admin[0])?;

        Ok(VaultStack { package: vault, version: version[0], package_admin: package_admin[0], registry: registry[0] })
    }

    /// Lists each of `venues` in the vault registry at the zero publication delay while the
    /// package is paused, raises the admission delay to 48 hours, and unpauses the package
    /// through its own unpause, through real ACL roles: `blast_core`'s `VenueAdmin` and the
    /// vault package's `UnpauseAdmin`.
    pub fn release_vault(&mut self, admin: ObjectID, admin_publication: &Outcome, core: ObjectID, stack: &VaultStack,
        treasury: ObjectID, witnesses: &[sui_types::TypeTag],
    ) -> Result<()> {
        let adapter_role = sui_types::parse_sui_type_tag(&format!("{core}::blast_domain::VenueAdmin"))?;
        let unpause_role = stack.unpause_role(admin)?;
        let cap = self.grant_roles(admin, admin_publication, &[adapter_role.clone(), unpause_role.clone()])?;
        let mut b = ProgrammableTransactionBuilder::new();
        let adapter = self.sign_in_as(&mut b, admin, admin_publication, cap, adapter_role)?;
        let registry = b.obj(self.shared(stack.registry, true))?;
        let version = b.obj(self.shared(stack.version, false))?;
        let clock = b.obj(self.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
        for witness in witnesses {
            call(&mut b, stack.package, "blast_vault_package", "schedule_witness", vec![witness.clone()], vec![registry, adapter, version, clock]);
            call(&mut b, stack.package, "blast_vault_package", "apply_witness", vec![witness.clone()], vec![registry, version, clock]);
        }
        let delay = b.pure(PUBLICATION_UPGRADE_DELAY_MS)?;
        call(&mut b, stack.package, "blast_vault_package", "schedule_witness_delay", vec![], vec![registry, adapter, version, delay, clock]);
        call(&mut b, stack.package, "blast_vault_package", "apply_witness_delay", vec![], vec![registry, version, clock]);
        self.execute(b.finish())?.assert_success();
        let (_, listed): VaultRegistryContents = bcs::from_bytes(&self.contents(stack.registry))?;
        ensure!(listed.members.len() == witnesses.len(), "every witness is listed");
        ensure!((listed.delay_ms, listed.admissions.len(), listed.pending_delay.is_some()) == (PUBLICATION_UPGRADE_DELAY_MS, 0, false),
            "the registry waits 48 hours with nothing pending");

        let clock_before = self.contents(sui_types::SUI_CLOCK_OBJECT_ID);
        let mut b = ProgrammableTransactionBuilder::new();
        let witness = self.sign_in_as(&mut b, admin, admin_publication, cap, unpause_role)?;
        stack.append_unpause(self, &mut b, witness, treasury, 1)?;
        self.execute(b.finish())?.assert_success();
        let (_, _, paused, _, _): GenericPackageVersionContents = bcs::from_bytes(&self.contents(stack.version))?;
        ensure!(paused == 0, "the vault package is released");
        assert_eq!(self.contents(sui_types::SUI_CLOCK_OBJECT_ID), clock_before);
        Ok(())
    }

    /// Decodes any package's `PackageAdmin`: its id, sealed Publisher, sealed caps and upgrade slot.
    pub fn package_admin(&self, package_admin: ObjectID) -> Result<PackageAdminContents> {
        bcs::from_bytes(&self.contents(package_admin)).context("decode PackageAdmin")
    }

    /// A fresh `PackageAdmin` waits the 48-hour publication delay with nothing scheduled.
    pub fn assert_publication_upgrade_delay(&self, package_admin: ObjectID) -> Result<()> {
        let (admin_id, _, sealed_caps, upgrade) = self.package_admin(package_admin)?;
        ensure!(admin_id == package_admin && upgrade.owner == package_admin && sealed_caps.len() == 1);
        ensure!(upgrade.pending.is_none(), "fresh custody has no scheduled action");
        ensure!(upgrade.delay_ms == PUBLICATION_UPGRADE_DELAY_MS, "publication starts at the 48-hour upgrade delay");
        Ok(())
    }

    /// Wraps the migrators' publication with its never-upgraded cap through `blast_admin`'s generic
    /// custody. The package defines no pause bits, so its version is shared unpaused at version
    /// one with nothing to release.
    pub fn wrap_migrators(&mut self, admin: ObjectID, package: ObjectID, publication: &Outcome) -> Result<ObjectID> {
        ensure!(publication.created(self, "package_version", "PackageVersion").is_empty(), "no version before custody");
        let bootstrap = publication.created(self, "package_version", "Publication");
        let cap = publication.created(self, "package", "UpgradeCap");
        ensure!(bootstrap.len() == 1 && cap.len() == 1, "one publication and one upgrade cap");
        ensure!(self.object(bootstrap[0]).owner().get_address_owner_address()? == self.sender, "the publisher keeps the publication");
        let otw = sui_types::parse_sui_type_tag(&format!("{package}::blast_migrators::BLAST_MIGRATORS"))?;
        let mut b = ProgrammableTransactionBuilder::new();
        let bootstrap_arg = b.obj(self.owned(bootstrap[0]))?;
        let cap_arg = b.obj(self.owned(cap[0]))?;
        call(&mut b, admin, "package_admin", "wrap", vec![otw], vec![bootstrap_arg, cap_arg]);
        let outcome = self.execute(b.finish())?;
        outcome.assert_success();
        ensure!(outcome.effects.deleted().iter().any(|object| object.0 == bootstrap[0]), "wrap consumes the publication");
        ensure!(outcome.effects.wrapped().iter().map(|object| object.0).collect::<Vec<_>>() == cap, "custody seals the cap");
        let version = outcome.created(self, "package_version", "PackageVersion");
        let package_admin = outcome.created(self, "package_admin", "PackageAdmin");
        ensure!(version.len() == 1 && package_admin.len() == 1);
        ensure!(self.object(version[0]).is_shared() && self.object(package_admin[0]).is_shared());
        let (_, valid, paused, package_witness, stored_version): GenericPackageVersionContents =
            bcs::from_bytes(&self.contents(version[0])).context("decode the migrators PackageVersion")?;
        ensure!((valid, paused, stored_version) == (0, 0, 1), "the migrators version defines no pause bits at version 1");
        ensure!(package_witness.ends_with("::blast_migrators::PackageWitness"), "{package_witness}");
        self.assert_publication_upgrade_delay(package_admin[0])?;
        Ok(version[0])
    }

    /// Releases `bits` of the presale through the real ACL: grants a fresh `AdminCap` the generic
    /// `UnpauseAdmin<BLAST_PRESALE_PACKAGE>` and calls `creation_policy::unpause`, which needs every
    /// presale delay guarded, without advancing the Clock.
    #[allow(clippy::too_many_arguments)]
    pub fn unpause_presale(&mut self, presale: ObjectID, admin: ObjectID, publication: &Outcome,
        version: ObjectID, package_admin: ObjectID, creation_policy: ObjectID, fee_policy: ObjectID, treasury: ObjectID, bits: u8,
    ) -> Result<()> {
        let role = presale_role(admin, ObjectID::ZERO, presale, "UnpauseAdmin")?;
        let cap = self.grant_roles(admin, publication, std::slice::from_ref(&role))?;
        let clock_before = self.contents(sui_types::SUI_CLOCK_OBJECT_ID);
        let mut b = ProgrammableTransactionBuilder::new();
        let witness = self.sign_in_as(&mut b, admin, publication, cap, role)?;
        append_presale_unpause(self, &mut b, presale, package_admin, version, witness, creation_policy, fee_policy, treasury, bits)?;
        self.execute(b.finish())?.assert_success();
        assert_eq!(self.contents(sui_types::SUI_CLOCK_OBJECT_ID), clock_before);
        Ok(())
    }

    pub fn snapshot(&self, objects: &[ObjectID], owners: &[SuiAddress]) -> Snapshot {
        Snapshot {
            objects: objects
                .iter()
                .map(|id| {
                    let object = self.object(*id);
                    let object = object.data.try_as_move().expect("Move object");
                    (*id, (object.type_().clone().into(), object.contents().to_vec()))
                })
                .collect(),
            owned: owners
                .iter()
                .map(|owner| {
                    let mut ids: Vec<_> = self.owned_by(*owner).iter().map(|object| object.id()).collect();
                    ids.sort();
                    (*owner, ids)
                })
                .collect(),
        }
    }

    /// Executes `pt`, requires it to fail as `expected`, and proves the failure committed nothing:
    /// no object created, deleted, wrapped, or unwrapped; no event; every mutated input other than
    /// gas is one of `objects` and all of `objects` and the `owners`' inventories are unchanged.
    pub fn assert_rolled_back(
        &mut self,
        pt: ProgrammableTransaction,
        expected: Expected,
        objects: &[ObjectID],
        owners: &[SuiAddress],
    ) -> Result<Outcome> {
        let mut objects = objects.to_vec();
        for registry in &self.registries {
            if !objects.contains(registry) {
                objects.push(*registry);
            }
        }
        let objects = objects.as_slice();
        let before = self.snapshot(objects, owners);
        let outcome = self.execute(pt)?;
        match (outcome.effects.status(), &expected) {
            (ExecutionStatus::Failure(failure), expected) => {
                assert!(
                    expected.matches(&failure.error),
                    "expected failure {expected:?}, got {:?} in command {:?}",
                    failure.error,
                    failure.command
                );
            }
            (ExecutionStatus::Success, _) => panic!("expected failure {expected:?}, but it succeeded"),
        }
        let effects = &outcome.effects;
        assert!(effects.created().is_empty(), "failed transaction created objects");
        assert!(effects.deleted().is_empty(), "failed transaction deleted objects");
        assert!(effects.wrapped().is_empty(), "failed transaction wrapped objects");
        assert!(effects.unwrapped().is_empty(), "failed transaction unwrapped objects");
        assert!(effects.unwrapped_then_deleted().is_empty(), "failed transaction unwrapped objects");
        assert!(outcome.events.is_empty(), "failed transaction emitted events");
        for (object, _) in effects.mutated() {
            assert!(
                object.0 == self.gas || objects.contains(&object.0),
                "failed transaction touched unwatched object {}",
                object.0
            );
        }
        assert_eq!(self.snapshot(objects, owners), before, "failed transaction changed state");

        Ok(outcome)
    }
}

/// The shared objects of a wrapped `blast_vault` package.
pub struct VaultStack {
    pub package: ObjectID,
    /// `blast_admin::package_version::PackageVersion<BLAST_VAULT_PACKAGE>`.
    pub version: ObjectID,
    /// `blast_admin::package_admin::PackageAdmin<BLAST_VAULT_PACKAGE>`.
    pub package_admin: ObjectID,
    pub registry: ObjectID,
}

impl VaultStack {
    /// `blast_admin::package_admin::UnpauseAdmin<BLAST_VAULT_PACKAGE>`.
    pub fn unpause_role(&self, admin: ObjectID) -> Result<sui_types::TypeTag> {
        Ok(sui_types::parse_sui_type_tag(&format!(
            "{admin}::package_admin::UnpauseAdmin<{}::blast_vault_package::BLAST_VAULT_PACKAGE>",
            self.package,
        ))?)
    }

    /// Appends `blast_vault_package::unpause`, which clears `bits` only while the registry's
    /// admission delay and the package's upgrade delay are guarded.
    pub fn append_unpause(&self, h: &Harness, b: &mut ProgrammableTransactionBuilder, witness: Argument, treasury: ObjectID, bits: u8) -> Result<()> {
        let registry = b.obj(h.shared(self.registry, false))?;
        let package_admin = b.obj(h.shared(self.package_admin, false))?;
        let version = b.obj(h.shared(self.version, true))?;
        let treasury = b.obj(h.shared(treasury, false))?;
        let bits = b.pure(bits)?;
        call(b, self.package, "blast_vault_package", "unpause", vec![], vec![registry, witness, package_admin, version, treasury, bits]);
        Ok(())
    }

    /// The ID `vault::new` claims for the vault of terms sealed by `package_witness` for `origin`:
    /// `VaultKey { package_witness, origin }` under the registry. The key's BCS is that `TypeName`'s
    /// string (original package IDs, no `0x`) followed by the 32-byte origin.
    pub fn vault_id(&self, package_witness: &sui_types::TypeTag, origin: ObjectID) -> Result<ObjectID> {
        let key = sui_types::parse_sui_type_tag(&format!("{}::vault::VaultKey", self.package))?;
        derived_id(self.registry, &key, &bcs::to_bytes(&(package_witness.to_canonical_string(false), origin))?)
    }
}

/// The ID `sui::derived_object::claim(parent, key)` gives: `parent`'s dynamic-field ID for
/// `DerivedObjectKey<K>` holding `key`, where `key_type` is `K` at original package IDs and
/// `key_bcs` is the key's BCS.
pub fn derived_id(parent: ObjectID, key_type: &sui_types::TypeTag, key_bcs: &[u8]) -> Result<ObjectID> {
    Ok(sui_types::derived_object::derive_object_id(parent, key_type, key_bcs)?)
}

/// The BCS of a zero-field positional key such as `LaunchKey<Meme>()`: Move compiles it with one
/// `dummy_field: bool`, so it is one zero byte.
const UNIT_KEY_BCS: [u8; 1] = [0];

/// The ID `launch::finalize` claims for `meme`'s one launch: `LaunchKey<Meme>()` under the
/// `LaunchRegistry` that `launchpad` (the original package ID) shared at publication.
pub fn launch_id(launchpad: ObjectID, registry: ObjectID, meme: &sui_types::TypeTag) -> Result<ObjectID> {
    let key = sui_types::parse_sui_type_tag(&format!("{launchpad}::launch::LaunchKey<{}>", meme.to_canonical_string(true)))?;
    derived_id(registry, &key, &UNIT_KEY_BCS)
}

/// The ID `blast_presale::finalize` claims for `sale_token`'s one presale: `PresaleKey<SaleToken>()`
/// under the `PresaleRegistry` that `presale` (the original package ID) shared at publication.
pub fn presale_id(presale: ObjectID, registry: ObjectID, sale_token: &sui_types::TypeTag) -> Result<ObjectID> {
    let key = sui_types::parse_sui_type_tag(&format!(
        "{presale}::blast_presale::PresaleKey<{}>",
        sale_token.to_canonical_string(true),
    ))?;
    derived_id(registry, &key, &UNIT_KEY_BCS)
}

/// The Blast packages every world publishes first: the ACL, partners, vesting, and `blast_core`,
/// whose initializer shares the `Treasury`.
pub struct CoreStack {
    pub admin: ObjectID,
    pub admin_publication: Outcome,
    pub partners: ObjectID,
    pub vesting: ObjectID,
    pub core: ObjectID,
    pub core_publication: Outcome,
    /// `blast_core::blast_treasury::Treasury`, shared at publication.
    pub treasury: ObjectID,
    sources: Vec<(PathBuf, ObjectID)>,
}

impl CoreStack {
    /// Every local source published so far with its simulator ID, for `build`.
    pub fn linked(&self) -> Vec<(&Path, ObjectID)> {
        self.sources.iter().map(|(source, id)| (source.as_path(), *id)).collect()
    }

    /// Compiles `package` linked to this stack and publishes it.
    pub fn publish(&self, h: &mut Harness, package: &Path, work: &Path) -> Result<(ObjectID, Outcome)> {
        h.publish(build(package, &self.linked(), work)?)
    }
}

/// The core stack and the launchpad linked to it.
pub struct Stack {
    pub base: CoreStack,
    pub launchpad: ObjectID,
    pub launchpad_code: CompiledPackage,
    pub launchpad_publication: Outcome,
    launchpad_source: PathBuf,
}

impl std::ops::Deref for Stack {
    type Target = CoreStack;

    fn deref(&self) -> &CoreStack {
        &self.base
    }
}

impl Stack {
    /// Every local source published so far, the launchpad included, for `build`.
    pub fn linked(&self) -> Vec<(&Path, ObjectID)> {
        let mut linked = self.base.linked();
        linked.push((self.launchpad_source.as_path(), self.launchpad));
        linked
    }

    /// Compiles `package` linked to this stack, the launchpad included, and publishes it.
    pub fn publish(&self, h: &mut Harness, package: &Path, work: &Path) -> Result<(ObjectID, Outcome)> {
        h.publish(build(package, &self.linked(), work)?)
    }
}

/// Publishes the ACL, partners, vesting and `blast_core`, each linked to the ones before it.
pub fn publish_core_stack(h: &mut Harness, work: &Path) -> Result<CoreStack> {
    let sui = sui_dir();
    let mut sources: Vec<(PathBuf, ObjectID)> = Vec::new();
    let publish = |h: &mut Harness, sources: &[(PathBuf, ObjectID)], name: &str| -> Result<(ObjectID, Outcome)> {
        let linked: Vec<(&Path, ObjectID)> = sources.iter().map(|(source, id)| (source.as_path(), *id)).collect();
        h.publish(build(&sui.join(name), &linked, work)?)
    };
    let (admin, admin_publication) = publish(h, &sources, "admin")?;
    sources.push((sui.join("admin"), admin));
    let (partners, _) = publish(h, &sources, "partners")?;
    sources.push((sui.join("partners"), partners));
    let (vesting, _) = h.publish(build_vesting(work)?)?;
    sources.push((vesting_dir()?, vesting));
    let (core, core_publication) = publish(h, &sources, "core")?;
    sources.push((sui.join("core"), core));
    let treasury = core_publication.created(h, "blast_treasury", "Treasury");
    ensure!(treasury.len() == 1 && h.object(treasury[0]).is_shared(), "core shares one Treasury");

    Ok(CoreStack { admin, admin_publication, partners, vesting, core, core_publication, treasury: treasury[0], sources })
}

/// Publishes the core stack and the launchpad linked to it. Nothing is wrapped or configured.
pub fn publish_stack(h: &mut Harness, work: &Path) -> Result<Stack> {
    let base = publish_core_stack(h, work)?;
    let launchpad_source = sui_dir().join("launchpad");
    let launchpad_code = build(&launchpad_source, &base.linked(), work)?;
    let (launchpad, launchpad_publication) = h.publish(launchpad_code.clone())?;

    Ok(Stack { base, launchpad, launchpad_code, launchpad_publication, launchpad_source })
}

/// The failure a rolled-back transaction must report.
#[derive(Debug)]
pub enum Expected {
    /// `MoveAbort` with `code` from `package::module`.
    Abort { package: ObjectID, module: &'static str, code: u64 },
    /// Any other failure whose rendered error contains the text.
    Error(&'static str),
}

impl Expected {
    fn matches(&self, error: &ExecutionFailureStatus) -> bool {
        match (self, error) {
            (Expected::Abort { package, module, code }, ExecutionFailureStatus::MoveAbort(location, abort)) => {
                *location.module.address() == AccountAddress::from(*package)
                    && location.module.name().as_str() == *module
                    && abort_code(*abort) == *code
            }
            (Expected::Abort { .. }, _) => false,
            (Expected::Error(text), error) => format!("{error:?}").contains(text),
        }
    }
}

/// The error code of a Move abort: a plain code as is, and the `code` of an `#[error(code = N)]`
/// constant from the tagged value such an abort carries (bit 63 set, code in bits 48..56).
fn abort_code(abort: u64) -> u64 {
    if abort >> 63 == 1 { (abort >> 48) & 0xFF } else { abort }
}

/// Shorthand for a Move call with `Identifier` names.
pub fn call(
    builder: &mut ProgrammableTransactionBuilder,
    package: ObjectID,
    module: &str,
    function: &str,
    type_arguments: Vec<sui_types::TypeTag>,
    arguments: Vec<Argument>,
) -> Argument {
    builder.programmable_move_call(
        package,
        Identifier::new(module).expect("module name"),
        Identifier::new(function).expect("function name"),
        type_arguments,
        arguments,
    )
}

/// Cargo runs integration tests from the crate root of the selected checkout.
/// A cached binary can have been compiled in a different checkout.
pub fn crate_dir() -> PathBuf {
    let dir = std::env::current_dir().expect("native PTB test working directory");
    // The tracer overlay is a generated Cargo project nested under the real crate.
    let dir = if dir.ends_with("target/fork-coverage-build") {
        dir.join("../..").canonicalize().expect("native PTB crate directory")
    } else {
        dir
    };
    assert!(
        dir.join("Cargo.toml").is_file() && dir.ends_with("launchpad/ptb_tests"),
        "run native PTB tests from the launchpad/ptb_tests crate: {}",
        dir.display(),
    );
    dir
}

/// The repository's `sui/` directory.
pub fn sui_dir() -> PathBuf {
    crate_dir().join("../..").canonicalize().expect("sui directory")
}

/// The local immutable vesting package linked by `blast_presale`.
pub fn vesting_dir() -> Result<PathBuf> {
    Ok(sui_dir().join("vesting").canonicalize()?)
}

/// Compiles the vesting package from a copy in `work`, so building never writes into the source package.
pub fn build_vesting(work: &Path) -> Result<CompiledPackage> {
    build_copy(&vesting_dir()?, "blast_fun_vesting", work)
}

fn build_copy(source: &Path, name: &str, work: &Path) -> Result<CompiledPackage> {
    let copy = work.join(name);
    std::fs::create_dir_all(copy.join("sources"))?;
    std::fs::copy(source.join("Move.toml"), copy.join("Move.toml"))?;
    for entry in std::fs::read_dir(source.join("sources"))? {
        let path = entry?.path();
        std::fs::copy(&path, copy.join("sources").join(path.file_name().context("source name")?))?;
    }

    build(&copy, &[], work)
}
