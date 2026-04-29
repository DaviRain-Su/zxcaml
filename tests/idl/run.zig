//! End-to-end tests for `omlz idl`.
//!
//! RESPONSIBILITIES:
//! - Invoke the installed compiler driver on IDL fixtures.
//! - Verify the emitted bytes parse as JSON.
//! - Assert the JSON carries instructions, discriminators, accounts, args, types, and errors.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const idl_options = @import("idl_options");

fn runIdl(allocator: Allocator, io: Io, ml_file: []const u8) !struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
} {
    const argv = [_][]const u8{ idl_options.omlz_bin, "idl", ml_file };
    const result = try std.process.run(allocator, io, .{ .argv = &argv });

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };

    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = exit_code };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("IDL JSON did not contain expected fragment:\n{s}\n\nJSON:\n{s}\n", .{ needle, haystack });
        return error.ExpectedFragmentMissing;
    }
}

test "idl: entrypoint fixture emits valid instruction schema" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const result = try runIdl(allocator, io, "tests/idl/entrypoint.ml");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        std.debug.print("omlz idl failed with stderr:\n{s}\n", .{result.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();

    try expectContains(result.stdout, "\"schema_version\":\"0.1.0\"");
    try expectContains(result.stdout, "\"program\":{\"name\":\"entrypoint\",\"program_id\":null}");
    try expectContains(result.stdout, "\"instructions\":[{\"name\":\"entrypoint\",\"discriminator\":[");
    try expectContains(result.stdout, "\"accounts\":[{\"name\":\"authority\",\"is_signer\":true,\"is_writable\":true}]");
    try expectContains(result.stdout, "\"args\":[{\"name\":\"amount\",\"type\":\"int\"}]");
    try expectContains(result.stdout, "\"kind\":\"record\",\"name\":\"vault\"");
    try expectContains(result.stdout, "\"kind\":\"variant\",\"name\":\"status\"");
    try expectContains(result.stdout, "\"errors\":[{\"name\":\"error_insufficient_funds\",\"code\":65537}]");
}

test "idl: no entrypoint emits empty instructions array" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const result = try runIdl(allocator, io, "tests/idl/no_entrypoint.ml");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        std.debug.print("omlz idl failed with stderr:\n{s}\n", .{result.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();

    try expectContains(result.stdout, "\"program\":{\"name\":\"no_entrypoint\",\"program_id\":null}");
    try expectContains(result.stdout, "\"instructions\":[]");
}
