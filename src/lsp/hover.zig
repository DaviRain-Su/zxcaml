//! `textDocument/hover` support for `omlz-lsp`.
//!
//! Hover resolution reuses `omlz check --emit=core-ir-with-loc` output for
//! a document. The Core IR sexp printer emits `:ty <ty>` annotations on every
//! expression node and a `(loc ...)` span on top-level bindings. For this
//! pass we resolve identifiers at the granularity of top-level `let` /
//! `let-rec` bindings: the LSP picks the identifier under the cursor and
//! reports its resolved type.
//!
//! The Core IR printer emits keyword atoms like `:ty` and `:layout` and
//! operator atoms like `<=`, `=`, `*` that the generic frontend_bridge
//! sexp lexer rejects, so this module ships a permissive, hover-specific
//! sexp tokenizer.

const std = @import("std");

/// Source span of a top-level binding name (the `X` in `let X = ...`) in
/// the document the cache was built from. Coordinates are LSP 0-based
/// `(line, character)` pairs.
pub const DefRange = struct {
    line: u32,
    start_character: u32,
    end_character: u32,
};

/// One entry in the hover symbol table.
pub const Symbol = struct {
    name: []const u8,
    rendered_ty: []const u8,
    /// Range of the binding name in the document the cache was built from,
    /// or `null` when no `let X` / `and X` token could be located (e.g.
    /// non-standard formatting or syntax inside macro expansions).
    def_range: ?DefRange = null,
};

/// Returns true when `rendered_ty` renders as a top-level arrow type, which
/// the completion provider uses to decide between `Function` and `Value`
/// `CompletionItemKind`s.
pub fn isFunctionType(rendered_ty: []const u8) bool {
    return std.mem.indexOf(u8, rendered_ty, "->") != null;
}

/// Cached `name -> type` lookup table for a single document.
pub const Cache = struct {
    arena: std.heap.ArenaAllocator,
    /// The exact document text the cache was built from. Mismatched text
    /// means the cache is stale and must be rebuilt.
    text: []const u8,
    symbols: std.StringHashMap(Symbol),

    pub fn deinit(self: *Cache) void {
        self.symbols.deinit();
        self.arena.deinit();
    }
};

// ----------------------------------------------------------------------------
// Permissive sexp tokenizer / parser for Core IR output.
// ----------------------------------------------------------------------------

const SexpKind = enum { list, atom };
const Sexp = struct {
    kind: SexpKind,
    // For atoms: the atom text (without surrounding quotes for strings, but
    // the leaf bytes verbatim otherwise).
    atom: []const u8 = "",
    // For lists: the child nodes.
    children: []const *Sexp = &.{},
};

const ParseError = error{ Unexpected, OutOfMemory };

const Parser = struct {
    arena: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,

    fn skipWs(self: *Parser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else break;
        }
    }

    fn parseOne(self: *Parser) ParseError!*Sexp {
        self.skipWs();
        if (self.pos >= self.input.len) return error.Unexpected;
        const c = self.input[self.pos];
        if (c == '(') return self.parseList();
        if (c == ')') return error.Unexpected;
        if (c == '"') return self.parseString();
        return self.parseAtom();
    }

    fn parseList(self: *Parser) ParseError!*Sexp {
        self.pos += 1; // consume '('
        var items = std.ArrayList(*Sexp).empty;
        while (true) {
            self.skipWs();
            if (self.pos >= self.input.len) return error.Unexpected;
            if (self.input[self.pos] == ')') {
                self.pos += 1;
                const owned = try items.toOwnedSlice(self.arena);
                const node = try self.arena.create(Sexp);
                node.* = .{ .kind = .list, .children = owned };
                return node;
            }
            const child = try self.parseOne();
            try items.append(self.arena, child);
        }
    }

    fn parseString(self: *Parser) ParseError!*Sexp {
        const start = self.pos;
        self.pos += 1; // opening quote
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '\\' and self.pos + 1 < self.input.len) {
                self.pos += 2;
                continue;
            }
            if (c == '"') {
                const bytes = self.input[start + 1 .. self.pos];
                self.pos += 1; // closing quote
                const node = try self.arena.create(Sexp);
                node.* = .{ .kind = .atom, .atom = bytes };
                return node;
            }
            self.pos += 1;
        }
        return error.Unexpected;
    }

    fn parseAtom(self: *Parser) ParseError!*Sexp {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '(' or c == ')') break;
            self.pos += 1;
        }
        const bytes = self.input[start..self.pos];
        const node = try self.arena.create(Sexp);
        node.* = .{ .kind = .atom, .atom = bytes };
        return node;
    }
};

