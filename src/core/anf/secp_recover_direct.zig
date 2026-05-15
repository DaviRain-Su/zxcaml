//! Core/ANF post-pass for the secp256k1_recover direct-write optimization.
//!
//! The pass recognizes:
//!
//!   let r = Crypto.secp256k1_recover hash recid sig in C
//!
//! or the equivalent external symbol binding to
//! `sol_secp256k1_recover_alloc`, provided `r` is used exactly once in `C`
//! and that single use writes the recovered pubkey directly to account data.
//! It then drops the intermediate arena-backed recovered value and rewrites
//! the consumer to the backend-only intrinsic
//! `Crypto.secp256k1_recover_into_account`.

const std = @import("std");
const ir = @import("../ir.zig");
const layout = @import("../layout.zig");

pub const direct_intrinsic_name = "Crypto.secp256k1_recover_into_account";

const PassError = std.mem.Allocator.Error;

const Rewriter = struct {
    arena: *std.heap.ArenaAllocator,
    externals: []const ir.ExternalDecl,

    fn allocator(self: *Rewriter) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn exprPtr(self: *Rewriter, expr: ir.Expr) PassError!*const ir.Expr {
        const ptr = try self.allocator().create(ir.Expr);
        ptr.* = expr;
        return ptr;
    }

    fn rewriteDecl(self: *Rewriter, decl: ir.Decl) PassError!ir.Decl {
        return switch (decl) {
            .Let => |let_decl| .{ .Let = .{
                .name = let_decl.name,
                .value = try self.rewriteExpr(let_decl.value.*),
                .ty = let_decl.ty,
                .layout = let_decl.layout,
                .is_rec = let_decl.is_rec,
            } },
            .LetGroup => |group| .{ .LetGroup = .{
                .bindings = try self.rewriteLetGroupBindings(group.bindings),
            } },
        };
    }

    fn rewriteLetGroupBindings(self: *Rewriter, bindings: []const ir.LetGroupBinding) PassError![]const ir.LetGroupBinding {
        const out = try self.allocator().alloc(ir.LetGroupBinding, bindings.len);
        for (bindings, 0..) |binding, index| {
            out[index] = .{
                .name = binding.name,
                .value = try self.rewriteExpr(binding.value.*),
                .ty = binding.ty,
                .layout = binding.layout,
            };
        }
        return out;
    }

    fn rewriteExpr(self: *Rewriter, expr: ir.Expr) PassError!*const ir.Expr {
        const rewritten = try self.rewriteExprChildren(expr);
        if (try self.rewriteRecoverLet(rewritten)) |replacement| return replacement;
        return rewritten;
    }

    fn rewriteExprChildren(self: *Rewriter, expr: ir.Expr) PassError!*const ir.Expr {
        return switch (expr) {
            .Lambda => |lambda| self.exprPtr(.{ .Lambda = .{
                .params = lambda.params,
                .body = try self.rewriteExpr(lambda.body.*),
                .ty = lambda.ty,
                .layout = lambda.layout,
                .loc = lambda.loc,
            } }),
            .Constant => self.exprPtr(expr),
            .App => |app| self.exprPtr(.{ .App = .{
                .callee = try self.rewriteExpr(app.callee.*),
                .args = try self.rewriteExprSlice(app.args),
                .ty = app.ty,
                .layout = app.layout,
                .is_tail_call = app.is_tail_call,
                .loc = app.loc,
            } }),
            .Let => |let_expr| self.exprPtr(.{ .Let = .{
                .name = let_expr.name,
                .value = try self.rewriteExpr(let_expr.value.*),
                .body = try self.rewriteExpr(let_expr.body.*),
                .ty = let_expr.ty,
                .layout = let_expr.layout,
                .is_rec = let_expr.is_rec,
                .loc = let_expr.loc,
            } }),
            .LetGroup => |group| self.exprPtr(.{ .LetGroup = .{
                .bindings = try self.rewriteLetGroupBindings(group.bindings),
                .body = try self.rewriteExpr(group.body.*),
                .ty = group.ty,
                .layout = group.layout,
                .loc = group.loc,
            } }),
            .Assert => |assert_expr| self.exprPtr(.{ .Assert = .{
                .condition = try self.rewriteExpr(assert_expr.condition.*),
                .ty = assert_expr.ty,
                .layout = assert_expr.layout,
                .loc = assert_expr.loc,
            } }),
            .If => |if_expr| self.exprPtr(.{ .If = .{
                .cond = try self.rewriteExpr(if_expr.cond.*),
                .then_branch = try self.rewriteExpr(if_expr.then_branch.*),
                .else_branch = try self.rewriteExpr(if_expr.else_branch.*),
                .ty = if_expr.ty,
                .layout = if_expr.layout,
                .loc = if_expr.loc,
            } }),
            .Prim => |prim| self.exprPtr(.{ .Prim = .{
                .op = prim.op,
                .args = try self.rewriteExprSlice(prim.args),
                .ty = prim.ty,
                .layout = prim.layout,
                .loc = prim.loc,
            } }),
            .Var => self.exprPtr(expr),
            .Ctor => |ctor| self.exprPtr(.{ .Ctor = .{
                .name = ctor.name,
                .args = try self.rewriteExprSlice(ctor.args),
                .ty = ctor.ty,
                .layout = ctor.layout,
                .tag = ctor.tag,
                .type_name = ctor.type_name,
                .loc = ctor.loc,
            } }),
            .Match => |match_expr| self.exprPtr(.{ .Match = .{
                .scrutinee = try self.rewriteExpr(match_expr.scrutinee.*),
                .arms = try self.rewriteArms(match_expr.arms),
                .ty = match_expr.ty,
                .layout = match_expr.layout,
                .loc = match_expr.loc,
            } }),
            .Tuple => |tuple| self.exprPtr(.{ .Tuple = .{
                .items = try self.rewriteExprSlice(tuple.items),
                .ty = tuple.ty,
                .layout = tuple.layout,
                .loc = tuple.loc,
            } }),
            .TupleProj => |tuple_proj| self.exprPtr(.{ .TupleProj = .{
                .tuple_expr = try self.rewriteExpr(tuple_proj.tuple_expr.*),
                .index = tuple_proj.index,
                .ty = tuple_proj.ty,
                .layout = tuple_proj.layout,
                .loc = tuple_proj.loc,
            } }),
            .Record => |record| self.exprPtr(.{ .Record = .{
                .fields = try self.rewriteRecordFields(record.fields),
                .ty = record.ty,
                .layout = record.layout,
                .loc = record.loc,
            } }),
            .RecordField => |record_field| self.exprPtr(.{ .RecordField = .{
                .record_expr = try self.rewriteExpr(record_field.record_expr.*),
                .field_name = record_field.field_name,
                .ty = record_field.ty,
                .layout = record_field.layout,
                .loc = record_field.loc,
            } }),
            .RecordUpdate => |record_update| self.exprPtr(.{ .RecordUpdate = .{
                .base_expr = try self.rewriteExpr(record_update.base_expr.*),
                .fields = try self.rewriteRecordFields(record_update.fields),
                .ty = record_update.ty,
                .layout = record_update.layout,
                .loc = record_update.loc,
            } }),
            .AccountFieldSet => |field_set| self.exprPtr(.{ .AccountFieldSet = .{
                .account_expr = try self.rewriteExpr(field_set.account_expr.*),
                .field_name = field_set.field_name,
                .value = try self.rewriteExpr(field_set.value.*),
                .ty = field_set.ty,
                .layout = field_set.layout,
                .loc = field_set.loc,
            } }),
            .ArrayLit => |array_lit| self.exprPtr(.{ .ArrayLit = .{
                .elem_ty = array_lit.elem_ty,
                .elems = try self.rewriteExprSlice(array_lit.elems),
                .ty = array_lit.ty,
                .layout = array_lit.layout,
                .loc = array_lit.loc,
            } }),
            .ArrayGet => |array_get| self.exprPtr(.{ .ArrayGet = .{
                .arr = try self.rewriteExpr(array_get.arr.*),
                .idx = try self.rewriteExpr(array_get.idx.*),
                .ty = array_get.ty,
                .layout = array_get.layout,
                .loc = array_get.loc,
            } }),
            .ArrayLength => |array_length| self.exprPtr(.{ .ArrayLength = .{
                .arr = try self.rewriteExpr(array_length.arr.*),
                .ty = array_length.ty,
                .layout = array_length.layout,
                .loc = array_length.loc,
            } }),
            .ArraySet => |array_set| self.exprPtr(.{ .ArraySet = .{
                .arr = try self.rewriteExpr(array_set.arr.*),
                .idx = try self.rewriteExpr(array_set.idx.*),
                .value = try self.rewriteExpr(array_set.value.*),
                .ty = array_set.ty,
                .layout = array_set.layout,
                .loc = array_set.loc,
            } }),
            .ArrayMake => |array_make| self.exprPtr(.{ .ArrayMake = .{
                .elem_ty = array_make.elem_ty,
                .size = array_make.size,
                .init = try self.rewriteExpr(array_make.init.*),
                .ty = array_make.ty,
                .layout = array_make.layout,
                .loc = array_make.loc,
            } }),
            .RefMake => |ref_make| self.exprPtr(.{ .RefMake = .{
                .elem_ty = ref_make.elem_ty,
                .init = try self.rewriteExpr(ref_make.init.*),
                .ty = ref_make.ty,
                .layout = ref_make.layout,
                .loc = ref_make.loc,
            } }),
            .RefGet => |ref_get| self.exprPtr(.{ .RefGet = .{
                .target = try self.rewriteExpr(ref_get.target.*),
                .ty = ref_get.ty,
                .layout = ref_get.layout,
                .loc = ref_get.loc,
            } }),
            .RefSet => |ref_set| self.exprPtr(.{ .RefSet = .{
                .target = try self.rewriteExpr(ref_set.target.*),
                .value = try self.rewriteExpr(ref_set.value.*),
                .ty = ref_set.ty,
                .layout = ref_set.layout,
                .loc = ref_set.loc,
            } }),
        };
    }

    fn rewriteExprSlice(self: *Rewriter, exprs: []const *const ir.Expr) PassError![]const *const ir.Expr {
        const out = try self.allocator().alloc(*const ir.Expr, exprs.len);
        for (exprs, 0..) |expr, index| {
            out[index] = try self.rewriteExpr(expr.*);
        }
        return out;
    }

    fn rewriteRecordFields(self: *Rewriter, fields: []const ir.RecordExprField) PassError![]const ir.RecordExprField {
        const out = try self.allocator().alloc(ir.RecordExprField, fields.len);
        for (fields, 0..) |field, index| {
            out[index] = .{
                .name = field.name,
                .value = try self.rewriteExpr(field.value.*),
            };
        }
        return out;
    }

    fn rewriteArms(self: *Rewriter, arms: []const ir.Arm) PassError![]const ir.Arm {
        const out = try self.allocator().alloc(ir.Arm, arms.len);
        for (arms, 0..) |arm, index| {
            out[index] = .{
                .pattern = arm.pattern,
                .guard = if (arm.guard) |guard| try self.rewriteExpr(guard.*) else null,
                .body = try self.rewriteExpr(arm.body.*),
            };
        }
        return out;
    }

    fn rewriteRecoverLet(self: *Rewriter, expr: *const ir.Expr) PassError!?*const ir.Expr {
        const let_expr = switch (expr.*) {
            .Let => |value| value,
            else => return null,
        };
        if (let_expr.is_rec) return null;

        const recover_app = switch (let_expr.value.*) {
            .App => |app| app,
            else => return null,
        };
        if (recover_app.args.len != 3) return null;
        if (!self.isRecoverCallee(recover_app.callee.*)) return null;
        if (countUses(let_expr.body.*, let_expr.name) != 1) return null;

        return try self.replaceSingleConsumer(
            let_expr.body,
            let_expr.name,
            recover_app.args[0],
            recover_app.args[1],
            recover_app.args[2],
        );
    }

    fn isRecoverCallee(self: *const Rewriter, callee: ir.Expr) bool {
        const var_ref = switch (callee) {
            .Var => |value| value,
            else => return false,
        };
        if (std.mem.eql(u8, var_ref.name, "Crypto.secp256k1_recover")) return true;
        if (std.mem.eql(u8, var_ref.name, "sol_secp256k1_recover_alloc")) return true;
        for (self.externals) |external| {
            if (!std.mem.eql(u8, external.name, var_ref.name)) continue;
            if (std.mem.eql(u8, external.symbol, "sol_secp256k1_recover_alloc")) return true;
            if (std.mem.eql(u8, external.name, "Crypto.secp256k1_recover")) return true;
        }
        return false;
    }

    fn replaceSingleConsumer(
        self: *Rewriter,
        expr: *const ir.Expr,
        name: []const u8,
        hash: *const ir.Expr,
        recid: *const ir.Expr,
        sig: *const ir.Expr,
    ) PassError!?*const ir.Expr {
        if (try self.directConsumerRewrite(expr.*, name, hash, recid, sig)) |replacement| {
            return replacement;
        }

        return switch (expr.*) {
            .Lambda => |lambda| blk: {
                if (paramsBindName(lambda.params, name)) break :blk null;
                const body = try self.replaceSingleConsumer(lambda.body, name, hash, recid, sig) orelse break :blk null;
                break :blk try self.exprPtr(.{ .Lambda = .{
                    .params = lambda.params,
                    .body = body,
                    .ty = lambda.ty,
                    .layout = lambda.layout,
                    .loc = lambda.loc,
                } });
            },
            .Constant, .Var => null,
            .App => |app| blk: {
                if (try self.replaceInExprPtrSlice(app.args, name, hash, recid, sig)) |args| {
                    break :blk try self.exprPtr(.{ .App = .{
                        .callee = app.callee,
                        .args = args,
                        .ty = app.ty,
                        .layout = app.layout,
                        .is_tail_call = app.is_tail_call,
                        .loc = app.loc,
                    } });
                }
                if (try self.replaceSingleConsumer(app.callee, name, hash, recid, sig)) |callee| {
                    break :blk try self.exprPtr(.{ .App = .{
                        .callee = callee,
                        .args = app.args,
                        .ty = app.ty,
                        .layout = app.layout,
                        .is_tail_call = app.is_tail_call,
                        .loc = app.loc,
                    } });
                }
                break :blk null;
            },
            .Let => |let_expr| blk: {
                const value = if (!let_expr.is_rec or !std.mem.eql(u8, let_expr.name, name))
                    try self.replaceSingleConsumer(let_expr.value, name, hash, recid, sig)
                else
                    null;
                const body = if (!std.mem.eql(u8, let_expr.name, name))
                    try self.replaceSingleConsumer(let_expr.body, name, hash, recid, sig)
                else
                    null;
                if (value == null and body == null) break :blk null;
                break :blk try self.exprPtr(.{ .Let = .{
                    .name = let_expr.name,
                    .value = value orelse let_expr.value,
                    .body = body orelse let_expr.body,
                    .ty = let_expr.ty,
                    .layout = let_expr.layout,
                    .is_rec = let_expr.is_rec,
                    .loc = let_expr.loc,
                } });
            },
            .LetGroup => |group| blk: {
                if (groupBindsName(group.bindings, name)) break :blk null;
                if (try self.replaceInBindings(group.bindings, name, hash, recid, sig)) |bindings| {
                    break :blk try self.exprPtr(.{ .LetGroup = .{
                        .bindings = bindings,
                        .body = group.body,
                        .ty = group.ty,
                        .layout = group.layout,
                        .loc = group.loc,
                    } });
                }
                if (try self.replaceSingleConsumer(group.body, name, hash, recid, sig)) |body| {
                    break :blk try self.exprPtr(.{ .LetGroup = .{
                        .bindings = group.bindings,
                        .body = body,
                        .ty = group.ty,
                        .layout = group.layout,
                        .loc = group.loc,
                    } });
                }
                break :blk null;
            },
            .Assert => |assert_expr| blk: {
                const condition = try self.replaceSingleConsumer(assert_expr.condition, name, hash, recid, sig) orelse break :blk null;
                break :blk try self.exprPtr(.{ .Assert = .{
                    .condition = condition,
                    .ty = assert_expr.ty,
                    .layout = assert_expr.layout,
                    .loc = assert_expr.loc,
                } });
            },
            .If => |if_expr| blk: {
                const cond = try self.replaceSingleConsumer(if_expr.cond, name, hash, recid, sig);
                const then_branch = try self.replaceSingleConsumer(if_expr.then_branch, name, hash, recid, sig);
                const else_branch = try self.replaceSingleConsumer(if_expr.else_branch, name, hash, recid, sig);
                if (cond == null and then_branch == null and else_branch == null) break :blk null;
                break :blk try self.exprPtr(.{ .If = .{
                    .cond = cond orelse if_expr.cond,
                    .then_branch = then_branch orelse if_expr.then_branch,
                    .else_branch = else_branch orelse if_expr.else_branch,
                    .ty = if_expr.ty,
                    .layout = if_expr.layout,
                    .loc = if_expr.loc,
                } });
            },
            .Prim => |prim| blk: {
                const args = try self.replaceInExprPtrSlice(prim.args, name, hash, recid, sig) orelse break :blk null;
                break :blk try self.exprPtr(.{ .Prim = .{
                    .op = prim.op,
                    .args = args,
                    .ty = prim.ty,
                    .layout = prim.layout,
                    .loc = prim.loc,
                } });
            },
            .Ctor => |ctor| blk: {
                const args = try self.replaceInExprPtrSlice(ctor.args, name, hash, recid, sig) orelse break :blk null;
                break :blk try self.exprPtr(.{ .Ctor = .{
                    .name = ctor.name,
                    .args = args,
                    .ty = ctor.ty,
                    .layout = ctor.layout,
                    .tag = ctor.tag,
                    .type_name = ctor.type_name,
                    .loc = ctor.loc,
                } });
            },
            .Match => |match_expr| blk: {
                if (try self.replaceSingleConsumer(match_expr.scrutinee, name, hash, recid, sig)) |scrutinee| {
                    break :blk try self.exprPtr(.{ .Match = .{
                        .scrutinee = scrutinee,
                        .arms = match_expr.arms,
                        .ty = match_expr.ty,
                        .layout = match_expr.layout,
                        .loc = match_expr.loc,
                    } });
                }
                if (try self.replaceInArms(match_expr.arms, name, hash, recid, sig)) |arms| {
                    break :blk try self.exprPtr(.{ .Match = .{
                        .scrutinee = match_expr.scrutinee,
                        .arms = arms,
                        .ty = match_expr.ty,
                        .layout = match_expr.layout,
                        .loc = match_expr.loc,
                    } });
                }
                break :blk null;
            },
            .Tuple => |tuple| blk: {
                const items = try self.replaceInExprPtrSlice(tuple.items, name, hash, recid, sig) orelse break :blk null;
                break :blk try self.exprPtr(.{ .Tuple = .{
                    .items = items,
                    .ty = tuple.ty,
                    .layout = tuple.layout,
                    .loc = tuple.loc,
                } });
            },
            .TupleProj => |tuple_proj| blk: {
                const tuple_expr = try self.replaceSingleConsumer(tuple_proj.tuple_expr, name, hash, recid, sig) orelse break :blk null;
                break :blk try self.exprPtr(.{ .TupleProj = .{
                    .tuple_expr = tuple_expr,
                    .index = tuple_proj.index,
                    .ty = tuple_proj.ty,
                    .layout = tuple_proj.layout,
                    .loc = tuple_proj.loc,
                } });
            },
            .Record => |record| blk: {
                const fields = try self.replaceInRecordFields(record.fields, name, hash, recid, sig) orelse break :blk null;
                break :blk try self.exprPtr(.{ .Record = .{
                    .fields = fields,
                    .ty = record.ty,
                    .layout = record.layout,
                    .loc = record.loc,
                } });
            },
            .RecordField => |record_field| blk: {
                const record_expr = try self.replaceSingleConsumer(record_field.record_expr, name, hash, recid, sig) orelse break :blk null;
                break :blk try self.exprPtr(.{ .RecordField = .{
                    .record_expr = record_expr,
                    .field_name = record_field.field_name,
                    .ty = record_field.ty,
                    .layout = record_field.layout,
                    .loc = record_field.loc,
                } });
            },
            .RecordUpdate => |record_update| blk: {
                if (try self.replaceSingleConsumer(record_update.base_expr, name, hash, recid, sig)) |base_expr| {
                    break :blk try self.exprPtr(.{ .RecordUpdate = .{
                        .base_expr = base_expr,
                        .fields = record_update.fields,
                        .ty = record_update.ty,
                        .layout = record_update.layout,
                        .loc = record_update.loc,
                    } });
                }
                const fields = try self.replaceInRecordFields(record_update.fields, name, hash, recid, sig) orelse break :blk null;
                break :blk try self.exprPtr(.{ .RecordUpdate = .{
                    .base_expr = record_update.base_expr,
                    .fields = fields,
                    .ty = record_update.ty,
                    .layout = record_update.layout,
                    .loc = record_update.loc,
                } });
            },
            .AccountFieldSet => |field_set| blk: {
                if (try self.replaceSingleConsumer(field_set.account_expr, name, hash, recid, sig)) |account_expr| {
                    break :blk try self.exprPtr(.{ .AccountFieldSet = .{
                        .account_expr = account_expr,
                        .field_name = field_set.field_name,
                        .value = field_set.value,
                        .ty = field_set.ty,
                        .layout = field_set.layout,
                        .loc = field_set.loc,
                    } });
                }
                if (try self.replaceSingleConsumer(field_set.value, name, hash, recid, sig)) |value| {
                    break :blk try self.exprPtr(.{ .AccountFieldSet = .{
                        .account_expr = field_set.account_expr,
                        .field_name = field_set.field_name,
                        .value = value,
                        .ty = field_set.ty,
                        .layout = field_set.layout,
                        .loc = field_set.loc,
                    } });
                }
                break :blk null;
            },
            .ArrayLit, .ArrayGet, .ArrayLength, .ArraySet, .ArrayMake => null,
            .RefMake, .RefGet, .RefSet => null,
        };
    }

    fn directConsumerRewrite(
        self: *Rewriter,
        expr: ir.Expr,
        name: []const u8,
        hash: *const ir.Expr,
        recid: *const ir.Expr,
        sig: *const ir.Expr,
    ) PassError!?*const ir.Expr {
        switch (expr) {
            .App => |app| {
                if (app.args.len == 2 and isVarNamed(app.callee.*, "set_account_data") and isVarNamed(app.args[1].*, name)) {
                    return try self.directApp(app.args[0], hash, recid, sig, app.ty, app.layout, app.loc);
                }
            },
            .AccountFieldSet => |field_set| {
                if (std.mem.eql(u8, field_set.field_name, "data") and isVarNamed(field_set.value.*, name)) {
                    return try self.directApp(field_set.account_expr, hash, recid, sig, field_set.ty, field_set.layout, field_set.loc);
                }
            },
            else => {},
        }
        return null;
    }

    fn directApp(
        self: *Rewriter,
        account: *const ir.Expr,
        hash: *const ir.Expr,
        recid: *const ir.Expr,
        sig: *const ir.Expr,
        ret_ty: ir.Ty,
        ret_layout: layout.Layout,
        loc: ?ir.Loc,
    ) PassError!*const ir.Expr {
        const param_tys = try self.allocator().alloc(ir.Ty, 4);
        param_tys[0] = exprTy(account.*);
        param_tys[1] = exprTy(hash.*);
        param_tys[2] = exprTy(recid.*);
        param_tys[3] = exprTy(sig.*);
        const ret_ptr = try self.allocator().create(ir.Ty);
        ret_ptr.* = ret_ty;

        const callee = try self.exprPtr(.{ .Var = .{
            .name = direct_intrinsic_name,
            .ty = .{ .Arrow = .{ .params = param_tys, .ret = ret_ptr } },
            .layout = layout.closure(),
            .loc = loc,
        } });
        const args = try self.allocator().alloc(*const ir.Expr, 4);
        args[0] = account;
        args[1] = hash;
        args[2] = recid;
        args[3] = sig;
        return self.exprPtr(.{ .App = .{
            .callee = callee,
            .args = args,
            .ty = ret_ty,
            .layout = ret_layout,
            .loc = loc,
        } });
    }

    fn replaceInExprPtrSlice(
        self: *Rewriter,
        exprs: []const *const ir.Expr,
        name: []const u8,
        hash: *const ir.Expr,
        recid: *const ir.Expr,
        sig: *const ir.Expr,
    ) PassError!?[]const *const ir.Expr {
        for (exprs, 0..) |expr, index| {
            if (try self.replaceSingleConsumer(expr, name, hash, recid, sig)) |replacement| {
                const out = try self.allocator().alloc(*const ir.Expr, exprs.len);
                @memcpy(out, exprs);
                out[index] = replacement;
                return out;
            }
        }
        return null;
    }

    fn replaceInRecordFields(
        self: *Rewriter,
        fields: []const ir.RecordExprField,
        name: []const u8,
        hash: *const ir.Expr,
        recid: *const ir.Expr,
        sig: *const ir.Expr,
    ) PassError!?[]const ir.RecordExprField {
        for (fields, 0..) |field, index| {
            if (try self.replaceSingleConsumer(field.value, name, hash, recid, sig)) |replacement| {
                const out = try self.allocator().alloc(ir.RecordExprField, fields.len);
                @memcpy(out, fields);
                out[index] = .{ .name = field.name, .value = replacement };
                return out;
            }
        }
        return null;
    }

    fn replaceInBindings(
        self: *Rewriter,
        bindings: []const ir.LetGroupBinding,
        name: []const u8,
        hash: *const ir.Expr,
        recid: *const ir.Expr,
        sig: *const ir.Expr,
    ) PassError!?[]const ir.LetGroupBinding {
        for (bindings, 0..) |binding, index| {
            if (try self.replaceSingleConsumer(binding.value, name, hash, recid, sig)) |replacement| {
                const out = try self.allocator().alloc(ir.LetGroupBinding, bindings.len);
                @memcpy(out, bindings);
                out[index] = .{
                    .name = binding.name,
                    .value = replacement,
                    .ty = binding.ty,
                    .layout = binding.layout,
                };
                return out;
            }
        }
        return null;
    }

    fn replaceInArms(
        self: *Rewriter,
        arms: []const ir.Arm,
        name: []const u8,
        hash: *const ir.Expr,
        recid: *const ir.Expr,
        sig: *const ir.Expr,
    ) PassError!?[]const ir.Arm {
        for (arms, 0..) |arm, index| {
            if (patternBindsName(arm.pattern, name)) continue;
            if (arm.guard) |guard| {
                if (try self.replaceSingleConsumer(guard, name, hash, recid, sig)) |replacement| {
                    const out = try self.allocator().alloc(ir.Arm, arms.len);
                    @memcpy(out, arms);
                    out[index] = .{ .pattern = arm.pattern, .guard = replacement, .body = arm.body };
                    return out;
                }
            }
            if (try self.replaceSingleConsumer(arm.body, name, hash, recid, sig)) |replacement| {
                const out = try self.allocator().alloc(ir.Arm, arms.len);
                @memcpy(out, arms);
                out[index] = .{ .pattern = arm.pattern, .guard = arm.guard, .body = replacement };
                return out;
            }
        }
        return null;
    }
};

