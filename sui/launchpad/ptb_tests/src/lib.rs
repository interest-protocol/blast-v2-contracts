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
        Argument, ObjectArg, ProgrammableTransaction, SharedObjectMutability, Transaction,
        TransactionData,
    },
};

/// The Sui revision `Cargo.toml` pins for the simulator. The CLI that compiles the packages must
/// be built from the same revision, or bytecode and framework could disagree.
const PINNED_SUI_REVISION: &str = "51d177ad7d65";

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
            "building {} failed:\n{}",
            package.display(),
            String::from_utf8_lossy(&output.stderr)
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
    let mut command = sui_move_build(package, work)?;
    let output = command.args(["-e", "mainnet"]).output().context("run the sui CLI")?;
    if !output.status.success() {
        bail!("building {} failed:\n{}", package.display(), String::from_utf8_lossy(&output.stderr));
    }
    let bytecode = package.join("build").join(name).join("bytecode_modules");
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

/// A `sui move build` command for `package` under the pinned CLI and an offline client config.
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

    /// IDs of created objects whose type is `module::name`.
    pub fn created(&self, harness: &Harness, module: &str, name: &str) -> Vec<ObjectID> {
        self.effects
            .created()
            .into_iter()
            .map(|(object, _)| object.0)
            .filter(|id| harness.is_type(*id, module, name))
            .collect()
    }

    /// Payload bytes of Blast events whose payload type is `module::name`. Blast wraps every
    /// payload in `blast_events::Event<T>`, whose BCS encoding is the payload's.
    pub fn events_of(&self, module: &str, name: &str) -> Vec<&[u8]> {
        self.events
            .iter()
            .filter(|event| {
                event.type_.module.as_str() == "blast_events"
                    && event.type_.name.as_str() == "Event"
                    && matches!(
                        event.type_.type_params.as_slice(),
                        [sui_types::TypeTag::Struct(payload)]
                            if payload.module.as_str() == module && payload.name.as_str() == name
                    )
            })
            .map(|event| event.contents.as_slice())
            .collect()
    }

    /// Payload type names of every event, in native order. Each event must be a `package` payload
    /// inside `package`'s `blast_events::Event<T>` envelope, so a bare or foreign event fails.
    pub fn wrapped_payloads(&self, package: ObjectID) -> Vec<String> {
        self.events
            .iter()
            .map(|event| {
                let envelope = &event.type_;
                assert!(
                    ObjectID::from(envelope.address) == package
                        && envelope.module.as_str() == "blast_events"
                        && envelope.name.as_str() == "Event",
                    "event {envelope} is not in the launchpad envelope"
                );
                let [sui_types::TypeTag::Struct(payload)] = envelope.type_params.as_slice() else {
                    panic!("envelope {envelope} does not carry exactly one payload");
                };
                assert_eq!(ObjectID::from(payload.address), package, "foreign payload {payload}");
                payload.name.to_string()
            })
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
}

impl Harness {
    pub fn new() -> Result<Self> {
        let mut sim = Simulacrum::new_with_rng(StdRng::seed_from_u64(0xB1A57));
        let (sender, key, gas) = sim.funded_account(1_000 * MIST_PER_SUI)?;
        Ok(Self { sim, sender, key, gas: gas.0 })
    }

