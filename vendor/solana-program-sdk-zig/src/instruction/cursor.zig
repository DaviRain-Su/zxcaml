const shared = @import("shared.zig");
const std = shared.std;

/// Allocation-free cursor over compact instruction payloads.
///
/// Stores only the original instruction-data slice and the current
/// offset. Checked reads, slices, and skips advance only on success.
/// Segment/count helpers restore the prior offset on failure so caller
/// code can treat them as all-or-nothing parse steps.
pub const IxDataCursor = struct {
    data: []const u8,
    pos: usize,

    const Self = @This();
    pub const Error = error{InvalidInstructionData};

    pub inline fn init(data: []const u8) Self {
        return .{ .data = data, .pos = 0 };
    }

    pub inline fn offset(self: Self) usize {
        return self.pos;
    }

    pub inline fn remaining(self: Self) usize {
        return self.data.len - self.pos;
    }

    pub inline fn unread(self: Self) []const u8 {
        return self.data[self.pos..];
    }

    pub inline fn read(self: *Self, comptime T: type) Error!T {
        comptime requireLittleEndianInt(T, "IxDataCursor.read");

        const size = @sizeOf(T);
        if (self.remaining() < size) return error.InvalidInstructionData;

        const out = std.mem.readInt(T, self.data[self.pos..][0..size], .little);
        self.pos += size;
        return out;
    }

    pub inline fn take(self: *Self, len: usize) Error![]const u8 {
        if (self.remaining() < len) return error.InvalidInstructionData;

        const start = self.pos;
        self.pos += len;
        return self.data[start..self.pos];
    }

    pub inline fn skip(self: *Self, len: usize) Error!void {
        if (self.remaining() < len) return error.InvalidInstructionData;
        self.pos += len;
    }

    pub inline fn readCount(self: *Self, comptime Count: type, max_count: Count) Error!Count {
        comptime requirePrefixInt(Count, "IxDataCursor.readCount");

        const start = self.pos;
        errdefer self.pos = start;

        const count = try self.read(Count);
        if (count > max_count) return error.InvalidInstructionData;
        return count;
    }

    pub inline fn takeLengthPrefixedCursor(
        self: *Self,
        comptime Len: type,
        max_len: usize,
    ) Error!Self {
        comptime requirePrefixInt(Len, "IxDataCursor.takeLengthPrefixedCursor");

        const start = self.pos;
        errdefer self.pos = start;

        const len = try self.read(Len);
        const segment_len: usize = @intCast(len);
        if (segment_len > max_len) return error.InvalidInstructionData;

        const segment = try self.take(segment_len);
        return Self.init(segment);
    }

    pub inline fn expectEnd(self: *const Self) Error!void {
        if (self.remaining() != 0) return error.InvalidInstructionData;
    }

    pub inline fn finish(self: *const Self) Error!void {
        try self.expectEnd();
    }

    fn requireLittleEndianInt(comptime T: type, comptime fn_name: []const u8) void {
        const info = @typeInfo(T);
        if (info != .int) {
            @compileError(fn_name ++ " requires an integer type (got " ++ @typeName(T) ++ ")");
        }
    }

    fn requirePrefixInt(comptime T: type, comptime fn_name: []const u8) void {
        const info = @typeInfo(T);
        if (info != .int) {
            @compileError(fn_name ++ " requires an unsigned integer prefix type (got " ++ @typeName(T) ++ ")");
        }
        if (info.int.signedness != .unsigned) {
            @compileError(fn_name ++ " requires an unsigned integer prefix type (got " ++ @typeName(T) ++ ")");
        }
        if (info.int.bits > @bitSizeOf(usize)) {
            @compileError(fn_name ++ " prefix width exceeds usize on this target");
        }
    }
};
