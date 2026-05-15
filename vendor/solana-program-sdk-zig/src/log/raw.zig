const shared = @import("shared.zig");

const hostPrint = shared.hostPrint;
const bpf = shared.bpf;

extern fn sol_log_(ptr: [*]const u8, len: u64) callconv(.c) void;
extern fn sol_log_64_(arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) callconv(.c) void;
extern fn sol_log_compute_units_() callconv(.c) void;
extern fn sol_log_data(ptr: [*]const []const u8, len: u64) callconv(.c) void;
extern fn sol_get_compute_budget() callconv(.c) u64;

/// Log a message.
pub inline fn log(message: []const u8) void {
    if (bpf.is_bpf_program) {
        sol_log_(message.ptr, message.len);
    } else {
        hostPrint("{s}", .{message});
    }
}

/// Log 5 u64 values (useful for debugging).
pub inline fn log64(
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
    arg5: u64,
) void {
    if (bpf.is_bpf_program) {
        sol_log_64_(arg1, arg2, arg3, arg4, arg5);
    } else {
        hostPrint("{d} {d} {d} {d} {d}", .{ arg1, arg2, arg3, arg4, arg5 });
    }
}

/// Log the current compute unit consumption.
pub inline fn logComputeUnits() void {
    if (bpf.is_bpf_program) {
        sol_log_compute_units_();
    } else {
        hostPrint("Compute units not available", .{});
    }
}

/// Log structured data.
pub inline fn logData(data: []const []const u8) void {
    if (bpf.is_bpf_program) {
        sol_log_data(data.ptr, data.len);
    } else {
        hostPrint("data: {any}", .{data});
    }
}

/// Get remaining compute units.
///
/// Returns the number of compute units remaining for this transaction.
/// Note: This syscall may not be available on all Solana versions.
pub inline fn getRemainingComputeUnits() u64 {
    if (bpf.is_bpf_program) {
        return sol_get_compute_budget();
    } else {
        return 0;
    }
}
