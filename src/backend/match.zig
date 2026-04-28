//! Decision-tree pattern matrix support for backend match compilation.
//!
//! RESPONSIBILITIES:
//! - Represent constructor-classified match decisions independently of Zig syntax.
//! - Provide a deterministic first-column matrix decomposition helper.
//! - Keep guard/action ordering explicit so codegen can preserve first-match wins.

const std = @import("std");
const lir = @import("../lower/lir.zig");

/// A compiled decision tree over a pattern matrix.
pub const DecisionTree = union(enum) {
    Leaf: usize,
    Switch: Switch,
    Fail,
};

/// Constructor dispatch node produced by first-column matrix decomposition.
pub const Switch = struct {
    column: usize,
    cases: []const Case,
    default: ?*const DecisionTree,
};

/// One constructor-specialized subtree.
pub const Case = struct {
    constructor: []const u8,
    tree: *const DecisionTree,
};

const Row = struct {
    patterns: []const lir.LPattern,
    action: usize,
};

/// Compiles a pattern matrix plus action vector into a deterministic decision tree.
pub fn compileMatrix(allocator: std.mem.Allocator, matrix: []const []const lir.LPattern, actions: []const usize) !*DecisionTree {
    if (matrix.len != actions.len) return error.InvalidPatternMatrix;
    const rows = try allocator.alloc(Row, matrix.len);
    defer allocator.free(rows);
    for (matrix, actions, 0..) |patterns, action, index| {
        rows[index] = .{ .patterns = patterns, .action = action };
    }
    return compileRows(allocator, rows);
}

fn compileRows(allocator: std.mem.Allocator, rows: []const Row) !*DecisionTree {
    const node = try allocator.create(DecisionTree);
    if (rows.len == 0) {
        node.* = .Fail;
        return node;
    }
    if (rows[0].patterns.len == 0 or firstRowIrrefutable(rows[0].patterns)) {
        node.* = .{ .Leaf = rows[0].action };
        return node;
    }

    const column: usize = 0;
    var constructors = std.ArrayList([]const u8).empty;
    defer constructors.deinit(allocator);
    for (rows) |row| {
        if (row.patterns.len == 0) continue;
        switch (row.patterns[column]) {
            .Ctor => |ctor| if (!contains(constructors.items, ctor.name)) try constructors.append(allocator, ctor.name),
            .Tuple, .Record, .Wildcard, .Var => {},
        }
    }
    if (constructors.items.len == 0) {
        node.* = .{ .Leaf = rows[0].action };
        return node;
    }

    const cases = try allocator.alloc(Case, constructors.items.len);
    for (constructors.items, 0..) |constructor, index| {
        const specialized = try specializeRows(allocator, rows, column, constructor);
        defer freeRows(allocator, specialized);
        cases[index] = .{
            .constructor = constructor,
            .tree = try compileRows(allocator, specialized),
        };
    }

    const default_rows = try defaultRows(allocator, rows, column);
    defer freeRows(allocator, default_rows);
    const default_tree = if (default_rows.len == 0) null else try compileRows(allocator, default_rows);
    node.* = .{ .Switch = .{ .column = column, .cases = cases, .default = default_tree } };
    return node;
}

fn firstRowIrrefutable(patterns: []const lir.LPattern) bool {
    for (patterns) |pattern| {
        switch (pattern) {
            .Tuple, .Record, .Wildcard, .Var => {},
            .Ctor => return false,
        }
    }
    return true;
}

