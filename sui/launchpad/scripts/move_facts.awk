# Deterministic Move reader shared by the launchpad and migrator source gates. It removes
# comments and string contents before parsing, so a token inside a comment, a
# doc comment, or a literal can never satisfy a requirement, and it reports each
# declaration with brace-matched boundaries, so indentation and line breaks
# cannot hide or split one. A carriage return, which the compiler accepts only
# as the `\r` of a `\r\n` line break, fails closed. Records are tab separated:
#   FN    name vis entry macro test_only after_marker line signature body
#   TYPE  name kind vis test_only after_marker line declaration
#   MARKER  first '// === Test-Only ... ===' line, or 0
#   NORM    whole comment-free source with whitespace collapsed
#   MALFORMED  reason (also exits nonzero, so unparsable source fails closed)

function blanks(count,   pad) {
    pad = ""
    while (length(pad) < count) pad = pad "                                        "
    return substr(pad, 1, count)
}

function normalize(chunk) {
    gsub(/[ \t\n\r]+/, " ", chunk)
    gsub(/ *\. */, ".", chunk)
    gsub(/ *:: */, "::", chunk)
    sub(/^ /, "", chunk)
    sub(/ $/, "", chunk)
    return chunk
}

function fail(reason) {
    printf("MALFORMED\t%s\n", reason)
    broken = 1
    exit 3
}

function line_of(offset,   parts) {
    return split(substr(text, 1, offset - 1), parts, "\n")
}

function match_paren(open, opener, closer,   depth, index_, char_) {
    depth = 0
    for (index_ = open; index_ <= text_length; index_++) {
        char_ = substr(text, index_, 1)
        if (char_ == opener) depth++
        else if (char_ == closer) {
            depth--
            if (depth == 0) return index_
        }
    }
    return 0
}

function modifiers_before(stop,   scan, char_, boundary, between) {
    boundary = 0
    for (scan = stop; scan >= 1; scan--) {
        char_ = substr(text, scan, 1)
        if (char_ == ";" || char_ == "}" || char_ == "]") { boundary = scan; break }
    }
    attribute_text = ""
    if (boundary > 0 && substr(text, boundary, 1) == "]") collect_attributes(boundary)
    between = normalize(substr(text, boundary + 1, stop - boundary))
    return between
}

