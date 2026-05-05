//! Single-source diagnostic-code explanation registry.
//!
//! The catalog mirrors `docs/diagnostics.md` without editing that frozen
//! documentation surface.  Each entry provides the three user-facing pieces
//! required by `omlz check --explain <CODE>`: title, description, and fix.

const std = @import("std");

pub const Entry = struct {
    code: []const u8,
    title: []const u8,
    description: []const u8,
    fix: []const u8,
};

pub const entries = [_]Entry{
    .{
        .code = "E0001",
        .title = "OCaml frontend parser or type-checker error",
        .description = "The upstream OCaml frontend rejected the source before ZxCaml lowering started. This covers syntax errors, unbound names, type mismatches, and other parser/type-checker diagnostics surfaced by zxc-frontend.",
        .fix = "Fix the OCaml syntax or type error at the reported span; for type mismatches, make the annotated type and expression type agree.",
    },
    .{
        .code = "E0002",
        .title = "Generic ZxCaml subset rejection",
        .description = "The program uses an OCaml construct that is not currently in the supported ZxCaml subset. Newer tailored subset diagnostics may report a more specific E0010-E0024 code for the same family.",
        .fix = "Rewrite the construct using supported OCaml subset features such as let bindings, ADTs, records, pattern matching, lists, and pure functions.",
    },
    .{
        .code = "E0003",
        .title = "Internal frontend bridge fallback",
        .description = "The OCaml-to-Zig bridge hit an unexpected internal failure or malformed frontend envelope. This is reserved for failures that are not ordinary user syntax, type, or subset errors.",
        .fix = "Re-run with the same source and capture the full command/output; reduce the input if possible and report the bridge failure.",
    },
    .{
        .code = "E0010",
        .title = "Polymorphic variants are outside the subset",
        .description = "OCaml polymorphic variant nodes cannot currently be represented in the ZxCaml Core IR. The subset expects ordinary variant constructors declared by a concrete algebraic data type.",
        .fix = "Replace polymorphic variants such as `\\`Ok` with a declared ADT, for example `type result_tag = Ok | Error`.",
    },
    .{
        .code = "E0011",
        .title = "Float constants cannot be lowered to BPF",
        .description = "Floating-point literals and operations are intentionally excluded from the deterministic Solana BPF target surface. The compiler cannot emit stable BPF code for OCaml float constants.",
        .fix = "Use integers, fixed-point scaling, or explicit decimal encoding instead of float literals.",
    },
    .{
        .code = "E0012",
        .title = "Unsupported constant form",
        .description = "The source contains a constant kind or integer-width literal that is not represented by the current ZxCaml subset. Only the documented primitive constants are lowered through Core IR.",
        .fix = "Rewrite the value using supported ints, chars, strings, booleans, or an explicit ADT/record representation.",
    },
    .{
        .code = "E0013",
        .title = "Mutable references or mutable updates are unsupported",
        .description = "Reference cells, assignment, dereference, and mutable field writes would introduce mutation that the current Core IR and BPF lowering do not model. ZxCaml expects values to flow through explicit bindings.",
        .fix = "Thread state through function arguments/returns, use immutable record updates, or encode state in Solana account data helpers.",
    },
    .{
        .code = "E0014",
        .title = "First-class modules are unsupported",
        .description = "First-class module packing and local module expressions are outside the current frontend bridge contract. The compiler lowers a direct subset of module-level declarations, not runtime module values.",
        .fix = "Move the needed definitions to ordinary top-level modules/functions, or monomorphize the code before passing it to omlz.",
    },
    .{
        .code = "E0015",
        .title = "Recursive modules are unsupported",
        .description = "Recursive module declarations require module-system semantics that are not represented in the ZxCaml wire format. The current bridge expects acyclic module structure.",
        .fix = "Break the recursive module cycle by extracting shared types/functions into a non-recursive module.",
    },
    .{
        .code = "E0016",
        .title = "Exceptions are unsupported",
        .description = "Exception declarations, raises, and handlers do not fit the explicit, deterministic error surface used by the current BPF pipeline. ZxCaml does not emit exception runtime support.",
        .fix = "Return `option`, `result`, or a domain-specific ADT and handle failures with pattern matching.",
    },
    .{
        .code = "E0017",
        .title = "Loops are unsupported",
        .description = "`for` and `while` loops are not part of the currently accepted subset. The compiler supports recursion and higher-order list helpers for repeatable control flow.",
        .fix = "Rewrite loops as recursive functions, tail-recursive accumulators, or `List.fold_left` over a bounded list.",
    },
    .{
        .code = "E0018",
        .title = "Objects and method calls are unsupported",
        .description = "OCaml object expressions and method dispatch require runtime object machinery outside the Core IR contract. The ZxCaml subset uses records, variants, and functions instead.",
        .fix = "Represent data with records/ADTs and pass behavior as ordinary functions.",
    },
    .{
        .code = "E0019",
        .title = "Arrays are unsupported",
        .description = "OCaml arrays imply mutable indexed storage that is not currently lowered by the arena-only Core/BPF pipeline. Lists and explicit records are the supported aggregate forms.",
        .fix = "Use lists for fixed functional sequences, records/tuples for small fixed layouts, or account-data helpers for Solana byte storage.",
    },
    .{
        .code = "E0020",
        .title = "Lazy expressions are unsupported",
        .description = "Lazy values require runtime thunks and forcing semantics that the current deterministic backend does not provide. ZxCaml evaluates supported expressions directly.",
        .fix = "Compute the value eagerly, or wrap an explicit function around the computation and call it where needed.",
    },
    .{
        .code = "E0021",
        .title = "Binding operators are unsupported",
        .description = "OCaml binding-operator syntax such as `let*` and `and*` is not lowered by the current typedtree subset checker. The underlying control flow can usually be expressed explicitly.",
        .fix = "Desugar binding operators into ordinary function calls and pattern matches, for example `bind value (fun x -> ...)`.",
    },
    .{
        .code = "E0022",
        .title = "Unreachable expressions are unsupported",
        .description = "The frontend found an unreachable-expression node that has no Core IR representation. These usually come from source forms the subset does not expect to lower directly.",
        .fix = "Remove the unreachable branch or rewrite the surrounding match/control flow to return an explicit value or error variant.",
    },
    .{
        .code = "E0023",
        .title = "Extension constructors are unsupported",
        .description = "OCaml extension constructors are not represented in the current subset type environment. ZxCaml lowers ordinary constructors belonging to known ADTs.",
        .fix = "Replace extension constructors with a regular variant type declared in the source file.",
    },
    .{
        .code = "E0024",
        .title = "Unknown constructor in subset environment",
        .description = "The subset checker saw a constructor that was not present in the type environment it can lower. This usually means the constructor is unsupported, misspelled, or not in a supported ADT declaration.",
        .fix = "Check the constructor name and define/import a regular ADT constructor that the ZxCaml subset supports.",
    },
    .{
        .code = "E0090-E0099",
        .title = "Generic subset fallback bucket",
        .description = "The compiler uses this bucket when a subset rejection does not yet have a narrower tailored code. It still means the source contains an OCaml construct outside the supported ZxCaml lowering surface.",
        .fix = "Inspect the diagnostic node/message, rewrite that construct into supported subset features, and prefer filing a reduced case if the message should have a specific E0010-E0024 code.",
    },
};

