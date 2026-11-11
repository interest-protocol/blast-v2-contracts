//! Publication, bootstrap and transaction builders for `blast_sui` on a several-validator
//! simulator, shared by the composition tests.

use anyhow::{Context, Result, ensure};
use sui_types::{
    SUI_CLOCK_OBJECT_ID, SUI_DISPLAY_REGISTRY_OBJECT_ID, SUI_SYSTEM_PACKAGE_ID, SUI_SYSTEM_STATE_OBJECT_ID,
    TypeTag,
    base_types::{ObjectID, SuiAddress},
    gas_coin::MIST_PER_SUI,
    parse_sui_type_tag,
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    sui_system_state::SuiSystemStateTrait,
    transaction::{Argument, Command, ProgrammableTransaction},
};

use crate::{Harness, Outcome, build, call, sui_dir};

/// The vault's seed: its fun reserve plus a blast bootstrap above the native minimum.
pub const SEED_MIST: u64 = 2 * MIST_PER_SUI;

/// A genesis validator and the staking pool it runs.
#[derive(Clone, Copy, Debug)]
pub struct Pool {
    pub validator: SuiAddress,
    pub pool_id: ObjectID,
}

/// A published and bootstrapped Blast SUI deployment.
pub struct BlastSui {
    pub admin: ObjectID,
    pub package: ObjectID,
    pub version: ObjectID,
    pub package_admin: ObjectID,
    pub vault: ObjectID,
    pub admin_cap: ObjectID,
    pub admin_publication: Outcome,
}

/// Every active validator and its pool, in active-set order.
pub fn active_pools(h: &Harness) -> Vec<Pool> {
    h.sim
        .system_state()
        .into_sui_system_state_summary()
        .active_validators
        .into_iter()
        .map(|validator| Pool { validator: validator.sui_address, pool_id: validator.staking_pool_id })
        .collect()
}

/// Advances to the next epoch, writing every active pool's exchange-rate entry.
pub fn advance_epoch(h: &mut Harness) {
    h.sim.create_checkpoint();
    h.sim.advance_epoch(Default::default());
}

impl BlastSui {
    /// Publishes `blast_admin` and `blast_sui` from the checkout, wraps the publication, creates
    /// the vault with `pools[0]`, admits the rest at the zero notice, raises the validator delay and
    /// releases every deposit bit: the runbook's bootstrap.
    pub fn deploy(h: &mut Harness, work: &std::path::Path, pools: &[Pool]) -> Result<Self> {
        let admin_source = sui_dir().join("governance/admin");
        let (admin, admin_publication) = h.publish(build(&admin_source, &[], work)?)?;
        let code = build(&sui_dir().join("defi/blast_sui"), &[(admin_source.as_path(), admin)], work)?;
        Self::deploy_code(h, admin, admin_publication, code, pools)
    }

