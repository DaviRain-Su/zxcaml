//! Typed Zig mirror for the M1 ZxCaml frontend S-expression format.
//!
//! RESPONSIBILITIES:
//! - Validate the `(zxcaml-cir 0.3 ...)` wire-format header.
//! - Decode the generic S-expression tree into `Module -> Decl -> Expr`.
//! - Keep all compiler-internal allocation explicit through a caller arena.

const std = @import("std");
const Io = std.Io;
const sexp_parser = @import("sexp_parser.zig");
const Sexp = sexp_parser.Sexp;

pub const expected_wire_version = "0.3";

/// Typed mirror of an accepted frontend module.
pub const Module = struct {
    decls: []const Decl,
};

/// Typed mirror of an accepted top-level declaration.
pub const Decl = union(enum) {
    Let: LetDecl,
};

/// Top-level `let` declaration.
pub const LetDecl = struct {
    name: []const u8,
    body: Expr,
};

/// Typed mirror of accepted expressions.
pub const Expr = union(enum) {
    Lambda: Lambda,
    Constant: Constant,
    Let: LetExpr,
    Var: Var,
    Ctor: Ctor,
};

/// Single lambda form.
pub const Lambda = struct {
    params: []const []const u8,
    body: *const Expr,
};

/// Nested `let NAME = VALUE in BODY` expression.
pub const LetExpr = struct {
    name: []const u8,
    value: *const Expr,
    body: *const Expr,
};

/// Variable reference expression.
pub const Var = struct {
    name: []const u8,
};

/// Constructor expression such as `None`, `Some x`, `Ok x`, or `Error e`.
pub const Ctor = struct {
    name: []const u8,
    args: []const Expr,
};

/// Typed mirror of constants.
pub const Constant = union(enum) {
    Int: i64,
    String: []const u8,
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
    MalformedLet,
    MalformedVar,
    MalformedCtor,
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
            try writeStderr(io, " expected=0.3\n");
            if (std.mem.eql(u8, extractHeaderVersion(bytes), "0.1") or
                std.mem.eql(u8, extractHeaderVersion(bytes), "0.2"))
            {
                try writeStderr(io, "hint: frontend wire format ");
                try writeStderr(io, extractHeaderVersion(bytes));
                try writeStderr(io, " is deprecated; rebuild zxc-frontend with this omlz so it emits constructor-aware sexp 0.3.\n");
            } else {
                try writeStderr(io, "hint: rebuild zxc-frontend with this omlz so the frontend and Zig bridge agree on the wire format.\n");
            }
        },
        error.EmptyInput => try writeStderr(io, "error: empty frontend sexp on stdin\n"),
        error.UnmatchedParen => try writeStderr(io, "error: malformed frontend sexp: unmatched paren\n"),
        error.UnexpectedRightParen => try writeStderr(io, "error: malformed frontend sexp: unexpected right paren\n"),
        error.BadAtom => try writeStderr(io, "error: malformed frontend sexp: bad atom\n"),
        error.InvalidHeader => try writeStderr(io, "error: malformed frontend sexp: expected (zxcaml-cir 0.3 ...)\n"),
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

    return .{ .Let = .{ .name = name, .body = body } };
}

