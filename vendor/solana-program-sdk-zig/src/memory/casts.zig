const shared = @import("shared.zig");

const std = shared.stdlib;

/// Safe cast from bytes to a typed pointer.
/// Ensures proper alignment and size.
pub inline fn fromBytes(comptime T: type, bytes: []const u8) *const T {
    std.debug.assert(bytes.len >= @sizeOf(T));
    std.debug.assert(@intFromPtr(bytes.ptr) % @alignOf(T) == 0);
    return @ptrCast(@alignCast(bytes.ptr));
}

/// Safe mutable cast from bytes to a typed pointer.
pub inline fn fromBytesMut(comptime T: type, bytes: []u8) *T {
    std.debug.assert(bytes.len >= @sizeOf(T));
    std.debug.assert(@intFromPtr(bytes.ptr) % @alignOf(T) == 0);
    return @ptrCast(@alignCast(bytes.ptr));
}

/// Cast a value to its byte representation.
pub inline fn asBytes(value: anytype) []const u8 {
    return std.mem.asBytes(value);
}

/// Cast a mutable value to its byte representation.
pub inline fn asBytesMut(value: anytype) []u8 {
    return std.mem.asBytes(value);
}
