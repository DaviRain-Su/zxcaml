const shared = @import("shared.zig");
const std = shared.std;
const bpf = shared.bpf;
const Pubkey = shared.Pubkey;

extern fn sol_set_return_data(data: [*]const u8, len: u64) callconv(.c) void;
extern fn sol_get_return_data(data: [*]u8, len: u64, program_id: *Pubkey) callconv(.c) u64;

/// Set return data for this program
pub fn setReturnData(data: []const u8) void {
    if (bpf.is_bpf_program) {
        sol_set_return_data(data.ptr, data.len);
    }
}

/// Get return data from the last CPI call.
///
/// If the callee returned more bytes than fit in `buffer`, the runtime
/// copies only the prefix that fits. This helper mirrors that behavior
/// by returning the copied prefix slice rather than slicing past the
/// caller-provided buffer length.
pub fn getReturnData(buffer: []u8) ?struct { Pubkey, []const u8 } {
    if (!bpf.is_bpf_program) {
        return null;
    }

    var program_id: Pubkey = undefined;
    const len = sol_get_return_data(buffer.ptr, buffer.len, &program_id);

    if (len == 0) {
        return null;
    }

    return .{ program_id, buffer[0..copiedReturnDataLen(buffer.len, len)] };
}

fn copiedReturnDataLen(buffer_len: usize, return_data_len: u64) usize {
    const capped: usize = if (return_data_len > std.math.maxInt(usize))
        std.math.maxInt(usize)
    else
        @intCast(return_data_len);
    return @min(buffer_len, capped);
}

test "return_data: host get returns null" {
    var buf: [8]u8 = undefined;
    try std.testing.expect(getReturnData(&buf) == null);
}

test "return_data: copied length clamps to caller buffer" {
    try std.testing.expectEqual(@as(usize, 0), copiedReturnDataLen(0, 0));
    try std.testing.expectEqual(@as(usize, 4), copiedReturnDataLen(8, 4));
    try std.testing.expectEqual(@as(usize, 8), copiedReturnDataLen(8, 8));
    try std.testing.expectEqual(@as(usize, 8), copiedReturnDataLen(8, 64));
}
