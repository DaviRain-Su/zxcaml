//! Frontend diagnostic parsing and rendering for the Zig driver.
//!
//! RESPONSIBILITIES:
//! - Parse the flat JSON diagnostic objects emitted by `zxc-frontend`.
//! - Preserve the location/severity/message/node_kind fields for tests and tooling.
//! - Render user-facing diagnostics in the conventional `file:line:col: severity: message` shape.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Flat JSON diagnostic shape emitted one-per-line by the OCaml frontend.
pub const Diagnostic = struct {
    file: []const u8,
    line: u32,
    col: u32,
    severity: []const u8,
    message: []const u8,
    node_kind: []const u8,
};

/// Owns a parsed diagnostic and any allocations made while decoding JSON.
pub const ParsedDiagnostic = std.json.Parsed(Diagnostic);

/// Parses one flat JSON diagnostic line from the frontend stderr stream.
pub fn parse(allocator: Allocator, line: []const u8) !ParsedDiagnostic {
    return std.json.parseFromSlice(Diagnostic, allocator, line, .{
        .ignore_unknown_fields = true,
    });
}

/// Writes the human-facing single-line representation of a diagnostic.
pub fn render(writer: anytype, diagnostic: Diagnostic) !void {
    try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{
        diagnostic.file,
        diagnostic.line,
        diagnostic.col,
        diagnostic.severity,
        diagnostic.message,
    });
}

test "parse flat frontend JSON diagnostic" {
    const json =
        \\{"file":"tests/ui/for_loop.ml","line":1,"col":19,"severity":"error","message":"Texp_for is not supported","node_kind":"Texp_for"}
    ;

    var parsed = try parse(std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("tests/ui/for_loop.ml", parsed.value.file);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.line);
    try std.testing.expectEqual(@as(u32, 19), parsed.value.col);
    try std.testing.expectEqualStrings("error", parsed.value.severity);
    try std.testing.expectEqualStrings("Texp_for is not supported", parsed.value.message);
    try std.testing.expectEqualStrings("Texp_for", parsed.value.node_kind);
}

test "parse ignores non-contract diagnostic fields" {
    const json =
        \\{"file":"a.ml","line":2,"col":3,"severity":"warning","message":"heads up","node_kind":"Texp_ident","hint":"extra context"}
    ;

    var parsed = try parse(std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("a.ml", parsed.value.file);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.line);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.col);
    try std.testing.expectEqualStrings("warning", parsed.value.severity);
    try std.testing.expectEqualStrings("heads up", parsed.value.message);
    try std.testing.expectEqualStrings("Texp_ident", parsed.value.node_kind);
}
