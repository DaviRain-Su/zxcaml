//! Instruction-data encoding, decoding, and staging helpers.
//!
//! This module groups the byte-level primitives used across the SDK's
//! entrypoint, CPI wrapper, and package surfaces:
//!
//! - fixed-size instruction-data builders for compact on-wire payloads
//! - zero-copy unaligned reads and enum-tag parsing
//! - typed instruction-data binding via `IxDataReader(T)`
//! - allocation-free cursor and staging helpers for compact payload formats
//!
//! Physical layout:
//! - `shared.zig` — common imports and `ProgramError` alias
//! - `builders.zig` — fixed-size instruction-data builders
//! - `reader.zig` — unaligned reads, tag parsing, typed ix-data binding
//! - `cursor.zig` — `IxDataCursor` checked parser
//! - `staging.zig` — caller-buffer-backed `IxDataStaging` writer
//!
//! The public API stays flattened as `sol.instruction.*`, with root aliases for
//! `sol.IxDataCursor` and `sol.IxDataStaging`.

const std = @import("std");
const builders_mod = @import("builders.zig");
const reader_mod = @import("reader.zig");
const cursor_mod = @import("cursor.zig");
const staging_mod = @import("staging.zig");

/// Fixed-size instruction-data builders.
pub const InstructionData = builders_mod.InstructionData;
pub const comptimeInstructionData = builders_mod.comptimeInstructionData;
pub const comptimeDiscriminantOnly = builders_mod.comptimeDiscriminantOnly;

/// Zero-copy unaligned reads, tag parsing, and typed field binding.
pub const readUnaligned = reader_mod.readUnaligned;
pub const readUnalignedPtr = reader_mod.readUnalignedPtr;
pub const tryReadUnaligned = reader_mod.tryReadUnaligned;
pub const parseTag = reader_mod.parseTag;
pub const parseTagUnchecked = reader_mod.parseTagUnchecked;
pub const IxDataReader = reader_mod.IxDataReader;

/// Checked parse / write helpers for compact variable-length payloads.
pub const IxDataCursor = cursor_mod.IxDataCursor;
pub const IxDataStaging = staging_mod.IxDataStaging;

// =============================================================================
// Tests
// =============================================================================

test "instruction: data transmute" {
    const Discriminant = enum(u32) {
        zero,
        one,
        two,
        three,
    };

    const Data = packed struct {
        a: u8,
        b: u16,
        c: u64,
    };

    const instruction = InstructionData(Discriminant, Data){
        .discriminant = Discriminant.three,
        .data = .{ .a = 1, .b = 2, .c = 3 },
    };
    try std.testing.expectEqualSlices(u8, instruction.asBytes(), &[_]u8{ 3, 0, 0, 0, 1, 2, 0, 3, 0, 0, 0, 0, 0, 0, 0 });
}

test "instruction: comptimeInstructionData init" {
    const Data = extern struct {
        lamports: u64,
        space: u64,
    };

    const Builder = comptimeInstructionData(u32, Data);
    const ix_data = Builder.init(2, .{ .lamports = 100, .space = 200 });

    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, ix_data[0..4], .little));
    try std.testing.expectEqual(@as(u64, 100), std.mem.readInt(u64, ix_data[4..12], .little));
    try std.testing.expectEqual(@as(u64, 200), std.mem.readInt(u64, ix_data[12..20], .little));
}

test "instruction: comptimeInstructionData initWithDiscriminant" {
    const Data = extern struct {
        lamports: u64,
        space: u64,
    };

    const Builder = comptimeInstructionData(u32, Data);
    const ix_data = Builder.initWithDiscriminant(2, .{ .lamports = 100, .space = 200 });

    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, ix_data[0..4], .little));
    try std.testing.expectEqual(@as(u64, 100), std.mem.readInt(u64, ix_data[4..12], .little));
    try std.testing.expectEqual(@as(u64, 200), std.mem.readInt(u64, ix_data[12..20], .little));
}

test "instruction: discriminant only" {
    const ix_data = comptimeDiscriminantOnly(@as(u32, 5));
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, &ix_data, .little));
}

