//! Source-map JSON schema support for BPF sidecar maps.
//!
//! Defines the stable sidecar shape used by later BPF source-map emission.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const schema_version: u32 = 1;
pub const elf_section_name = ".zxcaml.srcmap";

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

pub const LookupResult = struct {
    entry: Entry,
    exact: bool,
};

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

pub fn lookupPc(schema: Schema, pc: u32) ?LookupResult {
    var preceding: ?Entry = null;

    for (schema.entries) |entry| {
        if (entry.pc == pc) return .{ .entry = entry, .exact = true };
        if (entry.pc > pc) break;
        preceding = entry;
    }

    if (preceding) |entry| return .{ .entry = entry, .exact = false };
    return null;
}

pub fn readEmbeddedSectionJson(allocator: Allocator, io: std.Io, so_path: []const u8) ![]u8 {
    // F-SRCMAP-5 follows mission-internal/p9-investigation/report.md §4:
    // `omlz unmap --so` reads the loader-ignored `.zxcaml.srcmap` ELF
    // section and decompresses it when F-SRCMAP-4 embedded gzip bytes.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, so_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    const header = try std.elf.Header.read(&reader);
    if (header.shnum == 0) return error.MissingSectionHeaders;
    if (header.shstrndx >= header.shnum) return error.MissingSectionStringTable;

    var shstrtab: ?std.elf.Elf64_Shdr = null;
    var sh_iter = header.iterateSectionHeadersBuffer(bytes);
    var index: u16 = 0;
    while (try sh_iter.next()) |section| : (index += 1) {
        if (index == header.shstrndx) {
            shstrtab = section;
            break;
        }
    }

    const names_section = shstrtab orelse return error.MissingSectionStringTable;
    const names = try checkedSlice(bytes, names_section.sh_offset, names_section.sh_size);

    sh_iter = header.iterateSectionHeadersBuffer(bytes);
    while (try sh_iter.next()) |section| {
        const name = sectionName(names, section.sh_name) catch continue;
        if (!std.mem.eql(u8, name, elf_section_name)) continue;

        const payload = try checkedSlice(bytes, section.sh_offset, section.sh_size);
        return try decompressMaybeGzip(allocator, payload);
    }

    return error.MissingSourceMapSection;
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

fn checkedSlice(bytes: []const u8, offset: u64, size: u64) ![]const u8 {
    const start = std.math.cast(usize, offset) orelse return error.InvalidElfSectionBounds;
    const len = std.math.cast(usize, size) orelse return error.InvalidElfSectionBounds;
    const end = start + len;
    if (end < start or end > bytes.len) return error.InvalidElfSectionBounds;
    return bytes[start..end];
}

fn sectionName(names: []const u8, offset: u32) ![]const u8 {
    const start = std.math.cast(usize, offset) orelse return error.InvalidElfSectionName;
    if (start >= names.len) return error.InvalidElfSectionName;
    const nul = std.mem.indexOfScalarPos(u8, names, start, 0) orelse return error.InvalidElfSectionName;
    return names[start..nul];
}

fn decompressMaybeGzip(allocator: Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len < 2 or bytes[0] != 0x1f or bytes[1] != 0x8b) {
        return allocator.dupe(u8, bytes);
    }

    var input = std.Io.Reader.fixed(bytes);
    const flate_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(flate_buffer);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    var decompressor: std.compress.flate.Decompress = .init(&input, .gzip, flate_buffer);
    _ = try decompressor.reader.streamRemaining(&output.writer);
    return output.toOwnedSlice();
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

test "source-map lookup returns exact match or nearest preceding entry" {
    const entries = [_]Entry{
        .{ .pc = 4, .ml_file = "examples/demo.ml", .ml_line = 10, .ml_col = 2 },
        .{ .pc = 8, .ml_file = "examples/demo.ml", .ml_line = 11, .ml_col = 4 },
    };
    const schema = Schema{ .program = "demo", .entries = entries[0..] };

    const exact = lookupPc(schema, 8) orelse return error.ExpectedExactMatch;
    try std.testing.expect(exact.exact);
    try std.testing.expectEqual(@as(u32, 8), exact.entry.pc);

    const approximate = lookupPc(schema, 9) orelse return error.ExpectedApproximateMatch;
    try std.testing.expect(!approximate.exact);
    try std.testing.expectEqual(@as(u32, 8), approximate.entry.pc);

    try std.testing.expect(lookupPc(schema, 3) == null);
}
