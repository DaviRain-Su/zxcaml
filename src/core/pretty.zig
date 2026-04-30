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
    for (module.type_decls) |type_decl| {
        try append(&out, allocator, " ");
        try formatTypeDecl(&out, allocator, type_decl);
    }
    for (module.tuple_type_decls) |type_decl| {
        try append(&out, allocator, " ");
        try formatTupleTypeDecl(&out, allocator, type_decl);
    }
    for (module.record_type_decls) |type_decl| {
        try append(&out, allocator, " ");
        try formatRecordTypeDecl(&out, allocator, type_decl);
    }
    for (module.decls) |decl| {
        try append(&out, allocator, " ");
        try formatDecl(&out, allocator, decl);
    }
    try append(&out, allocator, ")");

    return out.toOwnedSlice(allocator);
}

fn formatTupleTypeDecl(out: *std.ArrayList(u8), allocator: std.mem.Allocator, type_decl: @import("types.zig").TupleType) !void {
    try append(out, allocator, "(tuple-type ");
    try append(out, allocator, type_decl.name);
    try formatTypeParams(out, allocator, type_decl.params);
    if (type_decl.is_recursive) try append(out, allocator, " :recursive true");
    try append(out, allocator, " (items");
    for (type_decl.items) |item| {
        try append(out, allocator, " ");
        try formatTypeExpr(out, allocator, item);
    }
    try append(out, allocator, "))");
}

fn formatRecordTypeDecl(out: *std.ArrayList(u8), allocator: std.mem.Allocator, type_decl: @import("types.zig").RecordType) !void {
    try append(out, allocator, "(record-type ");
    try append(out, allocator, type_decl.name);
    try formatTypeParams(out, allocator, type_decl.params);
    if (type_decl.is_recursive) try append(out, allocator, " :recursive true");
    try append(out, allocator, " (fields");
    for (type_decl.fields) |field| {
        try append(out, allocator, " (");
        try append(out, allocator, field.name);
        try append(out, allocator, " ");
        try formatTypeExpr(out, allocator, field.ty);
        if (field.is_mutable) try append(out, allocator, " :mutable true");
        try append(out, allocator, ")");
    }
    try append(out, allocator, "))");
}

fn formatTypeParams(out: *std.ArrayList(u8), allocator: std.mem.Allocator, params: []const []const u8) !void {
    if (params.len == 0) return;
    try append(out, allocator, " (params");
    for (params) |param| {
        try append(out, allocator, " ");
        try append(out, allocator, param);
    }
    try append(out, allocator, ")");
}

fn formatDecl(out: *std.ArrayList(u8), allocator: std.mem.Allocator, decl: ir.Decl) !void {
    switch (decl) {
        .Let => |let_decl| {
            try append(out, allocator, if (let_decl.is_rec) "(let-rec " else "(let ");
            try append(out, allocator, let_decl.name);
            try append(out, allocator, " ");
            try formatExpr(out, allocator, let_decl.value.*);
            try append(out, allocator, ")");
        },
        .LetGroup => |group| {
            try append(out, allocator, "(LetGroup");
            for (group.bindings) |binding| {
                try append(out, allocator, " (binding ");
                try append(out, allocator, binding.name);
                try append(out, allocator, " ");
                try formatExpr(out, allocator, binding.value.*);
                try append(out, allocator, ")");
            }
            try append(out, allocator, ")");
        },
    }
}

fn formatTypeDecl(out: *std.ArrayList(u8), allocator: std.mem.Allocator, type_decl: @import("types.zig").VariantType) !void {
    try append(out, allocator, "(type ");
    try append(out, allocator, type_decl.name);
    if (type_decl.params.len > 0) {
        try append(out, allocator, " (params");
        for (type_decl.params) |param| {
            try append(out, allocator, " ");
            try append(out, allocator, param);
        }
        try append(out, allocator, ")");
    }
    if (type_decl.is_recursive) try append(out, allocator, " :recursive true");
    try append(out, allocator, " (variants");
    for (type_decl.variants) |variant| {
        try appendPrint(out, allocator, " ({s} :tag {d}", .{ variant.name, variant.tag });
        if (variant.payload_types.len > 0) {
            try append(out, allocator, " :payload");
            for (variant.payload_types) |payload_ty| {
                try append(out, allocator, " ");
                try formatTypeExpr(out, allocator, payload_ty);
            }
        }
        try append(out, allocator, ")");
    }
    try append(out, allocator, "))");
}

