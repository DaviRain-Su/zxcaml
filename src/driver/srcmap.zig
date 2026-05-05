//! Source-map JSON schema support for BPF sidecar maps.
//!
//! Defines the stable sidecar shape used by later BPF source-map emission.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const schema_version: u32 = 1;

pub const Entry = struct {
    pc: u32,
    ml_file: []const u8,
    ml_line: u32,
    ml_col: u32,
};

pub const Schema = struct {
    version: u32 = schema_version,
    program: []const u8,
    entries: []const Entry,
};

pub const ParsedSchema = std.json.Parsed(Schema);

pub fn serializeJson(allocator: Allocator, schema: Schema) ![]u8 {
    try validateSchema(schema);

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll("{\"version\":");
    try out.writer.print("{d}", .{schema.version});
    try out.writer.writeAll(",\"program\":");
    try std.json.Stringify.value(schema.program, .{}, &out.writer);
    try out.writer.writeAll(",\"entries\":[");

    for (schema.entries, 0..) |entry, index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"pc\":");
        try out.writer.print("{d}", .{entry.pc});
        try out.writer.writeAll(",\"ml_file\":");
        try std.json.Stringify.value(entry.ml_file, .{}, &out.writer);
        try out.writer.writeAll(",\"ml_line\":");
        try out.writer.print("{d}", .{entry.ml_line});
        try out.writer.writeAll(",\"ml_col\":");
        try out.writer.print("{d}", .{entry.ml_col});
        try out.writer.writeByte('}');
    }

    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

pub fn deserializeJson(allocator: Allocator, bytes: []const u8) !ParsedSchema {
    var parsed = try std.json.parseFromSlice(Schema, allocator, bytes, .{
        .ignore_unknown_fields = false,
    });
    errdefer parsed.deinit();

    try validateSchema(parsed.value);
    return parsed;
}

pub fn validateSchema(schema: Schema) !void {
    if (schema.version != schema_version) return error.UnsupportedVersion;
    if (!entriesSortedByPc(schema.entries)) return error.UnsortedEntries;
}

pub fn entriesSortedByPc(entries: []const Entry) bool {
    if (entries.len < 2) return true;

    var previous = entries[0].pc;
    for (entries[1..]) |entry| {
        if (entry.pc < previous) return false;
        previous = entry.pc;
    }
    return true;
}

test "source-map entries must be sorted by pc" {
    const json =
        \\{"version":1,"program":"demo","entries":[{"pc":8,"ml_file":"examples/demo.ml","ml_line":1,"ml_col":1},{"pc":0,"ml_file":"examples/demo.ml","ml_line":1,"ml_col":1}]}
    ;

    var parsed = deserializeJson(std.testing.allocator, json) catch |err| {
        try std.testing.expectEqual(error.UnsortedEntries, err);
        return;
    };
    parsed.deinit();
    return error.ExpectedUnsortedEntries;
}

test "source-map serialize deserialize round-trip is byte identical" {
    const entries = [_]Entry{
        .{ .pc = 0, .ml_file = "examples/hackathon_greet.ml", .ml_line = 10, .ml_col = 3 },
        .{ .pc = 8, .ml_file = "examples/hackathon_greet.ml", .ml_line = 11, .ml_col = 5 },
    };
    const schema = Schema{
        .version = 1,
        .program = "hackathon_greet",
        .entries = entries[0..],
    };

    const first = try serializeJson(std.testing.allocator, schema);
    defer std.testing.allocator.free(first);

    var parsed = try deserializeJson(std.testing.allocator, first);
    defer parsed.deinit();

    const second = try serializeJson(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
}

test "source-map rejects unsupported schema version" {
    const json =
        \\{"version":2,"program":"demo","entries":[]}
    ;

    var parsed = deserializeJson(std.testing.allocator, json) catch |err| {
        try std.testing.expectEqual(error.UnsupportedVersion, err);
        return;
    };
    parsed.deinit();
    return error.ExpectedUnsupportedVersion;
}