fn parseSexp(arena_allocator: std.mem.Allocator, input: []const u8) ParseError!*Sexp {
    var parser = Parser{ .arena = arena_allocator, .input = input };
    return parser.parseOne();
}

// ----------------------------------------------------------------------------
// Symbol extraction.
// ----------------------------------------------------------------------------

/// Parses Core IR sexp output and extracts top-level `let` / `let-rec`
/// bindings with rendered OCaml-style types. Returns `null` when the input
/// is not a `(module ...)` sexp (for example when `omlz check` failed).
pub fn buildSymbolsFromCoreIr(
    backing_allocator: std.mem.Allocator,
    parent_text: []const u8,
    core_ir_sexp: []const u8,
) !?Cache {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const arena_text = try a.dupe(u8, parent_text);

    const root = parseSexp(a, core_ir_sexp) catch return null;
    if (root.kind != .list or root.children.len == 0) return null;
    const head = root.children[0];
    if (head.kind != .atom or !std.mem.eql(u8, head.atom, "module")) return null;

    var symbols = std.StringHashMap(Symbol).init(backing_allocator);
    errdefer symbols.deinit();

    for (root.children[1..]) |child| {
        try collectTopLevelBinding(a, child, &symbols);
    }

    // Annotate symbols with the source range of their binding name. We scan
    // the parent document for `let`, `let rec`, and `and` keywords at the
    // top level and match the first identifier after the keyword against
    // entries in the symbol table.
    annotateDefRanges(arena_text, &symbols);

    return Cache{
        .arena = arena,
        .text = arena_text,
        .symbols = symbols,
    };
}

/// Returns a pointer to the cached symbol for `name`, or `null` if the name
/// is not a known top-level binding. Reused by both hover and definition.
pub fn findSymbol(cache: *const Cache, name: []const u8) ?Symbol {
    return cache.symbols.get(name);
}

/// Walks the document text top-down, locating `let`/`let rec`/`and` keywords
/// outside of comments/strings, and records the LSP range of the binding name
/// for any symbol whose key matches. This is best-effort: only the first
/// matching occurrence wins, and bindings with shapes the scanner can't
/// recognize are left with `def_range = null`.
fn annotateDefRanges(text: []const u8, symbols: *std.StringHashMap(Symbol)) void {
    var i: usize = 0;
    var line: u32 = 0;
    var character: u32 = 0;
    var comment_depth: usize = 0;
    var in_string = false;
    var in_char = false;
    var escaped = false;
    // Tracks whether the last non-whitespace, non-comment token we saw was
    // a `let`/`and` keyword starting at the beginning of a logical top-level
    // line. We treat any `let`/`and` whose first non-whitespace position on
    // its line is the keyword itself as a top-level binding head.
    while (i < text.len) {
        const byte = text[i];

        // Track comments and strings.
        if (in_string or in_char) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (in_string and byte == '"') {
                in_string = false;
            } else if (in_char and byte == '\'') {
                in_char = false;
            }
            advance(byte, &i, &line, &character);
            continue;
        }
        if (comment_depth > 0) {
            if (i + 1 < text.len and byte == '(' and text[i + 1] == '*') {
                comment_depth += 1;
                advance(text[i], &i, &line, &character);
                advance(text[i], &i, &line, &character);
                continue;
            }
            if (i + 1 < text.len and byte == '*' and text[i + 1] == ')') {
                comment_depth -= 1;
                advance(text[i], &i, &line, &character);
                advance(text[i], &i, &line, &character);
                continue;
            }
            advance(byte, &i, &line, &character);
            continue;
        }
        if (i + 1 < text.len and byte == '(' and text[i + 1] == '*') {
            comment_depth += 1;
            advance(text[i], &i, &line, &character);
            advance(text[i], &i, &line, &character);
            continue;
        }
        if (byte == '"') {
            in_string = true;
            advance(byte, &i, &line, &character);
            continue;
        }

        // Match `let` / `and` keywords that start a binding head. We accept
        // any position (top-level or nested) for matching: the symbol table
        // is the source of truth for which names are top-level. Nested
        // `let` bindings won't have entries in the table, so their names
        // are silently ignored.
        if (isKeywordAt(text, i, "let")) {
            const after = skipLetRec(text, i + 3);
            tryRecordBindingName(text, after, line, character + @as(u32, @intCast(after - i)), symbols);
        } else if (isKeywordAt(text, i, "and")) {
            const after = skipSpaces(text, i + 3);
            tryRecordBindingName(text, after, line, character + @as(u32, @intCast(after - i)), symbols);
        }

        advance(byte, &i, &line, &character);
    }
}

