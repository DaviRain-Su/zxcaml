//! OCaml-ish source formatter core.
//!
//! This module is intentionally self-contained: FMT1 provides the pure source
//! formatter that later CLI/LSP features can call without depending on the
//! compiler driver.  The formatter tokenizes the pre-lowering OCaml source
//! surface, preserves opaque trivia such as comments and literals verbatim, and
//! emits a canonical token stream with deterministic whitespace.

const std = @import("std");

const max_columns = 100;
const indent_width = 2;

const TokenKind = enum {
    word,
    number,
    string,
    char,
    comment,
    op,
    punct,
};

const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

const LineParts = struct {
    code: []const u8,
    comment: []const u8,
};

/// Required allocator-free facade for downstream call sites that only need an
/// owned formatted byte slice.  The returned slice is allocated with
/// `std.heap.page_allocator`.
pub fn format(source: []const u8) []u8 {
    return formatAlloc(std.heap.page_allocator, source) catch
        @panic("out of memory while formatting OCaml source");
}

/// Lightweight syntax guard for the formatter-only path.
///
/// This intentionally remains lex-only: it rejects unterminated string
/// literals, character literals, and nested `(* ... *)` comments while avoiding
/// the Typedtree/subset validator used by `omlz build|run|test`.
pub fn analyze(source: []const u8) !void {
    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '"') {
            const end = scanString(source, index);
            if (!stringScanTerminated(source, index, end)) return error.UnterminatedString;
            index = end;
            continue;
        }
        if (source[index] == '\'') {
            if (looksLikeTypeVariableStart(source, index)) {
                index = scanTypeVariable(source, index);
                continue;
            }
            if (!looksLikeCharLiteralStart(source, index)) {
                index += 1;
                continue;
            }
            const end = scanCharLiteral(source, index);
            if (!charScanTerminated(source, index, end)) return error.UnterminatedChar;
            index = end;
            continue;
        }
        if (index + 1 < source.len and source[index] == '(' and source[index + 1] == '*') {
            const end = scanComment(source, index);
            if (!commentScanTerminated(source, index, end)) return error.UnterminatedComment;
            index = end;
            continue;
        }
        index += 1;
    }
}

/// Zig-style formatter entrypoint.  The caller owns the returned slice.
pub fn formatAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    var current_indent: usize = 0;
    var comment_depth: usize = 0;

    while (index < source.len) {
        const line_start = index;
        while (index < source.len and source[index] != '\n') : (index += 1) {}
        var line = source[line_start..index];
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        if (index < source.len and source[index] == '\n') index += 1;

        const trimmed_right = trimRight(line);
        const trimmed = std.mem.trim(u8, trimmed_right, " \t");

        if (trimmed.len == 0) {
            try out.append(allocator, '\n');
            continue;
        }

        const starts_inside_comment = comment_depth > 0;
        comment_depth = commentDepthAfterLine(trimmed_right, comment_depth);
        if (starts_inside_comment or startsWithBytes(trimmed, "(*")) {
            try out.appendSlice(allocator, trimmed_right);
            try out.append(allocator, '\n');
            continue;
        }

        const parts = splitInlineComment(trimmed);
        const formatted_code = try formatCodeSegment(allocator, parts.code);
        defer allocator.free(formatted_code);

        const formatted_trimmed = std.mem.trim(u8, formatted_code, " \t");
        var indent = current_indent;
        if (isTopLevelStart(formatted_trimmed)) {
            indent = 0;
        } else if (startsWithWord(formatted_trimmed, "in") or startsWithWord(formatted_trimmed, "else")) {
            indent = if (current_indent >= indent_width) current_indent - indent_width else 0;
        } else if (startsWithBytes(formatted_trimmed, "|")) {
            indent = current_indent;
        }

        var logical_line = std.ArrayList(u8).empty;
        defer logical_line.deinit(allocator);
        try logical_line.appendSlice(allocator, formatted_trimmed);
        if (parts.comment.len > 0) {
            if (logical_line.items.len > 0 and logical_line.items[logical_line.items.len - 1] != ' ') {
                try logical_line.append(allocator, ' ');
            }
            try logical_line.appendSlice(allocator, std.mem.trim(u8, parts.comment, " \t"));
        }

        try emitWrappedLine(allocator, &out, logical_line.items, indent);
        try out.append(allocator, '\n');

        current_indent = nextIndent(formatted_trimmed, indent);
    }

    while (out.items.len > 0) {
        const last = out.items[out.items.len - 1];
        if (last == ' ' or last == '\t' or last == '\r' or last == '\n') {
            out.items.len -= 1;
        } else {
            break;
        }
    }
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn trimRight(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) {
        end -= 1;
    }
    return line[0..end];
}