fn formatTypeExpr(out: *std.ArrayList(u8), allocator: std.mem.Allocator, expr: @import("types.zig").TypeExpr) anyerror!void {
    switch (expr) {
        .TypeVar => |name| try append(out, allocator, name),
        .TypeRef => |ref| try formatTypeRef(out, allocator, "type-ref", ref),
        .RecursiveRef => |ref| try formatTypeRef(out, allocator, "recursive-ref", ref),
        .Tuple => |items| {
            try append(out, allocator, "(tuple");
            for (items) |item| {
                try append(out, allocator, " ");
                try formatTypeExpr(out, allocator, item);
            }
            try append(out, allocator, ")");
        },
    }
}

fn formatTypeRef(out: *std.ArrayList(u8), allocator: std.mem.Allocator, tag: []const u8, ref: @import("types.zig").TypeRef) anyerror!void {
    try append(out, allocator, "(");
    try append(out, allocator, tag);
    try append(out, allocator, " ");
    try append(out, allocator, ref.name);
    for (ref.args) |arg| {
        try append(out, allocator, " ");
        try formatTypeExpr(out, allocator, arg);
    }
    try append(out, allocator, ")");
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
        .App => |app| {
            try append(out, allocator, "(app ");
            try formatExpr(out, allocator, app.callee.*);
            for (app.args) |arg| {
                try append(out, allocator, " ");
                try formatExpr(out, allocator, arg.*);
            }
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, app.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, app.layout);
            if (app.is_tail_call) try append(out, allocator, " :tail-call true");
            try append(out, allocator, ")");
        },
        .Let => |let_expr| {
            try append(out, allocator, if (let_expr.is_rec) "(let-rec " else "(let ");
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
        .LetGroup => |group| {
            try append(out, allocator, "(LetGroup");
            for (group.bindings) |binding| {
                try append(out, allocator, " (binding ");
                try append(out, allocator, binding.name);
                try append(out, allocator, " ");
                try formatExpr(out, allocator, binding.value.*);
                try append(out, allocator, ")");
            }
            try append(out, allocator, " ");
            try formatExpr(out, allocator, group.body.*);
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, group.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, group.layout);
            try append(out, allocator, ")");
        },
        .If => |if_expr| {
            try append(out, allocator, "(if ");
            try formatExpr(out, allocator, if_expr.cond.*);
            try append(out, allocator, " ");
            try formatExpr(out, allocator, if_expr.then_branch.*);
            try append(out, allocator, " ");
            try formatExpr(out, allocator, if_expr.else_branch.*);
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, if_expr.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, if_expr.layout);
            try append(out, allocator, ")");
        },
        .Prim => |prim| {
            try append(out, allocator, "(prim ");
            try append(out, allocator, primOpName(prim.op));
            for (prim.args) |arg| {
                try append(out, allocator, " ");
                try formatExpr(out, allocator, arg.*);
            }
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, prim.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, prim.layout);
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
        .Match => |match_expr| {
            try append(out, allocator, "(match ");
            try formatExpr(out, allocator, match_expr.scrutinee.*);
            for (match_expr.arms) |arm| {
                try append(out, allocator, " ((pattern ");
                try formatPattern(out, allocator, arm.pattern);
                try append(out, allocator, ") ");
                if (arm.guard) |guard_expr| {
                    try append(out, allocator, "(guard ");
                    try formatExpr(out, allocator, guard_expr.*);
                    try append(out, allocator, ") ");
                }
                try formatExpr(out, allocator, arm.body.*);
                try append(out, allocator, ")");
            }
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, match_expr.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, match_expr.layout);
            try append(out, allocator, ")");
        },
        .Tuple => |tuple_expr| {
            try append(out, allocator, "(tuple");
            for (tuple_expr.items) |item| {
                try append(out, allocator, " ");
                try formatExpr(out, allocator, item.*);
            }
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, tuple_expr.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, tuple_expr.layout);
            try append(out, allocator, ")");
        },
        .TupleProj => |tuple_proj| {
            try appendPrint(out, allocator, "(tuple-proj {d} ", .{tuple_proj.index});
            try formatExpr(out, allocator, tuple_proj.tuple_expr.*);
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, tuple_proj.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, tuple_proj.layout);
            try append(out, allocator, ")");
        },
        .Record => |record_expr| {
            try append(out, allocator, "(record");
            for (record_expr.fields) |field| {
                try append(out, allocator, " (");
                try append(out, allocator, field.name);
                try append(out, allocator, " ");
                try formatExpr(out, allocator, field.value.*);
                try append(out, allocator, ")");
            }
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, record_expr.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, record_expr.layout);
            try append(out, allocator, ")");
        },
        .RecordField => |record_field| {
            try append(out, allocator, "(record-field ");
            try formatExpr(out, allocator, record_field.record_expr.*);
            try append(out, allocator, " ");
            try append(out, allocator, record_field.field_name);
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, record_field.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, record_field.layout);
            try append(out, allocator, ")");
        },
        .RecordUpdate => |record_update| {
            try append(out, allocator, "(record-update ");
            try formatExpr(out, allocator, record_update.base_expr.*);
            for (record_update.fields) |field| {
                try append(out, allocator, " (");
                try append(out, allocator, field.name);
                try append(out, allocator, " ");
                try formatExpr(out, allocator, field.value.*);
                try append(out, allocator, ")");
            }
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, record_update.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, record_update.layout);
            try append(out, allocator, ")");
        },
        .AccountFieldSet => |field_set| {
            try append(out, allocator, "(account-field-set ");
            try formatExpr(out, allocator, field_set.account_expr.*);
            try append(out, allocator, " ");
            try append(out, allocator, field_set.field_name);
            try append(out, allocator, " ");
            try formatExpr(out, allocator, field_set.value.*);
            try append(out, allocator, " :ty ");
            try formatTy(out, allocator, field_set.ty);
            try append(out, allocator, " :layout ");
            try formatLayout(out, allocator, field_set.layout);
            try append(out, allocator, ")");
        },
    }
}

