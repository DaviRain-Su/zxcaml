//! Typed Zig mirror for the M1 P3 ZxCaml frontend S-expression format.
//!
//! RESPONSIBILITIES:
//! - Re-export the typed mirror definitions from `ttree_types.zig`.
//! - Re-export the wire-format decoding entry points from `ttree_decode.zig`.
//! - Preserve the stable `frontend_bridge/ttree.zig` import surface.

const ttree_types = @import("ttree_types.zig");
const ttree_decode = @import("ttree_decode.zig");

pub const expected_wire_version = ttree_decode.expected_wire_version;

// Typed mirror definitions (`ttree_types.zig`).
pub const Loc = ttree_types.Loc;
pub const Module = ttree_types.Module;
pub const Decl = ttree_types.Decl;
pub const LetDecl = ttree_types.LetDecl;
pub const LetRecBinding = ttree_types.LetRecBinding;
pub const LetRecGroupDecl = ttree_types.LetRecGroupDecl;
pub const ExternalDecl = ttree_types.ExternalDecl;
pub const ExternalTypeExpr = ttree_types.ExternalTypeExpr;
pub const ExternalTypeRef = ttree_types.ExternalTypeRef;
pub const ExternalTypeArrow = ttree_types.ExternalTypeArrow;
pub const TypeDecl = ttree_types.TypeDecl;
pub const TypeVariant = ttree_types.TypeVariant;
pub const TupleTypeDecl = ttree_types.TupleTypeDecl;
pub const RecordTypeDecl = ttree_types.RecordTypeDecl;
pub const TypeAliasDecl = ttree_types.TypeAliasDecl;
pub const RecordTypeField = ttree_types.RecordTypeField;
pub const TypeExpr = ttree_types.TypeExpr;
pub const TypeRef = ttree_types.TypeRef;
pub const Expr = ttree_types.Expr;
pub const RefMake = ttree_types.RefMake;
pub const RefGet = ttree_types.RefGet;
pub const RefSet = ttree_types.RefSet;
pub const ArrayLit = ttree_types.ArrayLit;
pub const ArrayGet = ttree_types.ArrayGet;
pub const ArrayLength = ttree_types.ArrayLength;
pub const ArraySet = ttree_types.ArraySet;
pub const ArrayMake = ttree_types.ArrayMake;
pub const Lambda = ttree_types.Lambda;
pub const App = ttree_types.App;
pub const LetExpr = ttree_types.LetExpr;
pub const LetRecGroupExpr = ttree_types.LetRecGroupExpr;
pub const AssertExpr = ttree_types.AssertExpr;
pub const IfExpr = ttree_types.IfExpr;
pub const Prim = ttree_types.Prim;
pub const Var = ttree_types.Var;
pub const Ctor = ttree_types.Ctor;
pub const Tuple = ttree_types.Tuple;
pub const TupleProj = ttree_types.TupleProj;
pub const Record = ttree_types.Record;
pub const RecordExprField = ttree_types.RecordExprField;
pub const RecordField = ttree_types.RecordField;
pub const RecordUpdate = ttree_types.RecordUpdate;
pub const FieldSet = ttree_types.FieldSet;
pub const Match = ttree_types.Match;
pub const Arm = ttree_types.Arm;
pub const Pattern = ttree_types.Pattern;
pub const PatternConstant = ttree_types.PatternConstant;
pub const AliasPattern = ttree_types.AliasPattern;
pub const CtorPattern = ttree_types.CtorPattern;
pub const RecordPatternField = ttree_types.RecordPatternField;
pub const Constant = ttree_types.Constant;

// Wire-format decoding (`ttree_decode.zig`).
pub const BridgeError = ttree_decode.BridgeError;
pub const parseModule = ttree_decode.parseModule;
pub const writeParseError = ttree_decode.writeParseError;

test {
    _ = ttree_types;
    _ = ttree_decode;
}
