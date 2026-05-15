const shared = @import("shared.zig");

const bpf = shared.bpf;

extern fn sol_memcpy_(dst: [*]u8, src: [*]const u8, n: u64) callconv(.c) void;
extern fn sol_memset_(dst: [*]u8, c: u8, n: u64) callconv(.c) void;
extern fn sol_memcmp_(a: [*]const u8, b: [*]const u8, n: u64, result: *i32) callconv(.c) void;

inline fn solMemcpy(dst: [*]u8, src: [*]const u8, n: usize) void {
    sol_memcpy_(dst, src, n);
}

inline fn solMemset(dst: [*]u8, c: u8, n: usize) void {
    sol_memset_(dst, c, n);
}

inline fn solMemcmp(a: [*]const u8, b: [*]const u8, n: usize) i32 {
    var result: i32 = 0;
    sol_memcmp_(a, b, n, &result);
    return result;
}

/// Copy memory from src to dst.
/// Uses `sol_memcpy_` on-chain and `@memcpy` on host.
pub inline fn memcpy(dst: [*]u8, src: [*]const u8, n: usize) void {
    if (bpf.is_bpf_program) {
        solMemcpy(dst, src, n);
    } else {
        @memcpy(dst[0..n], src[0..n]);
    }
}

/// Set memory to a specific byte value.
/// Uses `sol_memset_` on-chain and `@memset` on host.
pub inline fn memset(dst: [*]u8, c: u8, n: usize) void {
    if (bpf.is_bpf_program) {
        solMemset(dst, c, n);
    } else {
        @memset(dst[0..n], c);
    }
}

/// Compare two memory regions.
/// Uses `sol_memcmp_` on-chain and a byte loop on host.
pub inline fn memcmp(a: [*]const u8, b: [*]const u8, n: usize) i32 {
    if (bpf.is_bpf_program) {
        return solMemcmp(a, b, n);
    } else {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (a[i] != b[i]) {
                return @as(i32, a[i]) - @as(i32, b[i]);
            }
        }
        return 0;
    }
}

/// Zero out a memory region.
pub inline fn zero(dst: [*]u8, n: usize) void {
    memset(dst, 0, n);
}
