#!/usr/bin/env python3
"""Generate llms-full.txt: the integrator guides plus an API reference of every first-party package.

The reference comes from `sui move summary` (types, functions, docs) and the Move source (events,
errors, constants). Deployment status comes from each package's Published.toml and the matching
record under deployments/sui/mainnet/. Every first-party name a guide writes in backticks must
resolve, or generation fails.

    python3 scripts/gen_llms.py            # rebuild summaries and write llms-full.txt
    python3 scripts/gen_llms.py --check    # fail when llms-full.txt is stale
    python3 scripts/gen_llms.py --summaries DIR   # reuse summaries from an earlier run
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "llms-full.txt"
GUIDES_DIR = ROOT / "docs" / "llms"
REPO_URL = "https://github.com/interest-protocol/blast-v2-contracts/blob/main"

# Reference order: what an integrator reaches for first.
PACKAGES = [
    ("sui/presale", "Presale"),
    ("sui/launchpad", "Launchpad"),
    ("sui/migrators", "Migration and LP vaults"),
    ("sui/partners", "Partner codes"),
    ("sui/boosts/core", "Boosts core"),
    ("sui/boosts/products", "Boost product tags"),
    ("sui/boosts/aftermath_adapter", "Boosts Aftermath adapter"),
    ("sui/blast_sui", "blastSUI and funSUI"),
    ("sui/admin", "Administration"),
    ("sui/vendors/aftermath_dao_presale", "Aftermath DAO-pool presale migrator"),
]
GUIDES = [
    "basics.md",
    "presale.md",
    "launchpad.md",
    "migrators.md",
    "partners.md",
    "boosts.md",
    "blast-sui.md",
    "admin.md",
]

# Framework types an integrator recognizes without a module prefix.
BARE_TYPES = {
    ("std", "option", "Option"),
    ("std", "string", "String"),
    ("std", "type_name", "TypeName"),
    ("sui", "object", "UID"),
    ("sui", "object", "ID"),
    ("sui", "tx_context", "TxContext"),
    ("sui", "clock", "Clock"),
    ("sui", "coin", "Coin"),
    ("sui", "coin", "TreasuryCap"),
    ("sui", "balance", "Balance"),
    ("sui", "balance", "Supply"),
    ("sui", "table", "Table"),
    ("sui", "bag", "Bag"),
    ("sui", "vec_map", "VecMap"),
    ("sui", "vec_set", "VecSet"),
    ("sui", "coin_registry", "Currency"),
    ("sui", "coin_registry", "CoinRegistry"),
    ("sui", "coin_registry", "MetadataCap"),
    ("sui", "package", "UpgradeCap"),
    ("sui", "package", "UpgradeTicket"),
    ("sui", "package", "UpgradeReceipt"),
    ("sui", "package", "Publisher"),
}

HEADER = """\
# Blast contracts: integrator reference

> Everything an integrator needs to understand and call Blast's Sui Move contracts: a bonding-curve launchpad whose graduated coins migrate into Cetus or Bluefin pools, standalone overflow presales, partner fee codes, Boost leverage coins on Aftermath perpetuals, and the funSUI/blastSUI staking vault. Sui mainnet only.

This file is self-contained. Give it to an AI agent and ask it anything about Blast's contracts.

How it is organized:

1. **Packages and deployment status**: every package, whether it is live on Sui mainnet, and its IDs.
2. **Guides**: how each product works end to end, starting with the calling conventions every product shares. Use them for behavior, flows, economics, and pitfalls.
3. **API reference**: generated from the Move source. Every public function and type with its doc comment, every event, every abort code, and the package constants. Use it for exact signatures and field layouts.

When the guides and the reference disagree, the reference is right: it is generated from the source on every change. When this file does not say a behavior exists, treat it as unsupported. Source for every module is linked from the reference ([repository]({repo})).

