//! Typed Zig mirror for the M1 P3 ZxCaml frontend S-expression format.
//!
//! RESPONSIBILITIES:
//! - Validate the `(zxcaml-cir 1.5 ...)` wire-format header.
//! - Decode the generic S-expression tree into `Module -> Decl -> Expr`.
//! - Keep all compiler-internal allocation explicit through a caller arena.

const std = @import("std");
const Io = std.Io;
const sexp_parser = @import("sexp_parser.zig");
const Sexp = sexp_parser.Sexp;

pub const expected_wire_version = sexp_parser.expected_wire_version;

/// Source location carried by wire 1.2+ expression nodes.
pub const Loc = struct {
    file: []const u8,
    line: u32,
    col: u32,
    end_line: u32,
    end_col: u32,

    pub const unknown: Loc = .{
        .file = "_unknown_",
        .line = 0,
        .col = 0,
        .end_line = 0,
        .end_col = 0,
    };

    pub fn isUnknown(self: Loc) bool {
        return self.line == 0 and self.end_line == 0 and std.mem.eql(u8, self.file, "_unknown_");
    }
};

/// Typed mirror of an accepted frontend module.
pub const Module = struct {
    decls: []const Decl,
    type_decls: []const TypeDecl = &.{},
    tuple_type_decls: []const TupleTypeDecl = &.{},
    record_type_decls: []const RecordTypeDecl = &.{},
    type_alias_decls: []const TypeAliasDecl = &.{},
    externals: []const ExternalDecl = &.{},
};

/// Typed mirror of an accepted top-level declaration.
pub const Decl = union(enum) {
    Let: LetDecl,
    LetRecGroup: LetRecGroupDecl,
};

/// Top-level `let` declaration.
pub const LetDecl = struct {
    name: []const u8,
    body: Expr,
    is_rec: bool = false,
};

/// One binding in a mutually recursive value group.
pub const LetRecBinding = struct {
    name: []const u8,
    params: []const []const u8,
    /// Lockstep with `params`. See `Lambda.param_types`.
    param_types: []const ?TypeExpr = &.{},
    body: Expr,
};

/// Top-level `let rec ... and ...` group.
pub const LetRecGroupDecl = struct {
    bindings: []const LetRecBinding,
};

/// Top-level external declaration emitted by sexp v1.0.
pub const ExternalDecl = struct {
    name: []const u8,
    ty: ExternalTypeExpr,
    symbol: []const u8,
};

/// Type expression language used by external declarations.
pub const ExternalTypeExpr = union(enum) {
    TypeRef: ExternalTypeRef,
    Tuple: []const ExternalTypeExpr,
    Arrow: ExternalTypeArrow,
};

/// Named external type reference, optionally applied to type arguments.
pub const ExternalTypeRef = struct {
    name: []const u8,
    args: []const ExternalTypeExpr,
};

/// Function arrow type for external declarations.
pub const ExternalTypeArrow = struct {
    arg: *const ExternalTypeExpr,
    result: *const ExternalTypeExpr,
};

/// Top-level user-authored ADT declaration emitted by sexp v0.6.
pub const TypeDecl = struct {
    name: []const u8,
    params: []const []const u8,
    variants: []const TypeVariant,
    is_recursive: bool = false,
};

/// One constructor in a variant type declaration.
pub const TypeVariant = struct {
    name: []const u8,
    payload_types: []const TypeExpr,
};

/// Top-level tuple type alias emitted by sexp v0.7.
pub const TupleTypeDecl = struct {
    name: []const u8,
    params: []const []const u8,
    items: []const TypeExpr,
    is_recursive: bool = false,
};

/// Top-level record type declaration emitted by sexp v0.7.
pub const RecordTypeDecl = struct {
    name: []const u8,
    params: []const []const u8,
    fields: []const RecordTypeField,
    is_recursive: bool = false,
    is_account: bool = false,
};

/// Top-level erased type alias emitted by sexp v1.1.
pub const TypeAliasDecl = struct {
    name: []const u8,
    params: []const []const u8,
    rhs: TypeExpr,
};

/// One record field in a type declaration.
pub const RecordTypeField = struct {
    name: []const u8,
    ty: TypeExpr,
    is_mutable: bool = false,
};

/// Type expression language used inside ADT constructor payloads.
pub const TypeExpr = union(enum) {
    TypeVar: []const u8,
    TypeRef: TypeRef,
    RecursiveRef: TypeRef,
    Tuple: []const TypeExpr,
};

/// Named type reference, optionally applied to type arguments.
pub const TypeRef = struct {
    name: []const u8,
    args: []const TypeExpr,
};

/// Typed mirror of accepted expressions.
pub const Expr = union(enum) {
    Lambda: Lambda,
    Constant: Constant,
    App: App,
    Let: LetExpr,
    LetRecGroup: LetRecGroupExpr,
    Assert: AssertExpr,
    If: IfExpr,
    Prim: Prim,
    Var: Var,
    Ctor: Ctor,
    Match: Match,
    Tuple: Tuple,
    TupleProj: TupleProj,
    Record: Record,
    RecordField: RecordField,
    RecordUpdate: RecordUpdate,
    FieldSet: FieldSet,
    ArrayLit: ArrayLit,
    ArrayGet: ArrayGet,
    ArrayLength: ArrayLength,
    ArraySet: ArraySet,
    ArrayMake: ArrayMake,
    RefMake: RefMake,
    RefGet: RefGet,
    RefSet: RefSet,
};