fn advance(byte: u8, i: *usize, line: *u32, character: *u32) void {
    if (byte == '\n') {
        line.* += 1;
        character.* = 0;
    } else {
        character.* += 1;
    }
    i.* += 1;
}

fn isKeywordAt(text: []const u8, pos: usize, keyword: []const u8) bool {
    if (pos + keyword.len > text.len) return false;
    if (!std.mem.eql(u8, text[pos .. pos + keyword.len], keyword)) return false;
    // Preceding byte must not be an identifier character.
    if (pos > 0 and isIdentChar(text[pos - 1])) return false;
    // Following byte must not be an identifier character.
    const after = pos + keyword.len;
    if (after < text.len and isIdentChar(text[after])) return false;
    return true;
}

fn skipLetRec(text: []const u8, pos: usize) usize {
    var p = skipSpaces(text, pos);
    if (isKeywordAt(text, p, "rec")) {
        p = skipSpaces(text, p + 3);
    }
    return p;
}

fn skipSpaces(text: []const u8, pos: usize) usize {
    var p = pos;
    while (p < text.len and (text[p] == ' ' or text[p] == '\t')) : (p += 1) {}
    return p;
}

fn tryRecordBindingName(
    text: []const u8,
    start: usize,
    name_line: u32,
    name_character: u32,
    symbols: *std.StringHashMap(Symbol),
) void {
    if (start >= text.len) return;
    // The binding name must be a regular identifier (skip e.g. patterns like
    // `let (x, y) = ...`, which the top-level symbol table doesn't expose).
    const first = text[start];
    if (!std.ascii.isAlphabetic(first) and first != '_') return;
    var end = start;
    while (end < text.len and isIdentChar(text[end])) : (end += 1) {}
    if (end == start) return;
    const name = text[start..end];

    if (symbols.getPtr(name)) |entry| {
        if (entry.def_range != null) return; // first occurrence wins
        const start_char = name_character;
        const len: u32 = @intCast(end - start);
        entry.def_range = .{
            .line = name_line,
            .start_character = start_char,
            .end_character = start_char + len,
        };
    }
}

fn collectTopLevelBinding(
    arena_allocator: std.mem.Allocator,
    node: *Sexp,
    symbols: *std.StringHashMap(Symbol),
) !void {
    if (node.kind != .list or node.children.len == 0) return;
    const head = node.children[0];
    if (head.kind != .atom) return;

    if (std.mem.eql(u8, head.atom, "let") or std.mem.eql(u8, head.atom, "let-rec")) {
        if (node.children.len < 3) return;
        const name_node = node.children[1];
        if (name_node.kind != .atom) return;
        const body = node.children[node.children.len - 1];
        const ty_sexp = findOuterTy(body) orelse return;
        const rendered = try renderTy(arena_allocator, ty_sexp);
        const owned_name = try arena_allocator.dupe(u8, name_node.atom);
        try symbols.put(owned_name, .{ .name = owned_name, .rendered_ty = rendered });
        return;
    }

    if (std.mem.eql(u8, head.atom, "LetGroup")) {
        for (node.children[1..]) |entry| {
            if (entry.kind != .list or entry.children.len < 3) continue;
            const tag = entry.children[0];
            if (tag.kind != .atom or !std.mem.eql(u8, tag.atom, "binding")) continue;
            const name_node = entry.children[1];
            if (name_node.kind != .atom) continue;
            const body = entry.children[entry.children.len - 1];
            const ty_sexp = findOuterTy(body) orelse continue;
            const rendered = try renderTy(arena_allocator, ty_sexp);
            const owned_name = try arena_allocator.dupe(u8, name_node.atom);
            try symbols.put(owned_name, .{ .name = owned_name, .rendered_ty = rendered });
        }
        return;
    }
}

