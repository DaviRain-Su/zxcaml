//! S-expression pretty-printer for Core IR snapshots.
//!
//! RESPONSIBILITIES:
//! - Render Core IR deterministically for `omlz check --emit=core-ir`.
//! - Include type and layout annotations in the printed contract surface.
//! - Provide the M0 constant case needed by later golden tests.

const std = @import("std");
const ir = @import("ir.zig");
const layout = @import("layout.zig");

/// Formats a Core IR module as a deterministic single-line S-expression.
pub fn formatModule(allocator: std.mem.Allocator, module: ir.Module) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try append(&out, allocator, "(module");
    for (module.decls) |decl| {
        try append(&out, allocator, " ");
        try formatDecl(&out, allocator, decl);
    }
    try append(&out, allocator, ")");

    return out.toOwnedSlice(allocator);
}

fn formatDecl(out: *std.ArrayList(u8), allocator: std.mem.Allocator, decl: ir.Decl) !void {
    switch (decl) {
        .Let => |let_decl| {
            try append(out, allocator, "(let ");
            try append(out, allocator, let_decl.name);
            try append(out, allocator, " ");
            try formatExpr(out, allocator, let_decl.value.*);
            try append(out, allocator, ")");
        },
    }
}

fn formatLambda(out: *std.ArrayList(u8), allocator: std.mem.Allocator, lambda: ir.Lambda) anyerror!void {
    try append(out, allocator, "(lambda (");
    for (lambda.params, 0..) |param, index| {
        if (index != 0) try append(out, allocator, " ");
        try append(out, allocator, param.name);
    }
    try append(out, allocator, " :ty ");
    try formatTy(out, allocator, lambda.ty);
    try append(out, allocator, " :layout ");
    try formatLayout(out, allocator, lambda.layout);
    try append(out, allocator, ") ");
    try formatExpr(out, allocator, lambda.body.*);
    try append(out, allocator, ")");
}

fn formatExpr(out: *std.ArrayList(u8), allocator: std.mem.Allocator, expr: ir.Expr) anyerror!void {
    switch (expr) {
        .Lambda => |lambda| try formatLambda(out, allocator, lambda),
        .Constant => |constant| {
            switch (constant.value) {
                .Int => |value| try appendPrint(out, allocator, "(const {d} :ty ", .{value}),
                .String => |value| try appendPrint(out, allocator, "(const-string \"{f}\" :ty ", .{std.zig.fmtString(value)}),
            }
            try formatTy(out, allocator, constant.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, constant.layout);
            try append(out, allocator, ")");
        },
        .Let => |let_expr| {
            try append(out, allocator, "(let ");
            try append(out, allocator, let_expr.name);
            try append(out, allocator, " ");
            try formatExpr(out, allocator, let_expr.value.*);
            try append(out, allocator, " ");
            try formatExpr(out, allocator, let_expr.body.*);
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, let_expr.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, let_expr.layout);
            try append(out, allocator, ")");
        },
        .Var => |var_ref| {
            try append(out, allocator, "(var ");
            try append(out, allocator, var_ref.name);
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, var_ref.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, var_ref.layout);
            try append(out, allocator, ")");
        },
        .Ctor => |ctor_expr| {
            try append(out, allocator, "(ctor ");
            try append(out, allocator, ctor_expr.name);
            for (ctor_expr.args) |arg| {
                try append(out, allocator, " ");
                try formatExpr(out, allocator, arg.*);
            }
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, ctor_expr.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, ctor_expr.layout);
            try append(out, allocator, ")");
        },
    }
}

fn formatTy(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ty: ir.Ty) !void {
    switch (ty) {
        .Int => try append(out, allocator, "int"),
        .Unit => try append(out, allocator, "unit"),
        .String => try append(out, allocator, "string"),
        .Adt => |adt| {
            try append(out, allocator, "(");
            try append(out, allocator, adt.name);
            for (adt.params) |param_ty| {
                try append(out, allocator, " ");
                try formatTy(out, allocator, param_ty);
            }
            try append(out, allocator, ")");
        },
        .Arrow => |arrow| {
            try append(out, allocator, "(arrow");
            for (arrow.params) |param_ty| {
                try append(out, allocator, " ");
                try formatTy(out, allocator, param_ty);
            }
            try append(out, allocator, " ");
            try formatTy(out, allocator, arrow.ret.*);
            try append(out, allocator, ")");
        },
    }
}

fn formatLayout(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: layout.Layout) !void {
    try append(out, allocator, "(");
    try append(out, allocator, regionName(value.region));
    try append(out, allocator, " ");
    try append(out, allocator, reprName(value.repr));
    try append(out, allocator, ")");
}

fn regionName(region: layout.Region) []const u8 {
    return switch (region) {
        .Arena => "arena",
        .Static => "static",
        .Stack => "stack",
    };
}

fn reprName(repr: layout.Repr) []const u8 {
    return switch (repr) {
        .Flat => "flat",
        .Boxed => "boxed",
        .TaggedImmediate => "tagged-immediate",
    };
}

fn append(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try out.appendSlice(allocator, bytes);
}

fn appendPrint(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const bytes = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(bytes);
    try append(out, allocator, bytes);
}