    /// Bootstraps already compiled `blast_sui` bytecode against a published `blast_admin`.
    pub fn deploy_code(
        h: &mut Harness,
        admin: ObjectID,
        admin_publication: Outcome,
        code: crate::CompiledPackage,
        pools: &[Pool],
    ) -> Result<Self> {
        let (package, publication) = h.publish(code)?;
        let otw = parse_sui_type_tag(&format!("{package}::blast_sui_package::BLAST_SUI_PACKAGE"))?;

        let created_of = |h: &Harness, needle: &str| -> Result<ObjectID> {
            publication
                .effects
                .created()
                .iter()
                .map(|(object, _)| object.0)
                .find(|id| {
                    h.object(*id)
                        .data
                        .try_as_move()
                        .is_some_and(|object| object.type_().to_string().contains(needle))
                })
                .with_context(|| format!("publication created no {needle}"))
        };
        use sui_types::effects::TransactionEffectsAPI;
        let (fun, blast) = ("fun_sui::FUN_SUI", "blast_sui::BLAST_SUI");
        let fun_cap = created_of(h, &format!("TreasuryCap<{package}::{fun}>"))?;
        let blast_cap = created_of(h, &format!("TreasuryCap<{package}::{blast}>"))?;
        let fun_metadata = created_of(h, &format!("MetadataCap<{package}::{fun}>"))?;
        let blast_metadata = created_of(h, &format!("MetadataCap<{package}::{blast}>"))?;

        let publication_id = publication.created(h, "package_version", "Publication")[0];
        let upgrade_cap = publication.created(h, "package", "UpgradeCap")[0];
        let mut b = ProgrammableTransactionBuilder::new();
        let publication_arg = b.obj(h.owned(publication_id))?;
        let upgrade_cap_arg = b.obj(h.owned(upgrade_cap))?;
        call(&mut b, admin, "package_admin", "wrap", vec![otw.clone()], vec![publication_arg, upgrade_cap_arg]);
        let wrapped = h.execute(b.finish())?;
        wrapped.assert_success();
        let version = wrapped.created(h, "package_version", "PackageVersion")[0];
        let package_admin = wrapped.created(h, "package_admin", "PackageAdmin")[0];

        let domain = |role: &str| parse_sui_type_tag(&format!("{package}::blast_sui_domain::{role}"));
        let unpause = parse_sui_type_tag(&format!("{admin}::package_admin::UnpauseAdmin<{otw}>"))?;
        let admin_cap = h.grant_roles(
            admin,
            &admin_publication,
            &[domain("FeeAdmin")?, domain("CancelAdmin")?, domain("ValidatorAdmin")?, unpause.clone()],
        )?;

        let mut b = ProgrammableTransactionBuilder::new();
        let version_arg = b.obj(h.shared(version, false))?;
        let system = b.obj(h.shared(SUI_SYSTEM_STATE_OBJECT_ID, true))?;
        let registry = b.obj(h.shared(SUI_DISPLAY_REGISTRY_OBJECT_ID, true))?;
        let (fun_cap, blast_cap) = (b.obj(h.owned(fun_cap))?, b.obj(h.owned(blast_cap))?);
        let (fun_metadata, blast_metadata) = (b.obj(h.owned(fun_metadata))?, b.obj(h.owned(blast_metadata))?);
        let seed = split_gas(&mut b, SEED_MIST)?;
        let pool_id = b.pure(pools[0].pool_id)?;
        let clock = b.obj(h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(
            &mut b,
            package,
            "vault",
            "create",
            vec![],
            vec![version_arg, system, registry, fun_cap, blast_cap, fun_metadata, blast_metadata, seed, pool_id, clock],
        );
        let created = h.execute(b.finish())?;
        created.assert_success();
        let vault = created.created(h, "vault", "Vault")[0];
        ensure!(h.object(vault).is_shared(), "the vault is shared");

        let stack =
            Self { admin, package, version, package_admin, vault, admin_cap, admin_publication };
        for pool in &pools[1..] {
            stack.admit(h, pool)?;
        }
        stack.release(h, unpause)?;

        Ok(stack)
    }

    fn role(&self, name: &str) -> Result<TypeTag> {
        Ok(parse_sui_type_tag(&format!("{}::blast_sui_domain::{name}", self.package))?)
    }

    /// Schedules and applies one admission in one transaction; ready at once at the zero notice.
    pub fn admit(&self, h: &mut Harness, pool: &Pool) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let witness = h.sign_in_as(&mut b, self.admin, &self.admin_publication, self.admin_cap, self.role("ValidatorAdmin")?)?;
        let vault = b.obj(h.shared(self.vault, true))?;
        let version = b.obj(h.shared(self.version, false))?;
        let system = b.obj(h.shared(SUI_SYSTEM_STATE_OBJECT_ID, true))?;
        let pool_id = b.pure(pool.pool_id)?;
        let clock = b.obj(h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, self.package, "vault", "schedule_validator", vec![], vec![vault, version, witness, pool_id, clock]);
        call(&mut b, self.package, "vault", "apply_validator", vec![], vec![vault, version, system, pool_id, clock]);
        h.execute(b.finish())?.assert_success();
        Ok(())
    }

    /// Raises the validator delay to one millisecond and releases every deposit bit.
    fn release(&self, h: &mut Harness, unpause: TypeTag) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let validator_admin = h.sign_in_as(&mut b, self.admin, &self.admin_publication, self.admin_cap, self.role("ValidatorAdmin")?)?;
        let unpause_admin = h.sign_in_as(&mut b, self.admin, &self.admin_publication, self.admin_cap, unpause)?;
        let vault = b.obj(h.shared(self.vault, true))?;
        let version = b.obj(h.shared(self.version, true))?;
        let package_admin = b.obj(h.shared(self.package_admin, false))?;
        let clock = b.obj(h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        let delay = b.pure(1u64)?;
        let bits = b.pure(7u8)?;
        call(&mut b, self.package, "vault", "schedule_validator_delay", vec![], vec![vault, version, validator_admin, delay, clock]);
        call(&mut b, self.package, "vault", "apply_validator_delay", vec![], vec![vault, version, clock]);
        call(&mut b, self.package, "vault", "unpause", vec![], vec![vault, version, unpause_admin, package_admin, bits]);
        h.execute(b.finish())?.assert_success();
        Ok(())
    }

    /// The vault, package version and system state, in a call's leading argument order.
    pub fn inputs(&self, h: &Harness, b: &mut ProgrammableTransactionBuilder) -> Result<(Argument, Argument, Argument)> {
        Ok((
            b.obj(h.shared(self.vault, true))?,
            b.obj(h.shared(self.version, false))?,
            b.obj(h.shared(SUI_SYSTEM_STATE_OBJECT_ID, true))?,
        ))
    }

