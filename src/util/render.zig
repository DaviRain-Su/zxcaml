//! Rustc-style diagnostic rendering.
//!
//! The pre-P9 baseline (see `mission-internal/p9-investigation/report.md`
//! §1 and Appendix A) rendered frontend diagnostics as one line in
//! `src/util/diag.zig`: `path:line:col: severity: message`. This module keeps
//! the renderer itself pure by accepting source text directly, with a thin
//! file-reading helper for the CLI plumbing that lands in later DX1 features.

const std = @import("std");
const diag_explain = @import("diag_explain.zig");

const red = "\x1b[31m";
const yellow = "\x1b[33m";
const dim = "\x1b[2m";
const reset = "\x1b[0m";

pub const Color = enum {
    auto,
    always,
    never,
};

pub const Severity = enum {
    @"error",
    warning,
};

pub const Span = struct {
    file: []const u8,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
};

pub const Diagnostic = struct {
    severity: Severity,
    code: ?[]const u8 = null,
    message: []const u8,
    span: Span,
};

pub const Options = struct {
    color: Color = .auto,
    /// The caller supplies this bit from TTY detection. Keeping it injectable
    /// makes renderer tests deterministic and avoids terminal probing here.
    stderr_is_tty: bool = false,
    /// Mirrors whether `NO_COLOR` is present in the process environment.
    no_color_env: bool = false,
};

pub fn optionsFromEnvironment(
    color: Color,
    stderr_is_tty: bool,
    environ_map: ?*const std.process.Environ.Map,
) Options {
    return .{
        .color = color,
        .stderr_is_tty = stderr_is_tty,
        .no_color_env = if (environ_map) |env| env.get("NO_COLOR") != null else false,
    };
}

pub fn renderFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    diagnostic: Diagnostic,
    options: Options,
) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        diagnostic.span.file,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(source);

    try renderSource(writer, diagnostic, source, options);
}

pub fn renderSource(
    writer: *std.Io.Writer,
    diagnostic: Diagnostic,
    source: []const u8,
    options: Options,
) !void {
    const use_color = shouldUseColor(options);
    const severity_text = severityName(diagnostic.severity);
    const severity_color = severityColor(diagnostic.severity);

    if (use_color) try writer.writeAll(severity_color);
    try writer.print("{s}", .{severity_text});
    if (use_color) try writer.writeAll(reset);

    if (diagnostic.code) |code| {
        try writer.print("[{s}]", .{code});
    }
    try writer.print(": {s}\n", .{diagnostic.message});

    if (use_color) try writer.writeAll(dim);
    try writer.print(" --> {s}:{d}:{d}\n", .{
        diagnostic.span.file,
        diagnostic.span.start_line,
        diagnostic.span.start_col,
    });
    try writer.writeAll("  |\n");
    if (use_color) try writer.writeAll(reset);

    const line = sourceLine(source, diagnostic.span.start_line) orelse "";
    try writer.print("{d} | {s}\n", .{ diagnostic.span.start_line, line });

    if (use_color) try writer.writeAll(dim);
    try writer.writeAll("  | ");
    if (use_color) {
        try writer.writeAll(reset);
        try writer.writeAll(severity_color);
    }
    try writeRepeatedByte(writer, ' ', caretPadding(diagnostic.span.start_col));
    try writeRepeatedByte(writer, '^', caretWidth(diagnostic.span, line.len));
    if (use_color) try writer.writeAll(reset);
    try writer.writeAll("\n");

    if (diagnostic.code) |code| {
        if (diag_explain.lookup(code)) |entry| {
            if (entry.hint) |hint_text| {
                if (use_color) try writer.writeAll(dim);
                try writer.writeAll("  = help: ");
                if (use_color) try writer.writeAll(reset);
                try writer.print("{s}\n", .{hint_text});
            }
        }
    }
}

fn shouldUseColor(options: Options) bool {
    if (options.no_color_env) return false;
    return switch (options.color) {
        .always => true,
        .never => false,
        .auto => options.stderr_is_tty,
    };
}

fn severityName(severity: Severity) []const u8 {
    return switch (severity) {
        .@"error" => "error",
        .warning => "warning",
    };
}

fn severityColor(severity: Severity) []const u8 {
    return switch (severity) {
        .@"error" => red,
        .warning => yellow,
    };
}

fn caretPadding(start_col: u32) usize {
    if (start_col == 0) return 0;
    return start_col - 1;
}

fn caretWidth(span: Span, line_len: usize) usize {
    if (span.end_line == span.start_line and span.end_col > span.start_col) {
        return @max(1, span.end_col - span.start_col);
    }

    const start_zero_based = caretPadding(span.start_col);
    if (line_len > start_zero_based) {
        return @max(1, line_len - start_zero_based);
    }
    return 1;
}

fn writeRepeatedByte(writer: *std.Io.Writer, byte: u8, count: usize) !void {
    for (0..count) |_| {
        try writer.writeByte(byte);
    }
}

fn sourceLine(source: []const u8, one_based_line: u32) ?[]const u8 {
    if (one_based_line == 0) return null;

    var lines = std.mem.splitScalar(u8, source, '\n');
    var current: u32 = 1;
    while (lines.next()) |line_with_possible_cr| : (current += 1) {
        if (current == one_based_line) {
            return std.mem.trimEnd(u8, line_with_possible_cr, "\r");
        }
    }
    return null;
}