pub fn lookup(code: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.code, code)) return entry;
    }

    if (isFallbackBucketCode(code)) {
        return entries[entries.len - 1];
    }
    return null;
}

pub fn isFallbackBucketCode(code: []const u8) bool {
    if (code.len != 5) return false;
    if (code[0] != 'E' or code[1] != '0' or code[2] != '0' or code[3] != '9') return false;
    return code[4] >= '0' and code[4] <= '9';
}

pub fn render(writer: anytype, requested_code: []const u8, entry: Entry) !void {
    try writer.print("{s} — {s}\n", .{ requested_code, entry.title });
    try writer.print("Description: {s}\n", .{entry.description});
    try writer.print("Suggested fix: {s}\n", .{entry.fix});
}

test "lookup covers catalog codes and E0090-E0099 bucket" {
    const codes = [_][]const u8{
        "E0001", "E0002", "E0003",
        "E0010", "E0011", "E0012",
        "E0013", "E0014", "E0015",
        "E0016", "E0017", "E0018",
        "E0019", "E0020", "E0021",
        "E0022", "E0023", "E0024",
        "E0090", "E0095", "E0099",
    };
    for (codes) |code| {
        const entry = lookup(code) orelse return error.MissingExplanation;
        try std.testing.expect(entry.title.len > 0);
        try std.testing.expect(entry.description.len > 0);
        try std.testing.expect(entry.fix.len > 0);
    }
}
