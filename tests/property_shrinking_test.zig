//! Integration tests for the OCaml property-test shrinking framework.
//!
//! These tests compile `stdlib/generators.ml` with upstream OCaml and exercise
//! shrink convergence through the public API that the future `omlz test`
//! property runner will call after a generated counterexample fails.

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

fn runOcamlShrinkingTest(allocator: Allocator, name: []const u8, source: []const u8) !CommandResult {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir_path = try std.fmt.allocPrint(allocator, "/tmp/zxcaml_property_shrinking_{s}", .{name});
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
    const result = try runOcamlShrinkingTest(allocator, name, source);
    defer freeResult(allocator, result);

    if (result.exit_code != 0) {
        std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ result.stdout, result.stderr });
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "property_shrinking: int shrink converges toward threshold by binary search" {
    try expectOcamlPass("int_converges",
        \\open Generators
        \\
        \\let () =
        \\  let value, steps = shrink_to_minimal ~fails:(fun n -> n > 5) shrink_int 37 in
        \\  assert (value = 6);
        \\  assert (steps > 0 && steps <= shrink_step_budget)
        \\
    );
}

test "property_shrinking: list shrink drops elements to a minimal failing length" {
    try expectOcamlPass("list_converges",
        \\open Generators
        \\
        \\let () =
        \\  let value, steps =
        \\    shrink_to_minimal ~fails:(fun xs -> List.length xs > 2)
        \\      (shrink_list shrink_int) [ 9; 8; 7; 6; 5 ]
        \\  in
        \\  assert (value = [ 7; 6; 5 ] || value = [ 8; 6; 5 ] || value = [ 8; 7; 5 ] || value = [ 8; 7; 6 ]);
        \\  assert (List.length value = 3);
        \\  assert (steps > 0 && steps <= shrink_step_budget)
        \\
    );
}

test "property_shrinking: string shrink drops characters to a minimal failing length" {
    try expectOcamlPass("string_converges",
        \\open Generators
        \\
        \\let () =
        \\  let value, steps =
        \\    shrink_to_minimal ~fails:(fun s -> String.length s > 2) shrink_string "abcdef"
        \\  in
        \\  assert (String.length value = 3);
        \\  assert (steps > 0 && steps <= shrink_step_budget)
        \\
    );
}

test "property_shrinking: tuple shrink minimizes each component independently" {
    try expectOcamlPass("tuple_converges",
        \\open Generators
        \\
        \\let () =
        \\  let value, steps =
        \\    shrink_to_minimal ~fails:(fun (left, right) -> left + right > 10)
        \\      (shrink_tuple2 shrink_int shrink_int) (20, 20)
        \\  in
        \\  let left, right = value in
        \\  assert (left + right = 11);
        \\  assert (steps > 0 && steps <= shrink_step_budget)
        \\
    );
}

test "property_shrinking: option shrink tries None before shrinking Some value" {
    try expectOcamlPass("option_converges",
        \\open Generators
        \\
        \\let () =
        \\  let value, steps =
        \\    shrink_to_minimal
        \\      ~fails:(function None -> false | Some n -> n > 3)
        \\      (shrink_option shrink_int) (Some 18)
        \\  in
        \\  assert (value = Some 4);
        \\  assert (steps > 0 && steps <= shrink_step_budget)
        \\
    );
}

test "property_shrinking: map shrink re-applies function to shrunk inputs" {
    try expectOcamlPass("map_converges",
        \\open Generators
        \\
        \\let () =
        \\  let candidates = shrink_map (fun n -> n * 2) shrink_int 12 in
        \\  assert (List.mem 0 candidates);
        \\  assert (List.mem 12 candidates);
        \\  assert (List.mem 22 candidates)
        \\
    );
}

test "property_shrinking: filter shrink keeps only predicate-preserving inputs" {
    try expectOcamlPass("filter_converges",
        \\open Generators
        \\
        \\let () =
        \\  let candidates = shrink_filter (fun n -> n mod 2 = 0) shrink_int 12 in
        \\  assert (List.for_all (fun n -> n mod 2 = 0) candidates);
        \\  assert (List.mem 0 candidates);
        \\  assert (List.mem 6 candidates)
        \\
    );
}

test "property_shrinking: shrink budget exhaustion is a runtime failure" {
    const allocator = std.testing.allocator;
    const result = try runOcamlShrinkingTest(allocator, "budget_exhaustion",
        \\open Generators
        \\
        \\let () =
        \\  let _value, _steps =
        \\    shrink_to_minimal ~budget:1 ~fails:(fun n -> n > 0) shrink_int 100
        \\  in
        \\  ()
        \\
    );
    defer freeResult(allocator, result);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(contains(result.stderr, "Generators.shrink: budget exhausted"));
}