/// Returns the first `:ty <node>` annotation reachable from `node`. The Core
/// IR printer attaches `:ty` directly inside the node's surface form (or, for
/// lambdas, inside the parameter list). A depth-first scan therefore finds
/// the binding's "outer" type before any inner expression type.
fn findOuterTy(node: *Sexp) ?*Sexp {
    if (node.kind != .list) return null;
    var i: usize = 0;
    while (i + 1 < node.children.len) : (i += 1) {
        const child = node.children[i];
        if (child.kind == .atom and std.mem.eql(u8, child.atom, ":ty")) {
            return node.children[i + 1];
        }
    }
    for (node.children) |child| {
        if (findOuterTy(child)) |ty| return ty;
    }
    return null;
}

// ----------------------------------------------------------------------------
// Pretty-printer for Core IR `Ty` sexps.
// ----------------------------------------------------------------------------

const RenderContext = enum { top, arrow_lhs, type_arg };

fn renderTy(arena_allocator: std.mem.Allocator, node: *Sexp) anyerror![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(arena_allocator);
    try renderTyInto(&out, arena_allocator, node, .top);
    return out.toOwnedSlice(arena_allocator);
}

fn renderTyInto(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    node: *Sexp,
    ctx: RenderContext,
) anyerror!void {
    switch (node.kind) {
        .atom => try out.appendSlice(a, node.atom),
        .list => {
            if (node.children.len == 0) {
                try out.appendSlice(a, "()");
                return;
            }
            const head = node.children[0];
            if (head.kind != .atom) {
                try out.appendSlice(a, "?");
                return;
            }

            if (std.mem.eql(u8, head.atom, "arrow")) {
                if (node.children.len < 3) {
                    try out.appendSlice(a, "?");
                    return;
                }
                const need_parens = ctx != .top;
                if (need_parens) try out.append(a, '(');
                var i: usize = 1;
                while (i < node.children.len) : (i += 1) {
                    if (i > 1) try out.appendSlice(a, " -> ");
                    const sub_ctx: RenderContext = if (i + 1 == node.children.len) .top else .arrow_lhs;
                    try renderTyInto(out, a, node.children[i], sub_ctx);
                }
                if (need_parens) try out.append(a, ')');
                return;
            }

            if (std.mem.eql(u8, head.atom, "tuple")) {
                if (node.children.len < 2) {
                    try out.appendSlice(a, "unit");
                    return;
                }
                const need_parens = ctx != .top;
                if (need_parens) try out.append(a, '(');
                var i: usize = 1;
                while (i < node.children.len) : (i += 1) {
                    if (i > 1) try out.appendSlice(a, " * ");
                    try renderTyInto(out, a, node.children[i], .arrow_lhs);
                }
                if (need_parens) try out.append(a, ')');
                return;
            }

            if (std.mem.eql(u8, head.atom, "record")) {
                if (node.children.len < 2 or node.children[1].kind != .atom) {
                    try out.appendSlice(a, "?");
                    return;
                }
                try renderApplied(out, a, node.children[1].atom, node.children[2..]);
                return;
            }

            try renderApplied(out, a, head.atom, node.children[1..]);
        },
    }
}

fn renderApplied(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    name: []const u8,
    args: []const *Sexp,
) anyerror!void {
    if (args.len == 0) {
        try out.appendSlice(a, name);
        return;
    }
    if (args.len == 1) {
        try renderTyInto(out, a, args[0], .type_arg);
        try out.append(a, ' ');
        try out.appendSlice(a, name);
        return;
    }
    try out.append(a, '(');
    for (args, 0..) |arg, i| {
        if (i != 0) try out.appendSlice(a, ", ");
        try renderTyInto(out, a, arg, .top);
    }
    try out.appendSlice(a, ") ");
    try out.appendSlice(a, name);
}

// ----------------------------------------------------------------------------
// Position helpers.
// ----------------------------------------------------------------------------

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '\'' or ch == '.';
}

/// Identifier under an LSP `(line, character)` cursor position.
pub const WordSpan = struct {
    text: []const u8,
    start_line: u32,
    start_character: u32,
    end_line: u32,
    end_character: u32,
};

pub fn wordAtPosition(text: []const u8, line: u32, character: u32) ?WordSpan {
    const offset = byteOffsetForLineCharacter(text, line, character) orelse return null;
    if (offset > text.len) return null;

    var start = offset;
    while (start > 0) {
        const prev = text[start - 1];
        if (!isIdentChar(prev)) break;
        start -= 1;
    }
    var end = offset;
    while (end < text.len and isIdentChar(text[end])) end += 1;
    if (start == end) return null;
    if (start >= text.len) return null;
    if (std.ascii.isDigit(text[start])) return null;

    const word = text[start..end];
    return .{
        .text = word,
        .start_line = line,
        .start_character = character - @as(u32, @intCast(offset - start)),
        .end_line = line,
        .end_character = character + @as(u32, @intCast(end - offset)),
    };
}