fn startsWithBytes(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

fn startsWithWord(s: []const u8, word: []const u8) bool {
    if (!startsWithBytes(s, word)) return false;
    return s.len == word.len or isWhitespace(s[word.len]) or s[word.len] == '(';
}

fn isTopLevelStart(line: []const u8) bool {
    return startsWithBytes(line, "let ") or
        startsWithBytes(line, "let%") or
        startsWithBytes(line, "let rec ") or
        startsWithBytes(line, "type ") or
        startsWithBytes(line, "external ");
}

fn nextIndent(line: []const u8, indent: usize) usize {
    if (line.len == 0) return indent;
    if (isTopLevelStart(line)) {
        if (endsWithBytes(line, "=") or containsWord(line, "match")) return indent + indent_width;
        return 0;
    }
    if (containsWord(line, "match") and containsWord(line, "with")) {
        return indent + indent_width;
    }
    if (startsWithBytes(line, "|")) {
        return indent;
    }
    if (endsWithBytes(line, "=") or endsWithBytes(line, "then") or endsWithBytes(line, "else")) {
        return indent + indent_width;
    }
    return indent;
}

fn endsWithBytes(s: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, s, suffix);
}

fn containsWord(s: []const u8, word: []const u8) bool {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, s, index, word)) |found| {
        const before_ok = found == 0 or !isIdentChar(s[found - 1]);
        const after = found + word.len;
        const after_ok = after >= s.len or !isIdentChar(s[after]);
        if (before_ok and after_ok) return true;
        index = found + word.len;
    }
    return false;
}

fn splitInlineComment(line: []const u8) LineParts {
    var index: usize = 0;
    while (index < line.len) {
        if (line[index] == '"') {
            index = scanString(line, index);
            continue;
        }
        if (line[index] == '\'') {
            if (looksLikeTypeVariableStart(line, index)) {
                index = scanTypeVariable(line, index);
                continue;
            }
            index = scanCharLiteral(line, index);
            continue;
        }
        if (index + 1 < line.len and line[index] == '(' and line[index + 1] == '*') {
            return .{ .code = trimRight(line[0..index]), .comment = line[index..] };
        }
        index += 1;
    }
    return .{ .code = line, .comment = "" };
}

fn commentDepthAfterLine(line: []const u8, initial_depth: usize) usize {
    var depth = initial_depth;
    var index: usize = 0;
    while (index < line.len) {
        if (depth == 0 and line[index] == '"') {
            index = scanString(line, index);
            continue;
        }
        if (depth == 0 and line[index] == '\'') {
            if (looksLikeTypeVariableStart(line, index)) {
                index = scanTypeVariable(line, index);
                continue;
            }
            index = scanCharLiteral(line, index);
            continue;
        }
        if (index + 1 < line.len and line[index] == '(' and line[index + 1] == '*') {
            depth += 1;
            index += 2;
            continue;
        }
        if (index + 1 < line.len and line[index] == '*' and line[index + 1] == ')' and depth > 0) {
            depth -= 1;
            index += 2;
            continue;
        }
        index += 1;
    }
    return depth;
}

fn formatCodeSegment(allocator: std.mem.Allocator, code: []const u8) ![]u8 {
    const tokens = try lexLine(allocator, code);
    defer allocator.free(tokens);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var previous: ?Token = null;
    for (tokens) |token| {
        if (token.text.len == 0) continue;
        if (previous) |prev| {
            if (needsSpace(prev, token) and out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                try out.append(allocator, ' ');
            }
        }
        try out.appendSlice(allocator, token.text);
        previous = token;
    }

    return out.toOwnedSlice(allocator);
}

