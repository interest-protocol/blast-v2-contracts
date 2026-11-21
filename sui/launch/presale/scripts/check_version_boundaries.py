#!/usr/bin/env python3
"""Pin the complete public mutation surface and the generic package administration boundary."""
from pathlib import Path
import re
import subprocess

SOURCES = Path(__file__).resolve().parent.parent / "sources"
READER = SOURCES.parents[1] / "launchpad/scripts/move_facts.awk"
GUARD = "package_version.assert_current(constants::version!());"
GUARDED = {'blast_presale': ['new', 'set_supply', 'set_token_allocations', 'set_participant_vesting', 'set_raise', 'set_windows', 'set_eligibility', 'set_uncapped_phase', 'set_hard_cap', 'set_fee_split', 'set_partner', 'finalize', 'share', 'set_protocol_fees', 'commit_open', 'commit_allowlisted', 'commit_uncapped', 'settle', 'cancel_unlaunched', 'claim', 'migrate', 'prove_owner', 'pay_protocol_fees_with_partner'], 'creation_policy': ['schedule_venue_delay', 'apply_venue_delay', 'cancel_venue_delay', 'set_quote_allowed', 'schedule_venue', 'apply_venue', 'cancel_venue', 'remove_venue', 'add_partner', 'remove_partner', 'unpause'], 'fee_policy': ['schedule_fees', 'apply_fees', 'cancel_fees']}
# Deletion of an inert, caller-owned cap needs no version.
EXEMPT = {"destroy_cap"}

def functions(source):
    source = source.split("// === Test-Only Functions ===")[0]
    for match in re.finditer(r"^(?:public(?:\(package\))? )?fun (\w+)", source, re.M):
        body = source.index("{", match.end())
        yield match[1], source[match.start():body], source[body + 1:source.index("\n}", body)]

def module_path(module):
    paths = list(SOURCES.rglob(module + ".move"))
    assert len(paths) == 1, (module, paths)
    return paths[0]

for module, names in GUARDED.items():
    found = {}
    rows = subprocess.check_output(["awk", "-f", str(READER), str(module_path(module))], text=True)
    for row in rows.splitlines():
        if not row.startswith("FN\t"):
            continue
        _, name, visibility, entry, macro, test_only, _, _, signature, body = row.split("\t")
        if test_only == "1" or macro == "1":
            continue
        if visibility == "public":
            found[name] = (signature, body)
        # Entry functions can be called by a transaction at any visibility.
        if visibility != "public" and entry != "1":
            continue
        if re.search(r"&\s*mut\b", signature) and name not in names and name not in EXEMPT:
            raise AssertionError(f"Unreviewed mutable entry point: {module}::{name}")
    for name in names:
        signature, body = found[name]
        assert "PackageVersion<BLAST_PRESALE_PACKAGE>" in signature, (module, name)
        assert body.strip().startswith(GUARD), (module, name)

# The package defines no administration of its own: version, pause, upgrades and custody are
# blast_admin's generic objects, typed by the presale's one-time witness.
for path in SOURCES.rglob("*.move"):
    production = path.read_text().split("// === Test-Only Functions ===")[0]
    for forbidden in ("public struct Publication", "public struct PackageVersion", "public struct PackageAdmin",
                      "operational_version", "upgrade_custody", "UpgradeCap"):
        assert forbidden not in production, (path.name, forbidden)
assert not list(SOURCES.rglob("package_admin.move"))
otw = (SOURCES / "blast_presale_package.move").read_text().split("// === Test-Only Functions ===")[0]
assert "public struct BLAST_PRESALE_PACKAGE() has drop;" in otw
assert "public struct PackageWitness() has drop;" in otw
init = dict((name, body) for name, _, body in functions(otw))["init"]
assert "package_version::new_publication<_, PackageWitness>(otw, constants::valid_pause_bits!(), ctx)" in init
assert ".keep(ctx)" in init and "share_object" not in init
assert set(name for name, _, _ in functions(otw)) == {"init", "package_witness"}
assert "public(package) fun package_witness(): PackageWitness {" in otw
# Only the presale's unpause clears bits, after checking every presale delay.
callers = [(path.stem, name) for path in SOURCES.rglob("*.move")
           for name, _, body in functions(path.read_text()) if "clear_pause_bits(" in body]
assert callers == [("creation_policy", "unpause")], callers
unpause = dict((name, body) for name, _, body in functions(module_path("creation_policy").read_text()))["unpause"]
assert unpause.index("self.is_guarded() && fee_policy.is_guarded()") < unpause.index("clear_pause_bits(")
assert "package_admin.clear_pause_bits(unpause_admin, package_witness(), package_version, bits);" in unpause
print("Presale activation and version boundaries: OK")
