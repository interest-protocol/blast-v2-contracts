// Fail-closed parsing for the `sui client ptb` move-call surface used by the
// release-evidence scripts. A call owns every token up to the next PTB flag.

const MOVE_TARGET = /^0x[0-9a-fA-F]{64}::[A-Za-z_][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*$/;

function fail(path, message) {
    throw new Error(`${path}: ${message}`);
}

function splitTypeArguments(token, path) {
    const body = token.slice(1, -1);
    if (body.length === 0) fail(path, 'empty type-argument list');
    const result = [];
    let depth = 0;
    let start = 0;
    for (let index = 0; index < body.length; index += 1) {
        if (body[index] === '<') depth += 1;
        else if (body[index] === '>') {
            depth -= 1;
            if (depth < 0) fail(path, 'unbalanced type-argument list');
        } else if (body[index] === ',' && depth === 0) {
            const value = body.slice(start, index);
            if (value.length === 0) fail(path, 'empty type argument');
            result.push(value);
            start = index + 1;
        }
    }
    if (depth !== 0) fail(path, 'unbalanced type-argument list');
    const value = body.slice(start);
    if (value.length === 0) fail(path, 'empty type argument');
    result.push(value);
    return result;
}

export function parseMoveCalls(args, path) {
    if (!Array.isArray(args) || args.some((arg) => typeof arg !== 'string')) {
        fail(path, 'expected string list');
    }
    const calls = [];
    for (let index = 0; index < args.length; index += 1) {
        if (args[index] !== '--move-call') continue;
        const start = index;
        const target = args[index + 1];
        if (typeof target !== 'string' || !MOVE_TARGET.test(target)) {
            fail(`${path}[${index + 1}]`, 'expected canonical move-call target');
        }
        index += 2;
        let typeArguments = [];
        if (typeof args[index] === 'string'
            && args[index].startsWith('<')
            && args[index].endsWith('>')) {
            typeArguments = splitTypeArguments(args[index], `${path}[${index}]`);
            index += 1;
        }
        const arguments_ = [];
        while (index < args.length && !args[index].startsWith('--')) {
            if (MOVE_TARGET.test(args[index])) {
                fail(`${path}[${index}]`, `target-shaped argument ${args[index]}`);
            }
            arguments_.push(args[index]);
            index += 1;
        }
        calls.push({ target, typeArguments, arguments: arguments_, start, end: index });
        index -= 1;
    }
    if (calls.length === 0) fail(path, 'expected executed production calls');
    return calls;
}