test "instruction: readUnaligned primitive" {
    const data = [_]u8{ 0x01, 0xef, 0xcd, 0xab, 0x90, 0x78, 0x56, 0x34, 0x12 };
    const amount = readUnaligned(u64, &data, 1);
    try std.testing.expectEqual(@as(u64, 0x1234567890abcdef), amount);

    const tag = readUnaligned(u8, &data, 0);
    try std.testing.expectEqual(@as(u8, 1), tag);
}

test "instruction: readUnaligned struct" {
    const Args = extern struct {
        a: u32 align(1),
        b: u64 align(1),
    };
    const data = [_]u8{
        0x78, 0x56, 0x34, 0x12, // a = 0x12345678
        0xef, 0xcd, 0xab, 0x90, 0x78, 0x56, 0x34, 0x12, // b
    };
    const args = readUnaligned(Args, &data, 0);
    try std.testing.expectEqual(@as(u32, 0x12345678), args.a);
    try std.testing.expectEqual(@as(u64, 0x1234567890abcdef), args.b);
}

test "instruction: IxDataReader basic" {
    const VaultArgs = extern struct {
        tag: u8,
        amount: u64 align(1),
    };

    const data = [_]u8{
        2, // tag
        0xef, 0xcd, 0xab, 0x90, 0x78, 0x56, 0x34, 0x12, // amount
    };

    const r = IxDataReader(VaultArgs).bind(&data) orelse unreachable;
    try std.testing.expectEqual(@as(u8, 2), r.get(.tag));
    try std.testing.expectEqual(@as(u64, 0x1234567890abcdef), r.get(.amount));
}

test "instruction: IxDataReader bind returns null on short slice" {
    const VaultArgs = extern struct {
        tag: u8,
        amount: u64 align(1),
    };
    const short = [_]u8{ 1, 2, 3 };
    try std.testing.expect(IxDataReader(VaultArgs).bind(&short) == null);
}

test "instruction: tryReadUnaligned bounds" {
    const data = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 42 };
    try std.testing.expectEqual(@as(?u8, 1), tryReadUnaligned(u8, &data, 0));
    try std.testing.expectEqual(@as(?u64, 1), tryReadUnaligned(u64, &data, 0));
    try std.testing.expectEqual(@as(?u64, null), tryReadUnaligned(u64, &data, 2));
    try std.testing.expectEqual(@as(?u8, 42), tryReadUnaligned(u8, &data, 8));
    try std.testing.expectEqual(@as(?u8, null), tryReadUnaligned(u8, &data, 9));
}

test "instruction: parseTag" {
    const Ix = enum(u8) { initialize, deposit, withdraw };
    try std.testing.expectEqual(Ix.initialize, parseTag(Ix, &.{0}).?);
    try std.testing.expectEqual(Ix.deposit, parseTag(Ix, &.{ 1, 0xff }).?);
    try std.testing.expectEqual(Ix.withdraw, parseTag(Ix, &.{2}).?);
    try std.testing.expect(parseTag(Ix, &.{5}) == null); // out-of-range
    try std.testing.expect(parseTag(Ix, &.{}) == null); // empty
}

test "instruction: parseTag u32" {
    const Tag = enum(u32) { transfer, burn, mint };
    const data = [_]u8{ 2, 0, 0, 0, 0xff };
    try std.testing.expectEqual(Tag.mint, parseTag(Tag, &data).?);
}

test "instruction: parseTagUnchecked" {
    const Ix = enum(u8) { initialize, deposit, withdraw };
    try std.testing.expectEqual(Ix.deposit, parseTagUnchecked(Ix, &.{1}).?);
    try std.testing.expect(parseTagUnchecked(Ix, &.{}) == null);
}

test "instruction: IxDataCursor stores only slice and offset" {
    const info = @typeInfo(IxDataCursor).@"struct";
    try std.testing.expectEqual(@as(usize, 2), info.fields.len);
    try std.testing.expect(info.fields[0].type == []const u8);
    try std.testing.expect(info.fields[1].type == usize);
    try std.testing.expectEqual(@sizeOf([]const u8) + @sizeOf(usize), @sizeOf(IxDataCursor));

    const data = [_]u8{ 1, 2, 3 };
    var cursor = IxDataCursor.init(&data);
    try std.testing.expectEqual(@as(usize, 0), cursor.offset());
    try std.testing.expectEqual(data.len, cursor.remaining());
}

