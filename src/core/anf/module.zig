//! RESPONSIBILITIES:
//! - Orchestrate ttree-module lowering into ANF Core IR (`lowerModule`).
//! - Re-export the lowering surface from `type_lowering.zig`,
//!   `expr_lowering.zig`, and `call_lowering.zig` for existing consumers.

const std = @import("std");
const ttree = @import("../../frontend_bridge/ttree.zig");
const ir = @import("../ir.zig");
const layout = @import("../layout.zig");
const context = @import("context.zig");
const type_ops = @import("type_ops.zig");
const type_lowering = @import("type_lowering.zig");
const expr_lowering = @import("expr_lowering.zig");
const call_lowering = @import("call_lowering.zig");

pub const LowerError = context.LowerError;
const BindingInfo = context.BindingInfo;
const ConstructorInfo = context.ConstructorInfo;
const LowerContext = context.LowerContext;

const layoutForTy = type_ops.layoutForTy;

pub const lowerTypeDecls = type_lowering.lowerTypeDecls;
pub const lowerTupleTypeDecls = type_lowering.lowerTupleTypeDecls;
pub const lowerRecordTypeDecls = type_lowering.lowerRecordTypeDecls;
pub const lowerExternalDecls = type_lowering.lowerExternalDecls;
pub const lowerTypeExprs = type_lowering.lowerTypeExprs;
pub const lowerTypeExpr = type_lowering.lowerTypeExpr;
pub const lowerTypeExprOpt = type_lowering.lowerTypeExprOpt;
pub const dupeStringSlice = type_lowering.dupeStringSlice;
pub const indexConstructors = type_lowering.indexConstructors;

pub const lowerDecl = expr_lowering.lowerDecl;
pub const lowerLetRecGroupBinding = expr_lowering.lowerLetRecGroupBinding;
pub const lowerLambda = expr_lowering.lowerLambda;
pub const lowerExprPtr = expr_lowering.lowerExprPtr;
pub const lowerExprPtrExpected = expr_lowering.lowerExprPtrExpected;
pub const lowerExpr = expr_lowering.lowerExpr;
pub const lowerExprExpected = expr_lowering.lowerExprExpected;
pub const lowerArrayLit = expr_lowering.lowerArrayLit;
pub const lowerArrayGet = expr_lowering.lowerArrayGet;
pub const lowerArrayLength = expr_lowering.lowerArrayLength;
pub const lowerArraySet = expr_lowering.lowerArraySet;
pub const lowerRefMake = expr_lowering.lowerRefMake;
pub const lowerRefGet = expr_lowering.lowerRefGet;
pub const lowerRefSet = expr_lowering.lowerRefSet;
pub const lowerArrayMake = expr_lowering.lowerArrayMake;
pub const lowerAssert = expr_lowering.lowerAssert;
pub const lowerTuple = expr_lowering.lowerTuple;
pub const lowerTupleProj = expr_lowering.lowerTupleProj;
pub const lowerRecord = expr_lowering.lowerRecord;
pub const lowerRecordField = expr_lowering.lowerRecordField;
pub const lowerRecordUpdate = expr_lowering.lowerRecordUpdate;
pub const lowerFieldSet = expr_lowering.lowerFieldSet;
pub const lowerLetRecGroupExpr = expr_lowering.lowerLetRecGroupExpr;
pub const lowerLetExpr = expr_lowering.lowerLetExpr;