fn parseExpr(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!Expr {
    const items = try expectList(node);
    if (items.len == 0) return error.UnexpectedAtom;

    const tag = try expectAtom(items[0]);
    if (std.mem.eql(u8, tag, "lambda")) return .{ .Lambda = try parseLambda(arena, items) };
    if (std.mem.eql(u8, tag, "const-int")) return .{ .Constant = .{ .Int = try parseConstInt(items) } };
    if (std.mem.eql(u8, tag, "const-string")) return .{ .Constant = .{ .String = try parseConstString(arena, items) } };
    if (std.mem.eql(u8, tag, "let")) return .{ .Let = try parseLetExpr(arena, items) };
    if (std.mem.eql(u8, tag, "var")) return .{ .Var = try parseVar(arena, items) };
    if (std.mem.eql(u8, tag, "ctor")) return .{ .Ctor = try parseCtor(arena, items) };
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

    return .{
        .params = try params.toOwnedSlice(arena.allocator()),
        .body = body,
    };
}

fn parseLetExpr(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!LetExpr {
    if (items.len != 4) return error.MalformedLet;

    const value = try arena.allocator().create(Expr);
    value.* = try parseExpr(arena, items[2]);

    const body = try arena.allocator().create(Expr);
    body.* = try parseExpr(arena, items[3]);

    return .{
        .name = try dupeAtom(arena, items[1]),
        .value = value,
        .body = body,
    };
}

fn parseVar(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!Var {
    if (items.len != 2) return error.MalformedVar;
    return .{ .name = try dupeAtom(arena, items[1]) };
}

fn parseCtor(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!Ctor {
    if (items.len < 2) return error.MalformedCtor;

    var args = std.ArrayList(Expr).empty;
    errdefer args.deinit(arena.allocator());
    for (items[2..]) |arg_node| {
        try args.append(arena.allocator(), try parseExpr(arena, arg_node));
    }

    return .{
        .name = try dupeAtom(arena, items[1]),
        .args = try args.toOwnedSlice(arena.allocator()),
    };
}

fn parseConstInt(items: []const *const Sexp) BridgeError!i64 {
    if (items.len != 2) return error.MalformedConstant;
    return expectInteger(items[1]);
}

fn parseConstString(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError![]const u8 {
    if (items.len != 2) return error.MalformedConstant;
    return arena.allocator().dupe(u8, try expectAtom(items[1]));
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

    const module = try parseModule(&arena, "(zxcaml-cir 0.3 (module))");
    try std.testing.expectEqual(@as(usize, 0), module.decls.len);
}

test "parse single int constant module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(&arena, "(zxcaml-cir 0.3 (module (let entrypoint (lambda (_) (const-int 0)))))");
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
        .String => return error.TestUnexpectedResult,
    }
}

test "parse top-level and nested let expressions with variable references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(
        &arena,
        "(zxcaml-cir 0.3 (module (let x (const-int 1)) (let entrypoint (lambda (_input) (let y (const-int 7) (var x))))))",
    );
    try std.testing.expectEqual(@as(usize, 2), module.decls.len);

    const top_level = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
    };
    try std.testing.expectEqualStrings("x", top_level.name);
    _ = switch (top_level.body) {
        .Constant => |value| value,
        else => return error.TestUnexpectedResult,
    };

    const entrypoint = switch (module.decls[1]) {
        .Let => |let_decl| let_decl,
    };
    const lambda = switch (entrypoint.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const nested = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("y", nested.name);
    const var_ref = switch (nested.body.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("x", var_ref.name);
}

test "malformed sexp cases are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.UnmatchedParen, parseModule(&arena, "(zxcaml-cir 0.3 (module)"));
    try std.testing.expectError(error.BadAtom, parseModule(&arena, "(zxcaml-cir 0.3 (module bad@atom))"));
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

test "parse constructor expressions and string payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(&arena, "(zxcaml-cir 0.3 (module (let some_value (ctor Some (const-int 1))) (let error_value (ctor Error (const-string \"oops\")))))");
    try std.testing.expectEqual(@as(usize, 2), module.decls.len);

    const some_decl = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
    };
    const some_ctor = switch (some_decl.body) {
        .Ctor => |ctor| ctor,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Some", some_ctor.name);
    try std.testing.expectEqual(@as(usize, 1), some_ctor.args.len);

    const error_decl = switch (module.decls[1]) {
        .Let => |let_decl| let_decl,
    };
    const error_ctor = switch (error_decl.body) {
        .Ctor => |ctor| ctor,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Error", error_ctor.name);
    const string_arg = switch (error_ctor.args[0]) {
        .Constant => |constant| switch (constant) {
            .String => |value| value,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("oops", string_arg);
}
