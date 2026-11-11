#!/usr/bin/env python3
"""Check the greenfield declaration and error conventions in AGENTS.md."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SECTIONS = [
    "Constants", "Package Constants", "Public Types",
    "Private Initialization", "Public Functions", "Package Functions",
    "Private Functions", "Test-Only Types", "Test-Only Functions",
    "Tests", "Test Helpers", "Errors", "Imports",
]
TRAILING = ["Constants", "Package Constants", "Errors"]
# A module may instead end with its events, constants and errors, just before Imports.
TAIL_SECTIONS = [name for name in SECTIONS if name not in TRAILING + ["Imports"]] + ["Events"] + TRAILING + ["Imports"]
# Published utilities retain their pre-consolidation section order: moving lines
# changes their source-position abort identities. All other checks still apply.
UTILITY_SECTIONS = [
    "Constants", "Public Types", "Public Functions", "Private Functions",
    "Test-Only Functions", "Events", "Errors", "Imports",
]
ERROR_NAME = r"E[A-Z](?=[A-Za-z0-9]*[a-z])[A-Za-z0-9]*"
# Exempt from the qualified-type rule only; every other style check still applies.
# blast_sui adopted the generic administration but keeps this exemption until its
# validator work resolves it; boosts is out of the one-way stack scope; scratch-sui
# is parked, out of scope.
QUALIFIED_TYPES_EXEMPT = ("sui/defi/blast_sui", "sui/defi/boosts", "scratch-sui")
# A lowercase module segment followed by a type segment: `module::Type`,
# `pkg::module::Type`, `module::Type::Variant`. Calls through a module
# (`payout::pay_or_vest`, `errors::x!`) and `Enum::Variant` stay allowed.
QUALIFIED_TYPE = re.compile(r"\b[a-z_][a-z0-9_]*::[A-Z]\w*")


def mask(source):
    """Keep offsets and newlines while hiding comments and string literals."""
    return re.sub(
        r'//[^\n]*|/\*[\s\S]*?\*/|b?"(?:\\.|[^"\\])*"',
        lambda match: re.sub(r"[^\n]", " ", match[0]), source,
    )


def mask_attributes_and_uses(text):
    """Hide attributes (abort_code and location paths) and use declarations."""
    spans = [match.span() for match in re.finditer(r"\b(?:public\s+)?use\b[^;]*;", text)]
    for match in re.finditer(r"#\[", text):
        depth, cursor = 1, match.end()
        while depth and cursor < len(text):
            depth += (text[cursor] == "[") - (text[cursor] == "]")
            cursor += 1
        spans.append((match.start(), cursor))
    chars = list(text)
    for start, end in spans:
        for index in range(start, end):
            if chars[index] != "\n":
                chars[index] = " "
    return "".join(chars)


def check_qualified_types(source):
    """Types are imported and named bare; only calls go through a module."""
    text = mask_attributes_and_uses(mask(source))
    hits = [
        f"line {text[:match.start()].count(chr(10)) + 1}: {match[0]}"
        for match in QUALIFIED_TYPE.finditer(text)
    ]
    if hits:
        raise ValueError("import types instead of qualifying them: " + "; ".join(hits))


def declarations(source):
    text = mask(source)
    module = re.search(r"\bmodule\s+[\w:]+\s*;", text)
    if not module:
        raise ValueError("expected a Move 2024 module declaration")
    cursor = module.end()
    while cursor < len(text):
        while cursor < len(text) and text[cursor].isspace():
            cursor += 1
        if cursor == len(text):
            return
        start = cursor
        while text[cursor:cursor + 2] == "#[":
            depth = 1
            cursor += 2
            while depth:
                depth += (text[cursor] == "[") - (text[cursor] == "]")
                cursor += 1
            while text[cursor].isspace():
                cursor += 1
        body = cursor
        match = re.match(
            r"(?:(?:public(?:\(package\))?|macro|entry|native)\s+)*"
            r"(const|fun|struct|enum|use)\b", text[body:],
        )
        if not match:
            raise ValueError(f"unrecognized declaration at line {source[:body].count(chr(10)) + 1}")
        kind = match[1]
        depth = 0
        while cursor < len(text):
            char = text[cursor]
            if char == "{":
                depth += 1
            if char == "}":
                depth -= 1
                if depth == 0 and kind not in ("use", "const"):
                    cursor += 1
                    if text[cursor:cursor + 1] == ";":
                        cursor += 1
                    break
            if char == ";" and depth == 0:
                cursor += 1
                break
            cursor += 1
        yield start, kind, text[start:body], source[body:cursor]


def section_for(path, test_module, kind, attributes, declaration, events):
    if kind == "use":
        return "Imports"
    if kind == "const":
        return "Errors" if re.match(rf"const {ERROR_NAME}:", declaration) else "Constants"
    if path.name == "errors.move":
        return "Errors"
    if path.name == "constants.move" and "macro" in declaration.split("fun")[0]:
        return "Package Constants"
    if kind in ("struct", "enum"):
        if test_module or "#[test_only]" in attributes:
            return "Test-Only Types"
        return "Events" if re.search(r"\b(?:struct|enum)\s+(\w+)", declaration)[1] in events else "Public Types"
    if test_module:
        return "Tests" if re.search(r"#\[\s*test(?:\s*[,\]])", attributes) else "Test Helpers"
    if "#[test_only]" in attributes:
        return "Test-Only Functions"
    if re.match(r"fun init\b", declaration):
        return "Private Initialization"
    if re.match(r"(?:macro )?public\(package\)", declaration):
        return "Package Functions"
    if re.match(r"(?:macro )?public\b", declaration):
        return "Public Functions"
    return "Private Functions"


def check_event_types(path, items):
    """Event modules own payload schemas, not storable or unrelated domain values."""
    if not path.stem.endswith("events"):
        return
    production = [mask(declaration) for _, _, attributes, declaration in items
                  if "#[test_only]" not in attributes]
    types = {}
    for _, kind, attributes, declaration in items:
        if kind not in ("struct", "enum") or "#[test_only]" in attributes:
            continue
        text = mask(declaration)
        name = re.search(r"\b(?:struct|enum)\s+(\w+)", text)[1]
        header = text.split("{")[0].split(";")[0]
        if re.search(r"\bhas\s+[^{};]*\b(?:key|store)\b", header):
            raise ValueError(f"{name}: declare stored domain values in their owning module, not event modules")
        types[name] = text
    payloads = set(re.findall(r"\b(?:emit|emit_event)\(\s*(\w+)", "\n".join(production)))
    # Event-only snapshots may be nested inside an emitted payload.
    pending = list(payloads & types.keys())
    reachable = set(pending)
    while pending:
        name = pending.pop()
        type_names = set(re.findall(r"\b\w+\b", types[name]))
        nested = (type_names & types.keys()) - reachable
        reachable.update(nested)
        pending.extend(nested)
    unrelated = types.keys() - reachable
    if unrelated:
        raise ValueError(f"{', '.join(sorted(unrelated))}: event modules may declare only emitted payloads and event-only snapshots")


def check(path):
    source = path.read_text()
    items = list(declarations(source))
    check_event_types(path, items)
    module_start = re.search(r"\bmodule\b", mask(source)).start()
    test_module = "#[test_only]" in source[:module_start]
    headings = list(re.finditer(r"^// === (.*?) ===$", source, re.M))
    names = [heading[1] for heading in headings]
    if any(name not in TAIL_SECTIONS for name in names):
        raise ValueError("use the section names in AGENTS.md")
    in_order = lambda order: set(names) <= set(order) and (
        [order.index(name) for name in names] == sorted({order.index(name) for name in names})
    )
    # A module with an Events section keeps every struct it emits there.
    events = set(re.findall(r"event::emit\(\s*(\w+)", mask(source))) if "Events" in names else set()
    utility_layout = any(
        path.resolve().is_relative_to(ROOT / "sui/utilities" / package)
        for package in ("otc", "vesting")
    ) and in_order(UTILITY_SECTIONS)
    if not (in_order(SECTIONS) or in_order(TAIL_SECTIONS) or utility_layout):
        raise ValueError("sections must occur once, in the order in AGENTS.md")
    if not any(
        path.resolve().is_relative_to(ROOT / directory)
        for directory in QUALIFIED_TYPES_EXEMPT
    ):
        check_qualified_types(source)
    previous_kind = None
    closed_constant_sections = set()
    previous_section = None
    for start, kind, attributes, declaration in items:
        section = next((h[1] for h in reversed(headings) if h.start() < start), None)
        expected = section_for(path, test_module, kind, attributes, declaration, events)
        if section != expected:
            line = source[:start].count("\n") + 1
            raise ValueError(f"line {line}: declaration belongs under {expected}, found {section}")
        if kind == "const" and section in closed_constant_sections:
            raise ValueError("group all constants together within their section")
        if previous_kind == "const" and kind != "const":
            closed_constant_sections.add(previous_section)
        previous_kind = kind
        previous_section = section
    codes = [int(code) for code in re.findall(r"#\[error\(code = (\d+)\)\]", mask(source))]
    if codes != list(range(len(codes))):
        raise ValueError("local error codes must be sequential from zero")
    numeric_codes = [
        int(code) for code in re.findall(rf"\bconst {ERROR_NAME}: u64 = (\d+);", mask(source))
    ]
    if numeric_codes != list(range(len(numeric_codes))):
        raise ValueError("numeric error codes must be sequential from zero")
    if re.search(r"^//.*(?:[Cc]odes? \d+.*(?:retired|moved)|[Aa]ppend-only|[Nn]ever reuse)", source, re.M):
        raise ValueError("remove obsolete error reservations")
    if path.name == "errors.move":
        constants = []
        macros = []
        for _, kind, attributes, declaration in items:
            if kind == "const":
                match = re.fullmatch(r"const (E\w+): u64 = (\d+);", declaration)
                if not match or "#[test_only]" not in attributes:
                    raise ValueError("registry constants must be test-only numeric errors")
                constants.append((match[1], int(match[2])))
            elif kind == "fun":
                match = re.fullmatch(r"macro public\(package\) fun (\w+)\(\): u64 \{\s*(\d+)\s*\}", declaration)
                if not match:
                    raise ValueError("registry functions must be literal-returning package macros")
                macros.append(("E" + "".join(word.capitalize() for word in match[1].split("_")), int(match[2])))
        if constants != macros or [code for _, code in macros] != list(range(len(macros))):
            raise ValueError("registry constants and macros must match names and sequential codes from zero")


def main():
    files = sorted(
        path for directory in ("sui", "scratch-sui")
        for path in (ROOT / directory).rglob("*.move")
        if not {"build", "interfaces", "target"}.intersection(path.parts)
    )
    failures = []
    for path in files:
        try:
            check(path)
        except (ValueError, IndexError) as error:
            failures.append(f"{path.relative_to(ROOT)}: {error}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"Move style holds across {len(files)} first-party modules.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
