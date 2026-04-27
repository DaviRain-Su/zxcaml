//! Typed Zig mirror for the M0 ZxCaml frontend S-expression format.
//!
//! RESPONSIBILITIES:
//! - Validate the `(zxcaml-cir 0.1 ...)` wire-format header.
//! - Decode the generic S-expression tree into `Module -> Decl -> Expr`.
//! - Keep all compiler-internal allocation explicit through a caller arena.

const std = @import("std");
const Io = std.Io;
const sexp_parser = @import("sexp_parser.zig");
const Sexp = sexp_parser.Sexp;

pub const expected_wire_version = "0.1";

/// Typed mirror of an accepted frontend module.
pub const Module = struct {
    decls: []const Decl,
};

/// Typed mirror of an accepted top-level declaration.
pub const Decl = union(enum) {
    Let: LetDecl,
};

/// M0 top-level `let` declaration.
pub const LetDecl = struct {
    name: []const u8,
    body: Expr,
};

/// Typed mirror of accepted M0 expressions.
pub const Expr = union(enum) {
    Lambda: Lambda,
    Constant: Constant,
};

/// M0 single lambda form.
pub const Lambda = struct {
    params: []const []const u8,
    body: *const Expr,
};

/// Typed mirror of M0 constants.
pub const Constant = union(enum) {
    Int: i64,
};

/// Errors that can occur while validating and decoding the typed mirror.
pub const BridgeError = sexp_parser.ParseError || error{
    InvalidHeader,
    WireFormatVersionMismatch,
    ExpectedList,
    ExpectedAtom,
    ExpectedInteger,
    UnexpectedAtom,
    UnsupportedNode,
    MalformedModule,
    MalformedDecl,
    MalformedLambda,
    MalformedConstant,
};

/// Parses frontend bytes into an arena-owned typed module mirror.
pub fn parseModule(arena: *std.heap.ArenaAllocator, bytes: []const u8) BridgeError!Module {
    const root = try sexp_parser.parse(arena, bytes);
    const header = try expectList(root);
    if (header.len != 3) return error.InvalidHeader;
    try expectAtomValue(header[0], "zxcaml-cir");

    const file_version = try expectAtom(header[1]);
    if (!std.mem.eql(u8, file_version, expected_wire_version)) {
        return error.WireFormatVersionMismatch;
    }

    return parseModuleNode(arena, header[2]);
}

/// Writes a user-facing parse/bridge diagnostic to stderr.
pub fn writeParseError(io: Io, bytes: []const u8, err: anyerror) !void {
    switch (err) {
        error.WireFormatVersionMismatch => {
            try writeStderr(io, "wire format version mismatch: file=");
            try writeStderr(io, extractHeaderVersion(bytes));
            try writeStderr(io, " expected=0.1\n");
            try writeStderr(io, "hint: ADR-010 and docs/06-bpf-target.md describe the frontend wire-format upgrade path.\n");
        },
        error.EmptyInput => try writeStderr(io, "error: empty frontend sexp on stdin\n"),
        error.UnmatchedParen => try writeStderr(io, "error: malformed frontend sexp: unmatched paren\n"),
        error.UnexpectedRightParen => try writeStderr(io, "error: malformed frontend sexp: unexpected right paren\n"),
        error.BadAtom => try writeStderr(io, "error: malformed frontend sexp: bad atom\n"),
        error.InvalidHeader => try writeStderr(io, "error: malformed frontend sexp: expected (zxcaml-cir 0.1 ...)\n"),
        error.UnexpectedAtom => try writeStderr(io, "error: malformed frontend sexp: unexpected atom in typed tree\n"),
        else => try writeStderr(io, "error: malformed frontend sexp: could not decode typed tree\n"),
    }
}