Conventions: amounts are atomic units of the coin named; rates are basis points (BPS) out of 10,000; times are Unix milliseconds from Sui's shared `Clock` at `0x6`. Types are written as Move: `module::Type` names a type in another module of the same package, `package::module::Type` one in another Blast package, and well-known Sui framework types appear bare.
"""


@dataclass
class Package:
    path: str
    title: str
    name: str
    modules: dict[str, dict] = field(default_factory=dict)
    sources: dict[str, Path] = field(default_factory=dict)
    events: set[str] = field(default_factory=set)
    envelope: bool = False


# --- Summaries -------------------------------------------------------------------------------------


def package_name(path: str) -> str:
    return tomllib.loads((ROOT / path / "Move.toml").read_text())["package"]["name"]


def build_summaries(out: Path) -> None:
    for path, _ in PACKAGES:
        name = package_name(path)
        result = subprocess.run(
            [
                "sui", "move", "summary",
                "-p", str(ROOT / path),
                "--output-directory", str(out / name),
                "--install-dir", str(out / f"build_{name}"),
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            sys.exit(f"sui move summary failed for {path}:\n{result.stdout}\n{result.stderr}")


def load_package(path: str, title: str, summaries: Path) -> Package:
    name = package_name(path)
    pkg = Package(path=path, title=title, name=name)
    summary_dir = summaries / name / name
    if not summary_dir.is_dir():
        sys.exit(f"no summary for {name} under {summaries / name}")
    for file in sorted(summary_dir.glob("*.json")):
        module = json.loads(file.read_text())
        pkg.modules[module["id"]["name"]] = module
    for file in sorted((ROOT / path / "sources").rglob("*.move")):
        match = re.search(rf"^module\s+{name}::(\w+)", file.read_text(), re.M)
        if match:
            pkg.sources[match.group(1)] = file
    text = "\n".join(strip_tests(f.read_text()) for f in pkg.sources.values())
    pkg.events = set(re.findall(r"\bemit\w*\s*\(\s*([A-Z]\w*)", text)) - {"Event"}
    pkg.envelope = "blast_events" in pkg.sources and re.search(
        r"public struct Event<", pkg.sources["blast_events"].read_text()
    ) is not None
    return pkg


def strip_tests(source: str) -> str:
    """Drops `#[test_only]`/`#[test]` items closely enough for event scanning."""
    return re.sub(r"#\[test(_only)?\][^\n]*\n(\s*///[^\n]*\n)*\s*(public\s+)?fun\s+\w+[^{]*\{", "", source)


# --- Rendering types -------------------------------------------------------------------------------


class TypeRenderer:
    def __init__(self, pkg: Package, module: str, first_party: set[str]):
        self.pkg, self.module, self.first_party = pkg, module, first_party

    def render(self, t) -> str:
        if isinstance(t, str):
            return t
        if "Reference" in t:
            mutable, inner = t["Reference"]
            return ("&mut " if mutable else "&") + self.render(inner)
        if "vector" in t:
            return f"vector<{self.render(t['vector'])}>"
        if "NamedTypeParameter" in t:
            return t["NamedTypeParameter"]
        if "TypeParameter" in t:
            return f"T{t['TypeParameter']}"
        data = t["Datatype"]
        addr, mod, name = data["module"]["address"], data["module"]["name"], data["name"]
        args = [self.render(a["argument"]) for a in data["type_arguments"]]
        if addr == self.pkg.name and mod == self.module or (addr, mod, name) in BARE_TYPES:
            prefix = ""
        elif addr == self.pkg.name:
            prefix = f"{mod}::"
        elif addr in self.first_party:
            prefix = f"{addr}::{mod}::"
        else:
            prefix = f"{mod}::"
        return prefix + name + (f"<{', '.join(args)}>" if args else "")


def doc_lines(doc: str | None, indent: str = "") -> list[str]:
    if not doc:
        return []
    return [f"{indent}///{line}".rstrip() for line in doc.split("\n")]


def abilities(abs_: list[str]) -> str:
    return f" has {', '.join(a.lower() for a in abs_)}" if abs_ else ""


def type_params(params: list[dict], struct: bool) -> str:
    if not params:
        return ""
    out = []
    for p in params:
        bound = " + ".join(c.lower() for c in p["constraints"])
        out.append(("phantom " if struct and p.get("phantom") else "") + p["name"] + (f": {bound}" if bound else ""))
    return f"<{', '.join(out)}>"


def render_fields(fields: dict, r: TypeRenderer, indent: str) -> tuple[str, list[str]]:
    """Returns the field form (`named`, `positional`, or `empty`) and its rendered lines."""
    items = sorted(fields["fields"].items(), key=lambda kv: kv[1]["index"])
    if not items or (len(items) == 1 and items[0][0] == "dummy_field"):
        return "empty", []
    if fields["positional_fields"]:
        return "positional", [", ".join(r.render(f["type_"]) for _, f in items)]
    lines = []
    for name, f in items:
        lines += doc_lines(f.get("doc"), indent)
        lines.append(f"{indent}{name}: {r.render(f['type_'])},")
    return "named", lines


def render_struct(name: str, s: dict, r: TypeRenderer) -> list[str]:
    head = f"public struct {name}{type_params(s['type_parameters'], True)}"
    kind, lines = render_fields(s["fields"], r, "    ")
    out = doc_lines(s.get("doc"))
    if kind == "empty":
        out.append(f"{head}(){abilities(s['abilities'])};" if s["abilities"] else f"{head} {{}}")
    elif kind == "positional":
        out.append(f"{head}({lines[0]}){abilities(s['abilities'])};")
    else:
        out += [f"{head}{abilities(s['abilities'])} {{", *lines, "}"]
    return out


def render_enum(name: str, e: dict, r: TypeRenderer) -> list[str]:
    out = doc_lines(e.get("doc"))
    out.append(f"public enum {name}{type_params(e['type_parameters'], True)}{abilities(e['abilities'])} {{")
    for vname, v in sorted(e["variants"].items(), key=lambda kv: kv[1]["index"]):
        out += doc_lines(v.get("doc"), "    ")
        kind, lines = render_fields(v["fields"], r, "        ")
        if kind == "empty":
            out.append(f"    {vname},")
        elif kind == "positional":
            out.append(f"    {vname}({lines[0]}),")
        else:
            out += [f"    {vname} {{", *lines, "    },"]
    out.append("}")
    return out


def render_function(name: str, f: dict, r: TypeRenderer) -> list[str]:
    prefix = ("public " if f["visibility"] == "Public" else "") + ("entry " if f["entry"] else "")
    params = [f"{p['name']}: {r.render(p['type_'])}" for p in f["parameters"]]
    returns = [r.render(t) for t in f["return_"]]
    ret = "" if not returns else f": {returns[0]}" if len(returns) == 1 else f": ({', '.join(returns)})"
    head = f"{prefix}fun {name}{type_params(f['type_parameters'], False)}"
    one_line = f"{head}({', '.join(params)}){ret}"
    out = doc_lines(f.get("doc"))
    if len(one_line) <= 100:
        out.append(one_line)
    else:
        out += [f"{head}(", *[f"    {p}," for p in params], f"){ret}"]
    return out


# --- Source facts: errors and constants -------------------------------------------------------------

DOC_BLOCK = r"((?:[ \t]*///[^\n]*\n)*)"


def docs_from(block: str) -> str:
    return " ".join(line.strip()[3:].strip() for line in block.strip().splitlines())


def clever_errors(source: str) -> list[tuple[str, str | None, str]]:
    """`#[error]` constants: (name, explicit code, message)."""
    pattern = re.compile(
        r"#\[error(?:\(code\s*=\s*(\d+)\))?\]\s*" + DOC_BLOCK
        + r"\s*const\s+(E\w+)\s*:\s*(?:vector<u8>\s*=\s*b\"((?:[^\"\\]|\\.)*)\"|u64\s*=\s*(\d+))\s*;"
    )
    out = []
    for m in pattern.finditer(source):
        code, doc, name, message, number = m.groups()
        out.append((name, code or number, message or docs_from(doc)))
    return out


def registry_errors(source: str) -> list[tuple[int, str, str]]:
    """An `errors` registry: test-only constants mirror the numeric macros callers abort with."""
    pattern = re.compile(r"#\[test_only\]\s*" + DOC_BLOCK + r"\s*const\s+(E\w+)\s*:\s*u64\s*=\s*(\d+)\s*;")
    return sorted((int(n), name, docs_from(doc)) for doc, name, n in pattern.findall(source))


def constants(source: str) -> list[tuple[str, str, str, str]]:
    """Non-error constants and package constant macros: (name, type, value, doc)."""
    out = []
    plain = re.compile(r"(?<!#\[test_only\]\n)" + DOC_BLOCK + r"[ \t]*const\s+([A-Z][A-Z0-9_]+)\s*:\s*([^=]+?)\s*=\s*([^;]+);")
    for doc, name, type_, value in plain.findall(source):
        out.append((name, type_.strip(), " ".join(value.split()), docs_from(doc)))
    macro = re.compile(DOC_BLOCK + r"[ \t]*macro public\(package\) fun\s+(\w+)\(\)\s*:\s*([^{]+?)\s*\{\s*([^}]*?)\s*\}")
    for doc, name, type_, value in macro.findall(source):
        out.append((name, type_.strip(), " ".join(value.split()), docs_from(doc)))
    return out


# --- Deployment status ------------------------------------------------------------------------------


def deployment(path: str) -> dict:
    published = ROOT / path / "Published.toml"
    if not published.exists():
        return {"live": False}
    entry = tomllib.loads(published.read_text())["published"]["mainnet"]
    info = {"live": True, "published_at": entry["published-at"], "original_id": entry["original-id"], "matches": None}
    for record in sorted((ROOT / "deployments/sui/mainnet").glob("*.json")):
        text = record.read_text()
        data = json.loads(text)
        if entry["published-at"] not in text or "deployment" not in str(data.get("recordKind", "")):
            continue
        if "rehearsal" in str(data.get("recordKind")) or data.get("status") != "success":
            continue
        commit = (data.get("repository") or {}).get("commit")
        if not commit:
            continue
        diff = subprocess.run(
            ["git", "diff", "--quiet", commit, "--", f"{path}/sources", f"{path}/Move.toml"],
            cwd=ROOT,
            capture_output=True,
        )
        if diff.returncode in (0, 1):
            info["matches"] = diff.returncode == 0
    return info


def status_text(info: dict) -> str:
    if not info["live"]:
        return "Not yet published on mainnet. Its interface may change before publication."
    if info["matches"] is True:
        return "Live on mainnet. This reference matches the published source."
    if info["matches"] is False:
        return (
            "Live on mainnet, published from an earlier revision. The source documented here has "
            "changed since; until it is republished, confirm signatures against the live package."
        )
    return "Live on mainnet."


# --- Assembly ---------------------------------------------------------------------------------------


def status_table(pkgs: list[Package]) -> list[str]:
    out = [
        "## Packages and deployment status",
        "",
        "Call a live package at its package ID (`published-at`). Types and events are named by the "
        "package that first defined them (`original-id`), which stays the same across upgrades.",
        "",
        "| Package | Product | Status | Package ID (`published-at`) | Type origin (`original-id`) |",
        "| --- | --- | --- | --- | --- |",
    ]
    for pkg in pkgs:
        info = deployment(pkg.path)
        if info["live"]:
            short = "live" if info["matches"] is not False else "live; source has changed since"
            out.append(f"| `{pkg.name}` | {pkg.title} | {short} | `{info['published_at']}` | `{info['original_id']}` |")
        else:
            out.append(f"| `{pkg.name}` | {pkg.title} | not yet published | — | — |")
    return out + [""]


def module_reference(pkg: Package, mod: str, first_party: set[str]) -> list[str]:
    summary = pkg.modules[mod]
    r = TypeRenderer(pkg, mod, first_party)
    source = pkg.sources[mod].read_text()
    events = {n: s for n, s in summary["structs"].items() if n in pkg.events}
    def position(name: str) -> int:
        match = re.search(rf"public\s+(?:struct|enum)\s+{name}\b", source)
        return match.start() if match else len(source)

    types = [("s", n, s) for n, s in summary["structs"].items() if n not in events]
    types += [("e", n, e) for n, e in summary.get("enums", {}).items()]
    types.sort(key=lambda t: position(t[1]))
    functions = sorted(
        ((n, f) for n, f in summary["functions"].items() if f["visibility"] == "Public" or f["entry"]),
        key=lambda nf: nf[1]["source_index"],
    )
    errors = clever_errors(source)
    consts = [] if mod == "errors" else constants(source)
    if not (types or functions or events or errors or consts):
        return []
    rel = pkg.sources[mod].relative_to(ROOT)
    out = [f"### `{pkg.name}::{mod}`", ""]
    if summary.get("doc"):
        out += [" ".join(l.strip() for l in summary["doc"].split("\n")), ""]
    out += [f"Source: {REPO_URL}/{rel}", ""]
    for label, items, render in (
        ("Types", types, lambda t: render_struct(t[1], t[2], r) if t[0] == "s" else render_enum(t[1], t[2], r)),
        ("Functions", functions, lambda nf: render_function(nf[0], nf[1], r)),
        ("Events", sorted(events.items(), key=lambda kv: position(kv[0])), lambda kv: render_struct(kv[0], kv[1], r)),
    ):
        if not items:
            continue
        out += [f"#### {label}", "", "```move"]
        for i, item in enumerate(items):
            out += ([""] if i else []) + render(item)
        out += ["```", ""]
    if errors:
        out += ["#### Errors", "", "| Constant | Code | Message |", "| --- | --- | --- |"]
        out += [f"| `{n}` | {c if c is not None else '—'} | {m} |" for n, c, m in errors]
        out.append("")
    if consts:
        out += ["#### Constants", ""]
        out += [f"- `{n}: {t} = {v}`" + (f": {d}" if d else "") for n, t, v, d in consts]
        out.append("")
    return out


def package_reference(pkg: Package, first_party: set[str]) -> list[str]:
    info = deployment(pkg.path)
    out = [f"## API reference: `{pkg.name}` ({pkg.title})", "", status_text(info), ""]
    out.append(
        f"Events: every payload is emitted inside `{pkg.name}::blast_events::Event<T>`; filter on that type."
        if pkg.envelope
        else "Events: payload structs are emitted directly, each under its own type."
    )
    out.append("")
    if "errors" in pkg.sources:
        rows = registry_errors(pkg.sources["errors"].read_text())
        out += [
            "Abort codes: this package aborts with the numeric codes below from whichever module detects "
            "the failure; the abort location names that module.",
            "",
            "| Code | Constant | Meaning |",
            "| --- | --- | --- |",
            *[f"| {n} | `{name}` | {doc} |" for n, name, doc in rows],
            "",
        ]
    for mod in sorted(pkg.modules):
        out += module_reference(pkg, mod, first_party)
    return out


# --- Guide name check -------------------------------------------------------------------------------

NAME = re.compile(r"`([a-z_][a-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*){1,2})(?:<[^`]*>|\([^`]*\))?`")


def check_guides(guides: dict[str, str], pkgs: list[Package]) -> list[str]:
    by_pkg = {p.name: p for p in pkgs}
    owners: dict[str, list[Package]] = {}
    for p in pkgs:
        for mod in p.modules:
            owners.setdefault(mod, []).append(p)

    def members(p: Package, mod: str) -> set[str]:
        s = p.modules[mod]
        public = {n for n, f in s["functions"].items() if f["visibility"] == "Public" or f["entry"]}
        names = public | set(s["structs"]) | set(s.get("enums", {}))
        source = p.sources[mod].read_text()
        names |= {e[0] for e in clever_errors(source)} | {c[0] for c in constants(source)}
        if mod == "errors":
            names |= {e[1] for e in registry_errors(source)}
        return names

    problems = []
    for guide, text in guides.items():
        for ref in sorted(set(NAME.findall(text))):
            parts = ref.split("::")
            if parts[0] in by_pkg:
                p = by_pkg[parts[0]]
                if len(parts) == 2 and parts[1] not in p.modules and parts[0] in p.modules:
                    # A package whose main module shares its name: `blast_presale::new`.
                    if parts[1] not in members(p, parts[0]):
                        problems.append(f"{guide}: `{ref}`: no public member {parts[1]} in {p.name}::{parts[0]}")
                elif parts[1] not in p.modules:
                    problems.append(f"{guide}: `{ref}`: {p.name} has no module {parts[1]}")
                elif len(parts) == 3 and parts[2] not in members(p, parts[1]):
                    problems.append(f"{guide}: `{ref}`: no public member {parts[2]}")
            elif parts[0] in owners and len(parts) == 2:
                found = owners[parts[0]]
                if len(found) > 1:
                    problems.append(f"{guide}: `{ref}`: qualify with the package; {parts[0]} is in " + ", ".join(p.name for p in found))
                elif parts[1] not in members(found[0], parts[0]):
                    problems.append(f"{guide}: `{ref}`: no public member {parts[1]} in {found[0].name}::{parts[0]}")
    return problems


# --- Main -------------------------------------------------------------------------------------------


def generate(summaries: Path) -> str:
    pkgs = [load_package(path, title, summaries) for path, title in PACKAGES]
    first_party = {p.name for p in pkgs}
    guides = {g: (GUIDES_DIR / g).read_text().strip() for g in GUIDES if (GUIDES_DIR / g).exists()}
    missing = [g for g in GUIDES if g not in guides]
    if missing:
        sys.exit(f"missing guides: {', '.join(missing)}")
    problems = check_guides(guides, pkgs)
    if problems:
        sys.exit("guides name members that do not resolve:\n  " + "\n  ".join(problems))
    out = [HEADER.format(repo=REPO_URL.rsplit("/blob/", 1)[0]), *status_table(pkgs)]
    for g in GUIDES:
        out += [guides[g], ""]
    for pkg in pkgs:
        out += package_reference(pkg, first_party)
    return "\n".join(out).rstrip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail when llms-full.txt is stale")
    parser.add_argument("--summaries", type=Path, help="reuse `sui move summary` output from this directory")
    args = parser.parse_args()
    if args.summaries:
        text = generate(args.summaries)
    else:
        with tempfile.TemporaryDirectory() as tmp:
            build_summaries(Path(tmp))
            text = generate(Path(tmp))
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != text:
            sys.exit("llms-full.txt is stale: run python3 scripts/gen_llms.py")
        print("llms-full.txt is current.")
        return
    OUTPUT.write_text(text)
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({len(text.splitlines())} lines)")


if __name__ == "__main__":
    main()