fn byteOffsetForLineCharacter(text: []const u8, target_line: u32, target_character: u32) ?usize {
    var line: u32 = 0;
    var character: u32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (line == target_line and character == target_character) return i;
        if (text[i] == '\n') {
            line += 1;
            character = 0;
        } else {
            character += 1;
        }
    }
    if (line == target_line and character == target_character) return text.len;
    return null;
}

/// One token occurrence emitted by `collectOccurrences`. Coordinates are
/// LSP 0-based `(line, character)` pairs covering just the identifier
/// itself (not surrounding whitespace).
pub const Occurrence = struct {
    line: u32,
    start_character: u32,
    end_character: u32,
};

/// Scans `text` and returns every stand-alone occurrence of `name` that
/// sits outside of comments and string/char literals. "Stand-alone" matches
/// `wordAtPosition`: the preceding and following bytes (if any) must not be
/// identifier characters. Caller owns the returned slice.
pub fn collectOccurrences(
    allocator: std.mem.Allocator,
    text: []const u8,
    name: []const u8,
) ![]Occurrence {
    var out = std.ArrayList(Occurrence).empty;
    errdefer out.deinit(allocator);
    if (name.len == 0) return out.toOwnedSlice(allocator);

    var i: usize = 0;
    var line: u32 = 0;
    var character: u32 = 0;
    var comment_depth: usize = 0;
    var in_string = false;
    var in_char = false;
    var escaped = false;

    while (i < text.len) {
        const byte = text[i];

        if (in_string or in_char) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (in_string and byte == '"') {
                in_string = false;
            } else if (in_char and byte == '\'') {
                in_char = false;
            }
            advance(byte, &i, &line, &character);
            continue;
        }

        if (comment_depth > 0) {
            if (i + 1 < text.len and byte == '(' and text[i + 1] == '*') {
                comment_depth += 1;
                advance(text[i], &i, &line, &character);
                advance(text[i], &i, &line, &character);
                continue;
            }
            if (i + 1 < text.len and byte == '*' and text[i + 1] == ')') {
                comment_depth -= 1;
                advance(text[i], &i, &line, &character);
                advance(text[i], &i, &line, &character);
                continue;
            }
            advance(byte, &i, &line, &character);
            continue;
        }

        if (i + 1 < text.len and byte == '(' and text[i + 1] == '*') {
            comment_depth += 1;
            advance(text[i], &i, &line, &character);
            advance(text[i], &i, &line, &character);
            continue;
        }
        if (byte == '"') {
            in_string = true;
            advance(byte, &i, &line, &character);
            continue;
        }

        // Try a token match starting at the current byte. We use a stricter
        // identifier class here (no `.`) so that module-qualified accesses
        // like `List.length` do not match a bare `length` reference search.
        if (isWordStart(text, i) and i + name.len <= text.len and
            std.mem.eql(u8, text[i .. i + name.len], name) and
            isWordEnd(text, i + name.len))
        {
            try out.append(allocator, .{
                .line = line,
                .start_character = character,
                .end_character = character + @as(u32, @intCast(name.len)),
            });
            // Advance past the matched token to avoid overlapping matches.
            var consumed: usize = 0;
            while (consumed < name.len) : (consumed += 1) {
                advance(text[i], &i, &line, &character);
            }
            continue;
        }

        advance(byte, &i, &line, &character);
    }

    return out.toOwnedSlice(allocator);
}

fn isWordStart(text: []const u8, pos: usize) bool {
    if (pos == 0) return true;
    return !isWordChar(text[pos - 1]);
}

fn isWordEnd(text: []const u8, pos: usize) bool {
    if (pos >= text.len) return true;
    return !isWordChar(text[pos]);
}

/// Identifier character class for occurrence scanning. We deliberately omit
/// `.` (which `isIdentChar` includes for hover) so that `List.length` does
/// not glue together as a single "word" when scanning for `length` use sites.
fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '\'';
}