fn specializeRows(allocator: std.mem.Allocator, rows: []const Row, column: usize, constructor: []const u8) ![]Row {
    var out = std.ArrayList(Row).empty;
    errdefer freeRows(allocator, out.items);
    const payload_arity = constructorPayloadArity(rows, column, constructor) orelse 0;
    for (rows) |row| {
        if (row.patterns.len <= column) continue;
        switch (row.patterns[column]) {
            .Ctor => |ctor| {
                if (!std.mem.eql(u8, ctor.name, constructor)) continue;
                try out.append(allocator, .{
                    .patterns = try replaceColumnWith(allocator, row.patterns, column, ctor.args),
                    .action = row.action,
                });
            },
            .Wildcard, .Var, .Tuple, .Record => {
                const wildcard_payloads = try wildcardPatterns(allocator, payload_arity);
                errdefer allocator.free(wildcard_payloads);
                try out.append(allocator, .{
                    .patterns = try replaceColumnWith(allocator, row.patterns, column, wildcard_payloads),
                    .action = row.action,
                });
                allocator.free(wildcard_payloads);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

fn defaultRows(allocator: std.mem.Allocator, rows: []const Row, column: usize) ![]Row {
    var out = std.ArrayList(Row).empty;
    errdefer freeRows(allocator, out.items);
    for (rows) |row| {
        if (row.patterns.len <= column) continue;
        switch (row.patterns[column]) {
            .Wildcard, .Var, .Tuple, .Record => try out.append(allocator, .{
                .patterns = try removeColumn(allocator, row.patterns, column),
                .action = row.action,
            }),
            .Ctor => {},
        }
    }
    return out.toOwnedSlice(allocator);
}

fn replaceColumnWith(allocator: std.mem.Allocator, patterns: []const lir.LPattern, column: usize, replacement: []const lir.LPattern) ![]lir.LPattern {
    const out = try allocator.alloc(lir.LPattern, patterns.len - 1 + replacement.len);
    var index: usize = 0;
    for (patterns[0..column]) |pattern| {
        out[index] = pattern;
        index += 1;
    }
    for (replacement) |pattern| {
        out[index] = pattern;
        index += 1;
    }
    for (patterns[column + 1 ..]) |pattern| {
        out[index] = pattern;
        index += 1;
    }
    return out;
}

fn removeColumn(allocator: std.mem.Allocator, patterns: []const lir.LPattern, column: usize) ![]lir.LPattern {
    return replaceColumnWith(allocator, patterns, column, &.{});
}

fn constructorPayloadArity(rows: []const Row, column: usize, constructor: []const u8) ?usize {
    for (rows) |row| {
        if (row.patterns.len <= column) continue;
        switch (row.patterns[column]) {
            .Ctor => |ctor| {
                if (std.mem.eql(u8, ctor.name, constructor)) return ctor.args.len;
            },
            .Tuple, .Record, .Wildcard, .Var => {},
        }
    }
    return null;
}

fn wildcardPatterns(allocator: std.mem.Allocator, count: usize) ![]lir.LPattern {
    const out = try allocator.alloc(lir.LPattern, count);
    for (out) |*pattern| pattern.* = .{ .Wildcard = {} };
    return out;
}

fn freeRows(allocator: std.mem.Allocator, rows: []const Row) void {
    for (rows) |row| allocator.free(row.patterns);
    allocator.free(rows);
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

test "compileMatrix emits switch with specialized cases and default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const matrix = &.{
        &.{lir.LPattern{ .Ctor = .{ .name = "A", .args = &.{} } }},
        &.{lir.LPattern{ .Ctor = .{ .name = "B", .args = &.{} } }},
        &.{lir.LPattern{ .Wildcard = {} }},
    };
    const actions = &.{ @as(usize, 10), @as(usize, 20), @as(usize, 30) };

    const tree = try compileMatrix(allocator, matrix, actions);
    try std.testing.expectEqual(@as(usize, 0), tree.Switch.column);
    try std.testing.expectEqual(@as(usize, 2), tree.Switch.cases.len);
    try std.testing.expectEqualStrings("A", tree.Switch.cases[0].constructor);
    try std.testing.expectEqual(@as(usize, 10), tree.Switch.cases[0].tree.Leaf);
    try std.testing.expect(tree.Switch.default != null);
    try std.testing.expectEqual(@as(usize, 30), tree.Switch.default.?.Leaf);
}

test "compileMatrix expands wildcard defaults across constructor payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const matrix = &.{
        &.{lir.LPattern{ .Ctor = .{ .name = "Some", .args = &.{.{ .Ctor = .{ .name = "Some", .args = &.{.{ .Var = "v" }} } }} } }},
        &.{lir.LPattern{ .Wildcard = {} }},
    };
    const actions = &.{ @as(usize, 10), @as(usize, 20) };

    const tree = try compileMatrix(allocator, matrix, actions);
    try std.testing.expectEqual(@as(usize, 0), tree.Switch.column);
    try std.testing.expectEqual(@as(usize, 1), tree.Switch.cases.len);
    try std.testing.expectEqualStrings("Some", tree.Switch.cases[0].constructor);

    const some_tree = tree.Switch.cases[0].tree;
    try std.testing.expectEqual(@as(usize, 0), some_tree.Switch.column);
    try std.testing.expectEqual(@as(usize, 1), some_tree.Switch.cases.len);
    try std.testing.expectEqualStrings("Some", some_tree.Switch.cases[0].constructor);
    try std.testing.expectEqual(@as(usize, 10), some_tree.Switch.cases[0].tree.Leaf);
    try std.testing.expect(some_tree.Switch.default != null);
    try std.testing.expectEqual(@as(usize, 20), some_tree.Switch.default.?.Leaf);
}
