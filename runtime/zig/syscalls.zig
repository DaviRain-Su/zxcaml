//! Solana syscall bindings for generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Centralize MurmurHash3-32 dispatch addresses for Solana BPF syscalls.
//! - Expose safe Zig-shaped wrappers that generated user code can call.
//! - Provide deterministic hosted fallbacks for native tests and builds.

const std = @import("std");
const builtin = @import("builtin");
const Arena = @import("arena.zig").Arena;

/// 32-byte Solana public key or hash value.
pub const Pubkey = [32]u8;

/// 32-byte hash output produced by Solana hash syscalls.
pub const Hash = [32]u8;

/// C ABI byte slice descriptor consumed by Solana hash syscalls.
pub const SolBytes = extern struct {
    addr: [*]const u8,
    len: u64,
};

/// Solana Clock sysvar layout.
pub const Clock = extern struct {
    slot: u64 = 0,
    epoch_start_timestamp: i64 = 0,
    epoch: u64 = 0,
    leader_schedule_epoch: u64 = 0,
    unix_timestamp: i64 = 0,
};

/// Solana Rent sysvar layout.
pub const Rent = extern struct {
    lamports_per_byte_year: u64 = 0,
    exemption_threshold: f64 = 0,
    burn_percent: u8 = 0,
};

/// MurmurHash3-32 dispatch address for `sol_log_`.
pub const sol_log_address: usize = 0x20755f21;
/// MurmurHash3-32 dispatch address for `sol_log_64_`.
pub const sol_log_64_address: usize = 0x5c2a3178;
/// MurmurHash3-32 dispatch address for `sol_log_pubkey`.
pub const sol_log_pubkey_address: usize = 0x7ef08fcb;
/// MurmurHash3-32 dispatch address for `sol_sha256`.
pub const sol_sha256_address: usize = 0x11f49d42;
/// MurmurHash3-32 dispatch address for `sol_keccak256`.
pub const sol_keccak256_address: usize = 0xd763ada3;
/// MurmurHash3-32 dispatch address for `sol_get_clock_sysvar`.
pub const sol_get_clock_sysvar_address: usize = 0x85532d94;
/// MurmurHash3-32 dispatch address for `sol_get_rent_sysvar`.
pub const sol_get_rent_sysvar_address: usize = 0x9aca9a41;
/// MurmurHash3-32 dispatch address for `sol_remaining_compute_units`.
pub const sol_remaining_compute_units_address: usize = 0x4e3bc231;

const is_bpf = builtin.target.cpu.arch == .bpfel or builtin.target.cpu.arch == .bpfeb;

const SolLogFn = *align(1) const fn ([*]const u8, u64) void;
const SolLog64Fn = *align(1) const fn (u64, u64, u64, u64, u64) void;
const SolLogPubkeyFn = *align(1) const fn (*const Pubkey) void;
const SolHashFn = *align(1) const fn (*const SolBytes, u64, *Hash) void;
const SolGetClockSysvarFn = *align(1) const fn (*Clock) u64;
const SolGetRentSysvarFn = *align(1) const fn (*Rent) u64;
const SolRemainingComputeUnitsFn = *align(1) const fn () u64;

/// Logs a UTF-8 byte slice through Solana's `sol_log_` syscall.
pub fn sol_log_(message: []const u8) void {
    if (comptime is_bpf) {
        const syscall: SolLogFn = @ptrFromInt(sol_log_address);
        syscall(message.ptr, message.len);
    }
}

/// Logs five unsigned 64-bit values through Solana's `sol_log_64_` syscall.
pub fn sol_log_64_(a: i64, b: i64, c: i64, d: i64, e: i64) void {
    if (comptime is_bpf) {
        const syscall: SolLog64Fn = @ptrFromInt(sol_log_64_address);
        syscall(@bitCast(a), @bitCast(b), @bitCast(c), @bitCast(d), @bitCast(e));
    }
}

/// Logs a public key through Solana's `sol_log_pubkey` syscall.
pub fn sol_log_pubkey(pubkey: *const Pubkey) void {
    if (comptime is_bpf) {
        const syscall: SolLogPubkeyFn = @ptrFromInt(sol_log_pubkey_address);
        syscall(pubkey);
    }
}

