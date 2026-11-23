#!/usr/bin/env python3
"""Require live, sequential first-party errors with exact-abort test oracles."""
from pathlib import Path
import re
import sys
from check_move_style import check, declarations, mask

ROOT = Path(__file__).resolve().parents[1]

def imports(source):
    """Resolve nested Move imports, including Self and renamed modules."""
    aliases = {}
    for match in re.finditer(r"\buse\s+([^;]+);", mask(source)):
        tokens = re.findall(r"\w+|::|[{},]", match[1])
        if "fun" in tokens:
            continue
        position = 0

        def read_members(prefix):
            nonlocal position
            while position < len(tokens) and tokens[position] != "}":
                if tokens[position] == ",":
                    position += 1
                    continue
                path = prefix[:]
                while position < len(tokens) and tokens[position] not in ("{", "}", ",", "as"):
                    if tokens[position] != "::":
                        path.append(tokens[position])
                    position += 1
                if position < len(tokens) and tokens[position] == "{":
                    position += 1
                    read_members(path)
                    position += 1
                    continue
                if path[-1] == "Self":
                    path.pop()
                alias = path[-1]
                if position < len(tokens) and tokens[position] == "as":
                    position += 1
                    alias = tokens[position]
                    position += 1
                aliases[alias] = "::".join(path)

        read_members([])
    return aliases


def resolve(name, aliases):
    first, *rest = name.split("::")
    return "::".join([aliases.get(first, first), *rest])


def mask_rust(source):
    # Rust character literals must be recognized before a quote inside one can
    # start a string. Lifetimes such as 'static are not character literals.
    pattern = r"""//[^\n]*|/\*[\s\S]*?\*/|b?r(?P<hash>#+)"[\s\S]*?"(?P=hash)|b?"(?:\\.|[^"\\])*"|b?'(?:\\.|[^'\\])'"""
    return re.sub(pattern, lambda match: re.sub(r"[^\n]", " ", match[0]), source, flags=re.S)


# These venue objects require the transaction runtime and captured venue bytecode,
# and ESelfEnrollment needs a real published package identity that a 0x0 unit build cannot reproduce.
# Pin the existing native oracles instead of pretending link-stub unit tests cover them.
NATIVE_TESTS = {
    ('blast_upgrade_cap_manager::blast_upgrade_cap_manager', 'ESelfEnrollment'): (
        'upgrade_cap_manager.rs', 'enrolling_own_cap_is_rejected',
        'Expected::Abort { package: fresh_wrapper, module: MODULE, code: SELF_ENROLLMENT }',
        'const SELF_ENROLLMENT: u64 = 10;', 10,
    ),
    ('blast_migrators::errors', 'EInvalidAutoLpPrice'): (
        'venue_fork.rs', 'compounding_guards',
        'Expected::Abort { package: self.migrators, module: self.case.module(), code: INVALID_AUTO_LP_PRICE }',
        'const INVALID_AUTO_LP_PRICE: u64 = 5;', 5,
    ),
    ('blast_migrators::errors', 'EInvalidCoinOrder'): (
        'venue_fork.rs', 'migration_failures_commit_nothing',
        'Expected::Abort { package: self.migrators, module: "cetus", code: INVALID_COIN_ORDER }',
        'const INVALID_COIN_ORDER: u64 = 0;', 0,
    ),
    ('blast_migrators::errors', 'EPositionPoolMismatch'): (
        'venue_fork.rs', 'other_pool_is_refused',
        'Expected::Abort { package: self.migrators, module, code }',
        'const POSITION_POOL_MISMATCH: u64 = 1;', 1,
    ),
}


def native_oracle(root, module, error):
    spec = NATIVE_TESTS.get((module, error['name']))
    if not spec:
        return False
    filename, function, oracle, number, expected_code = spec
    path = root / 'sui/launch/launchpad/ptb_tests/tests' / filename
    if not path.exists() or error['code'] != expected_code:
        return False
    source = path.read_text()
    # Locate the function with masked, brace-matched boundaries; a comment cannot
    # impersonate a function, and an assertion elsewhere cannot satisfy its oracle.
    masked = mask_rust(source)
    match = re.search(r'\bfn\s+' + re.escape(function) + r'\s*\(', masked)
    if not match:
        return False
    start = masked.index('{', match.end())
    end, depth = start + 1, 1
    while depth and end < len(masked):
        depth += (masked[end] == '{') - (masked[end] == '}')
        end += 1
    body = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/', '', source[start:end])
    code_source = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/', '', source)
    compact = lambda text: re.sub(r'\s+', '', text)
    return (
        compact(oracle) in compact(body)
        and compact(number) in compact(code_source)
        and 'self.h.assert_rolled_back(' in body
    )