fn lexLine(allocator: std.mem.Allocator, line: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(allocator);

    var index: usize = 0;
    while (index < line.len) {
        const c = line[index];
        if (isWhitespace(c)) {
            index += 1;
            continue;
        }
        if (c == '"') {
            const end = scanString(line, index);
            try tokens.append(allocator, .{ .kind = .string, .text = line[index..end] });
            index = end;
            continue;
        }
        if (c == '\'') {
            if (looksLikeTypeVariableStart(line, index)) {
                const end = scanTypeVariable(line, index);
                try tokens.append(allocator, .{ .kind = .word, .text = line[index..end] });
                index = end;
                continue;
            }
            const end = scanCharLiteral(line, index);
            try tokens.append(allocator, .{ .kind = .char, .text = line[index..end] });
            index = end;
            continue;
        }
        if (index + 1 < line.len and c == '(' and line[index + 1] == '*') {
            const end = scanComment(line, index);
            try tokens.append(allocator, .{ .kind = .comment, .text = line[index..end] });
            index = end;
            continue;
        }
        if (isIdentStart(c)) {
            const start = index;
            index += 1;
            while (index < line.len and isIdentChar(line[index])) : (index += 1) {}
            try tokens.append(allocator, .{ .kind = .word, .text = line[start..index] });
            continue;
        }
        if (isDigit(c)) {
            const start = index;
            index += 1;
            while (index < line.len and (isDigit(line[index]) or line[index] == '_')) : (index += 1) {}
            try tokens.append(allocator, .{ .kind = .number, .text = line[start..index] });
            continue;
        }
        if (c == '~' and index + 1 < line.len and isIdentStart(line[index + 1])) {
            const start = index;
            index += 2;
            while (index < line.len and isIdentChar(line[index])) : (index += 1) {}
            try tokens.append(allocator, .{ .kind = .word, .text = line[start..index] });
            continue;
        }
        if (c == '?' and index + 1 < line.len and line[index + 1] == '(') {
            const end = scanOptionalArgumentBinder(line, index);
            try tokens.append(allocator, .{ .kind = .word, .text = line[index..end] });
            index = end;
            continue;
        }
        if (isOperatorChar(c)) {
            const start = index;
            index += 1;
            while (index < line.len and isOperatorChar(line[index])) : (index += 1) {}
            try tokens.append(allocator, .{ .kind = .op, .text = line[start..index] });
            continue;
        }

        try tokens.append(allocator, .{ .kind = .punct, .text = line[index .. index + 1] });
        index += 1;
    }

    return tokens.toOwnedSlice(allocator);
}

fn needsSpace(prev: Token, current: Token) bool {
    if (current.kind == .comment or prev.kind == .comment) return true;
    if (current.kind == .punct and isClosingOrSeparator(current.text)) return false;
    if (prev.kind == .punct and isOpening(prev.text)) return false;
    if (current.kind == .punct and std.mem.eql(u8, current.text, ".")) return false;
    if (prev.kind == .punct and std.mem.eql(u8, prev.text, ".")) return false;
    if (current.kind == .op or prev.kind == .op) return true;
    if (prev.kind == .punct and (std.mem.eql(u8, prev.text, ",") or std.mem.eql(u8, prev.text, ";"))) return true;
    if (current.kind == .punct and isOpening(current.text)) return true;
    return current.kind != .punct and prev.kind != .punct;
}

fn isClosingOrSeparator(text: []const u8) bool {
    return std.mem.eql(u8, text, ")") or
        std.mem.eql(u8, text, "]") or
        std.mem.eql(u8, text, "}") or
        std.mem.eql(u8, text, ",") or
        std.mem.eql(u8, text, ";");
}

fn isOpening(text: []const u8) bool {
    return std.mem.eql(u8, text, "(") or
        std.mem.eql(u8, text, "[") or
        std.mem.eql(u8, text, "{");
}

fn emitWrappedLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
    indent: usize,
) !void {
    if (line.len == 0) return;

    if (indent + line.len > max_columns) {
        if (std.mem.indexOf(u8, line, " in ")) |in_index| {
            try appendIndent(allocator, out, indent);
            try out.appendSlice(allocator, std.mem.trim(u8, line[0..in_index], " \t"));
            try out.append(allocator, '\n');
            try appendIndent(allocator, out, indent);
            const rhs = std.mem.trim(u8, line[in_index + 1 ..], " \t");
            try emitApplicationWrap(allocator, out, rhs, indent);
            return;
        }
    }

    try appendIndent(allocator, out, indent);
    try emitApplicationWrap(allocator, out, line, indent);
}