/// Computes a SHA-256 digest through Solana's syscall on BPF, or std.crypto on hosted targets.
pub fn sol_sha256(payload: []const u8) Hash {
    if (comptime is_bpf) {
        var descriptor = [_]SolBytes{.{ .addr = payload.ptr, .len = payload.len }};
        var out: Hash = undefined;
        const syscall: SolHashFn = @ptrFromInt(sol_sha256_address);
        syscall(&descriptor, descriptor.len, &out);
        return out;
    } else {
        var out: Hash = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &out, .{});
        return out;
    }
}

/// Computes SHA-256 and returns an arena-owned byte slice suitable for OCaml `bytes`.
pub fn sol_sha256_alloc(arena: *Arena, payload: []const u8) []const u8 {
    const digest = sol_sha256(payload);
    const out = arena.alloc(u8, digest.len) catch unreachable;
    @memcpy(out, &digest);
    return out;
}

/// Computes a Keccak-256 digest through Solana's syscall on BPF, or std.crypto on hosted targets.
pub fn sol_keccak256(payload: []const u8) Hash {
    if (comptime is_bpf) {
        var descriptor = [_]SolBytes{.{ .addr = payload.ptr, .len = payload.len }};
        var out: Hash = undefined;
        const syscall: SolHashFn = @ptrFromInt(sol_keccak256_address);
        syscall(&descriptor, descriptor.len, &out);
        return out;
    } else {
        var out: Hash = undefined;
        std.crypto.hash.sha3.Keccak256.hash(payload, &out, .{});
        return out;
    }
}

/// Computes Keccak-256 and returns an arena-owned byte slice suitable for OCaml `bytes`.
pub fn sol_keccak256_alloc(arena: *Arena, payload: []const u8) []const u8 {
    const digest = sol_keccak256(payload);
    const out = arena.alloc(u8, digest.len) catch unreachable;
    @memcpy(out, &digest);
    return out;
}

/// Reads the Clock sysvar through Solana's `sol_get_clock_sysvar` syscall.
pub fn sol_get_clock_sysvar() Clock {
    var clock: Clock = .{};
    if (comptime is_bpf) {
        const syscall: SolGetClockSysvarFn = @ptrFromInt(sol_get_clock_sysvar_address);
        _ = syscall(&clock);
    }
    return clock;
}

/// Reads the Rent sysvar through Solana's `sol_get_rent_sysvar` syscall.
pub fn sol_get_rent_sysvar() Rent {
    var rent: Rent = .{};
    if (comptime is_bpf) {
        const syscall: SolGetRentSysvarFn = @ptrFromInt(sol_get_rent_sysvar_address);
        _ = syscall(&rent);
    }
    return rent;
}

/// Returns the remaining compute units reported by Solana's runtime.
pub fn sol_remaining_compute_units() u64 {
    if (comptime is_bpf) {
        const syscall: SolRemainingComputeUnitsFn = @ptrFromInt(sol_remaining_compute_units_address);
        return syscall();
    }
    return 0;
}

test "syscall dispatch addresses match Solana MurmurHash3-32 values" {
    try std.testing.expectEqual(@as(usize, 0x20755f21), sol_log_address);
    try std.testing.expectEqual(@as(usize, 0x5c2a3178), sol_log_64_address);
    try std.testing.expectEqual(@as(usize, 0x7ef08fcb), sol_log_pubkey_address);
    try std.testing.expectEqual(@as(usize, 0x11f49d42), sol_sha256_address);
    try std.testing.expectEqual(@as(usize, 0xd763ada3), sol_keccak256_address);
    try std.testing.expectEqual(@as(usize, 0x85532d94), sol_get_clock_sysvar_address);
    try std.testing.expectEqual(@as(usize, 0x9aca9a41), sol_get_rent_sysvar_address);
    try std.testing.expectEqual(@as(usize, 0x4e3bc231), sol_remaining_compute_units_address);
}

test "hosted hash fallbacks match known SHA-256 and Keccak-256 vectors" {
    const sha = sol_sha256("abc");
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad },
        &sha,
    );

    const keccak = sol_keccak256("abc");
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x4e, 0x03, 0x65, 0x7a, 0xea, 0x45, 0xa9, 0x4f, 0xc7, 0xd4, 0x7b, 0xa8, 0x26, 0xc8, 0xd6, 0x67, 0xc0, 0xd1, 0xe6, 0xe3, 0x3a, 0x64, 0xa0, 0x36, 0xec, 0x44, 0xf5, 0x8f, 0xa1, 0x2d, 0x6c, 0x45 },
        &keccak,
    );
}
