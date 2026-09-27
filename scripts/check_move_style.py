#!/usr/bin/env python3
"""Check the greenfield declaration and error conventions in AGENTS.md."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SECTIONS = [
    "Constants", "Package Constants", "Errors", "Public Types",
    "Private Initialization", "Public Functions", "Package Functions",
    "Private Functions", "Test-Only Types", "Test-Only Functions",
    "Tests", "Test Helpers", "Imports",
]
TRAILING = ["Constants", "Package Constants", "Errors"]
# A module may instead end with its events, constants and errors, just before Imports.
TAIL_SECTIONS = [name for name in SECTIONS if name not in TRAILING + ["Imports"]] + ["Events"] + TRAILING + ["Imports"]
ERROR_NAME = r"E[A-Z](?=[A-Za-z0-9]*[a-z])[A-Za-z0-9]*"


def mask(source):
    """Keep offsets and newlines while hiding comments and string literals."""
    return re.sub(
        r'//[^\n]*|/\*[\s\S]*?\*/|b?"(?:\\.|[^"\\])*"',
        lambda match: re.sub(r"[^\n]", " ", match[0]), source,
    )


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


def check(path):
    source = path.read_text()
    items = list(declarations(source))
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
    if not (in_order(SECTIONS) or in_order(TAIL_SECTIONS)):
        raise ValueError("sections must occur once, in the order in AGENTS.md")
    previous_kind = None
    constants_closed = False
    for start, kind, attributes, declaration in items:
        section = next((h[1] for h in reversed(headings) if h.start() < start), None)
        expected = section_for(path, test_module, kind, attributes, declaration, events)
        if section != expected:
            line = source[:start].count("\n") + 1
            raise ValueError(f"line {line}: declaration belongs under {expected}, found {section}")
        if kind == "const" and constants_closed:
            raise ValueError("group all constants together, first or just before Imports")
        constants_closed = constants_closed or (previous_kind == "const" and kind != "const")
        previous_kind = kind
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