/// Rewrites every declaration body in a Core IR module.
pub fn rewriteSecpRecoverIntoAccountWrite(arena: *std.heap.ArenaAllocator, module: ir.Module) PassError!ir.Module {
    var rewriter: Rewriter = .{
        .arena = arena,
        .externals = module.externals,
    };
    const decls = try arena.allocator().alloc(ir.Decl, module.decls.len);
    for (module.decls, 0..) |decl, index| {
        decls[index] = try rewriter.rewriteDecl(decl);
    }
    return .{
        .decls = decls,
        .type_decls = module.type_decls,
        .tuple_type_decls = module.tuple_type_decls,
        .record_type_decls = module.record_type_decls,
        .externals = module.externals,
    };
}

fn countUses(expr: ir.Expr, name: []const u8) usize {
    return switch (expr) {
        .Lambda => |lambda| if (paramsBindName(lambda.params, name)) 0 else countUses(lambda.body.*, name),
        .Constant => 0,
        .App => |app| countUses(app.callee.*, name) + countUsesInExprSlice(app.args, name),
        .Let => |let_expr| blk: {
            var count: usize = 0;
            if (!let_expr.is_rec or !std.mem.eql(u8, let_expr.name, name)) {
                count += countUses(let_expr.value.*, name);
            }
            if (!std.mem.eql(u8, let_expr.name, name)) {
                count += countUses(let_expr.body.*, name);
            }
            break :blk count;
        },
        .LetGroup => |group| blk: {
            if (groupBindsName(group.bindings, name)) break :blk 0;
            var count: usize = 0;
            for (group.bindings) |binding| count += countUses(binding.value.*, name);
            count += countUses(group.body.*, name);
            break :blk count;
        },
        .Assert => |assert_expr| countUses(assert_expr.condition.*, name),
        .If => |if_expr| countUses(if_expr.cond.*, name) +
            countUses(if_expr.then_branch.*, name) +
            countUses(if_expr.else_branch.*, name),
        .Prim => |prim| countUsesInExprSlice(prim.args, name),
        .Var => |var_ref| if (std.mem.eql(u8, var_ref.name, name)) 1 else 0,
        .Ctor => |ctor| countUsesInExprSlice(ctor.args, name),
        .Match => |match_expr| blk: {
            var count = countUses(match_expr.scrutinee.*, name);
            for (match_expr.arms) |arm| {
                if (patternBindsName(arm.pattern, name)) continue;
                if (arm.guard) |guard| count += countUses(guard.*, name);
                count += countUses(arm.body.*, name);
            }
            break :blk count;
        },
        .Tuple => |tuple| countUsesInExprSlice(tuple.items, name),
        .TupleProj => |tuple_proj| countUses(tuple_proj.tuple_expr.*, name),
        .Record => |record| countUsesInRecordFields(record.fields, name),
        .RecordField => |record_field| countUses(record_field.record_expr.*, name),
        .RecordUpdate => |record_update| countUses(record_update.base_expr.*, name) +
            countUsesInRecordFields(record_update.fields, name),
        .AccountFieldSet => |field_set| countUses(field_set.account_expr.*, name) +
            countUses(field_set.value.*, name),
        .ArrayLit => |array_lit| countUsesInExprSlice(array_lit.elems, name),
        .ArrayGet => |array_get| countUses(array_get.arr.*, name) + countUses(array_get.idx.*, name),
        .ArrayLength => |array_length| countUses(array_length.arr.*, name),
        .ArraySet => |array_set| countUses(array_set.arr.*, name) + countUses(array_set.idx.*, name) + countUses(array_set.value.*, name),
        .ArrayMake => |array_make| countUses(array_make.init.*, name),
        .RefMake => |ref_make| countUses(ref_make.init.*, name),
        .RefGet => |ref_get| countUses(ref_get.target.*, name),
        .RefSet => |ref_set| countUses(ref_set.target.*, name) + countUses(ref_set.value.*, name),
    };
}