def audit(root):
    modules, tests, pins = {}, [], []
    for path in sorted((root / 'sui').rglob('*.move')):
        if {'interfaces', 'target', 'build', 'ptb_tests'}.intersection(path.parts):
            continue
        check(path)
        source = path.read_text()
        masked = mask(source)
        module_match = re.search(r'\bmodule\s+([\w:]+)\s*;', masked)
        module = module_match[1]
        items = list(declarations(source))
        aliases = imports(source)
        test_module = bool(re.search(r'#\[[^\]]*\btest_only\b[^\]]*\]', masked[:module_match.start()]))
        production = '\n'.join(
            mask(declaration) for _, kind, attributes, declaration in items
            if not test_module and not re.search(r'\btest_only\b', attributes)
            and not re.search(r'#\[\s*test\b', attributes)
            and kind not in ('const', 'use')
        )
        production = re.sub(
            r'\b[\w:]+::\w+!?', lambda match: resolve(match[0], aliases), production,
        )
        errors = []
        for _, kind, attributes, declaration in items:
            if kind == 'const' and not test_module:
                name = re.match(r'const (E[A-Z][a-zA-Z0-9]*):', declaration)
                if not name:
                    continue
                code = re.search(r'error\(code\s*=\s*(\d+)\)', attributes) or re.search(r': u64 = (\d+)', declaration)
                if not code:
                    raise ValueError(f'{module}::{name[1]}: missing explicit error code')
                macro = None
                if module.endswith('::errors'):
                    for _, member_kind, _, member in items:
                        found = re.fullmatch(r'macro public\(package\) fun (\w+)\(\): u64 \{\s*(\d+)\s*\}', member)
                        if member_kind == 'fun' and found and int(found[2]) == int(code[1]):
                            macro = found[1]
                errors.append({'name': name[1], 'code': int(code[1]), 'macro': macro})
            if kind != 'fun' or not re.search(r'#\[\s*test\b', attributes):
                continue
            code = re.search(r'abort_code\s*=\s*([\w:]+)', attributes)
            location = re.search(r'location\s*=\s*([\w:]+)', attributes)
            if 'expected_failure' in attributes:
                if not location or (not code and 'arithmetic_error' not in attributes):
                    raise ValueError(f'{path.relative_to(root)}: expected failure needs exact code and location')
                if code:
                    tests.append((resolve(code[1], aliases), resolve(location[1], aliases)))
            body = re.sub(r'\b[\w:]+::\w+!?', lambda m: resolve(m[0], aliases), mask(declaration))
            pins.extend(re.findall(r'assert_eq!\(\s*([\w:]+)!\(\)\s*,\s*(\d+)\s*\)', body))
            # Existing registries may pin an ordered vector with a tested index
            # loop instead of repeating literal assertions for every member.
            compact = re.sub(r'\s+', '', body)
            for vector in re.finditer(r'let(\w+)=vector\[([^\]]+)\];', compact):
                name, members = vector.groups()
                names = re.findall(r'([\w:]+)!\(\)', members)
                if members.rstrip(',') != ','.join(member + '!()' for member in names):
                    continue
                if (f'assert_eq!({name}.length(),{len(names)});' in compact
                        and f'{name}.length().do!(|i|assert_eq!({name}[i],i));' in compact):
                    pins.extend((member, str(index)) for index, member in enumerate(names))
        modules[module] = {'production': production, 'errors': errors}

    failures, total, native = [], 0, 0
    for module, info in modules.items():
        for error in info['errors']:
            total += 1
            identity = module + '::' + error['name']
            if error['macro']:
                macro = module + '::' + error['macro']
                users = {
                    owner for owner, other in modules.items()
                    if re.search(r'\b' + re.escape(macro) + r'!\s*\(', other['production'])
                }
                codes = [int(code) for name, code in pins if name == macro]
                if not codes or any(code != error['code'] for code in codes):
                    failures.append(identity + ': needs matching numeric registry pins')
            else:
                users = {module} if re.search(r'\b' + error['name'] + r'\b', info['production']) else set()
            if not users:
                failures.append(identity + ': unused in production')
            if any(code in (identity, str(error['code'])) and location in users for code, location in tests):
                continue
            if native_oracle(root, module, error):
                native += 1
            else:
                failures.append(identity + ': missing exact-abort test at a production raising module')
    return failures, total, native


def main():
    try:
        failures, total, native = audit(ROOT)
    except (ValueError, IndexError) as error:
        print(error, file=sys.stderr)
        return 1
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        return 1
    print(f'All {total} first-party errors are used, sequential and have exact-abort oracles ({native} native, {total - native} Move).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
