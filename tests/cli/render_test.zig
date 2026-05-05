//! Unit tests for the P9 rustc-style diagnostic renderer.
//!
//! These tests intentionally exercise only the pure renderer surface. CLI flag
//! plumbing for `--color` and `--error-format` lands in later DX1 features.

const std = @import("std");
const render = @import("render");

fn diagnostic(span: render.Span) render.Diagnostic {
    return .{
        .severity = .@"error",
        .code = "E0001",
        .message = "This expression has type string but int was expected",
        .span = span,
    };
}

fn renderToOwnedSlice(
    allocator: std.mem.Allocator,
    source: []const u8,
    span: render.Span,
    options: render.Options,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try render.renderSource(&out.writer, diagnostic(span), source, options);
    return out.toOwnedSlice();
}

test "render: basic single-line caret block" {
    const allocator = std.testing.allocator;
    const source = "let _: int = \"abc\"\n";

    const output = try renderToOwnedSlice(allocator, source, .{
        .file = "tests/golden/dx1_type_caret.ml",
        .start_line = 1,
        .start_col = 14,
        .end_line = 1,
        .end_col = 19,
    }, .{ .color = .never });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "error[E0001]: This expression has type string but int was expected\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, " --> tests/golden/dx1_type_caret.ml:1:14\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1 | let _: int = \"abc\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  |              ^^^^^\n") != null);
}

test "render: multi-line span draws caret only on first source line" {
    const allocator = std.testing.allocator;
    const source =
        \\let x =
        \\  "abc"
        \\in x
        \\
    ;

    const output = try renderToOwnedSlice(allocator, source, .{
        .file = "multi.ml",
        .start_line = 1,
        .start_col = 5,
        .end_line = 2,
        .end_col = 8,
    }, .{ .color = .never });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "1 | let x =\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  |     ^^^\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2 |") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"abc\"") == null);
}

test "render: Color.never produces no ANSI escapes" {
    const allocator = std.testing.allocator;
    const output = try renderToOwnedSlice(allocator, "let _: int = \"abc\"\n", .{
        .file = "color.ml",
        .start_line = 1,
        .start_col = 14,
        .end_line = 1,
        .end_col = 19,
    }, .{ .color = .never });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
}

test "render: Color.always produces ANSI escapes" {
    const allocator = std.testing.allocator;
    const output = try renderToOwnedSlice(allocator, "let _: int = \"abc\"\n", .{
        .file = "color.ml",
        .start_line = 1,
        .start_col = 14,
        .end_line = 1,
        .end_col = 19,
    }, .{ .color = .always });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null);
}

test "render: NO_COLOR overrides auto color" {
    const allocator = std.testing.allocator;
    const output = try renderToOwnedSlice(allocator, "let _: int = \"abc\"\n", .{
        .file = "color.ml",
        .start_line = 1,
        .start_col = 14,
        .end_line = 1,
        .end_col = 19,
    }, .{ .color = .auto, .stderr_is_tty = true, .no_color_env = true });
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
}