fn formatPattern(out: *std.ArrayList(u8), allocator: std.mem.Allocator, pattern: ir.Pattern) anyerror!void {
    switch (pattern) {
        .Wildcard => try append(out, allocator, "_"),
        .Var => |var_pattern| {
            try append(out, allocator, "(var ");
            try append(out, allocator, var_pattern.name);
            try append(out, allocator, ")");
        },
        .Constant => |constant| try formatPatternConstant(out, allocator, constant),
        .Alias => |alias| {
            try append(out, allocator, "(alias ");
            try formatPattern(out, allocator, alias.pattern.*);
            try append(out, allocator, " ");
            try append(out, allocator, alias.name);
            try append(out, allocator, ")");
        },
        .Ctor => |ctor_pattern| {
            try append(out, allocator, "(ctor ");
            try append(out, allocator, ctor_pattern.name);
            for (ctor_pattern.args) |arg| {
                try append(out, allocator, " ");
                try formatPattern(out, allocator, arg);
            }
            try append(out, allocator, ")");
        },
        .Tuple => |items| {
            try append(out, allocator, "(tuple-pattern");
            for (items) |item| {
                try append(out, allocator, " ");
                try formatPattern(out, allocator, item);
            }
            try append(out, allocator, ")");
        },
        .Record => |fields| {
            try append(out, allocator, "(record-pattern");
            for (fields) |field| {
                try append(out, allocator, " (");
                try append(out, allocator, field.name);
                try append(out, allocator, " ");
                try formatPattern(out, allocator, field.pattern);
                try append(out, allocator, ")");
            }
            try append(out, allocator, ")");
        },
    }
}

fn formatPatternConstant(out: *std.ArrayList(u8), allocator: std.mem.Allocator, constant: ir.PatternConstant) !void {
    switch (constant) {
        .Int => |value| try appendPrint(out, allocator, "(const-int {d})", .{value}),
        .Char => |value| try appendPrint(out, allocator, "(const-char {d})", .{value}),
        .String => |value| try appendPrint(out, allocator, "(const-string \"{f}\")", .{std.zig.fmtString(value)}),
    }
}

fn formatTy(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ty: ir.Ty) !void {
    switch (ty) {
        .Int => try append(out, allocator, "int"),
        .Bool => try append(out, allocator, "bool"),
        .Unit => try append(out, allocator, "unit"),
        .String => try append(out, allocator, "string"),
        .Var => |name| try append(out, allocator, name),
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
        .Tuple => |items| {
            try append(out, allocator, "(tuple");
            for (items) |item| {
                try append(out, allocator, " ");
                try formatTy(out, allocator, item);
            }
            try append(out, allocator, ")");
        },
        .Record => |record| {
            try append(out, allocator, "(record ");
            try append(out, allocator, record.name);
            for (record.params) |param_ty| {
                try append(out, allocator, " ");
                try formatTy(out, allocator, param_ty);
            }
            try append(out, allocator, ")");
        },
    }
}

fn primOpName(op: ir.PrimOp) []const u8 {
    return switch (op) {
        .Add => "+",
        .Sub => "-",
        .Mul => "*",
        .Div => "/",
        .Mod => "mod",
        .Eq => "=",
        .Ne => "<>",
        .Lt => "<",
        .Le => "<=",
        .Gt => ">",
        .Ge => ">=",
        .StringLength => "String.length",
        .StringGet => "String.get",
        .StringSub => "String.sub",
        .StringConcat => "^",
        .CharCode => "Char.code",
        .CharChr => "Char.chr",
    };
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