    /// `mint_fun_sui`, picking `pool`, returning the minted coin's argument.
    pub fn mint_fun(&self, h: &Harness, b: &mut ProgrammableTransactionBuilder, pool: ObjectID, amount: u64) -> Result<Argument> {
        let (vault, version, system) = self.inputs(h, b)?;
        let pool_id = b.pure(pool)?;
        let sui = split_gas(b, amount)?;
        Ok(call(b, self.package, "vault", "mint_fun_sui", vec![], vec![vault, version, system, pool_id, sui]))
    }

    /// `request_blast_sui`, picking `pool`, returning the receipt's argument.
    pub fn request_blast(&self, h: &Harness, b: &mut ProgrammableTransactionBuilder, pool: ObjectID, amount: u64) -> Result<Argument> {
        let (vault, version, system) = self.inputs(h, b)?;
        let pool_id = b.pure(pool)?;
        let sui = split_gas(b, amount)?;
        Ok(call(b, self.package, "vault", "request_blast_sui", vec![], vec![vault, version, system, pool_id, sui]))
    }

    /// Requests a deposit and keeps the receipt with the sender.
    pub fn request_and_keep(&self, h: &mut Harness, pool: ObjectID, amount: u64) -> Result<Outcome> {
        let mut b = ProgrammableTransactionBuilder::new();
        let receipt = self.request_blast(h, &mut b, pool, amount)?;
        call(&mut b, self.package, "deposit_receipt", "keep", vec![], vec![receipt]);
        h.execute(b.finish())
    }

    /// Mints funSUI and keeps it with the sender.
    pub fn mint_and_keep(&self, h: &mut Harness, pool: ObjectID, amount: u64) -> Result<Outcome> {
        let mut b = ProgrammableTransactionBuilder::new();
        let coin = self.mint_fun(h, &mut b, pool, amount)?;
        b.transfer_arg(h.sender, coin);
        h.execute(b.finish())
    }

    /// Claims `receipt` at any price and keeps the blastSUI with the sender.
    pub fn claim_and_keep(&self, h: &mut Harness, receipt: ObjectID) -> Result<Outcome> {
        let mut b = ProgrammableTransactionBuilder::new();
        let (vault, version, system) = self.inputs(h, &mut b)?;
        let receipt = b.obj(h.owned(receipt))?;
        let min_out = b.pure(0u64)?;
        let coin = call(&mut b, self.package, "vault", "claim_blast_sui", vec![], vec![vault, version, system, receipt, min_out]);
        b.transfer_arg(h.sender, coin);
        h.execute(b.finish())
    }

    /// The permissionless refresh and idle delegation.
    pub fn sync(&self, h: &mut Harness) -> Result<Outcome> {
        let mut b = ProgrammableTransactionBuilder::new();
        let (vault, version, system) = self.inputs(h, &mut b)?;
        call(&mut b, self.package, "vault", "sync", vec![], vec![vault, version, system]);
        h.execute(b.finish())
    }

    /// The sender's coins of a package coin type, largest set first in store order.
    pub fn coins_of(&self, h: &Harness, coin: &str) -> Vec<ObjectID> {
        let needle = format!("{}::{coin}", self.package);
        h.owned_by(h.sender)
            .into_iter()
            .filter(|object| {
                object.data.try_as_move().is_some_and(|data| {
                    let name = data.type_().to_string();
                    name.contains("coin::Coin<") && name.contains(&needle)
                })
            })
            .map(|object| object.id())
            .collect()
    }

    /// Merges `coins` in the transaction and returns the single coin argument.
    pub fn merged(&self, h: &Harness, b: &mut ProgrammableTransactionBuilder, coins: &[ObjectID]) -> Result<Argument> {
        let first = b.obj(h.owned(coins[0]))?;
        if coins.len() > 1 {
            let rest = coins[1..].iter().map(|coin| b.obj(h.owned(*coin))).collect::<Result<Vec<_>>>()?;
            b.command(Command::MergeCoins(first, rest));
        }
        Ok(first)
    }

    /// Has a genesis validator request its own removal, effective at the next epoch change.
    pub fn remove_from_active_set(&self, h: &mut Harness, validator: SuiAddress) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let system = b.obj(h.shared(SUI_SYSTEM_STATE_OBJECT_ID, true))?;
        call(&mut b, SUI_SYSTEM_PACKAGE_ID, "sui_system", "request_remove_validator", vec![], vec![system]);
        let pt: ProgrammableTransaction = b.finish();
        h.impersonate(validator, pt)?.assert_success();
        Ok(())
    }
}

/// Splits `amount` off the gas coin for use as a `Coin<SUI>` argument.
pub fn split_gas(b: &mut ProgrammableTransactionBuilder, amount: u64) -> Result<Argument> {
    let amount = b.pure(amount)?;
    Ok(b.command(Command::SplitCoins(Argument::GasCoin, vec![amount])))
}
