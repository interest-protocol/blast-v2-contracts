//! Publication must remain inactive until the original, never-upgraded cap enters custody.

use std::path::Path;

use anyhow::Result;
use blast_launchpad_ptb_tests::{Expected, Harness, build, build_timelock, call, sui_dir, timelock_dir};
use sui_types::{move_package::{MovePackage, UpgradeCap}, programmable_transaction_builder::ProgrammableTransactionBuilder};

#[test]
fn only_fresh_matching_custody_enables_the_launchpad() -> Result<()> {
    let work = Path::new(env!("CARGO_TARGET_TMPDIR")).join("launchpad_bootstrap");
    let sui = sui_dir();
    let timelock_dir = timelock_dir()?;
    let admin_dir = sui.join("admin");
    let partners_dir = sui.join("partners");
    let mut h = Harness::new()?;
    let (timelock, _) = h.publish(build_timelock(&work)?)?;
    let (admin, admin_publication) = h.publish(build(&admin_dir, &[(&timelock_dir, timelock)], &work)?)?;
    let (partners, _) = h.publish(build(&partners_dir, &[(&timelock_dir, timelock), (&admin_dir, admin)], &work)?)?;
    let code = build(
        &sui.join("launchpad"),
        &[(&timelock_dir, timelock), (&admin_dir, admin), (&partners_dir, partners)],
        &work,
    )?;
    let (blast, publication) = h.publish(code.clone())?;
    assert!(publication.created(&h, "blast_fun", "PackageVersion").is_empty());
    assert!(publication.created(&h, "package_admin", "PackageAdmin").is_empty());
    assert!(publication.created(&h, "package", "Publisher").is_empty());
    let bootstrap = publication.created(&h, "blast_fun", "Bootstrap")[0];
    let cap = publication.created(&h, "package", "UpgradeCap")[0];
    assert_eq!(bcs::from_bytes::<UpgradeCap>(&h.contents(cap))?.version, 1);
    let foreign_cap = admin_publication.created(&h, "package", "UpgradeCap")[0];

    let mut b = ProgrammableTransactionBuilder::new();
    let bootstrap_arg = b.obj(h.owned(bootstrap))?;
    let cap_arg = b.obj(h.owned(foreign_cap))?;
    call(&mut b, blast, "package_admin", "wrap", vec![], vec![bootstrap_arg, cap_arg]);
    h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: admin, module: "upgrade_custody", code: 16 },
        &[bootstrap, cap, foreign_cap],
        &[h.sender],
    )?;

    let version = h.wrap_launchpad(blast, &publication)?;
    h.shared(version, false);
    // Simulacrum resolves historical owned inputs; test_scenario covers repeated intake.
    assert!(h.sim.store().get_object(&bootstrap).is_none());

    // A native upgrade is possible before wrapping, but its cap can never activate this lineage.
    let (unwrapped, publication) = h.publish(code.clone())?;
    let bootstrap = publication.created(&h, "blast_fun", "Bootstrap")[0];
    let cap = publication.created(&h, "package", "UpgradeCap")[0];
    let digest = MovePackage::compute_digest_for_modules_and_deps(&code.modules, &code.dependencies, true);
    let framework = sui_types::SUI_FRAMEWORK_PACKAGE_ID;
    let mut b = ProgrammableTransactionBuilder::new();
    let cap_arg = b.obj(h.owned(cap))?;
    let policy = b.pure(0u8)?;
    let digest = b.pure(digest.to_vec())?;
    let ticket = call(&mut b, framework, "package", "authorize_upgrade", vec![], vec![cap_arg, policy, digest]);
    let receipt = b.upgrade(unwrapped, ticket, code.dependencies, code.modules);
    call(&mut b, framework, "package", "commit_upgrade", vec![], vec![cap_arg, receipt]);
    let upgraded = h.execute(b.finish())?;
    upgraded.assert_success();
    assert_eq!(bcs::from_bytes::<UpgradeCap>(&h.contents(cap))?.version, 2);
    assert!(upgraded.created(&h, "blast_fun", "PackageVersion").is_empty());
    let mut b = ProgrammableTransactionBuilder::new();
    let bootstrap_arg = b.obj(h.owned(bootstrap))?;
    let cap_arg = b.obj(h.owned(cap))?;
    call(&mut b, unwrapped, "package_admin", "wrap", vec![], vec![bootstrap_arg, cap_arg]);
    h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: admin, module: "upgrade_custody", code: 16 },
        &[bootstrap, cap],
        &[h.sender],
    )?;

    Ok(())
}
