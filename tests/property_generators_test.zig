//! Integration tests for the OCaml property-test generator stdlib module.
//!
//! Each Zig test compiles `stdlib/generators.ml` with the system OCaml
//! compiler and runs a small upstream-OCaml program against the shipped module.
//! This keeps the tests close to the public OCaml API that future `omlz test`
//! property-runner work will consume.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn freeResult(allocator: Allocator, result: CommandResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn runCommand(allocator: Allocator, io: Io, argv: []const []const u8) !CommandResult {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = exit_code };
}

fn runOcamlGeneratorTest(allocator: Allocator, name: []const u8, source: []const u8) !CommandResult {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir_path = try std.fmt.allocPrint(allocator, "/tmp/zxcaml_property_generators_{s}", .{name});
    defer allocator.free(dir_path);

    cwd.deleteTree(io, dir_path) catch {};
    try cwd.createDirPath(io, dir_path);
    defer cwd.deleteTree(io, dir_path) catch {};

    const test_path = try std.fmt.allocPrint(allocator, "{s}/test.ml", .{dir_path});
    defer allocator.free(test_path);
    try cwd.writeFile(io, .{ .sub_path = test_path, .data = source });

    const command = try std.fmt.allocPrint(
        allocator,
        "cp stdlib/generators.ml {s}/generators.ml && cd {s} && opam exec --switch=zxcaml-p1 -- ocamlc generators.ml test.ml -o test.exe && ./test.exe",
        .{ dir_path, dir_path },
    );
    defer allocator.free(command);

    return runCommand(allocator, std.testing.io, &.{ "sh", "-c", command });
}

fn expectOcamlPass(name: []const u8, source: []const u8) !void {
    const allocator = std.testing.allocator;
    const result = try runOcamlGeneratorTest(allocator, name, source);
    defer freeResult(allocator, result);

    if (result.exit_code != 0) {
        std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ result.stdout, result.stderr });
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "property_generators: fixed seed reproduces same int output and seed" {
    try expectOcamlPass("deterministic",
        \\open Generators
        \\
        \\let () =
        \\  let gen = int_range ~low:10 ~high:20 in
        \\  let value1, seed1 = gen 12345L in
        \\  let value2, seed2 = gen 12345L in
        \\  assert (value1 = value2);
        \\  assert (seed1 = seed2)
        \\
    );
}

test "property_generators: int_range respects inclusive bounds" {
    try expectOcamlPass("range",
        \\open Generators
        \\
        \\let () =
        \\  let gen = int_range ~low:(-3) ~high:3 in
        \\  let rec loop remaining seed =
        \\    if remaining = 0 then ()
        \\    else
        \\      let value, next = gen seed in
        \\      assert (value >= -3 && value <= 3);
        \\      loop (remaining - 1) next
        \\  in
        \\  loop 100 7L
        \\
    );
}

test "property_generators: bool is deterministic for a fixed seed" {
    try expectOcamlPass("bool",
        \\open Generators
        \\
        \\let () =
        \\  let value1, seed1 = bool 99L in
        \\  let value2, seed2 = bool 99L in
        \\  assert (value1 = value2);
        \\  assert (seed1 = seed2)
        \\
    );
}

test "property_generators: string_of_len emits printable ASCII with exact length" {
    try expectOcamlPass("string",
        \\open Generators
        \\
        \\let () =
        \\  let gen = string_of_len ~len:16 in
        \\  let rec loop remaining seed =
        \\    if remaining = 0 then ()
        \\    else
        \\      let value, next = gen seed in
        \\      assert (String.length value = 16);
        \\      String.iter
        \\        (fun ch ->
        \\          let code = Char.code ch in
        \\          assert (code >= 32 && code <= 126))
        \\        value;
        \\      loop (remaining - 1) next
        \\  in
        \\  loop 25 123L
        \\
    );
}

test "property_generators: list_of honors the configured length bound" {
    try expectOcamlPass("list",
        \\open Generators
        \\
        \\let () =
        \\  let gen = list_of (int_range ~low:0 ~high:10) 5 in
        \\  let rec loop remaining seed =
        \\    if remaining = 0 then ()
        \\    else
        \\      let value, next = gen seed in
        \\      assert (List.length value <= 5);
        \\      List.iter (fun item -> assert (item >= 0 && item <= 10)) value;
        \\      loop (remaining - 1) next
        \\  in
        \\  loop 50 456L
        \\
    );
}

test "property_generators: option_of is deterministic and threads seed" {
    try expectOcamlPass("option",
        \\open Generators
        \\
        \\let () =
        \\  let gen = option_of (int_range ~low:1 ~high:1) in
        \\  let value1, seed1 = gen 88L in
        \\  let value2, seed2 = gen 88L in
        \\  assert (value1 = value2);
        \\  assert (seed1 = seed2);
        \\  match value1 with
        \\  | None -> ()
        \\  | Some value -> assert (value = 1)
        \\
    );
}

test "property_generators: tuple2 combines two generator samples in order" {
    try expectOcamlPass("tuple",
        \\open Generators
        \\
        \\let () =
        \\  let gen = tuple2 (int_range ~low:1 ~high:1) (string_of_len ~len:3) in
        \\  let (left, right), _ = gen 12L in
        \\  assert (left = 1);
        \\  assert (String.length right = 3)
        \\
    );
}

test "property_generators: map transforms generated samples" {
    try expectOcamlPass("map",
        \\open Generators
        \\
        \\let () =
        \\  let gen = map (fun value -> value * 2) (int_range ~low:2 ~high:2) in
        \\  let value, _ = gen 33L in
        \\  assert (value = 4)
        \\
    );
}

test "property_generators: filter only returns accepted samples" {
    try expectOcamlPass("filter_accept",
        \\open Generators
        \\
        \\let () =
        \\  let gen = filter (fun value -> value mod 2 = 0) (int_range ~low:0 ~high:20) in
        \\  let rec loop remaining seed =
        \\    if remaining = 0 then ()
        \\    else
        \\      let value, next = gen seed in
        \\      assert (value mod 2 = 0);
        \\      loop (remaining - 1) next
        \\  in
        \\  loop 20 44L
        \\
    );
}

test "property_generators: filter retry budget exhausts with runtime failure" {
    const allocator = std.testing.allocator;
    const result = try runOcamlGeneratorTest(allocator, "filter_exhaustion",
        \\open Generators
        \\
        \\let () =
        \\  let gen = filter (fun _ -> false) bool in
        \\  let _value, _seed = gen 55L in
        \\  ()
        \\
    );
    defer freeResult(allocator, result);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(contains(result.stderr, "Generators.filter: retry budget exhausted"));
}