test "instruction: IxDataCursor reads little-endian integers and advances only on success" {
    const data = [_]u8{
        0xff,
        0x34,
        0x12,
        0x78,
        0x56,
        0x34,
        0x12,
        0xef,
        0xcd,
        0xab,
        0x90,
        0x78,
        0x56,
        0x34,
        0x12,
    };

    var cursor = IxDataCursor.init(data[1..]);
    try std.testing.expectEqual(@as(u16, 0x1234), try cursor.read(u16));
    try std.testing.expectEqual(@as(usize, 2), cursor.offset());
    try std.testing.expectEqual(@as(u32, 0x12345678), try cursor.read(u32));
    try std.testing.expectEqual(@as(usize, 6), cursor.offset());
    try std.testing.expectEqual(@as(u64, 0x1234567890abcdef), try cursor.read(u64));
    try std.testing.expectEqual(@as(usize, 14), cursor.offset());

    const before = cursor.offset();
    try std.testing.expectError(error.InvalidInstructionData, cursor.read(u16));
    try std.testing.expectEqual(before, cursor.offset());
    try std.testing.expectEqual(@as(usize, 0), cursor.remaining());
}

test "instruction: IxDataCursor take and skip are bounded zero-copy operations" {
    const data = [_]u8{ 0, 1, 2, 3, 4 };
    var cursor = IxDataCursor.init(&data);

    const empty = try cursor.take(0);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectEqual(@as(usize, 0), cursor.offset());
    try std.testing.expectEqual(data.len, cursor.remaining());

    const first = try cursor.take(2);
    try std.testing.expectEqualSlices(u8, data[0..2], first);
    try std.testing.expectEqual(@intFromPtr(&data[0]), @intFromPtr(first.ptr));
    try std.testing.expectEqual(@as(usize, 2), cursor.offset());
    try std.testing.expectEqual(@as(usize, 3), cursor.remaining());

    try cursor.skip(0);
    try std.testing.expectEqual(@as(usize, 2), cursor.offset());
    try cursor.skip(2);
    try std.testing.expectEqual(@as(usize, 4), cursor.offset());
    try std.testing.expectEqual(@as(usize, 1), cursor.remaining());

    const before_take = cursor.offset();
    try std.testing.expectError(error.InvalidInstructionData, cursor.take(2));
    try std.testing.expectEqual(before_take, cursor.offset());

    const before_skip = cursor.offset();
    try std.testing.expectError(error.InvalidInstructionData, cursor.skip(2));
    try std.testing.expectEqual(before_skip, cursor.offset());

    const last = try cursor.take(1);
    try std.testing.expectEqualSlices(u8, data[4..5], last);
    try std.testing.expectEqual(@as(usize, 5), cursor.offset());
    try std.testing.expectEqual(@as(usize, 0), cursor.remaining());
}