fn emitApplicationWrap(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
    indent: usize,
) !void {
    if (indent + line.len <= max_columns) {
        try out.appendSlice(allocator, line);
        return;
    }

    var words = std.mem.tokenizeScalar(u8, line, ' ');
    var current_len = indent;
    var first_word = true;
    var continuation = false;
    while (words.next()) |word| {
        if (!first_word and current_len + 1 + word.len > max_columns) {
            try out.append(allocator, '\n');
            try appendIndent(allocator, out, indent + indent_width);
            try out.appendSlice(allocator, word);
            current_len = indent + indent_width + word.len;
            continuation = true;
        } else {
            if (!first_word) {
                try out.append(allocator, ' ');
                current_len += 1;
            } else if (continuation) {
                current_len = indent + indent_width;
            }
            try out.appendSlice(allocator, word);
            current_len += word.len;
        }
        first_word = false;
    }
}

fn appendIndent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), count: usize) !void {
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        try out.append(allocator, ' ');
    }
}

fn scanString(line: []const u8, start: usize) usize {
    var index = start + 1;
    while (index < line.len) {
        if (line[index] == '\\') {
            index = @min(line.len, index + 2);
        } else if (line[index] == '"') {
            return index + 1;
        } else {
            index += 1;
        }
    }
    return line.len;
}

fn scanCharLiteral(line: []const u8, start: usize) usize {
    var index = start + 1;
    while (index < line.len) {
        if (line[index] == '\\') {
            index = @min(line.len, index + 2);
        } else if (line[index] == '\'') {
            return index + 1;
        } else {
            index += 1;
        }
    }
    return line.len;
}

fn scanTypeVariable(line: []const u8, start: usize) usize {
    var index = start + 2;
    while (index < line.len and isTypeVariableChar(line[index])) : (index += 1) {}
    return index;
}

fn scanOptionalArgumentBinder(line: []const u8, start: usize) usize {
    var depth: usize = 0;
    var index = start + 1;
    while (index < line.len) {
        if (line[index] == '"') {
            index = scanString(line, index);
            continue;
        }
        if (line[index] == '\'') {
            index = scanCharLiteral(line, index);
            continue;
        }
        if (index + 1 < line.len and line[index] == '(' and line[index + 1] == '*') {
            index = scanComment(line, index);
            continue;
        }
        if (line[index] == '(') {
            depth += 1;
        } else if (line[index] == ')') {
            if (depth == 0) return index + 1;
            depth -= 1;
            if (depth == 0) return index + 1;
        }
        index += 1;
    }
    return line.len;
}

fn scanComment(line: []const u8, start: usize) usize {
    var depth: usize = 1;
    var index = start + 2;
    while (index < line.len) {
        if (index + 1 < line.len and line[index] == '(' and line[index + 1] == '*') {
            depth += 1;
            index += 2;
        } else if (index + 1 < line.len and line[index] == '*' and line[index + 1] == ')') {
            depth -= 1;
            index += 2;
            if (depth == 0) return index;
        } else {
            index += 1;
        }
    }
    return line.len;
}

fn stringScanTerminated(source: []const u8, start: usize, end: usize) bool {
    if (end < source.len) return true;
    var index = start + 1;
    while (index < source.len) {
        if (source[index] == '\\') {
            index = @min(source.len, index + 2);
        } else if (source[index] == '"') {
            return index + 1 == end;
        } else {
            index += 1;
        }
    }
    return false;
}

fn looksLikeTypeVariableStart(source: []const u8, start: usize) bool {
    if (start + 1 >= source.len) return false;
    if (!isTypeVariableStart(source[start + 1])) return false;
    if (start + 2 < source.len and source[start + 2] == '\'') return false;
    return !previousSignificantByteIs(source, start, '=');
}

fn looksLikeCharLiteralStart(source: []const u8, start: usize) bool {
    if (start + 1 >= source.len) return true;
    const next = source[start + 1];
    if (next == '\n' or next == '\r') return true;
    if (next == '\\') return true;
    if (start + 2 >= source.len) return true;
    if (source[start + 2] == '\'') return true;
    if (source[start + 2] == '\n' or source[start + 2] == '\r') return true;
    return false;
}