/// ADR-015 option C / R10: arena-allocated single-slot ref cell.
pub const RefMake = struct {
    elem_ty: TypeExpr,
    init: *const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option C / R10: ref cell dereference (`!r`).
pub const RefGet = struct {
    target: *const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option C / R10: ref cell assignment (`r := v`).
pub const RefSet = struct {
    target: *const Expr,
    value: *const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option B / R9.1: read-only int array literal.
pub const ArrayLit = struct {
    /// Element type as carried by the wire 1.4 envelope. R9.1 only emits
    /// `(type-ref int)`; non-int element types are rejected upstream
    /// (frontend E0040).
    elem_ty: TypeExpr,
    elems: []const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option B / R9.1: read-only array indexed access (`a.(i)`).
pub const ArrayGet = struct {
    arr: *const Expr,
    idx: *const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option B / R9.1: array length (`Array.length a`).
pub const ArrayLength = struct {
    arr: *const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option B / R9.2: in-place int array write
/// (`Array.set a i v` or `a.(i) <- v`).
pub const ArraySet = struct {
    arr: *const Expr,
    idx: *const Expr,
    value: *const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option B / R9.2: `Array.make N init` where `N` is a positive
/// int literal known at parse time and the element type is `Int`.
pub const ArrayMake = struct {
    elem_ty: TypeExpr,
    size: u32,
    init: *const Expr,
    loc: Loc = Loc.unknown,
};

/// Single lambda form.
pub const Lambda = struct {
    params: []const []const u8,
    /// One entry per `params`, in lockstep. Wire 1.3 emits an explicit type per
    /// parameter; wire <=1.2 emits the bare-name form and the bridge fills
    /// these with `null` so downstream consumers fall back to heuristics.
    param_types: []const ?TypeExpr = &.{},
    body: *const Expr,
    loc: Loc = Loc.unknown,
};

/// Function application expression.
pub const App = struct {
    callee: *const Expr,
    args: []const Expr,
    loc: Loc = Loc.unknown,
};

/// Nested `let NAME = VALUE in BODY` expression.
pub const LetExpr = struct {
    name: []const u8,
    value: *const Expr,
    body: *const Expr,
    is_rec: bool = false,
    loc: Loc = Loc.unknown,
};

/// Nested `let rec A = ... and B = ... in BODY` expression.
pub const LetRecGroupExpr = struct {
    bindings: []const LetRecBinding,
    body: *const Expr,
    loc: Loc = Loc.unknown,
};

/// Assert expression whose condition must evaluate to true.
pub const AssertExpr = struct {
    condition: *const Expr,
    loc: Loc = Loc.unknown,
};

/// Conditional expression with an explicit else branch.
pub const IfExpr = struct {
    cond: *const Expr,
    then_branch: *const Expr,
    else_branch: *const Expr,
    loc: Loc = Loc.unknown,
};

/// Primitive integer/comparison operation.
pub const Prim = struct {
    op: []const u8,
    args: []const Expr,
    loc: Loc = Loc.unknown,
};

/// Variable reference expression.
pub const Var = struct {
    name: []const u8,
    loc: Loc = Loc.unknown,
};

/// Constructor expression such as `None`, `Some x`, `Ok x`, `Error e`, `[]`, or `x :: xs`.
pub const Ctor = struct {
    name: []const u8,
    args: []const Expr,
    loc: Loc = Loc.unknown,
};

/// Tuple construction expression.
pub const Tuple = struct {
    items: []const Expr,
    loc: Loc = Loc.unknown,
};

/// Tuple projection expression, emitted for `fst`/`snd` helpers.
pub const TupleProj = struct {
    tuple_expr: *const Expr,
    index: usize,
    loc: Loc = Loc.unknown,
};

/// Record construction expression with source-order fields.
pub const Record = struct {
    fields: []const RecordExprField,
    loc: Loc = Loc.unknown,
};

/// One field assignment in a record construction/update expression.
pub const RecordExprField = struct {
    name: []const u8,
    value: Expr,
};

/// Record field access expression.
pub const RecordField = struct {
    record_expr: *const Expr,
    field_name: []const u8,
    loc: Loc = Loc.unknown,
};

/// Functional record update expression.
pub const RecordUpdate = struct {
    base_expr: *const Expr,
    fields: []const RecordExprField,
    loc: Loc = Loc.unknown,
};

/// In-place record field assignment expression emitted for mutable fields.
pub const FieldSet = struct {
    record_expr: *const Expr,
    field_name: []const u8,
    value: *const Expr,
    loc: Loc = Loc.unknown,
};

/// Pattern match expression with arms evaluated top-to-bottom.
pub const Match = struct {
    scrutinee: *const Expr,
    arms: []const Arm,
    loc: Loc = Loc.unknown,
};

/// Single match arm.
pub const Arm = struct {
    pattern: Pattern,
    guard: ?*const Expr = null,
    body: *const Expr,
};

/// Recursive pattern forms accepted for match arms.
pub const Pattern = union(enum) {
    Wildcard,
    Var: []const u8,
    Const: PatternConstant,
    Ctor: CtorPattern,
    Tuple: []const Pattern,
    Record: []const RecordPatternField,
    Alias: AliasPattern,
    Or: []const Pattern,
};

/// Literal constant pattern such as `0`, `"hello"`, or `'a'`.
pub const PatternConstant = union(enum) {
    Int: i64,
    String: []const u8,
    Char: i64,
};

/// Alias pattern such as `p as name`.
pub const AliasPattern = struct {
    pattern: *const Pattern,
    name: []const u8,
};

/// Constructor pattern such as `Some x`, `None`, `[]`, `x :: xs`, or nested constructor payloads.
pub const CtorPattern = struct {
    name: []const u8,
    args: []const Pattern,
};

/// One field pattern inside a record pattern.
pub const RecordPatternField = struct {
    name: []const u8,
    pattern: Pattern,
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
    MalformedExternalDecl,
    MalformedExternalType,
    MalformedTypeDecl,
    MalformedTypeExpr,
    MalformedTuple,
    MalformedRecord,
    MalformedLambda,
    MalformedApp,
    MalformedLet,
    MalformedAssert,
    MalformedIf,
    MalformedPrim,
    MalformedVar,
    MalformedCtor,
    MalformedMatch,
    MalformedPattern,
    MalformedConstant,
    MalformedLoc,
};

/// Parses frontend bytes into an arena-owned typed module mirror.
pub fn parseModule(arena: *std.heap.ArenaAllocator, bytes: []const u8) BridgeError!Module {
    const root = try sexp_parser.parse(arena, bytes);
    const header = try expectList(root);
    if (header.len != 3) return error.InvalidHeader;
    try expectAtomValue(header[0], "zxcaml-cir");

    const file_version = try expectAtom(header[1]);
    if (!std.mem.eql(u8, file_version, expected_wire_version) and
        !std.mem.eql(u8, file_version, "1.4") and
        !std.mem.eql(u8, file_version, "1.3") and
        !std.mem.eql(u8, file_version, "1.2") and
        !std.mem.eql(u8, file_version, "1.1") and
        !std.mem.eql(u8, file_version, "1.0") and
        !std.mem.eql(u8, file_version, "0.9") and
        !std.mem.eql(u8, file_version, "0.8") and
        !std.mem.eql(u8, file_version, "0.6") and
        !std.mem.eql(u8, file_version, "0.5") and
        !std.mem.eql(u8, file_version, "0.7") and
        !std.mem.eql(u8, file_version, "0.4"))
    {
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
            try writeStderr(io, " expected=1.5\n");
            if (std.mem.eql(u8, extractHeaderVersion(bytes), "0.1") or
                std.mem.eql(u8, extractHeaderVersion(bytes), "0.2") or
                std.mem.eql(u8, extractHeaderVersion(bytes), "0.3") or
                std.mem.eql(u8, extractHeaderVersion(bytes), "0.4") or
                std.mem.eql(u8, extractHeaderVersion(bytes), "0.5") or
                std.mem.eql(u8, extractHeaderVersion(bytes), "0.6") or
                std.mem.eql(u8, extractHeaderVersion(bytes), "0.7") or
                std.mem.eql(u8, extractHeaderVersion(bytes), "0.8") or
                std.mem.eql(u8, extractHeaderVersion(bytes), "0.9") or
                std.mem.eql(u8, extractHeaderVersion(bytes), "1.0") or
                std.mem.eql(u8, extractHeaderVersion(bytes), "1.1"))
            {
                try writeStderr(io, "hint: frontend wire format ");
                try writeStderr(io, extractHeaderVersion(bytes));
                try writeStderr(io, " is deprecated; rebuild zxc-frontend with this omlz so it emits ref-capable sexp 1.5.\n");
            } else {
                try writeStderr(io, "hint: rebuild zxc-frontend with this omlz so the frontend and Zig bridge agree on the wire format.\n");
            }
        },
        error.EmptyInput => try writeStderr(io, "error: empty frontend sexp on stdin\n"),
        error.UnmatchedParen => try writeStderr(io, "error: malformed frontend sexp: unmatched paren\n"),
        error.UnexpectedRightParen => try writeStderr(io, "error: malformed frontend sexp: unexpected right paren\n"),
        error.BadAtom => try writeStderr(io, "error: malformed frontend sexp: bad atom\n"),
        error.InvalidHeader => try writeStderr(io, "error: malformed frontend sexp: expected (zxcaml-cir 1.5 ...)\n"),
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
    var type_decls = std.ArrayList(TypeDecl).empty;
    errdefer type_decls.deinit(arena.allocator());
    var tuple_type_decls = std.ArrayList(TupleTypeDecl).empty;
    errdefer tuple_type_decls.deinit(arena.allocator());
    var record_type_decls = std.ArrayList(RecordTypeDecl).empty;
    errdefer record_type_decls.deinit(arena.allocator());
    var type_alias_decls = std.ArrayList(TypeAliasDecl).empty;
    errdefer type_alias_decls.deinit(arena.allocator());
    var externals = std.ArrayList(ExternalDecl).empty;
    errdefer externals.deinit(arena.allocator());

    for (items[1..]) |decl_node| {
        const decl_items = try expectList(decl_node);
        if (decl_items.len == 0) return error.MalformedDecl;
        const tag = try expectAtom(decl_items[0]);
        if (std.mem.eql(u8, tag, "type_decl")) {
            try type_decls.append(arena.allocator(), try parseTypeDecl(arena, decl_items));
        } else if (std.mem.eql(u8, tag, "tuple_type_decl")) {
            try tuple_type_decls.append(arena.allocator(), try parseTupleTypeDecl(arena, decl_items));
        } else if (std.mem.eql(u8, tag, "record_type_decl")) {
            try record_type_decls.append(arena.allocator(), try parseRecordTypeDecl(arena, decl_items));
        } else if (std.mem.eql(u8, tag, "type_alias_decl")) {
            try type_alias_decls.append(arena.allocator(), try parseTypeAliasDecl(arena, decl_items));
        } else if (std.mem.eql(u8, tag, "external")) {
            try externals.append(arena.allocator(), try parseExternalDecl(arena, decl_items));
        } else {
            try decls.append(arena.allocator(), try parseDeclItems(arena, decl_items));
        }
    }

    return .{
        .decls = try decls.toOwnedSlice(arena.allocator()),
        .type_decls = try type_decls.toOwnedSlice(arena.allocator()),
        .tuple_type_decls = try tuple_type_decls.toOwnedSlice(arena.allocator()),
        .record_type_decls = try record_type_decls.toOwnedSlice(arena.allocator()),
        .type_alias_decls = try type_alias_decls.toOwnedSlice(arena.allocator()),
        .externals = try externals.toOwnedSlice(arena.allocator()),
    };
}

fn parseDecl(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!Decl {
    const items = try expectList(node);
    return parseDeclItems(arena, items);
}

fn parseDeclItems(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!Decl {
    const tag = try expectAtom(items[0]);
    if (std.mem.eql(u8, tag, "Let_rec_group")) {
        if (items.len != 2) return error.MalformedDecl;
        return .{ .LetRecGroup = .{ .bindings = try parseLetRecBindings(arena, items[1]) } };
    }

    if (items.len != 3) return error.MalformedDecl;
    const is_rec = if (std.mem.eql(u8, tag, "let")) false else if (std.mem.eql(u8, tag, "let-rec")) true else return error.MalformedDecl;

    const name = try dupeAtom(arena, items[1]);
    const body = try parseExpr(arena, items[2]);

    return .{ .Let = .{ .name = name, .body = body, .is_rec = is_rec } };
}

fn parseExternalDecl(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!ExternalDecl {
    if (items.len != 4) return error.MalformedExternalDecl;

    const name_items = try expectList(items[1]);
    if (name_items.len != 2) return error.MalformedExternalDecl;
    try expectAtomValue(name_items[0], "name");

    const type_items = try expectList(items[2]);
    if (type_items.len != 2) return error.MalformedExternalDecl;
    try expectAtomValue(type_items[0], "type");

    const symbol_items = try expectList(items[3]);
    if (symbol_items.len != 2) return error.MalformedExternalDecl;
    try expectAtomValue(symbol_items[0], "symbol");

    return .{
        .name = try dupeAtom(arena, name_items[1]),
        .ty = try parseExternalTypeExpr(arena, type_items[1]),
        .symbol = try dupeAtom(arena, symbol_items[1]),
    };
}

fn parseExternalTypeExpr(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!ExternalTypeExpr {
    if (node.atomLike()) |name| {
        return .{ .TypeRef = .{
            .name = try arena.allocator().dupe(u8, name),
            .args = &.{},
        } };
    }

    const items = try expectList(node);
    if (items.len == 0) return error.MalformedExternalType;
    const tag = try expectAtom(items[0]);

    if (std.mem.eql(u8, tag, "arrow")) {
        if (items.len != 3) return error.MalformedExternalType;
        const arg = try arena.allocator().create(ExternalTypeExpr);
        arg.* = try parseExternalTypeExpr(arena, items[1]);
        const result = try arena.allocator().create(ExternalTypeExpr);
        result.* = try parseExternalTypeExpr(arena, items[2]);
        return .{ .Arrow = .{ .arg = arg, .result = result } };
    }
    if (std.mem.eql(u8, tag, "tuple")) {
        if (items.len < 2) return error.MalformedExternalType;
        var members = std.ArrayList(ExternalTypeExpr).empty;
        errdefer members.deinit(arena.allocator());
        for (items[1..]) |member_node| {
            try members.append(arena.allocator(), try parseExternalTypeExpr(arena, member_node));
        }
        return .{ .Tuple = try members.toOwnedSlice(arena.allocator()) };
    }
    if (std.mem.eql(u8, tag, "type-ref")) {
        if (items.len < 2) return error.MalformedExternalType;
        var args = std.ArrayList(ExternalTypeExpr).empty;
        errdefer args.deinit(arena.allocator());
        for (items[2..]) |arg_node| {
            try args.append(arena.allocator(), try parseExternalTypeExpr(arena, arg_node));
        }
        return .{ .TypeRef = .{
            .name = try dupeAtom(arena, items[1]),
            .args = try args.toOwnedSlice(arena.allocator()),
        } };
    }
    return error.MalformedExternalType;
}

fn parseTypeDecl(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!TypeDecl {
    if (items.len != 4 and items.len != 5) return error.MalformedTypeDecl;

    const name_items = try expectList(items[1]);
    if (name_items.len != 2) return error.MalformedTypeDecl;
    try expectAtomValue(name_items[0], "name");

    const params = try parseParams(arena, items[2]);

    var variants_index: usize = 3;
    var is_recursive = false;
    if (items.len == 5) {
        const recursive_items = try expectList(items[3]);
        if (recursive_items.len != 2) return error.MalformedTypeDecl;
        try expectAtomValue(recursive_items[0], "recursive");
        try expectAtomValue(recursive_items[1], "true");
        is_recursive = true;
        variants_index = 4;
    }

    return .{
        .name = try dupeAtom(arena, name_items[1]),
        .params = params,
        .variants = try parseTypeVariants(arena, items[variants_index]),
        .is_recursive = is_recursive,
    };
}

fn parseTupleTypeDecl(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!TupleTypeDecl {
    if (items.len != 4 and items.len != 5) return error.MalformedTypeDecl;

    const name_items = try expectList(items[1]);
    if (name_items.len != 2) return error.MalformedTypeDecl;
    try expectAtomValue(name_items[0], "name");

    var items_index: usize = 3;
    var is_recursive = false;
    if (items.len == 5) {
        const recursive_items = try expectList(items[3]);
        if (recursive_items.len != 2) return error.MalformedTypeDecl;
        try expectAtomValue(recursive_items[0], "recursive");
        try expectAtomValue(recursive_items[1], "true");
        is_recursive = true;
        items_index = 4;
    }

    const type_items = try expectList(items[items_index]);
    if (type_items.len == 0) return error.MalformedTypeDecl;
    try expectAtomValue(type_items[0], "items");
    var tuple_items = std.ArrayList(TypeExpr).empty;
    errdefer tuple_items.deinit(arena.allocator());
    for (type_items[1..]) |item_node| {
        try tuple_items.append(arena.allocator(), try parseTypeExpr(arena, item_node));
    }

    return .{
        .name = try dupeAtom(arena, name_items[1]),
        .params = try parseParams(arena, items[2]),
        .items = try tuple_items.toOwnedSlice(arena.allocator()),
        .is_recursive = is_recursive,
    };
}

fn parseRecordTypeDecl(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!RecordTypeDecl {
    if (items.len < 4 or items.len > 6) return error.MalformedTypeDecl;

    const name_items = try expectList(items[1]);
    if (name_items.len != 2) return error.MalformedTypeDecl;
    try expectAtomValue(name_items[0], "name");

    var fields_node: ?*const Sexp = null;
    var is_recursive = false;
    var is_account = false;
    for (items[3..]) |item| {
        const item_items = try expectList(item);
        if (item_items.len == 0) return error.MalformedTypeDecl;
        const tag = try expectAtom(item_items[0]);
        if (std.mem.eql(u8, tag, "recursive")) {
            if (item_items.len != 2) return error.MalformedTypeDecl;
            try expectAtomValue(item_items[1], "true");
            is_recursive = true;
        } else if (std.mem.eql(u8, tag, "fields")) {
            if (fields_node != null) return error.MalformedTypeDecl;
            fields_node = item;
        } else if (std.mem.eql(u8, tag, "account_attr")) {
            if (item_items.len != 1) return error.MalformedTypeDecl;
            is_account = true;
        } else {
            return error.MalformedTypeDecl;
        }
    }
    const fields = fields_node orelse return error.MalformedTypeDecl;

    return .{
        .name = try dupeAtom(arena, name_items[1]),
        .params = try parseParams(arena, items[2]),
        .fields = try parseRecordTypeFields(arena, fields),
        .is_recursive = is_recursive,
        .is_account = is_account,
    };
}

fn parseTypeAliasDecl(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!TypeAliasDecl {
    if (items.len != 4) return error.MalformedTypeDecl;

    const name_items = try expectList(items[1]);
    if (name_items.len != 2) return error.MalformedTypeDecl;
    try expectAtomValue(name_items[0], "name");

    const rhs_items = try expectList(items[3]);
    if (rhs_items.len != 2) return error.MalformedTypeDecl;
    try expectAtomValue(rhs_items[0], "rhs");

    return .{
        .name = try dupeAtom(arena, name_items[1]),
        .params = try parseParams(arena, items[2]),
        .rhs = try parseTypeExpr(arena, rhs_items[1]),
    };
}

fn parseParams(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError![]const []const u8 {
    const params_items = try expectList(node);
    if (params_items.len == 0) return error.MalformedTypeDecl;
    try expectAtomValue(params_items[0], "params");
    var params = std.ArrayList([]const u8).empty;
    errdefer params.deinit(arena.allocator());
    for (params_items[1..]) |param_node| {
        try params.append(arena.allocator(), try dupeAtom(arena, param_node));
    }
    return params.toOwnedSlice(arena.allocator());
}

fn parseRecordTypeFields(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError![]const RecordTypeField {
    const items = try expectList(node);
    if (items.len != 2) return error.MalformedTypeDecl;
    try expectAtomValue(items[0], "fields");
    const field_nodes = try expectList(items[1]);

    var fields = std.ArrayList(RecordTypeField).empty;
    errdefer fields.deinit(arena.allocator());
    for (field_nodes) |field_node| {
        try fields.append(arena.allocator(), try parseRecordTypeField(arena, field_node));
    }
    return fields.toOwnedSlice(arena.allocator());
}

fn parseRecordTypeField(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!RecordTypeField {
    const items = try expectList(node);
    if (items.len != 2 and items.len != 3) return error.MalformedTypeDecl;
    var is_mutable = false;
    if (items.len == 3) {
        const mutable_items = try expectList(items[2]);
        if (mutable_items.len != 2) return error.MalformedTypeDecl;
        try expectAtomValue(mutable_items[0], "mutable");
        try expectAtomValue(mutable_items[1], "true");
        is_mutable = true;
    }
    return .{
        .name = try dupeAtom(arena, items[0]),
        .ty = try parseTypeExpr(arena, items[1]),
        .is_mutable = is_mutable,
    };
}

fn parseTypeVariants(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError![]const TypeVariant {
    const items = try expectList(node);
    if (items.len != 2) return error.MalformedTypeDecl;
    try expectAtomValue(items[0], "variants");
    const variant_nodes = try expectList(items[1]);

    var variants = std.ArrayList(TypeVariant).empty;
    errdefer variants.deinit(arena.allocator());
    for (variant_nodes) |variant_node| {
        try variants.append(arena.allocator(), try parseTypeVariant(arena, variant_node));
    }
    return variants.toOwnedSlice(arena.allocator());
}

fn parseTypeVariant(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!TypeVariant {
    const items = try expectList(node);
    if (items.len != 2) return error.MalformedTypeDecl;

    const payload_items = try expectList(items[1]);
    if (payload_items.len == 0) return error.MalformedTypeDecl;
    try expectAtomValue(payload_items[0], "payload_types");

    var payload_types = std.ArrayList(TypeExpr).empty;
    errdefer payload_types.deinit(arena.allocator());
    for (payload_items[1..]) |payload_node| {
        try payload_types.append(arena.allocator(), try parseTypeExpr(arena, payload_node));
    }

    return .{
        .name = try dupeAtom(arena, items[0]),
        .payload_types = try payload_types.toOwnedSlice(arena.allocator()),
    };
}

fn parseTypeExpr(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!TypeExpr {
    const items = try expectList(node);
    if (items.len == 0) return error.MalformedTypeExpr;
    const tag = try expectAtom(items[0]);

    if (std.mem.eql(u8, tag, "any")) {
        // Wire 1.3 emits `(any)` for unconstrained type slots, including
        // inside applied type constructors like `(type-ref list (any))`
        // when the element type is not pinned down. Treat as a fresh
        // unbound type variable; downstream lowering reuses the same
        // fallback path as wire 1.2 (which omitted param_types entirely).
        if (items.len != 1) return error.MalformedTypeExpr;
        return .{ .TypeVar = try arena.allocator().dupe(u8, "_") };
    }
    if (std.mem.eql(u8, tag, "type-var")) {
        if (items.len != 2) return error.MalformedTypeExpr;
        return .{ .TypeVar = try dupeAtom(arena, items[1]) };
    }
    if (std.mem.eql(u8, tag, "type-ref") or std.mem.eql(u8, tag, "recursive-ref")) {
        if (items.len < 2) return error.MalformedTypeExpr;
        var args = std.ArrayList(TypeExpr).empty;
        errdefer args.deinit(arena.allocator());
        for (items[2..]) |arg_node| {
            try args.append(arena.allocator(), try parseTypeExpr(arena, arg_node));
        }
        const type_ref: TypeRef = .{
            .name = try dupeAtom(arena, items[1]),
            .args = try args.toOwnedSlice(arena.allocator()),
        };
        if (std.mem.eql(u8, tag, "recursive-ref")) return .{ .RecursiveRef = type_ref };
        return .{ .TypeRef = type_ref };
    }
    if (std.mem.eql(u8, tag, "tuple-type")) {
        if (items.len < 2) return error.MalformedTypeExpr;
        var members = std.ArrayList(TypeExpr).empty;
        errdefer members.deinit(arena.allocator());
        for (items[1..]) |member_node| {
            try members.append(arena.allocator(), try parseTypeExpr(arena, member_node));
        }
        return .{ .Tuple = try members.toOwnedSlice(arena.allocator()) };
    }
    return error.MalformedTypeExpr;
}

fn parseExpr(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!Expr {
    const items = try expectList(node);
    if (items.len == 0) return error.UnexpectedAtom;

    const tag = try expectAtom(items[0]);
    if (std.mem.eql(u8, tag, "located")) return parseLocatedExpr(arena, items);

    const located = try splitTrailingLoc(arena, items);
    const expr_items = located.items;
    const expr_tag = try expectAtom(expr_items[0]);
    if (std.mem.eql(u8, expr_tag, "lambda")) {
        var value = try parseLambda(arena, expr_items);
        value.loc = located.loc;
        return .{ .Lambda = value };
    }
    if (std.mem.eql(u8, expr_tag, "const-int")) return .{ .Constant = .{ .Int = try parseConstInt(expr_items) } };
    if (std.mem.eql(u8, expr_tag, "const-string")) return .{ .Constant = .{ .String = try parseConstString(arena, expr_items) } };
    if (std.mem.eql(u8, expr_tag, "app")) {
        var value = try parseApp(arena, expr_items);
        value.loc = located.loc;
        return .{ .App = value };
    }
    if (std.mem.eql(u8, expr_tag, "let")) {
        var value = try parseLetExpr(arena, expr_items, false);
        value.loc = located.loc;
        return .{ .Let = value };
    }
    if (std.mem.eql(u8, expr_tag, "let-rec")) {
        var value = try parseLetExpr(arena, expr_items, true);
        value.loc = located.loc;
        return .{ .Let = value };
    }
    if (std.mem.eql(u8, expr_tag, "Let_rec_group")) {
        var value = try parseLetRecGroupExpr(arena, expr_items);
        value.loc = located.loc;
        return .{ .LetRecGroup = value };
    }
    if (std.mem.eql(u8, expr_tag, "Assert")) {
        var value = try parseAssert(arena, expr_items);
        value.loc = located.loc;
        return .{ .Assert = value };
    }
    if (std.mem.eql(u8, expr_tag, "if")) {
        var value = try parseIf(arena, expr_items);
        value.loc = located.loc;
        return .{ .If = value };
    }
    if (std.mem.eql(u8, expr_tag, "prim")) {
        var value = try parsePrim(arena, expr_items);
        value.loc = located.loc;
        return .{ .Prim = value };
    }
    if (std.mem.eql(u8, expr_tag, "var")) {
        var value = try parseVar(arena, expr_items);
        value.loc = located.loc;
        return .{ .Var = value };
    }
    if (std.mem.eql(u8, expr_tag, "ctor")) {
        var value = try parseCtor(arena, expr_items);
        value.loc = located.loc;
        return .{ .Ctor = value };
    }
    if (std.mem.eql(u8, expr_tag, "match")) {
        var value = try parseMatch(arena, expr_items);
        value.loc = located.loc;
        return .{ .Match = value };
    }
    if (std.mem.eql(u8, expr_tag, "tuple")) {
        var value = try parseTuple(arena, expr_items);
        value.loc = located.loc;
        return .{ .Tuple = value };
    }
    if (std.mem.eql(u8, expr_tag, "tuple_project")) {
        var value = try parseTupleProj(arena, expr_items);
        value.loc = located.loc;
        return .{ .TupleProj = value };
    }
    if (std.mem.eql(u8, expr_tag, "record")) {
        var value = try parseRecord(arena, expr_items);
        value.loc = located.loc;
        return .{ .Record = value };
    }
    if (std.mem.eql(u8, expr_tag, "field_access")) {
        var value = try parseRecordField(arena, expr_items);
        value.loc = located.loc;
        return .{ .RecordField = value };
    }
    if (std.mem.eql(u8, expr_tag, "record_update")) {
        var value = try parseRecordUpdate(arena, expr_items);
        value.loc = located.loc;
        return .{ .RecordUpdate = value };
    }
    if (std.mem.eql(u8, expr_tag, "field_set")) {
        var value = try parseFieldSet(arena, expr_items);
        value.loc = located.loc;
        return .{ .FieldSet = value };
    }
    if (std.mem.eql(u8, expr_tag, "array-lit")) {
        var value = try parseArrayLit(arena, expr_items);
        value.loc = located.loc;
        return .{ .ArrayLit = value };
    }
    if (std.mem.eql(u8, expr_tag, "array-get")) {
        var value = try parseArrayGet(arena, expr_items);
        value.loc = located.loc;
        return .{ .ArrayGet = value };
    }
    if (std.mem.eql(u8, expr_tag, "array-length")) {
        var value = try parseArrayLength(arena, expr_items);
        value.loc = located.loc;
        return .{ .ArrayLength = value };
    }
    if (std.mem.eql(u8, expr_tag, "array-set")) {
        var value = try parseArraySet(arena, expr_items);
        value.loc = located.loc;
        return .{ .ArraySet = value };
    }
    if (std.mem.eql(u8, expr_tag, "array-make")) {
        var value = try parseArrayMake(arena, expr_items);
        value.loc = located.loc;
        return .{ .ArrayMake = value };
    }
    if (std.mem.eql(u8, expr_tag, "ref-make")) {
        var value = try parseRefMake(arena, expr_items);
        value.loc = located.loc;
        return .{ .RefMake = value };
    }
    if (std.mem.eql(u8, expr_tag, "ref-get")) {
        var value = try parseRefGet(arena, expr_items);
        value.loc = located.loc;
        return .{ .RefGet = value };
    }
    if (std.mem.eql(u8, expr_tag, "ref-set")) {
        var value = try parseRefSet(arena, expr_items);
        value.loc = located.loc;
        return .{ .RefSet = value };
    }
    return error.UnsupportedNode;
}

fn parseRefMake(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!RefMake {
    // (ref-make (ty <type-expr>) <init-expr>)
    if (items.len != 3) return error.UnsupportedNode;
    const ty_items = try expectList(items[1]);
    if (ty_items.len != 2) return error.MalformedTypeExpr;
    try expectAtomValue(ty_items[0], "ty");
    const elem_ty = try parseTypeExpr(arena, ty_items[1]);
    const init = try arena.allocator().create(Expr);
    init.* = try parseExpr(arena, items[2]);
    return .{ .elem_ty = elem_ty, .init = init };
}

fn parseRefGet(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!RefGet {
    if (items.len != 2) return error.UnsupportedNode;
    const target = try arena.allocator().create(Expr);
    target.* = try parseExpr(arena, items[1]);
    return .{ .target = target };
}

fn parseRefSet(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!RefSet {
    if (items.len != 3) return error.UnsupportedNode;
    const target = try arena.allocator().create(Expr);
    target.* = try parseExpr(arena, items[1]);
    const value = try arena.allocator().create(Expr);
    value.* = try parseExpr(arena, items[2]);
    return .{ .target = target, .value = value };
}

fn parseArrayLit(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!ArrayLit {
    if (items.len < 2) return error.UnsupportedNode;
    // items[0] = "array-lit"; items[1] = (ty <type-expr>); items[2..] = elements
    const ty_items = try expectList(items[1]);
    if (ty_items.len != 2) return error.MalformedTypeExpr;
    try expectAtomValue(ty_items[0], "ty");
    const elem_ty = try parseTypeExpr(arena, ty_items[1]);

    var elems = std.ArrayList(Expr).empty;
    errdefer elems.deinit(arena.allocator());
    for (items[2..]) |elem_node| {
        try elems.append(arena.allocator(), try parseExpr(arena, elem_node));
    }
    return .{
        .elem_ty = elem_ty,
        .elems = try elems.toOwnedSlice(arena.allocator()),
    };
}

fn parseArrayGet(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!ArrayGet {
    if (items.len != 3) return error.UnsupportedNode;
    const arr = try arena.allocator().create(Expr);
    arr.* = try parseExpr(arena, items[1]);
    const idx = try arena.allocator().create(Expr);
    idx.* = try parseExpr(arena, items[2]);
    return .{ .arr = arr, .idx = idx };
}

fn parseArrayLength(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!ArrayLength {
    if (items.len != 2) return error.UnsupportedNode;
    const arr = try arena.allocator().create(Expr);
    arr.* = try parseExpr(arena, items[1]);
    return .{ .arr = arr };
}

fn parseArraySet(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!ArraySet {
    if (items.len != 4) return error.UnsupportedNode;
    const arr = try arena.allocator().create(Expr);
    arr.* = try parseExpr(arena, items[1]);
    const idx = try arena.allocator().create(Expr);
    idx.* = try parseExpr(arena, items[2]);
    const value = try arena.allocator().create(Expr);
    value.* = try parseExpr(arena, items[3]);
    return .{ .arr = arr, .idx = idx, .value = value };
}

fn parseArrayMake(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!ArrayMake {
    // (array-make <size-int-literal> <init-expr> (ty <type-expr>))
    if (items.len != 4) return error.UnsupportedNode;
    const size = try expectU32(items[1]);
    const init = try arena.allocator().create(Expr);
    init.* = try parseExpr(arena, items[2]);
    const ty_items = try expectList(items[3]);
    if (ty_items.len != 2) return error.MalformedTypeExpr;
    try expectAtomValue(ty_items[0], "ty");
    const elem_ty = try parseTypeExpr(arena, ty_items[1]);
    return .{ .elem_ty = elem_ty, .size = size, .init = init };
}

const LocatedItems = struct {
    items: []const *const Sexp,
    loc: Loc,
};

fn parseLocatedExpr(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!Expr {
    if (items.len != 3) return error.MalformedLoc;
    const loc = try parseLoc(arena, items[1]);
    const child = try parseExpr(arena, items[2]);
    return applyLoc(child, loc);
}

fn splitTrailingLoc(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!LocatedItems {
    if (items.len == 0) return error.UnexpectedAtom;
    const last_items = expectList(items[items.len - 1]) catch return .{ .items = items, .loc = Loc.unknown };
    if (last_items.len == 0) return .{ .items = items, .loc = Loc.unknown };
    const last_tag = expectAtom(last_items[0]) catch return .{ .items = items, .loc = Loc.unknown };
    if (!std.mem.eql(u8, last_tag, "loc")) return .{ .items = items, .loc = Loc.unknown };
    return .{
        .items = items[0 .. items.len - 1],
        .loc = try parseLocItems(arena, last_items),
    };
}

fn parseLoc(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!Loc {
    return parseLocItems(arena, try expectList(node));
}

fn parseLocItems(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!Loc {
    if (items.len != 6) return error.MalformedLoc;
    try expectAtomValue(items[0], "loc");
    return .{
        .file = try dupeAtom(arena, items[1]),
        .line = try expectU32(items[2]),
        .col = try expectU32(items[3]),
        .end_line = try expectU32(items[4]),
        .end_col = try expectU32(items[5]),
    };
}

fn applyLoc(expr: Expr, loc: Loc) Expr {
    return switch (expr) {
        .Lambda => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .Lambda = copy };
        },
        .Constant => expr,
        .App => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .App = copy };
        },
        .Let => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .Let = copy };
        },
        .LetRecGroup => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .LetRecGroup = copy };
        },
        .Assert => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .Assert = copy };
        },
        .If => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .If = copy };
        },
        .Prim => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .Prim = copy };
        },
        .Var => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .Var = copy };
        },
        .Ctor => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .Ctor = copy };
        },
        .Match => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .Match = copy };
        },
        .Tuple => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .Tuple = copy };
        },
        .TupleProj => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .TupleProj = copy };
        },
        .Record => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .Record = copy };
        },
        .RecordField => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .RecordField = copy };
        },
        .RecordUpdate => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .RecordUpdate = copy };
        },
        .FieldSet => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .FieldSet = copy };
        },
        .ArrayLit => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .ArrayLit = copy };
        },
        .ArrayGet => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .ArrayGet = copy };
        },
        .ArrayLength => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .ArrayLength = copy };
        },
        .ArraySet => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .ArraySet = copy };
        },
        .ArrayMake => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .ArrayMake = copy };
        },
        .RefMake => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .RefMake = copy };
        },
        .RefGet => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .RefGet = copy };
        },
        .RefSet => |value| blk: {
            var copy = value;
            copy.loc = loc;
            break :blk .{ .RefSet = copy };
        },
    };
}