test "instruction: IxDataCursor count and segment helpers rollback on failure" {
    var count_cursor = IxDataCursor.init(&.{2});
    try std.testing.expectEqual(@as(u8, 2), try count_cursor.readCount(u8, 4));
    try std.testing.expectEqual(@as(usize, 1), count_cursor.offset());

    var over_max_count = IxDataCursor.init(&.{5});
    try std.testing.expectError(error.InvalidInstructionData, over_max_count.readCount(u8, 4));
    try std.testing.expectEqual(@as(usize, 0), over_max_count.offset());

    var short_count = IxDataCursor.init(&.{});
    try std.testing.expectError(error.InvalidInstructionData, short_count.readCount(u16, 4));
    try std.testing.expectEqual(@as(usize, 0), short_count.offset());

    const payload = [_]u8{
        4,
        2,
        0xaa,
        0xbb,
        0xcc,
    };
    var payload_cursor = IxDataCursor.init(&payload);
    var outer = try payload_cursor.takeLengthPrefixedCursor(u8, 4);
    try std.testing.expectEqual(@as(usize, 0), outer.offset());
    try std.testing.expectEqual(@as(usize, 4), outer.remaining());
    try std.testing.expectEqual(@as(usize, 5), payload_cursor.offset());
    try std.testing.expectEqual(@as(usize, 0), payload_cursor.remaining());

    var inner = try outer.takeLengthPrefixedCursor(u8, 2);
    try std.testing.expectEqual(@as(usize, 0), inner.offset());
    try std.testing.expectEqual(@as(usize, 2), inner.remaining());
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, try inner.take(2));
    try inner.expectEnd();

    try std.testing.expectEqual(@as(u8, 0xcc), try outer.read(u8));
    try outer.expectEnd();

    var truncated = IxDataCursor.init(&.{ 3, 0xaa, 0xbb });
    try std.testing.expectError(error.InvalidInstructionData, truncated.takeLengthPrefixedCursor(u8, 4));
    try std.testing.expectEqual(@as(usize, 0), truncated.offset());

    var over_max = IxDataCursor.init(&.{ 5, 0xaa, 0xbb, 0xcc, 0xdd, 0xee });
    try std.testing.expectError(error.InvalidInstructionData, over_max.takeLengthPrefixedCursor(u8, 4));
    try std.testing.expectEqual(@as(usize, 0), over_max.offset());
}

test "instruction: IxDataCursor expectEnd rejects trailing bytes without advancing" {
    var exact = IxDataCursor.init(&.{ 1, 2 });
    _ = try exact.take(2);
    try exact.expectEnd();
    try exact.finish();

    var trailing = IxDataCursor.init(&.{ 1, 2 });
    _ = try trailing.take(1);
    const before = trailing.offset();
    try std.testing.expectError(error.InvalidInstructionData, trailing.expectEnd());
    try std.testing.expectEqual(before, trailing.offset());
    try std.testing.expectEqual(@as(usize, 1), trailing.remaining());
}

test "instruction: IxDataStaging writes little-endian payloads and raw bytes" {
    var backing: [16]u8 = .{0xcc} ** 16;
    var staging = IxDataStaging.init(backing[0..]);

    try std.testing.expectEqual(@as(usize, 0), staging.written().len);

    try staging.writeIntLittleEndian(u16, 0x1234);
    try staging.writeIntLittleEndian(u32, 0x90abcdef);
    try staging.appendBytes(&.{ 0xaa, 0xbb, 0xcc });

    try std.testing.expectEqual(@as(usize, 9), staging.written().len);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x34, 0x12, 0xef, 0xcd, 0xab, 0x90, 0xaa, 0xbb, 0xcc },
        staging.written(),
    );
    try std.testing.expectEqual(@as(u8, 0xcc), backing[9]);
}

test "instruction: IxDataStaging capacity failures rollback logical length and reset reuses buffer" {
    var zero_backing: [0]u8 = .{};
    var zero = IxDataStaging.init(zero_backing[0..]);
    try std.testing.expectError(error.InvalidArgument, zero.appendBytes(&.{0x01}));
    try std.testing.expectEqual(@as(usize, 0), zero.written().len);

    var backing: [4]u8 = .{0xee} ** 4;
    var staging = IxDataStaging.init(backing[0..]);

    try staging.writeIntLittleEndian(u16, 0x4321);
    try std.testing.expectEqualSlices(u8, &.{ 0x21, 0x43 }, staging.written());

    try std.testing.expectError(
        error.InvalidArgument,
        staging.writeIntLittleEndian(u32, 0x12345678),
    );
    try std.testing.expectEqual(@as(usize, 2), staging.written().len);
    try std.testing.expectEqualSlices(u8, &.{ 0x21, 0x43 }, staging.written());

    staging.reset();
    try std.testing.expectEqual(@as(usize, 0), staging.written().len);

    try staging.appendBytes(&.{ 0xaa, 0xbb, 0xcc, 0xdd });
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc, 0xdd }, staging.written());
    try std.testing.expectError(error.InvalidArgument, staging.appendBytes(&.{0xee}));
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc, 0xdd }, staging.written());
}