pub const lowerApp = call_lowering.lowerApp;
pub const lowerLogicalAnd = call_lowering.lowerLogicalAnd;
pub const lowerLogicalNot = call_lowering.lowerLogicalNot;
pub const lowerLogicalOr = call_lowering.lowerLogicalOr;
pub const boolCoreExpr = call_lowering.boolCoreExpr;
pub const lowerBuiltinCallApp = call_lowering.lowerBuiltinCallApp;
pub const builtinCallOp = call_lowering.builtinCallOp;
pub const builtinCallArgTys = call_lowering.builtinCallArgTys;
pub const builtinCallReturnTy = call_lowering.builtinCallReturnTy;
pub const lowerStdlibCallApp = call_lowering.lowerStdlibCallApp;
pub const lowerArrayOfListApp = call_lowering.lowerArrayOfListApp;
pub const lowerListLiteralExpr = call_lowering.lowerListLiteralExpr;
pub const stdlibCallSignature = call_lowering.stdlibCallSignature;
pub const makeStdlibCallSignature = call_lowering.makeStdlibCallSignature;
pub const lowerListMapLiteralApp = call_lowering.lowerListMapLiteralApp;
pub const lowerListFilterLiteralApp = call_lowering.lowerListFilterLiteralApp;
pub const lowerListFoldLeftLiteralApp = call_lowering.lowerListFoldLeftLiteralApp;
pub const lowerOptionMapApp = call_lowering.lowerOptionMapApp;
pub const lowerOptionBindApp = call_lowering.lowerOptionBindApp;
pub const lowerOptionFoldApp = call_lowering.lowerOptionFoldApp;
pub const lowerResultMapApp = call_lowering.lowerResultMapApp;
pub const lowerResultBindApp = call_lowering.lowerResultBindApp;
pub const lowerResultMapErrorApp = call_lowering.lowerResultMapErrorApp;
pub const collectListLiteralItems = call_lowering.collectListLiteralItems;
pub const isVarNamed = call_lowering.isVarNamed;
pub const appReturnTy = call_lowering.appReturnTy;
pub const lowerIf = call_lowering.lowerIf;
pub const lowerPrim = call_lowering.lowerPrim;
pub const lowerPrimOp = call_lowering.lowerPrimOp;
pub const primOpArity = call_lowering.primOpArity;
pub const primOpReturnTy = call_lowering.primOpReturnTy;
pub const lowerVar = call_lowering.lowerVar;
pub const lowerVarExpr = call_lowering.lowerVarExpr;
pub const lowerConstant = call_lowering.lowerConstant;
pub const lowerCtor = call_lowering.lowerCtor;

pub fn lowerModule(arena: *std.heap.ArenaAllocator, module: ttree.Module) LowerError!ir.Module {
    var decls = std.ArrayList(ir.Decl).empty;
    errdefer decls.deinit(arena.allocator());

    var ctx: LowerContext = .{
        .scope = std.StringHashMap(BindingInfo).init(arena.allocator()),
        .constructors = std.StringHashMap(ConstructorInfo).init(arena.allocator()),
    };
    defer ctx.constructors.deinit();
    defer ctx.scope.deinit();

    const type_decls = try lowerTypeDecls(arena, module.type_decls);
    const tuple_type_decls = try lowerTupleTypeDecls(arena, module.tuple_type_decls);
    const record_type_decls = try lowerRecordTypeDecls(arena, module.record_type_decls);
    const externals = try lowerExternalDecls(arena, module.externals, record_type_decls);
    ctx.tuple_type_decls = tuple_type_decls;
    ctx.record_type_decls = record_type_decls;
    try indexConstructors(&ctx, type_decls);

    for (externals) |external| {
        try ctx.scope.put(external.name, .{
            .ty = external.ty,
            .layout = layoutForTy(external.ty),
        });
    }

    for (module.decls) |decl| {
        switch (decl) {
            .Let => |let_decl| {
                if (let_decl.is_rec) {
                    try ctx.scope.put(let_decl.name, .{
                        .ty = .Unit,
                        .layout = layout.topLevelLambda(),
                    });
                }
            },
            .LetRecGroup => |group| {
                for (group.bindings) |binding| {
                    try ctx.scope.put(binding.name, .{
                        .ty = .Unit,
                        .layout = layout.topLevelLambda(),
                    });
                }
            },
        }
    }

    for (module.decls) |decl| {
        const lowered = try lowerDecl(arena, &ctx, decl);
        try decls.append(arena.allocator(), lowered);
        switch (lowered) {
            .Let => |let_decl| try ctx.scope.put(let_decl.name, .{
                .ty = let_decl.ty,
                .layout = let_decl.layout,
            }),
            .LetGroup => |group| for (group.bindings) |binding| {
                try ctx.scope.put(binding.name, .{
                    .ty = binding.ty,
                    .layout = binding.layout,
                });
            },
        }
    }

    return .{
        .decls = try decls.toOwnedSlice(arena.allocator()),
        .type_decls = type_decls,
        .tuple_type_decls = tuple_type_decls,
        .record_type_decls = record_type_decls,
        .externals = externals,
    };
}