    pub fn gas_id(&self) -> ObjectID {
        self.gas
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
        let (effects, error) = self.sim.execute_transaction(transaction.clone())?;
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
        let (effects, error) = self.sim.execute_transaction_impersonating(transaction.clone())?;
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

    /// Seals the publication capabilities before any launchpad configuration or launch.
    pub fn wrap_launchpad(&mut self, package: ObjectID, publication: &Outcome) -> Result<ObjectID> {
        assert!(publication.created(self, "blast_fun", "PackageVersion").is_empty());
        let bootstrap = publication.created(self, "blast_fun", "Bootstrap");
        let cap = publication.created(self, "package", "UpgradeCap");
        assert_eq!(bootstrap.len(), 1);
        assert_eq!(cap.len(), 1);
        let (bootstrap_id, publisher, generation): (ObjectID, (ObjectID, String, String), u64) =
            bcs::from_bytes(&self.contents(bootstrap[0]))?;
        let cap_contents = self.contents(cap[0]);
        let mut builder = ProgrammableTransactionBuilder::new();
        let bootstrap_arg = builder.obj(self.owned(bootstrap[0]))?;
        let cap_arg = builder.obj(self.owned(cap[0]))?;
        call(&mut builder, package, "package_admin", "wrap", vec![], vec![bootstrap_arg, cap_arg]);
        let outcome = self.execute(builder.finish())?;
        outcome.assert_success();
        assert_eq!(outcome.effects.deleted().iter().map(|object| object.0).collect::<Vec<_>>(), vec![bootstrap_id]);
        // The simulator retains wrapped objects in its cache; transaction effects establish custody.
        assert_eq!(outcome.effects.wrapped().iter().map(|object| object.0).collect::<Vec<_>>(), cap);
        let version = outcome.created(self, "blast_fun", "PackageVersion");
        assert_eq!(version.len(), 1);
        let admin = outcome.created(self, "package_admin", "PackageAdmin");
        assert_eq!(admin.len(), 1);
        self.shared(admin[0], false);
        let (admin_id, sealed_publisher, sealed_caps): (ObjectID, (ObjectID, String, String), Vec<UpgradeCap>) =
            bcs::from_bytes(&self.contents(admin[0]))?;
        assert_eq!(admin_id, admin[0]);
        assert_eq!(sealed_publisher, publisher);
        assert_eq!(sealed_caps.len(), 1);
        assert_eq!(bcs::to_bytes(&sealed_caps[0])?, cap_contents);
        let (version_id, active_generation): (ObjectID, u64) = bcs::from_bytes(&self.contents(version[0]))?;
        assert_eq!((version_id, active_generation), (version[0], generation));

        Ok(version[0])
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
    ) -> Result<()> {
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

        Ok(())
    }
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

/// The repository's `sui/` directory.
pub fn sui_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().expect("sui directory")
}

/// Where the CLI checks out `name`, a git dependency of `sui/<package>` from blast-util-contracts.
/// Pubfiles name it by this path, as they name local packages.
fn git_dependency_dir(package: &str, name: &str) -> Result<PathBuf> {
    let manifest = std::fs::read_to_string(sui_dir().join(package).join("Move.toml"))?;
    let dependency = manifest
        .lines()
        .find(|line| line.starts_with(name))
        .with_context(|| format!("{package}'s {name} dependency"))?;
    let field = |key: &str| -> Result<&str> {
        let (_, rest) = dependency.split_once(&format!("{key} = \"")).with_context(|| format!("{name} {key}"))?;
        Ok(rest.split('"').next().unwrap_or_default())
    };
    let move_home = match std::env::var("MOVE_HOME") {
        Ok(home) => PathBuf::from(home),
        Err(_) => PathBuf::from(std::env::var("HOME")?).join(".move"),
    };
    let checkout = format!("{}_{}", field("git")?.replace([':', '/', '.'], "_"), field("rev")?);
    let dir = move_home.join("git").join(checkout).join(field("subdir")?);
    ensure!(
        dir.join("Move.toml").is_file(),
        "{} is missing; `sui move build` in sui/{package} fetches it",
        dir.display(),
    );

    Ok(dir)
}

/// The cached checkout of `blast_fun_timelock`, which `blast_admin` links.
pub fn timelock_dir() -> Result<PathBuf> {
    git_dependency_dir("admin", "blast_fun_timelock")
}

/// The cached checkout of `blast_fun_vesting`, which `blast_presale` links.
pub fn vesting_dir() -> Result<PathBuf> {
    git_dependency_dir("presale", "blast_fun_vesting")
}

/// Compiles the timelock from a copy in `work`, so building never writes into the CLI's cache.
pub fn build_timelock(work: &Path) -> Result<CompiledPackage> {
    build_copy(&timelock_dir()?, "blast_fun_timelock", work)
}

/// Compiles the vesting package from a copy in `work`, unpublished, as the timelock is.
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
