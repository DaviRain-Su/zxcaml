//! Integration tests for `omlz test`.
//!
//! These are wired as a standalone build.zig test module because they spawn the
//! installed `omlz` binary and exercise end-to-end CLI behavior.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const omlz_bin = "zig-out/bin/omlz";

const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

fn runCommand(allocator: Allocator, io: Io, argv: []const []const u8) !CommandResult {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = exit_code };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn freeResult(allocator: Allocator, result: CommandResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn writeTempFile(path: []const u8, source: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(std.testing.io, .{ .sub_path = path, .data = source, .flags = .{ .truncate = true } });
}

test "omlz_test_subcommand: help lists supported options" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "--help" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(contains(result.stdout, "--filter"));
    try std.testing.expect(contains(result.stdout, "--format"));
    try std.testing.expect(contains(result.stdout, "--no-color"));
}

test "omlz_test_subcommand: zero-test file reports zero tests and exits ok" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "tests/fixtures/otest/zero_tests.ml" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(contains(result.stdout, "running 0 tests"));
    try std.testing.expect(contains(result.stdout, "0 tests, 0 passed"));
    try std.testing.expect(contains(result.stdout, "test result: ok. 0 passed; 0 failed;"));
}

test "omlz_test_subcommand: single passing test exits zero" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "tests/fixtures/otest/pass.ml" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(contains(result.stdout, "running 1 tests"));
    try std.testing.expect(contains(result.stdout, "test tests/fixtures/otest/pass.ml::math passes ... ok"));
    try std.testing.expect(contains(result.stdout, "test result: ok. 1 passed; 0 failed;"));
}

test "omlz_test_subcommand: failing test exits one and prints location" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "tests/fixtures/otest/mixed.ml" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(contains(result.stdout, "test tests/fixtures/otest/mixed.ml::bar fails ... FAILED"));
    try std.testing.expect(contains(result.stdout, "ZXCAML_PANIC:assert_failure"));
    try std.testing.expect(contains(result.stdout, "tests/fixtures/otest/mixed.ml:"));
}

test "omlz_test_subcommand: mixed file reports pass and fail counts" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "tests/fixtures/otest/mixed.ml" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(contains(result.stdout, "running 2 tests"));
    try std.testing.expect(contains(result.stdout, "test tests/fixtures/otest/mixed.ml::foo passes ... ok"));
    try std.testing.expect(contains(result.stdout, "test result: FAILED. 1 passed; 1 failed;"));
}

test "omlz_test_subcommand: filter runs only matching test names" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "--filter", "foo", "tests/fixtures/otest/mixed.ml" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(contains(result.stdout, "running 1 tests"));
    try std.testing.expect(contains(result.stdout, "foo passes"));
    try std.testing.expect(!contains(result.stdout, "bar fails"));
    try std.testing.expect(contains(result.stdout, "test result: ok. 1 passed; 0 failed;"));
}

test "omlz_test_subcommand: missing file exits two" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "/tmp/does_not_exist_otest.ml" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 2), result.exit_code);
    try std.testing.expect(contains(result.stderr, "test file not found"));
}

test "omlz_test_subcommand: json format emits parseable result and summary lines" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "--format=json", "tests/fixtures/otest/mixed.ml" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);

    var line_count: usize = 0;
    var summary_seen = false;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
        defer parsed.deinit();
        line_count += 1;
        const object = parsed.value.object;
        try std.testing.expect(object.contains("type"));
        if (std.mem.eql(u8, object.get("type").?.string, "summary")) {
            summary_seen = true;
            try std.testing.expectEqual(@as(i64, 2), object.get("total").?.integer);
            try std.testing.expectEqual(@as(i64, 1), object.get("failed").?.integer);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), line_count);
    try std.testing.expect(summary_seen);
}

test "omlz_test_subcommand: NO_COLOR suppresses ANSI escapes" {
    const allocator = std.testing.allocator;
    const result = try runCommand(
        allocator,
        std.testing.io,
        &.{ "env", "NO_COLOR=1", omlz_bin, "test", "tests/fixtures/otest/pass.ml" },
    );
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\x1b[") == null);
}

test "omlz_test_subcommand: help lists property-test options" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "--help" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(contains(result.stdout, "--num-cases"));
    try std.testing.expect(contains(result.stdout, "--seed"));
}