fn previousSignificantByteIs(source: []const u8, start: usize, target: u8) bool {
    var index = start;
    while (index > 0) {
        index -= 1;
        if (isWhitespace(source[index])) continue;
        return source[index] == target;
    }
    return false;
}

fn charScanTerminated(source: []const u8, start: usize, end: usize) bool {
    if (end < source.len) return true;
    var index = start + 1;
    while (index < source.len) {
        if (source[index] == '\\') {
            index = @min(source.len, index + 2);
        } else if (source[index] == '\'') {
            return index + 1 == end;
        } else {
            index += 1;
        }
    }
    return false;
}

fn commentScanTerminated(source: []const u8, start: usize, end: usize) bool {
    var depth: usize = 1;
    var index = start + 2;
    while (index < end) {
        if (index + 1 < end and source[index] == '(' and source[index + 1] == '*') {
            depth += 1;
            index += 2;
        } else if (index + 1 < end and source[index] == '*' and source[index + 1] == ')') {
            depth -= 1;
            index += 2;
            if (depth == 0) return index == end;
        } else {
            index += 1;
        }
    }
    return false;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '%';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or isDigit(c) or c == '\'';
}

fn isTypeVariableStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or c == '_';
}

fn isTypeVariableChar(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

fn isOperatorChar(c: u8) bool {
    return switch (c) {
        '=', '+', '-', '*', '/', '<', '>', ':', '&', '|', '^', '@', '!', '?' => true,
        else => false,
    };
}

fn expectFormat(input: []const u8, expected: []const u8) !void {
    const once = try formatAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(once);
    try std.testing.expectEqualStrings(expected, once);
}

fn expectDoubleApply(input: []const u8) !void {
    const once = try formatAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(once);
    const twice = try formatAlloc(std.testing.allocator, once);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(once, twice);
}

test "analyze accepts tokenizable input without subset validation" {
    try analyze("let manhattan {x;y}=x+y\nmodule M = struct let x = 1 end\n");
}

test "analyze rejects unterminated string literal" {
    try std.testing.expectError(error.UnterminatedString, analyze("let x = \"unterminated\n"));
}

test "analyze rejects unterminated char literal" {
    try std.testing.expectError(error.UnterminatedChar, analyze("let c = 'x\n"));
}

test "analyze rejects unterminated nested comment" {
    try std.testing.expectError(error.UnterminatedComment, analyze("let x = 1 (* outer (* inner *)\n"));
}

test "formats simple top-level lets with two-space body indentation" {
    try expectFormat(
        "let entrypoint x=\nmatch x with\n| Some y->y\n| None->0",
        "let entrypoint x =\n  match x with\n    | Some y -> y\n    | None -> 0\n",
    );
}

test "keeps short let-in chains on one line" {
    try expectFormat(
        "let y=let x=1 in x+1",
        "let y = let x = 1 in x + 1\n",
    );
}

test "breaks long let-in chains before in" {
    try expectFormat(
        "let result=let very_long_identifier=alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu in very_long_identifier",
        "let result = let very_long_identifier = alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\nin very_long_identifier\n",
    );
}

test "wraps long function application with continuation indent" {
    try expectFormat(
        "let result=compute alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau",
        "let result = compute alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi\n  omicron pi rho sigma tau\n",
    );
}

test "preserves comments verbatim while stripping trailing whitespace" {
    try expectFormat(
        "let x=1  (* keep   me *)   \n",
        "let x = 1 (* keep   me *)\n",
    );
}

test "preserves let percent attributes" {
    try expectFormat(
        "let%test_unit \"adds\"=assert (1+1=2)\nlet%test_prop \"prop\" gen=fun x->x=x",
        "let%test_unit \"adds\" = assert (1 + 1 = 2)\nlet%test_prop \"prop\" gen = fun x -> x = x\n",
    );
}

test "idempotent double.apply for comments and match arms" {
    try expectDoubleApply(
        "let entrypoint x=\n  (* keep   comment *)\nmatch x with\n| Ok y->y\n| Error _->0\n",
    );
}

test "fixed.point idempotency for let-in and applications" {
    try expectDoubleApply(
        "let result=let f=compute alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu in f",
    );
}
