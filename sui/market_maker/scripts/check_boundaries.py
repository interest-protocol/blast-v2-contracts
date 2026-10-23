#!/usr/bin/env python3
"""Check the Blast market maker package's frozen dependencies and custody seams."""

from pathlib import Path
import re
import subprocess
import sys
import tomllib

BASELINE = "01d7659617abcd552cece6d05b9db409ec4ff2c0"
PACKAGE = Path(__file__).resolve().parents[1]
REPOSITORY = PACKAGE.parents[1]
FROZEN = ("sui/launchpad", "sui/migrators", "sui/presale", "sui/admin", "sui/partners")


def git(*arguments: str) -> str:
    return subprocess.check_output(
        ["git", *arguments], cwd=REPOSITORY, text=True, stderr=subprocess.PIPE
    ).strip()


def without_comments(source: str) -> str:
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"//[^\n]*", "", source)


def check() -> list[str]:
    failures: list[str] = []

    def require(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    git("cat-file", "-e", f"{BASELINE}^{{commit}}")
    for directory in FROZEN:
        require(not git("diff", BASELINE, "--", directory), f"Frozen dependency changed: {directory}")
        require(
            not git("ls-files", "--others", "--exclude-standard", "--", directory),
            f"New untracked source in frozen dependency: {directory}",
        )

    manifest = tomllib.loads((PACKAGE / "Move.toml").read_text())
    dependencies = manifest["dependencies"]
    require("blast_fun" in dependencies and "blast_presale" in dependencies, "Both frozen core dependencies are required")
    require("blast_partners" in dependencies, "Creator-selected partner objects must be an explicit dependency")
    require("blast_admin" in dependencies, "Blast ACL must be an explicit dependency")
    require("blast_fun_migrators" not in dependencies, "Existing Migrators must remain independent")

    sources = {
        path.stem: without_comments(path.read_text())
        for path in sorted((PACKAGE / "sources").glob("*.move"))
    }
    for name, source in sources.items():
        require(f"module blast_market_maker::{name};" in source, f"Wrong module identity: {name}")
        require("blast_fun_migrators::" not in source, f"Existing Migrators internals imported in {name}")
        if re.search(r"\bfun\s+init\s*\(", source):
            require(name == "blast_market_maker", f"Only the marker may initialize singletons: {name}")
        if re.search(r"\bstruct\s+Witness\b", source):
            require(name in {"cetus_migrator", "presale_adapter"}, f"Unexpected migration witness in {name}")
            require("struct Witness() has drop;" in source, f"Witness must have a sealed positional constructor: {name}")
        if re.search(r"\blaunch::(?:new|migrate|treasury_cap_mut)\s*(?:<|\()", source):
            require(name == "cetus_migrator", f"Bonding seam used outside its adapter: {name}")
        if re.search(r"\bpresale::(?:new|migrate)\s*(?:<|\()", source):
            require(name == "presale_adapter", f"Presale seam used outside its adapter: {name}")
        if name in {"cetus_migrator", "presale_adapter"}:
            other = "presale_adapter" if name == "cetus_migrator" else "cetus_migrator"
            require(other not in source, f"Adapters must not depend on each other: {name}")
        if re.search(r"\bpool::\w+\s*(?:<|\()", source):
            require(name == "cetus_engine", f"Pool execution must belong to shared engine: {name}")
        if re.search(r"\blp_burn::\w+\s*(?:<|\()", source):
            require(name == "cetus_engine", f"LP Burn execution must belong to shared engine: {name}")
        # Public production functions cannot return raw custody objects or witnesses.
        # Test-only fixture seams deliberately have separate compiler-only visibility.
        for match in re.finditer(r"public fun\s+\w+[\s\S]*?(?=\{)", source):
            prefix = source[: match.start()].rstrip()
            attributes = prefix.rsplit("}", 1)[-1].rsplit(";", 1)[-1]
            if "#[test_only]" in attributes:
                continue
            signature = match.group()
            returns = signature.rsplit(")", 1)[-1]
            require(
                not re.search(r"\b(?:BlastMarketMakerVault|Position|CetusLPBurnProof|Witness|PoolCreationCap|UpgradeCap)\b", returns),
                f"Public custody escape in {name}: {signature.splitlines()[0]}",
            )
        require(
            not re.search(r"(?:take_escrowed_child|remove)\s*(?:<[^;]*?>)?\s*\([^;]*?BaseProofKey\(", source, re.S),
            f"Burned base proof must never be removed: {name}",
        )

    # Every public construction route must require a real partner; neither adapter
    # may bypass the upstream initializer admission check with a raw ID/None path.
    for adapter, function in (
        ("cetus_migrator", "create_and_share"),
        ("cetus_migrator", "launch_buy_and_share"),
        ("presale_adapter", "create_and_share"),
    ):
        signature = sources[adapter].split(f"public fun {function}<", 1)[1].split(") {", 1)[0]
        require("partner: &Partner" in signature, f"Required creator-selected partner omitted: {adapter}::{function}")
    for adapter, core in (("cetus_migrator", "launch"), ("presale_adapter", "presale")):
        require(f"{core}::set_partner(" in sources[adapter], f"Core partner binding missing: {adapter}")

    # Reservation fixes tick spacing. A later fee-rate edit must not become a new
    # wrapper veto over an already funded/graduated migration. This is a source
    # regression gate; real changed-tier execution still needs venue runtime proof.
    for adapter, function in (("cetus_migrator", "migrate_and_activate"), ("presale_adapter", "migrate")):
        body = sources[adapter].split(f"public fun {function}<", 1)[1].split("\npublic fun ", 1)[0]
        require("EVenueRateChanged" not in body and "get_fee_rate(" not in body,
                f"Migration must not veto settlement after a venue tier-rate edit: {adapter}")

    require("event::emit" not in sources["blast_market_maker"],
            "Publication marker initialization must remain eventless; native effects own created IDs")
    created_event = re.search(r"public struct BlastCurveMarketMakerCreated[^}]+", sources["cetus_migrator"])
    require(created_event is not None and "ticket_supplier" not in created_event.group(),
            "Curve creation must not restate transaction sender in its event")

    require("protocol_admin" not in sources, "Parallel local administration must not return")
    for owner, role in (("market_maker_fee_policy", "FeeAdmin"), ("protocol_treasury", "TreasuryAdmin"), ("package_admin", "UpgradeAdmin")):
        require(f"AdminWitness<{role}>" in sources[owner], f"Typed Blast ACL authority missing: {owner}")
    for adapter in ("cetus_migrator", "presale_adapter"):
        require("creator: &BlastMarketMakerCreatorCap" in sources[adapter], f"Reusable creator authority missing: {adapter}")

    require(manifest["package"]["name"] == "blast_market_maker", "Blast package identity missing")
    require("public struct BLAST_MARKET_MAKER()" in sources["blast_market_maker"], "Blast Publisher marker missing")
    for name, source in sources.items():
        for event in re.findall(r"(?:event::emit|sui::event::emit)\s*(?:<[^>]+>)?\s*\(\s*(\w+)", source):
            require(event.startswith("Blast"), f"Event lacks Blast identity: {name}::{event}")
        for visible in re.findall(r"public struct (\w+)(?:<[^>]+>)?\s+has\s+key", source):
            require(visible.startswith("Blast"), f"Object lacks Blast identity: {name}::{visible}")

    market_maker = sources["market_maker"]
    require(
        bool(re.search(r"struct BlastMarketMakerVault<[^>]+>\s+has\s+key\s*\{", market_maker)),
        "Vault must remain key-only without store",
    )
    require(
        bool(re.search(r"struct BlastMarketMakerCreatorCap\s+has\s+key,\s*store\s*\{", market_maker)),
        "Reusable creator cap must support native transfer",
    )
    require(
        bool(re.search(r"struct InitialGeneration\s+has\s+store\s*\{", sources["package_version"])),
        "Initial generation must be linear: store, without copy/drop",
    )
    for expression, owner in (
        (r"package_version::initial_generation\s*\(", "blast_market_maker"),
        (r"package_version::activate\s*\(", "package_admin"),
        (r"protocol_treasury::new\s*\(", "blast_market_maker"),
        (r"market_maker_fee_policy::new\s*\(", "blast_market_maker"),
    ):
        callers = [name for name, source in sources.items() for _ in re.finditer(expression, source)]
        require(callers == [owner], f"Expected one canonical production caller of {expression}: {callers}")

    return failures


def main() -> int:
    try:
        failures = check()
    except (OSError, KeyError, subprocess.CalledProcessError, tomllib.TOMLDecodeError) as error:
        print(f"Boundary check could not complete: {error}", file=sys.stderr)
        return 1
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print("Blast ACL/custody boundaries hold; Launchpad, Migrators, Presale, Admin and Partners match the frozen baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