fn countUsesInExprSlice(exprs: []const *const ir.Expr, name: []const u8) usize {
    var count: usize = 0;
    for (exprs) |expr| count += countUses(expr.*, name);
    return count;
}

fn countUsesInRecordFields(fields: []const ir.RecordExprField, name: []const u8) usize {
    var count: usize = 0;
    for (fields) |field| count += countUses(field.value.*, name);
    return count;
}

fn paramsBindName(params: []const ir.Param, name: []const u8) bool {
    for (params) |param| {
        if (std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

fn groupBindsName(bindings: []const ir.LetGroupBinding, name: []const u8) bool {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return true;
    }
    return false;
}

fn patternBindsName(pattern: ir.Pattern, name: []const u8) bool {
    return switch (pattern) {
        .Wildcard, .Constant => false,
        .Var => |var_pattern| std.mem.eql(u8, var_pattern.name, name),
        .Ctor => |ctor_pattern| blk: {
            for (ctor_pattern.args) |arg| {
                if (patternBindsName(arg, name)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |items| blk: {
            for (items) |item| {
                if (patternBindsName(item, name)) break :blk true;
            }
            break :blk false;
        },
        .Record => |fields| blk: {
            for (fields) |field| {
                if (patternBindsName(field.pattern, name)) break :blk true;
            }
            break :blk false;
        },
        .Alias => |alias| std.mem.eql(u8, alias.name, name) or patternBindsName(alias.pattern.*, name),
    };
}

fn isVarNamed(expr: ir.Expr, name: []const u8) bool {
    return switch (expr) {
        .Var => |var_ref| std.mem.eql(u8, var_ref.name, name),
        else => false,
    };
}

fn exprTy(expr: ir.Expr) ir.Ty {
    return switch (expr) {
        .Lambda => |lambda| lambda.ty,
        .Constant => |constant| constant.ty,
        .App => |app| app.ty,
        .Let => |let_expr| let_expr.ty,
        .LetGroup => |group| group.ty,
        .Assert => |assert_expr| assert_expr.ty,
        .If => |if_expr| if_expr.ty,
        .Prim => |prim| prim.ty,
        .Var => |var_ref| var_ref.ty,
        .Ctor => |ctor| ctor.ty,
        .Match => |match_expr| match_expr.ty,
        .Tuple => |tuple| tuple.ty,
        .TupleProj => |tuple_proj| tuple_proj.ty,
        .Record => |record| record.ty,
        .RecordField => |record_field| record_field.ty,
        .RecordUpdate => |record_update| record_update.ty,
        .AccountFieldSet => |field_set| field_set.ty,
        .ArrayLit => |array_lit| array_lit.ty,
        .ArrayGet => |array_get| array_get.ty,
        .ArrayLength => |array_length| array_length.ty,
        .ArraySet => |array_set| array_set.ty,
        .ArrayMake => |array_make| array_make.ty,
        .RefMake => |ref_make| ref_make.ty,
        .RefGet => |ref_get| ref_get.ty,
        .RefSet => |ref_set| ref_set.ty,
    };
}