fn parseModuleNode(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!Module {
    const items = try expectList(node);
    if (items.len == 0) return error.MalformedModule;
    try expectAtomValue(items[0], "module");

    var decls = std.ArrayList(Decl).empty;
    errdefer decls.deinit(arena.allocator());

    for (items[1..]) |decl_node| {
        try decls.append(arena.allocator(), try parseDecl(arena, decl_node));
    }

    return .{ .decls = try decls.toOwnedSlice(arena.allocator()) };
}

fn parseDecl(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!Decl {
    const items = try expectList(node);
    if (items.len != 3) return error.MalformedDecl;
    try expectAtomValue(items[0], "let");

    const name = try dupeAtom(arena, items[1]);
    const body = try parseExpr(arena, items[2]);

    switch (body) {
        .Lambda => {},
        else => return error.UnsupportedNode,
    }

    return .{ .Let = .{ .name = name, .body = body } };
}

fn parseExpr(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!Expr {
    const items = try expectList(node);
    if (items.len == 0) return error.UnexpectedAtom;

    const tag = try expectAtom(items[0]);
    if (std.mem.eql(u8, tag, "lambda")) return .{ .Lambda = try parseLambda(arena, items) };
    if (std.mem.eql(u8, tag, "const-int")) return .{ .Constant = .{ .Int = try parseConstInt(items) } };
    return error.UnsupportedNode;
}

fn parseLambda(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!Lambda {
    if (items.len != 3) return error.MalformedLambda;

    const param_nodes = try expectList(items[1]);
    var params = std.ArrayList([]const u8).empty;
    errdefer params.deinit(arena.allocator());
    for (param_nodes) |param_node| {
        try params.append(arena.allocator(), try dupeAtom(arena, param_node));
    }

    const body = try arena.allocator().create(Expr);
    body.* = try parseExpr(arena, items[2]);
    switch (body.*) {
        .Constant => {},
        else => return error.UnsupportedNode,
    }

    return .{
        .params = try params.toOwnedSlice(arena.allocator()),
        .body = body,
    };
}

fn parseConstInt(items: []const *const Sexp) BridgeError!i64 {
    if (items.len != 2) return error.MalformedConstant;
    return expectInteger(items[1]);
}

fn expectList(node: *const Sexp) BridgeError![]const *const Sexp {
    return switch (node.*) {
        .list => |items| items,
        else => error.ExpectedList,
    };
}

fn expectAtom(node: *const Sexp) BridgeError![]const u8 {
    return node.atomLike() orelse error.ExpectedAtom;
}

fn expectAtomValue(node: *const Sexp, expected: []const u8) BridgeError!void {
    const actual = try expectAtom(node);
    if (!std.mem.eql(u8, actual, expected)) return error.UnexpectedAtom;
}

fn dupeAtom(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError![]const u8 {
    return arena.allocator().dupe(u8, try expectAtom(node));
}

fn expectInteger(node: *const Sexp) BridgeError!i64 {
    return switch (node.*) {
        .integer => |value| value,
        else => error.ExpectedInteger,
    };
}

fn extractHeaderVersion(bytes: []const u8) []const u8 {
    const marker = "zxcaml-cir";
    const marker_index = std.mem.indexOf(u8, bytes, marker) orelse return "unknown";
    var index = marker_index + marker.len;
    while (index < bytes.len and std.ascii.isWhitespace(bytes[index])) : (index += 1) {}
    if (index >= bytes.len) return "unknown";

    if (bytes[index] == '"') {
        const start = index + 1;
        index = start;
        while (index < bytes.len and bytes[index] != '"') : (index += 1) {}
        return bytes[start..index];
    }

    const start = index;
    while (index < bytes.len and !isVersionDelimiter(bytes[index])) : (index += 1) {}
    if (index == start) return "unknown";
    return bytes[start..index];
}

fn isVersionDelimiter(ch: u8) bool {
    return ch == '(' or ch == ')' or std.ascii.isWhitespace(ch);
}

fn writeStderr(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}

test "parse empty module sexp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(&arena, "(zxcaml-cir 0.1 (module))");
    try std.testing.expectEqual(@as(usize, 0), module.decls.len);
}

test "parse single int constant module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(&arena, "(zxcaml-cir 0.1 (module (let entrypoint (lambda (_) (const-int 0)))))");
    try std.testing.expectEqual(@as(usize, 1), module.decls.len);

    const decl = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
    };
    try std.testing.expectEqualStrings("entrypoint", decl.name);

    const lambda = switch (decl.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), lambda.params.len);
    try std.testing.expectEqualStrings("_", lambda.params[0]);

    const constant = switch (lambda.body.*) {
        .Constant => |value| value,
        else => return error.TestUnexpectedResult,
    };
    switch (constant) {
        .Int => |value| try std.testing.expectEqual(@as(i64, 0), value),
    }
}

test "malformed sexp cases are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.UnmatchedParen, parseModule(&arena, "(zxcaml-cir 0.1 (module)"));
    try std.testing.expectError(error.BadAtom, parseModule(&arena, "(zxcaml-cir 0.1 (module bad@atom))"));
}

test "version mismatch is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.WireFormatVersionMismatch, parseModule(&arena, "(zxcaml-cir 0.2 (module))"));
}

test "empty stdin is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.EmptyInput, parseModule(&arena, ""));
}