/// Returns true when `(line, character)` lies inside an OCaml `(* ... *)`
/// comment. Respects nested comments and string literals.
pub fn isInsideComment(text: []const u8, line: u32, character: u32) bool {
    const target = byteOffsetForLineCharacter(text, line, character) orelse return false;

    var comment_depth: usize = 0;
    var in_string = false;
    var in_char = false;
    var escaped = false;
    var i: usize = 0;
    while (i < text.len and i < target) : (i += 1) {
        const byte = text[i];
        if (in_string or in_char) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (in_string and byte == '"') {
                in_string = false;
            } else if (in_char and byte == '\'') {
                in_char = false;
            }
            continue;
        }

        if (comment_depth > 0) {
            if (i + 1 < text.len and byte == '(' and text[i + 1] == '*') {
                comment_depth += 1;
                i += 1;
            } else if (i + 1 < text.len and byte == '*' and text[i + 1] == ')') {
                comment_depth -= 1;
                i += 1;
            }
            continue;
        }

        if (i + 1 < text.len and byte == '(' and text[i + 1] == '*') {
            comment_depth += 1;
            i += 1;
        } else if (byte == '"') {
            in_string = true;
        } else if (byte == '\'') {
            in_char = true;
        }
    }

    return comment_depth > 0;
}

// ----------------------------------------------------------------------------
// Tests.
// ----------------------------------------------------------------------------

test "wordAtPosition extracts identifier" {
    const text = "let factorial n = n";
    const word = wordAtPosition(text, 0, 6).?;
    try std.testing.expectEqualStrings("factorial", word.text);
    try std.testing.expectEqual(@as(u32, 4), word.start_character);
    try std.testing.expectEqual(@as(u32, 13), word.end_character);
}

test "wordAtPosition returns null at whitespace" {
    const text = "let   x = 1";
    try std.testing.expect(wordAtPosition(text, 0, 4) == null);
}

test "isInsideComment detects nested comments" {
    const text = "let x = (* hello *) 1";
    try std.testing.expect(isInsideComment(text, 0, 12));
    try std.testing.expect(!isInsideComment(text, 0, 4));
    try std.testing.expect(!isInsideComment(text, 0, 20));
}

test "renderTy renders arrow types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try parseSexp(arena.allocator(), "(arrow int int)");
    const rendered = try renderTy(arena.allocator(), node);
    try std.testing.expectEqualStrings("int -> int", rendered);
}

test "renderTy renders polymorphic list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try parseSexp(arena.allocator(), "(list int)");
    const rendered = try renderTy(arena.allocator(), node);
    try std.testing.expectEqualStrings("int list", rendered);
}

test "renderTy renders nested arrow without redundant parens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Single-argument arrow returning another arrow comes back as a top-level
    // arrow node, so we exercise the right-associative chain rendering.
    const node = try parseSexp(arena.allocator(), "(arrow int int int)");
    const rendered = try renderTy(arena.allocator(), node);
    try std.testing.expectEqualStrings("int -> int -> int", rendered);
}

test "collectOccurrences finds stand-alone identifier matches" {
    const text = "let factorial n = factorial (n - 1)\n";
    const occs = try collectOccurrences(std.testing.allocator, text, "factorial");
    defer std.testing.allocator.free(occs);
    try std.testing.expectEqual(@as(usize, 2), occs.len);
    try std.testing.expectEqual(@as(u32, 4), occs[0].start_character);
    try std.testing.expectEqual(@as(u32, 13), occs[0].end_character);
    try std.testing.expectEqual(@as(u32, 18), occs[1].start_character);
}

test "collectOccurrences ignores comments and partial words" {
    const text = "(* factorial *) let factorialish = factorial\n";
    const occs = try collectOccurrences(std.testing.allocator, text, "factorial");
    defer std.testing.allocator.free(occs);
    try std.testing.expectEqual(@as(usize, 1), occs.len);
    try std.testing.expectEqual(@as(u32, 35), occs[0].start_character);
}

test "buildSymbolsFromCoreIr extracts top-level lets" {
    const sexp =
        "(module (let-rec fact (loc \"factorial.ml\" 1 13 2 40) (lambda (n :ty (arrow int int) :layout (arena flat)) (const 1 :ty int :layout (static flat)))))";
    var cache = (try buildSymbolsFromCoreIr(std.testing.allocator, "", sexp)) orelse return error.TestUnexpectedResult;
    defer cache.deinit();
    const sym = cache.symbols.get("fact") orelse return error.TestMissingSymbol;
    try std.testing.expectEqualStrings("int -> int", sym.rendered_ty);
}
