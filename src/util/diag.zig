//! Frontend diagnostic parsing and rendering for the Zig driver.
//!
//! RESPONSIBILITIES:
//! - Parse the flat JSON diagnostic objects emitted by `zxc-frontend`.
//! - Preserve the location/severity/message/node_kind fields for tests and tooling.
//! - Render user-facing diagnostics in either the legacy one-line shape or
//!   the P9 rustc-style human shape.

const std = @import("std");
const Allocator = std.mem.Allocator;
const render_block = @import("render.zig");

pub const ErrorFormat = enum {
    human,
    json,
    oneline,
};

pub const OutputOptions = struct {
    error_format: ErrorFormat = .human,
    color: render_block.Color = .auto,
    stderr_is_tty: bool = false,
    no_color_env: bool = false,
};

/// Flat JSON diagnostic shape emitted one-per-line by the OCaml frontend.
pub const Diagnostic = struct {
    file: []const u8,
    line: u32,
    col: u32,
    end_line: ?u32 = null,
    end_col: ?u32 = null,
    severity: []const u8,
    code: ?[]const u8 = null,
    message: []const u8,
    node_kind: []const u8 = "",
};

/// Owns a parsed diagnostic and any allocations made while decoding JSON.
pub const ParsedDiagnostic = std.json.Parsed(Diagnostic);

/// Parses one flat JSON diagnostic line from the frontend stderr stream.
pub fn parse(allocator: Allocator, line: []const u8) !ParsedDiagnostic {
    return std.json.parseFromSlice(Diagnostic, allocator, line, .{
        .ignore_unknown_fields = true,
    });
}

pub fn parseErrorFormat(value: []const u8) !ErrorFormat {
    if (std.mem.eql(u8, value, "human")) return .human;
    if (std.mem.eql(u8, value, "json")) return .json;
    if (std.mem.eql(u8, value, "oneline")) return .oneline;
    return error.InvalidErrorFormat;
}

pub fn parseColor(value: []const u8) !render_block.Color {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "always")) return .always;
    if (std.mem.eql(u8, value, "never")) return .never;
    return error.InvalidColor;
}

/// Writes the selected user-facing representation of a diagnostic.
pub fn render(
    writer: *std.Io.Writer,
    allocator: Allocator,
    io: std.Io,
    diagnostic: Diagnostic,
    options: OutputOptions,
) !void {
    switch (options.error_format) {
        .human => renderHuman(writer, allocator, io, diagnostic, options) catch try renderOneline(writer, diagnostic),
        .json => try renderJson(writer, diagnostic),
        .oneline => try renderOneline(writer, diagnostic),
    }
}

/// Writes the legacy single-line representation of a diagnostic.
pub fn renderOneline(writer: anytype, diagnostic: Diagnostic) !void {
    try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{
        diagnostic.file,
        diagnostic.line,
        diagnostic.col,
        diagnostic.severity,
        diagnostic.message,
    });
}

fn renderHuman(
    writer: *std.Io.Writer,
    allocator: Allocator,
    io: std.Io,
    diagnostic: Diagnostic,
    options: OutputOptions,
) !void {
    try render_block.renderFile(allocator, io, writer, .{
        .severity = severityForRenderer(diagnostic.severity),
        .code = diagnostic.code,
        .message = diagnostic.message,
        .span = .{
            .file = diagnostic.file,
            .start_line = diagnostic.line,
            .start_col = diagnostic.col,
            .end_line = diagnostic.end_line orelse diagnostic.line,
            .end_col = diagnostic.end_col orelse diagnostic.col + 1,
        },
    }, .{
        .color = options.color,
        .stderr_is_tty = options.stderr_is_tty,
        .no_color_env = options.no_color_env,
    });
}

fn severityForRenderer(severity: []const u8) render_block.Severity {
    if (std.ascii.eqlIgnoreCase(severity, "warning") or std.ascii.eqlIgnoreCase(severity, "warn")) {
        return .warning;
    }
    return .@"error";
}

fn renderJson(writer: *std.Io.Writer, diagnostic: Diagnostic) !void {
    try writer.writeByte('{');
    try writeJsonField(writer, "file", diagnostic.file, false);
    try writer.print(",\"line\":{d},\"col\":{d}", .{ diagnostic.line, diagnostic.col });
    if (diagnostic.end_line) |end_line| try writer.print(",\"end_line\":{d}", .{end_line});
    if (diagnostic.end_col) |end_col| try writer.print(",\"end_col\":{d}", .{end_col});
    try writeJsonField(writer, "severity", diagnostic.severity, true);
    if (diagnostic.code) |code| try writeJsonField(writer, "code", code, true);
    try writeJsonField(writer, "message", diagnostic.message, true);
    try writer.writeAll("}\n");
}

fn writeJsonField(writer: *std.Io.Writer, name: []const u8, value: []const u8, leading_comma: bool) !void {
    if (leading_comma) try writer.writeByte(',');
    try writeJsonString(writer, name);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (byte < 0x20) {
                try writer.print("\\u{x:0>4}", .{byte});
            } else {
                try writer.writeByte(byte);
            },
        }
    }
    try writer.writeByte('"');
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

test "parse accepts widened diagnostic envelope fields" {
    const json =
        \\{"file":"a.ml","line":2,"col":3,"end_line":2,"end_col":8,"severity":"error","code":"E0001","message":"bad"}
    ;

    var parsed = try parse(std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 2), parsed.value.end_line.?);
    try std.testing.expectEqual(@as(u32, 8), parsed.value.end_col.?);
    try std.testing.expectEqualStrings("E0001", parsed.value.code.?);
    try std.testing.expectEqualStrings("", parsed.value.node_kind);
}