test "omlz_test_subcommand: property num-cases flag is honored in cargo output" {
    const allocator = std.testing.allocator;
    const path = "/tmp/zxcaml_prop_num_cases.ml";
    try writeTempFile(path,
        \\let int seed = (seed, seed + 1)
        \\let%test_prop "id" int = fun x -> x = x
        \\
    );
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "--num-cases", "5", "--seed", "42", path });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(contains(result.stdout, "prop_id ... ok (5 cases)"));
}

test "omlz_test_subcommand: property default num-cases is 100" {
    const allocator = std.testing.allocator;
    const path = "/tmp/zxcaml_prop_default_cases.ml";
    try writeTempFile(path,
        \\let int seed = (seed, seed + 1)
        \\let%test_prop "default cases" int = fun x -> x = x
        \\
    );
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "--seed", "42", path });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(contains(result.stdout, "prop_default cases ... ok (100 cases)"));
}

test "omlz_test_subcommand: property seed makes cargo output deterministic" {
    const allocator = std.testing.allocator;
    const path = "/tmp/zxcaml_prop_seed_deterministic.ml";
    try writeTempFile(path,
        \\let int seed = (seed, seed + 1)
        \\let%test_prop "deterministic" int = fun x -> x = x
        \\
    );
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const first = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "--num-cases", "4", "--seed", "123", path });
    defer freeResult(allocator, first);
    const second = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "--num-cases", "4", "--seed", "123", path });
    defer freeResult(allocator, second);

    try std.testing.expectEqual(@as(u8, 0), first.exit_code);
    try std.testing.expectEqual(@as(u8, 0), second.exit_code);
    try std.testing.expectEqualStrings(first.stdout, second.stdout);
}

test "omlz_test_subcommand: property pass json includes prop fields" {
    const allocator = std.testing.allocator;
    const path = "/tmp/zxcaml_prop_json_pass.ml";
    try writeTempFile(path,
        \\let int seed = (seed, seed + 1)
        \\let%test_prop "json pass" int = fun x -> x = x
        \\
    );
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "--format=json", "--num-cases", "6", "--seed", "77", path });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    const first_line = lines.next().?;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, first_line, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("prop", object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 6), object.get("num_cases").?.integer);
    try std.testing.expectEqual(@as(i64, 77), object.get("seed").?.integer);
}

test "omlz_test_subcommand: property failure reports shrunk counterexample in cargo output" {
    const allocator = std.testing.allocator;
    const path = "/tmp/zxcaml_prop_fail_cargo.ml";
    try writeTempFile(path,
        \\let int seed = (seed, seed + 1)
        \\let%test_prop "broken" int = fun x -> x + 1 = x
        \\
    );
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "--num-cases", "8", "--seed", "42", path });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(contains(result.stdout, "FAILED after 1 tests; shrunk to: 0 (in 1 shrink steps)"));
}

test "omlz_test_subcommand: property failure json includes shrink shape" {
    const allocator = std.testing.allocator;
    const path = "/tmp/zxcaml_prop_fail_json.ml";
    try writeTempFile(path,
        \\let int seed = (seed, seed + 1)
        \\let%test_prop "broken json" int = fun x -> x + 1 = x
        \\
    );
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "--format=json", "--num-cases", "8", "--seed", "42", path });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    const first_line = lines.next().?;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, first_line, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("prop", object.get("kind").?.string);
    try std.testing.expectEqualStrings("0", object.get("counterexample").?.string);
    try std.testing.expectEqual(@as(i64, 1), object.get("shrunk_steps").?.integer);
    try std.testing.expectEqual(@as(i64, 8), object.get("num_cases").?.integer);
}

test "omlz_test_subcommand: mixed unit and property registry runs both kinds" {
    const allocator = std.testing.allocator;
    const path = "/tmp/zxcaml_prop_mixed.ml";
    try writeTempFile(path,
        \\let int seed = (seed, seed + 1)
        \\let%test_unit "unit still passes" = ()
        \\let%test_prop "prop passes" int = fun x -> x = x
        \\
    );
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const result = try runCommand(allocator, std.testing.io, &.{ omlz_bin, "test", "--num-cases", "3", "--seed", "42", path });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(contains(result.stdout, "running 2 tests"));
    try std.testing.expect(contains(result.stdout, "::unit still passes ... ok"));
    try std.testing.expect(contains(result.stdout, "::prop_prop passes ... ok (3 cases)"));
}
