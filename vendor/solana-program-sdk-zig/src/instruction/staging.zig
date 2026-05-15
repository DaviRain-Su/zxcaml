const shared = @import("shared.zig");
const std = shared.std;
const ProgramError = shared.ProgramError;

/// Caller-buffer-backed instruction-data staging.
///
/// Appends raw bytes and little-endian integers into a fixed caller
/// buffer while exposing only the initialized prefix via `written()`.
pub const IxDataStaging = struct {
    buf: []u8,
    len: usize = 0,

    const Self = @This();

    pub inline fn init(buf: []u8) Self {
        return .{ .buf = buf };
    }

    pub inline fn reset(self: *Self) void {
        self.len = 0;
    }

    pub inline fn written(self: *const Self) []const u8 {
        return self.buf[0..self.len];
    }

    pub inline fn appendBytes(self: *Self, bytes: []const u8) ProgramError!void {
        if (self.buf.len - self.len < bytes.len) return error.InvalidArgument;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub inline fn writeIntLittleEndian(
        self: *Self,
        comptime T: type,
        value: T,
    ) ProgramError!void {
        comptime {
            if (@typeInfo(T) != .int) {
                @compileError("IxDataStaging.writeIntLittleEndian requires an integer type");
            }
        }

        const size = @sizeOf(T);
        if (self.buf.len - self.len < size) return error.InvalidArgument;
        std.mem.writeInt(T, self.buf[self.len..][0..size], value, .little);
        self.len += size;
    }
};