fn parseAssert(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!AssertExpr {
    if (items.len != 2) return error.MalformedAssert;
    const condition = try arena.allocator().create(Expr);
    condition.* = try parseExpr(arena, items[1]);
    return .{ .condition = condition };
}

fn parseLetRecGroupExpr(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!LetRecGroupExpr {
    if (items.len != 3) return error.MalformedLet;
    const body = try arena.allocator().create(Expr);
    body.* = try parseExpr(arena, items[2]);
    return .{
        .bindings = try parseLetRecBindings(arena, items[1]),
        .body = body,
    };
}

fn parseLetRecBindings(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError![]const LetRecBinding {
    const items = try expectList(node);
    if (items.len < 2) return error.MalformedLet;
    try expectAtomValue(items[0], "bindings");
    var bindings = std.ArrayList(LetRecBinding).empty;
    errdefer bindings.deinit(arena.allocator());
    for (items[1..]) |binding_node| {
        try bindings.append(arena.allocator(), try parseLetRecBinding(arena, binding_node));
    }
    return bindings.toOwnedSlice(arena.allocator());
}

fn parseLetRecBinding(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!LetRecBinding {
    const items = try expectList(node);
    if (items.len != 4) return error.MalformedLet;
    try expectAtomValue(items[0], "binding");

    const name_items = try expectList(items[1]);
    if (name_items.len != 2) return error.MalformedLet;
    try expectAtomValue(name_items[0], "name");

    const body_items = try expectList(items[3]);
    if (body_items.len != 2) return error.MalformedLet;
    try expectAtomValue(body_items[0], "body");

    const params_with_types = try parseLetRecParams(arena, items[2]);

    return .{
        .name = try dupeAtom(arena, name_items[1]),
        .params = params_with_types.names,
        .param_types = params_with_types.types,
        .body = try parseExpr(arena, body_items[1]),
    };
}

const LetRecParams = struct {
    names: []const []const u8,
    types: []const ?TypeExpr,
};

fn parseLetRecParams(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!LetRecParams {
    const params_items = try expectList(node);
    if (params_items.len == 0) return error.MalformedLet;
    try expectAtomValue(params_items[0], "params");
    var names = std.ArrayList([]const u8).empty;
    errdefer names.deinit(arena.allocator());
    var types = std.ArrayList(?TypeExpr).empty;
    errdefer types.deinit(arena.allocator());
    for (params_items[1..]) |param_node| {
        const parsed = try parseLambdaParam(arena, param_node);
        try names.append(arena.allocator(), parsed.name);
        try types.append(arena.allocator(), parsed.ty);
    }
    return .{
        .names = try names.toOwnedSlice(arena.allocator()),
        .types = try types.toOwnedSlice(arena.allocator()),
    };
}

fn parseTuple(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!Tuple {
    if (items.len != 2) return error.MalformedTuple;
    const item_nodes = try expectList(items[1]);
    if (item_nodes.len == 0) return error.MalformedTuple;
    try expectAtomValue(item_nodes[0], "items");
    var values = std.ArrayList(Expr).empty;
    errdefer values.deinit(arena.allocator());
    for (item_nodes[1..]) |item_node| {
        try values.append(arena.allocator(), try parseExpr(arena, item_node));
    }
    return .{ .items = try values.toOwnedSlice(arena.allocator()) };
}

fn parseTupleProj(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!TupleProj {
    if (items.len != 3) return error.MalformedTuple;
    const tuple_expr = try arena.allocator().create(Expr);
    tuple_expr.* = try parseExpr(arena, items[1]);
    const index_items = try expectList(items[2]);
    if (index_items.len != 2) return error.MalformedTuple;
    try expectAtomValue(index_items[0], "index");
    const raw_index = try expectInteger(index_items[1]);
    if (raw_index < 0) return error.MalformedTuple;
    return .{ .tuple_expr = tuple_expr, .index = @intCast(raw_index) };
}

fn parseRecord(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!Record {
    if (items.len != 2) return error.MalformedRecord;
    return .{ .fields = try parseRecordExprFields(arena, items[1]) };
}

fn parseRecordField(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!RecordField {
    if (items.len != 3) return error.MalformedRecord;
    const record_expr = try arena.allocator().create(Expr);
    record_expr.* = try parseExpr(arena, items[1]);
    return .{
        .record_expr = record_expr,
        .field_name = try dupeAtom(arena, items[2]),
    };
}

fn parseRecordUpdate(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!RecordUpdate {
    if (items.len != 3) return error.MalformedRecord;
    const base_expr = try arena.allocator().create(Expr);
    base_expr.* = try parseExpr(arena, items[1]);
    return .{
        .base_expr = base_expr,
        .fields = try parseRecordExprFields(arena, items[2]),
    };
}

fn parseFieldSet(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!FieldSet {
    if (items.len != 4) return error.MalformedRecord;
    const record_expr = try arena.allocator().create(Expr);
    record_expr.* = try parseExpr(arena, items[1]);
    const value = try arena.allocator().create(Expr);
    value.* = try parseExpr(arena, items[3]);
    return .{
        .record_expr = record_expr,
        .field_name = try dupeAtom(arena, items[2]),
        .value = value,
    };
}

fn parseRecordExprFields(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError![]const RecordExprField {
    const items = try expectList(node);
    if (items.len != 2) return error.MalformedRecord;
    try expectAtomValue(items[0], "fields");
    const field_nodes = try expectList(items[1]);
    var fields = std.ArrayList(RecordExprField).empty;
    errdefer fields.deinit(arena.allocator());
    for (field_nodes) |field_node| {
        const field_items = try expectList(field_node);
        if (field_items.len != 2) return error.MalformedRecord;
        try fields.append(arena.allocator(), .{
            .name = try dupeAtom(arena, field_items[0]),
            .value = try parseExpr(arena, field_items[1]),
        });
    }
    return fields.toOwnedSlice(arena.allocator());
}

fn parseLambda(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!Lambda {
    if (items.len != 3) return error.MalformedLambda;

    const param_nodes = try expectList(items[1]);
    var params = std.ArrayList([]const u8).empty;
    errdefer params.deinit(arena.allocator());
    var param_types = std.ArrayList(?TypeExpr).empty;
    errdefer param_types.deinit(arena.allocator());
    for (param_nodes) |param_node| {
        const parsed = try parseLambdaParam(arena, param_node);
        try params.append(arena.allocator(), parsed.name);
        try param_types.append(arena.allocator(), parsed.ty);
    }

    const body = try arena.allocator().create(Expr);
    body.* = try parseExpr(arena, items[2]);

    return .{
        .params = try params.toOwnedSlice(arena.allocator()),
        .param_types = try param_types.toOwnedSlice(arena.allocator()),
        .body = body,
    };
}

const LambdaParam = struct {
    name: []const u8,
    ty: ?TypeExpr,
};

/// Parses one lambda/binding parameter as either:
///   - wire <= 1.2 legacy: a bare atom (`s` or `_`)
///   - wire 1.3: a list `(name (ty <type-expr>))` where `<type-expr>` may be
///     `(any)` to mean "type unknown, fall back to the lowerer heuristics".
fn parseLambdaParam(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!LambdaParam {
    if (node.atomLike()) |atom| {
        return .{
            .name = try arena.allocator().dupe(u8, atom),
            .ty = null,
        };
    }
    const items = try expectList(node);
    if (items.len != 2) return error.MalformedLambda;
    const name = try dupeAtom(arena, items[0]);
    const ty_items = try expectList(items[1]);
    if (ty_items.len != 2) return error.MalformedLambda;
    try expectAtomValue(ty_items[0], "ty");
    // `(any)` is a sentinel for "no type information"; record it as null so
    // the Core IR lowerer falls back to its existing heuristics.
    const ty_payload = ty_items[1];
    if (ty_payload.atomLike() == null) {
        const payload_items = try expectList(ty_payload);
        if (payload_items.len == 1) {
            const tag = try expectAtom(payload_items[0]);
            if (std.mem.eql(u8, tag, "any")) {
                return .{ .name = name, .ty = null };
            }
        }
    }
    return .{
        .name = name,
        .ty = try parseTypeExpr(arena, ty_payload),
    };
}

fn parseApp(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!App {
    if (items.len < 2) return error.MalformedApp;

    const callee = try arena.allocator().create(Expr);
    callee.* = try parseExpr(arena, items[1]);

    var args = std.ArrayList(Expr).empty;
    errdefer args.deinit(arena.allocator());
    for (items[2..]) |arg_node| {
        try args.append(arena.allocator(), try parseExpr(arena, arg_node));
    }

    return .{
        .callee = callee,
        .args = try args.toOwnedSlice(arena.allocator()),
    };
}

fn parseLetExpr(arena: *std.heap.ArenaAllocator, items: []const *const Sexp, is_rec: bool) BridgeError!LetExpr {
    if (items.len != 4) return error.MalformedLet;

    const value = try arena.allocator().create(Expr);
    value.* = try parseExpr(arena, items[2]);

    const body = try arena.allocator().create(Expr);
    body.* = try parseExpr(arena, items[3]);

    return .{
        .name = try dupeAtom(arena, items[1]),
        .value = value,
        .body = body,
        .is_rec = is_rec,
    };
}

fn parseIf(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!IfExpr {
    if (items.len != 4) return error.MalformedIf;

    const cond = try arena.allocator().create(Expr);
    cond.* = try parseExpr(arena, items[1]);
    const then_branch = try arena.allocator().create(Expr);
    then_branch.* = try parseExpr(arena, items[2]);
    const else_branch = try arena.allocator().create(Expr);
    else_branch.* = try parseExpr(arena, items[3]);

    return .{
        .cond = cond,
        .then_branch = then_branch,
        .else_branch = else_branch,
    };
}

fn parsePrim(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!Prim {
    if (items.len < 2) return error.MalformedPrim;

    var args = std.ArrayList(Expr).empty;
    errdefer args.deinit(arena.allocator());
    for (items[2..]) |arg_node| {
        try args.append(arena.allocator(), try parseExpr(arena, arg_node));
    }

    return .{
        .op = try dupeAtom(arena, items[1]),
        .args = try args.toOwnedSlice(arena.allocator()),
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

fn parseMatch(arena: *std.heap.ArenaAllocator, items: []const *const Sexp) BridgeError!Match {
    if (items.len < 3) return error.MalformedMatch;

    const scrutinee = try arena.allocator().create(Expr);
    scrutinee.* = try parseExpr(arena, items[1]);

    var arms = std.ArrayList(Arm).empty;
    errdefer arms.deinit(arena.allocator());
    for (items[2..]) |arm_node| {
        try arms.append(arena.allocator(), try parseArm(arena, arm_node));
    }

    return .{
        .scrutinee = scrutinee,
        .arms = try arms.toOwnedSlice(arena.allocator()),
    };
}

fn parseArm(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!Arm {
    const items = try expectList(node);
    if (items.len != 3) return error.MalformedMatch;
    try expectAtomValue(items[0], "case");

    var guard: ?*const Expr = null;
    const body = try arena.allocator().create(Expr);
    if (items[2].atomLike() == null) {
        const body_items = try expectList(items[2]);
        if (body_items.len == 3) {
            const body_tag = try expectAtom(body_items[0]);
            if (std.mem.eql(u8, body_tag, "when_guard")) {
                const guard_ptr = try arena.allocator().create(Expr);
                guard_ptr.* = try parseExpr(arena, body_items[1]);
                guard = guard_ptr;
                body.* = try parseExpr(arena, body_items[2]);
            } else {
                body.* = try parseExpr(arena, items[2]);
            }
        } else {
            body.* = try parseExpr(arena, items[2]);
        }
    } else {
        body.* = try parseExpr(arena, items[2]);
    }

    return .{
        .pattern = try parsePattern(arena, items[1]),
        .guard = guard,
        .body = body,
    };
}

fn parsePattern(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!Pattern {
    if (node.atomLike()) |atom| {
        if (std.mem.eql(u8, atom, "_")) return .Wildcard;
        return .{ .Var = try arena.allocator().dupe(u8, atom) };
    }

    const items = try expectList(node);
    if (items.len == 0) return error.MalformedPattern;

    const tag = try expectAtom(items[0]);
    if (std.mem.eql(u8, tag, "wildcard")) {
        if (items.len != 1) return error.MalformedPattern;
        return .Wildcard;
    }
    if (std.mem.eql(u8, tag, "var")) {
        if (items.len != 2) return error.MalformedPattern;
        const name = try dupeAtom(arena, items[1]);
        if (std.mem.eql(u8, name, "_")) return .Wildcard;
        return .{ .Var = name };
    }
    if (std.mem.eql(u8, tag, "const-pattern")) {
        if (items.len != 2) return error.MalformedPattern;
        return .{ .Const = try parsePatternConstant(arena, items[1]) };
    }
    if (std.mem.eql(u8, tag, "or-pattern")) {
        if (items.len < 2) return error.MalformedPattern;
        var alternatives = std.ArrayList(Pattern).empty;
        errdefer alternatives.deinit(arena.allocator());
        for (items[1..]) |alternative_node| {
            try alternatives.append(arena.allocator(), try parsePattern(arena, alternative_node));
        }
        return .{ .Or = try alternatives.toOwnedSlice(arena.allocator()) };
    }
    if (std.mem.eql(u8, tag, "alias-pattern")) {
        if (items.len != 3) return error.MalformedPattern;
        const child = try arena.allocator().create(Pattern);
        child.* = try parsePattern(arena, items[1]);
        return .{ .Alias = .{
            .pattern = child,
            .name = try dupeAtom(arena, items[2]),
        } };
    }
    if (std.mem.eql(u8, tag, "ctor")) {
        if (items.len < 2) return error.MalformedPattern;
        var args = std.ArrayList(Pattern).empty;
        errdefer args.deinit(arena.allocator());
        for (items[2..]) |arg_node| {
            try args.append(arena.allocator(), try parsePattern(arena, arg_node));
        }
        return .{ .Ctor = .{
            .name = try dupeAtom(arena, items[1]),
            .args = try args.toOwnedSlice(arena.allocator()),
        } };
    }
    if (std.mem.eql(u8, tag, "tuple_pattern")) {
        var patterns = std.ArrayList(Pattern).empty;
        errdefer patterns.deinit(arena.allocator());
        for (items[1..]) |item_node| {
            try patterns.append(arena.allocator(), try parsePattern(arena, item_node));
        }
        return .{ .Tuple = try patterns.toOwnedSlice(arena.allocator()) };
    }
    if (std.mem.eql(u8, tag, "record_pattern")) {
        if (items.len != 2) return error.MalformedPattern;
        const fields_items = try expectList(items[1]);
        if (fields_items.len != 2) return error.MalformedPattern;
        try expectAtomValue(fields_items[0], "fields");
        const field_nodes = try expectList(fields_items[1]);
        var fields = std.ArrayList(RecordPatternField).empty;
        errdefer fields.deinit(arena.allocator());
        for (field_nodes) |field_node| {
            const field_items = try expectList(field_node);
            if (field_items.len != 2) return error.MalformedPattern;
            try fields.append(arena.allocator(), .{
                .name = try dupeAtom(arena, field_items[0]),
                .pattern = try parsePattern(arena, field_items[1]),
            });
        }
        return .{ .Record = try fields.toOwnedSlice(arena.allocator()) };
    }
    return error.MalformedPattern;
}

fn parsePatternConstant(arena: *std.heap.ArenaAllocator, node: *const Sexp) BridgeError!PatternConstant {
    const items = try expectList(node);
    if (items.len != 2) return error.MalformedConstant;
    const tag = try expectAtom(items[0]);
    if (std.mem.eql(u8, tag, "const-int")) return .{ .Int = try expectInteger(items[1]) };
    if (std.mem.eql(u8, tag, "const-string")) return .{ .String = try arena.allocator().dupe(u8, try expectAtom(items[1])) };
    if (std.mem.eql(u8, tag, "const-char")) return .{ .Char = try expectInteger(items[1]) };
    return error.MalformedConstant;
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

fn expectU32(node: *const Sexp) BridgeError!u32 {
    const value = try expectInteger(node);
    if (value < 0 or value > std.math.maxInt(u32)) return error.MalformedLoc;
    return @intCast(value);
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

    const module = try parseModule(&arena, "(zxcaml-cir 0.6 (module))");
    try std.testing.expectEqual(@as(usize, 0), module.decls.len);
}

test "parse single int constant module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(&arena, "(zxcaml-cir 0.6 (module (let entrypoint (lambda (_) (const-int 0)))))");
    try std.testing.expectEqual(@as(usize, 1), module.decls.len);

    const decl = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => unreachable,
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

test "wire 1.2 loc fields populate top-level expression loc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(&arena, "(zxcaml-cir 1.2 (module (let entrypoint (lambda (_) (const-int 0) (loc \"tests/golden/dx2_wire.ml\" 3 4 3 18)))))");
    const decl = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => unreachable,
    };
    const lambda = switch (decl.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(!lambda.loc.isUnknown());
    try std.testing.expectEqualStrings("tests/golden/dx2_wire.ml", lambda.loc.file);
    try std.testing.expectEqual(@as(u32, 3), lambda.loc.line);
    try std.testing.expectEqual(@as(u32, 4), lambda.loc.col);
    try std.testing.expectEqual(@as(u32, 3), lambda.loc.end_line);
    try std.testing.expectEqual(@as(u32, 18), lambda.loc.end_col);
}

test "wire_back_compat compat_1_1 loc_unknown accepts missing loc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(&arena, "(zxcaml-cir 1.1 (module (let entrypoint (lambda (_) (const-int 0)))))");
    const decl = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => unreachable,
    };
    const lambda = switch (decl.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(lambda.loc.isUnknown());
}

test "parse top-level and nested let expressions with variable references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(
        &arena,
        "(zxcaml-cir 0.6 (module (let x (const-int 1)) (let entrypoint (lambda (_input) (let y (const-int 7) (var x))))))",
    );
    try std.testing.expectEqual(@as(usize, 2), module.decls.len);

    const top_level = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => unreachable,
    };
    try std.testing.expectEqualStrings("x", top_level.name);
    _ = switch (top_level.body) {
        .Constant => |value| value,
        else => return error.TestUnexpectedResult,
    };

    const entrypoint = switch (module.decls[1]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => unreachable,
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

test "parse type declaration sexp nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(
        &arena,
        "(zxcaml-cir 0.6 (module (type_decl (name tree) (params 'a) (recursive true) (variants ((Leaf (payload_types)) (Node (payload_types (recursive-ref tree (type-var 'a)) (recursive-ref tree (type-var 'a))))))) (let entrypoint (lambda (_) (const-int 0)))))",
    );
    try std.testing.expectEqual(@as(usize, 1), module.type_decls.len);
    try std.testing.expectEqual(@as(usize, 1), module.decls.len);

    const type_decl = module.type_decls[0];
    try std.testing.expectEqualStrings("tree", type_decl.name);
    try std.testing.expectEqual(@as(usize, 1), type_decl.params.len);
    try std.testing.expectEqualStrings("'a", type_decl.params[0]);
    try std.testing.expect(type_decl.is_recursive);
    try std.testing.expectEqual(@as(usize, 2), type_decl.variants.len);
    try std.testing.expectEqualStrings("Leaf", type_decl.variants[0].name);
    try std.testing.expectEqual(@as(usize, 0), type_decl.variants[0].payload_types.len);
    try std.testing.expectEqualStrings("Node", type_decl.variants[1].name);
    try std.testing.expectEqual(@as(usize, 2), type_decl.variants[1].payload_types.len);

    const left_ref = switch (type_decl.variants[1].payload_types[0]) {
        .RecursiveRef => |ref| ref,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("tree", left_ref.name);
    const left_param = switch (left_ref.args[0]) {
        .TypeVar => |name| name,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("'a", left_param);
}

test "parse external declaration sexp nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(
        &arena,
        "(zxcaml-cir 1.0 (module (external (name \"sol_log\") (type (arrow bytes unit)) (symbol \"sol_log_\"))))",
    );
    try std.testing.expectEqual(@as(usize, 0), module.decls.len);
    try std.testing.expectEqual(@as(usize, 1), module.externals.len);

    const external = module.externals[0];
    try std.testing.expectEqualStrings("sol_log", external.name);
    try std.testing.expectEqualStrings("sol_log_", external.symbol);

    const arrow = switch (external.ty) {
        .Arrow => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const arg = switch (arrow.arg.*) {
        .TypeRef => |ref| ref,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("bytes", arg.name);
    const result = switch (arrow.result.*) {
        .TypeRef => |ref| ref,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("unit", result.name);
}

test "malformed sexp cases are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.UnmatchedParen, parseModule(&arena, "(zxcaml-cir 0.6 (module)"));
    try std.testing.expectError(error.BadAtom, parseModule(&arena, "(zxcaml-cir 0.6 (module bad@atom))"));
}

test "version mismatch is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.WireFormatVersionMismatch, parseModule(&arena, "(zxcaml-cir 0.3 (module))"));
}

test "empty stdin is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.EmptyInput, parseModule(&arena, ""));
}

test "parse constructor expressions and string payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(&arena, "(zxcaml-cir 0.6 (module (let some_value (ctor Some (const-int 1))) (let error_value (ctor Error (const-string \"oops\")))))");
    try std.testing.expectEqual(@as(usize, 2), module.decls.len);

    const some_decl = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => unreachable,
    };
    const some_ctor = switch (some_decl.body) {
        .Ctor => |ctor| ctor,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Some", some_ctor.name);
    try std.testing.expectEqual(@as(usize, 1), some_ctor.args.len);

    const error_decl = switch (module.decls[1]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => unreachable,
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

test "parse basic match expressions and patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(
        &arena,
        "(zxcaml-cir 0.6 (module (let entrypoint (lambda (_input) (match (ctor Some (const-int 1)) (case (ctor Some (var x)) (var x)) (case (ctor None) (const-int 0)) (case _ (const-int 9)))))))",
    );
    const entrypoint = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => unreachable,
    };
    const lambda = switch (entrypoint.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const match_expr = switch (lambda.body.*) {
        .Match => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 3), match_expr.arms.len);

    const some_pattern = switch (match_expr.arms[0].pattern) {
        .Ctor => |pattern| pattern,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Some", some_pattern.name);
    const payload_pattern = switch (some_pattern.args[0]) {
        .Var => |name| name,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("x", payload_pattern);

    _ = switch (match_expr.arms[1].pattern) {
        .Ctor => |pattern| pattern,
        else => return error.TestUnexpectedResult,
    };
    _ = switch (match_expr.arms[2].pattern) {
        .Wildcard => {},
        else => return error.TestUnexpectedResult,
    };
}

test "parse quoted list constructor expressions and patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(
        &arena,
        "(zxcaml-cir 0.6 (module (let entrypoint (lambda (_input) (match (ctor \"::\" (const-int 1) (ctor \"[]\")) (case (ctor \"::\" (var x) (var rest)) (var x)) (case (ctor \"[]\") (const-int 0)))))))",
    );
    const entrypoint = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => unreachable,
    };
    const lambda = switch (entrypoint.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const match_expr = switch (lambda.body.*) {
        .Match => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const cons_expr = switch (match_expr.scrutinee.*) {
        .Ctor => |ctor| ctor,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("::", cons_expr.name);
    try std.testing.expectEqual(@as(usize, 2), cons_expr.args.len);
    const nil_tail = switch (cons_expr.args[1]) {
        .Ctor => |ctor| ctor,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("[]", nil_tail.name);

    const cons_pattern = switch (match_expr.arms[0].pattern) {
        .Ctor => |pattern| pattern,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("::", cons_pattern.name);
    try std.testing.expectEqual(@as(usize, 2), cons_pattern.args.len);
    const nil_pattern = switch (match_expr.arms[1].pattern) {
        .Ctor => |pattern| pattern,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("[]", nil_pattern.name);
}

test "parse nested constructor patterns and when guards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(
        &arena,
        "(zxcaml-cir 0.6 (module (let entrypoint (lambda (_input) (match (ctor Some (ctor Some (const-int 42))) (case (ctor Some (ctor Some (var v))) (when_guard (prim \">\" (var v) (const-int 40)) (var v))) (case (ctor None) (const-int 0)))))))",
    );
    const entrypoint = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => unreachable,
    };
    const lambda = switch (entrypoint.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const match_expr = switch (lambda.body.*) {
        .Match => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const outer_pattern = switch (match_expr.arms[0].pattern) {
        .Ctor => |pattern| pattern,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Some", outer_pattern.name);
    const inner_pattern = switch (outer_pattern.args[0]) {
        .Ctor => |pattern| pattern,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Some", inner_pattern.name);
    const guard = match_expr.arms[0].guard orelse return error.TestUnexpectedResult;
    const prim = switch (guard.*) {
        .Prim => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(">", prim.op);
}

test "parse tuple and record v0.7 sexp nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(
        &arena,
        "(zxcaml-cir 1.1 (module (record_type_decl (name person) (params) (fields ((name (type-ref string)) (age (type-ref int))))) (tuple_type_decl (name pair) (params) (items (type-ref int) (type-ref bool))) (type_alias_decl (name int_list) (params) (rhs (type-ref list (type-ref int)))) (let t (tuple (items (const-int 1) (ctor true) (const-int 42)))) (let r (record (fields ((name (const-string \"alice\")) (age (const-int 30)))))) (let u (record_update (var r) (fields ((age (tuple_project (var t) (index 0)))))))))",
    );

    try std.testing.expectEqual(@as(usize, 1), module.record_type_decls.len);
    try std.testing.expectEqualStrings("person", module.record_type_decls[0].name);
    try std.testing.expectEqual(@as(usize, 2), module.record_type_decls[0].fields.len);
    try std.testing.expectEqual(@as(usize, 1), module.tuple_type_decls.len);
    try std.testing.expectEqual(@as(usize, 1), module.type_alias_decls.len);
    try std.testing.expectEqualStrings("int_list", module.type_alias_decls[0].name);
    try std.testing.expectEqual(@as(usize, 3), module.decls.len);

    const tuple_decl = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => unreachable,
    };
    const tuple = switch (tuple_decl.body) {
        .Tuple => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 3), tuple.items.len);
    const update_decl = switch (module.decls[2]) {
        .Let => |value| value,
        .LetRecGroup => unreachable,
    };
    const update = switch (update_decl.body) {
        .RecordUpdate => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("age", update.fields[0].name);
}

test "parse record account attribute marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(
        &arena,
        "(zxcaml-cir 1.0 (module (record_type_decl (name counter) (params) (fields ((count (type-ref int)))) (account_attr)) (record_type_decl (name metadata) (params) (fields ((authority (type-ref bytes))))) (let entrypoint (lambda (_) (const-int 0)))))",
    );

    try std.testing.expectEqual(@as(usize, 2), module.record_type_decls.len);
    try std.testing.expectEqualStrings("counter", module.record_type_decls[0].name);
    try std.testing.expect(module.record_type_decls[0].is_account);
    try std.testing.expectEqualStrings("metadata", module.record_type_decls[1].name);
    try std.testing.expect(!module.record_type_decls[1].is_account);
}

test "parse account type references and syscall apps in v0.8 sexp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(
        &arena,
        "(zxcaml-cir 0.8 (module (record_type_decl (name account) (params) (fields ((key (type-ref bytes)) (lamports (type-ref int)) (data (type-ref bytes)) (owner (type-ref bytes)) (is_signer (type-ref bool)) (is_writable (type-ref bool)) (executable (type-ref bool))))) (record_type_decl (name holder) (params) (fields ((acct (type-ref account))))) (let entrypoint (lambda (acct) (app (var Syscall.sol_log_64) (field_access (var acct) lamports) (const-int 0) (const-int 0) (const-int 0) (const-int 0))))))",
    );

    try std.testing.expectEqual(@as(usize, 2), module.record_type_decls.len);
    try std.testing.expectEqualStrings("account", module.record_type_decls[0].name);
    try std.testing.expectEqual(@as(usize, 7), module.record_type_decls[0].fields.len);
    const holder_field_ty = switch (module.record_type_decls[1].fields[0].ty) {
        .TypeRef => |ref| ref,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("account", holder_field_ty.name);

    const entrypoint = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => unreachable,
    };
    const lambda = switch (entrypoint.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const app = switch (lambda.body.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const callee = switch (app.callee.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Syscall.sol_log_64", callee.name);
}

test "parse CPI type references and function apps in v0.9 sexp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseModule(
        &arena,
        "(zxcaml-cir 0.9 (module (record_type_decl (name account_meta) (params) (fields ((pubkey (type-ref bytes)) (is_writable (type-ref bool)) (is_signer (type-ref bool))))) (record_type_decl (name instruction) (params) (fields ((program_id (type-ref bytes)) (accounts (type-ref array (type-ref account_meta))) (data (type-ref bytes))))) (let entrypoint (lambda (ix seeds) (let _ (app (var invoke_signed) (var ix) (var seeds)) (app (var create_program_address) (var seeds) (field_access (var ix) program_id)))))))",
    );

    try std.testing.expectEqual(@as(usize, 2), module.record_type_decls.len);
    try std.testing.expectEqualStrings("account_meta", module.record_type_decls[0].name);
    try std.testing.expectEqualStrings("instruction", module.record_type_decls[1].name);

    const accounts_ty = switch (module.record_type_decls[1].fields[1].ty) {
        .TypeRef => |ref| ref,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("array", accounts_ty.name);
    const account_meta_ty = switch (accounts_ty.args[0]) {
        .TypeRef => |ref| ref,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("account_meta", account_meta_ty.name);

    const entrypoint = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => unreachable,
    };
    const lambda = switch (entrypoint.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const let_expr = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const invoke_app = switch (let_expr.value.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const invoke_callee = switch (invoke_app.callee.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("invoke_signed", invoke_callee.name);
    const pda_app = switch (let_expr.body.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const pda_callee = switch (pda_app.callee.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("create_program_address", pda_callee.name);
}