# Only the exact `#[test_only]` attribute marks test-only code. Any other attribute that names
# `test_only`, such as `#[ext(test_only)]`, compiles into production, so the reader rejects it
# rather than let it hide a declaration from the production checks.
function is_test_only_attribute(attributes, name) {
    if (attributes ~ /(^| )#\[ ?test_only ?\]( |$)/) return 1
    if (attributes ~ /test_only/) fail("attribute naming test_only is not exactly #[test_only] on " name)
    return 0
}

function collect_attributes(bracket_end,   depth, scan, char_, open) {
    while (1) {
        depth = 0
        open = 0
        for (scan = bracket_end; scan >= 1; scan--) {
            char_ = substr(text, scan, 1)
            if (char_ == "]") depth++
            else if (char_ == "[") {
                depth--
                if (depth == 0) { open = scan; break }
            }
        }
        if (open <= 1 || substr(text, open - 1, 1) != "#") return
        attribute_text = normalize(substr(text, open - 1, bracket_end - open + 2)) " " attribute_text
        bracket_end = 0
        for (scan = open - 2; scan >= 1; scan--) {
            char_ = substr(text, scan, 1)
            if (char_ == " " || char_ == "\t" || char_ == "\n") continue
            if (char_ == "]") { bracket_end = scan }
            break
        }
        if (bracket_end == 0) return
    }
}

{ source_lines[NR] = $0 }

END {
    total_lines = NR
    marker_line = 0
    for (index_ = 1; index_ <= total_lines; index_++) {
        if (source_lines[index_] ~ /^\/\/ === Test-Only (Functions|Types) ===$/) {
            marker_line = index_
            break
        }
    }

    text = ""
    in_block = 0
    block_depth = 0
    in_string = 0
    for (index_ = 1; index_ <= total_lines; index_++) {
        line = source_lines[index_]
        if (index(line, "\r")) fail("carriage return at line " index_)
        cleaned = ""
        line_length = length(line)
        cursor = 1
        while (cursor <= line_length) {
            char_ = substr(line, cursor, 1)
            pair = substr(line, cursor, 2)
            if (in_block) {
                if (pair == "*/") {
                    block_depth--
                    if (block_depth == 0) in_block = 0
                    cleaned = cleaned "  "
                    cursor += 2
                    continue
                }
                if (pair == "/*") {
                    block_depth++
                    cleaned = cleaned "  "
                    cursor += 2
                    continue
                }
                cleaned = cleaned " "
                cursor++
                continue
            }
            if (in_string) {
                if (char_ == "\\") {
                    cleaned = cleaned blanks(cursor + 1 <= line_length ? 2 : 1)
                    cursor += 2
                    continue
                }
                if (char_ == "\"") {
                    in_string = 0
                    cleaned = cleaned "\""
                    cursor++
                    continue
                }
                cleaned = cleaned "_"
                cursor++
                continue
            }
            if (pair == "//") {
                cleaned = cleaned blanks(line_length - cursor + 1)
                cursor = line_length + 1
                continue
            }
            if (pair == "/*") {
                in_block = 1
                block_depth = 1
                cleaned = cleaned "  "
                cursor += 2
                continue
            }
            if (char_ == "\"") {
                in_string = 1
                cleaned = cleaned "\""
                cursor++
                continue
            }
            cleaned = cleaned char_
            cursor++
        }
        text = text cleaned "\n"
    }
    if (in_block) fail("unterminated block comment")
    if (in_string) fail("unterminated string literal")

    text_length = length(text)

    cursor = 1
    while (cursor <= text_length) {
        remainder = substr(text, cursor)
        if (!match(remainder, /(^|[^A-Za-z0-9_$])fun[ \t\n]/)) break
        hit = substr(remainder, RSTART, 1)
        keyword = cursor + RSTART - 1
        if (hit != "f") keyword++
        cursor = keyword + 3

        if (substr(text, 1, keyword - 1) ~ /use[ \t\n]+$/) continue

        if (!match(substr(text, cursor), /^[ \t\n]+[A-Za-z_][A-Za-z0-9_]*!?/)) {
            fail("function keyword without a name at line " line_of(keyword))
        }
        name = normalize(substr(text, cursor + RSTART - 1, RLENGTH))
        name_end = cursor + RSTART + RLENGTH - 2

        modifiers = modifiers_before(keyword - 1)
        attributes = attribute_text
        if (modifiers != "" \
            && modifiers !~ /^((public(\(package\)|\(friend\))?|entry|macro)( |$))+$/) {
            fail("unrecognized function modifiers '" modifiers "' before " name)
        }

        visibility = "private"
        if (modifiers ~ /(^| )public\(package\)( |$)/) visibility = "package"
        else if (modifiers ~ /(^| )public\(friend\)( |$)/) visibility = "friend"
        else if (modifiers ~ /(^| )public( |$)/) visibility = "public"
        is_entry = (modifiers ~ /(^| )entry( |$)/) ? 1 : 0
        is_macro = (modifiers ~ /(^| )macro( |$)/) ? 1 : 0
        is_test_only = is_test_only_attribute(attributes, name)
        function_line = line_of(keyword)
        after_marker = (marker_line > 0 && function_line >= marker_line) ? 1 : 0

        open_paren = index(substr(text, name_end + 1), "(")
        if (open_paren == 0) fail("function " name " has no parameter list")
        open_paren += name_end
        close_paren = match_paren(open_paren, "(", ")")
        if (close_paren == 0) fail("function " name " has an unbalanced parameter list")

        body_open = 0
        for (index_ = close_paren + 1; index_ <= text_length; index_++) {
            char_ = substr(text, index_, 1)
            if (char_ == "{") { body_open = index_; break }
            if (char_ == ";") break
        }
        if (body_open == 0) fail("function " name " has no body")
        body_close = match_paren(body_open, "{", "}")
        if (body_close == 0) fail("function " name " has an unbalanced body")

        printf("FN\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n",
            name, visibility, is_entry, is_macro, is_test_only, after_marker,
            function_line,
            normalize(substr(text, keyword, body_open - keyword)),
            normalize(substr(text, body_open + 1, body_close - body_open - 1)))

        cursor = body_close + 1
    }

    cursor = 1
    while (cursor <= text_length) {
        remainder = substr(text, cursor)
        if (!match(remainder, /(^|[^A-Za-z0-9_$])(struct|enum)[ \t\n]/)) break
        hit = substr(remainder, RSTART, 1)
        keyword = cursor + RSTART - 1
        if (hit != "s" && hit != "e") keyword++
        kind = (substr(text, keyword, 6) == "struct") ? "struct" : "enum"
        cursor = keyword + length(kind)

        if (!match(substr(text, cursor), /^[ \t\n]+[A-Za-z_][A-Za-z0-9_]*/)) {
            fail(kind " keyword without a name at line " line_of(keyword))
        }
        name = normalize(substr(text, cursor + RSTART - 1, RLENGTH))

        declaration_end = 0
        for (index_ = cursor; index_ <= text_length; index_++) {
            char_ = substr(text, index_, 1)
            if (char_ == "{") {
                declaration_end = match_paren(index_, "{", "}")
                if (declaration_end == 0) fail(kind " " name " has an unbalanced body")
                break
            }
            if (char_ == ";") { declaration_end = index_; break }
        }
        if (declaration_end == 0) fail(kind " " name " is unterminated")

        modifiers = modifiers_before(keyword - 1)
        attributes = attribute_text
        visibility = (modifiers ~ /(^| )public( |$)/) ? "public" : "private"
        declaration_line = line_of(keyword)

        printf("TYPE\t%s\t%s\t%s\t%d\t%d\t%d\t%s\n",
            name, kind, visibility,
            is_test_only_attribute(attributes, name),
            (marker_line > 0 && declaration_line >= marker_line) ? 1 : 0,
            declaration_line,
            normalize(substr(text, keyword, declaration_end - keyword + 1)))

        cursor = declaration_end + 1
    }

    printf("MARKER\t%d\n", marker_line)
    printf("NORM\t%s\n", normalize(text))
}
