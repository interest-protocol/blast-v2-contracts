#!/usr/bin/env python3
"""Pin the complete public mutation surface and custody-before-activation boundary."""
from pathlib import Path
import re

SOURCES = Path(__file__).resolve().parent.parent / "sources"
GUARDED = {'blast_presale': ['new', 'set_supply', 'set_token_allocations', 'set_participant_vesting', 'set_raise', 'set_windows', 'set_eligibility', 'set_uncapped_phase', 'set_hard_cap', 'set_fee_split', 'set_partner', 'finalize', 'share', 'set_protocol_fees', 'commit_open', 'commit_allowlisted', 'commit_uncapped', 'settle', 'cancel_unlaunched', 'claim', 'migrate', 'pay_protocol_fees_with_partner'], 'creation_policy': ['set_quote_allowed', 'set_migration_witness_allowed', 'add_partner', 'remove_partner'], 'fee_policy': ['set_fees', 'set_destination'], 'bluefin': ['new', 'migrate', 'new_vault', 'collect_fees'], 'cetus': ['new', 'migrate', 'new_vault', 'collect_fees'], 'aftermath': ['new', 'finalize', 'share', 'migrate', 'collect_fees'], 'presale_vault': ['claim_migration_residuals', 'set_protocol_lp_fees', 'pay_protocol_lp_fees_with_partner'], 'holder_rewards': ['publish_round', 'claim', 'settle_gas_reserve', 'close_round'], 'package_admin': ['authorize_upgrade', 'commit_upgrade_and_advance']}
# Pure constructors/readers and deletion of an inert, caller-owned cap need no version.
EXEMPT = {"wrap", "destroy_cap"}

def functions(source):
    source = source.split("// === Test-Only Functions ===")[0]
    for match in re.finditer(r"^public fun (\w+)", source, re.M):
        body = source.index("{", match.end())
        yield match[1], source[match.start():body], source[body + 1:source.index("\n}", body)]

for module, names in GUARDED.items():
    found = {}
    for name, signature, body in functions((SOURCES / (module + ".move")).read_text()):
        found[name] = (signature, body)
        # Any new function accepting mutable state must be explicitly reviewed.
        if "&mut " in signature and name not in names and name not in EXEMPT:
            raise AssertionError(f"Unreviewed mutable entry point: {module}::{name}")
    for name in names:
        signature, body = found[name]
        guard = "assert_next" if name == "commit_upgrade_and_advance" else "assert_current"
        assert "package_version: &" in signature, (module, name)
        assert body.strip().startswith(f"package_version.{guard}();"), (module, name)

admin = (SOURCES / "package_admin.move").read_text().split("// === Test-Only Functions ===")[0]
wrap = dict((name, body) for name, _, body in functions(admin))["wrap"]
assert wrap.index("bootstrap.destroy()") < wrap.index("upgrade_custody::new") < wrap.index("generation.share_version(ctx)")
assert "receipt);\n    package_version.advance();" in admin
marker = (SOURCES / "blast_presale_package.move").read_text().split("// === Test-Only Functions ===")[0]
assert "public struct Bootstrap has key {" in marker
assert "public struct PackageVersion has key {" in marker
init = marker.split("fun init(")[1].split("// === Package Functions ===")[0]
assert "share_object" not in init
assert "public(package) fun share_version(" in marker
assert "public(package) fun destroy(" in marker
assert sum(p.read_text().split("// === Test-Only Functions ===")[0].count(".share_version(") for p in SOURCES.glob("*.move")) == 1
print("Presale activation and version boundaries: OK")
