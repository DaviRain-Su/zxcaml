//! Solana syscall bindings for generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Centralize MurmurHash3-32 dispatch addresses for Solana BPF syscalls.
//! - Expose safe Zig-shaped wrappers that generated user code can call.
//! - Provide deterministic hosted fallbacks for native tests and builds.

const std = @import("std");
const builtin = @import("builtin");
const Arena = @import("arena.zig").Arena;
const vendored_sdk = @import("vendored_sdk");
const sol = vendored_sdk.solana_program_sdk;
const sdk_hash = sol.hash;
const sdk_secp256k1_recover = sol.secp256k1_recover;
const sdk_clock = sol.clock;
const sdk_rent = sol.rent;
const sdk_compute_budget = sol.compute_budget;

/// 32-byte Solana public key or hash value.
pub const Pubkey = [32]u8;

/// 32-byte hash output produced by Solana hash syscalls.
pub const Hash = [32]u8;

/// 64-byte uncompressed secp256k1 public key returned by Solana recovery.
pub const Secp256k1Pubkey = [64]u8;

pub const secp256k1_hash_len: usize = 32;
pub const secp256k1_signature_len: usize = 64;
pub const secp256k1_pubkey_len: usize = 64;

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
pub const sol_log_address: usize = 0x207559bd;
/// MurmurHash3-32 dispatch address for `sol_log_64_`.
pub const sol_log_64_address: usize = 0x5c2a3178;
/// MurmurHash3-32 dispatch address for `sol_log_pubkey`.
pub const sol_log_pubkey_address: usize = 0x7ef088ca;
/// MurmurHash3-32 dispatch address for `sol_sha256`.
pub const sol_sha256_address: usize = 0x11f49d86;
/// MurmurHash3-32 dispatch address for `sol_keccak256`.
pub const sol_keccak256_address: usize = 0xd7793abb;
/// MurmurHash3-32 dispatch address for `sol_blake3`.
pub const sol_blake3_address: usize = 0x174c5122;
/// MurmurHash3-32 dispatch address for `sol_secp256k1_recover`.
pub const sol_secp256k1_recover_address: usize = 0x17e40350;
/// MurmurHash3-32 dispatch address for `sol_get_clock_sysvar`.
pub const sol_get_clock_sysvar_address: usize = 0xd56b5fe9;
/// MurmurHash3-32 dispatch address for `sol_get_rent_sysvar`.
pub const sol_get_rent_sysvar_address: usize = 0xbf7188f6;
/// MurmurHash3-32 dispatch address for `sol_log_compute_units_`.
pub const sol_log_compute_units_address: usize = 0x52ba5096;
/// MurmurHash3-32 dispatch address for `sol_remaining_compute_units`.
pub const sol_remaining_compute_units_address: usize = 0xedef5aee;

const is_bpf = std.mem.eql(u8, @tagName(builtin.target.cpu.arch), "sbf") or
    std.mem.eql(u8, @tagName(builtin.target.cpu.arch), "bpfel") or
    std.mem.eql(u8, @tagName(builtin.target.cpu.arch), "bpfeb");

const Syscall = struct {
    extern fn sol_log_(ptr: [*]const u8, len: u64) callconv(.c) void;
    extern fn sol_log_64_(a: u64, b: u64, c: u64, d: u64, e: u64) callconv(.c) void;
    extern fn sol_log_pubkey(pubkey: *const Pubkey) callconv(.c) void;
    extern fn sol_sha256(descriptor: [*]const SolBytes, descriptor_len: u64, out: [*]u8) callconv(.c) u64;
    extern fn sol_keccak256(descriptor: [*]const SolBytes, descriptor_len: u64, out: [*]u8) callconv(.c) u64;
    extern fn sol_blake3(descriptor: [*]const SolBytes, descriptor_len: u64, out: [*]u8) callconv(.c) u64;
    extern fn sol_secp256k1_recover(hash: [*]const u8, recovery_id: u64, signature: [*]const u8, out: [*]u8) callconv(.c) u64;
    extern fn sol_get_clock_sysvar(out: *Clock) callconv(.c) u64;
    extern fn sol_get_rent_sysvar(out: *Rent) callconv(.c) u64;
    extern fn sol_log_compute_units_() callconv(.c) void;
};

/// Logs a UTF-8 byte slice through Solana's `sol_log_` syscall.
pub inline fn sol_log_(message: []const u8) void {
    if (comptime is_bpf) {
        Syscall.sol_log_(message.ptr, message.len);
    }
}

/// Logs five unsigned 64-bit values through Solana's `sol_log_64_` syscall.
pub inline fn sol_log_64_(a: i64, b: i64, c: i64, d: i64, e: i64) void {
    if (comptime is_bpf) {
        Syscall.sol_log_64_(@bitCast(a), @bitCast(b), @bitCast(c), @bitCast(d), @bitCast(e));
    }
}

/// Logs a public key through Solana's `sol_log_pubkey` syscall.
pub inline fn sol_log_pubkey(pubkey: *const Pubkey) void {
    if (comptime is_bpf) {
        Syscall.sol_log_pubkey(pubkey);
    }
}

/// Computes a SHA-256 digest through Solana's syscall on BPF, or std.crypto on hosted targets.
pub inline fn sol_sha256(payload: []const u8) Hash {
    const parts = [_][]const u8{payload};
    const digest = sdk_hash.sha256(&parts) catch return std.mem.zeroes(Hash);
    return digest.bytes;
}

/// Computes SHA-256 and returns an arena-owned byte slice suitable for OCaml `bytes`.
pub inline fn sol_sha256_alloc(arena: *Arena, payload: []const u8) []const u8 {
    const digest = sol_sha256(payload);
    var out: []u8 = undefined;
    arena.allocIntoOrTrap(u8, digest.len, &out);
    @memcpy(out, &digest);
    return out;
}

/// Computes a Keccak-256 digest through Solana's syscall on BPF, or std.crypto on hosted targets.
pub inline fn sol_keccak256(payload: []const u8) Hash {
    const parts = [_][]const u8{payload};
    const digest = sdk_hash.keccak256(&parts) catch return std.mem.zeroes(Hash);
    return digest.bytes;
}

/// Computes Keccak-256 and returns an arena-owned byte slice suitable for OCaml `bytes`.
pub inline fn sol_keccak256_alloc(arena: *Arena, payload: []const u8) []const u8 {
    const digest = sol_keccak256(payload);
    var out: []u8 = undefined;
    arena.allocIntoOrTrap(u8, digest.len, &out);
    @memcpy(out, &digest);
    return out;
}

/// Computes a BLAKE3 digest through Solana's syscall on BPF, or std.crypto on hosted targets.
pub inline fn sol_blake3(payload: []const u8) Hash {
    const parts = [_][]const u8{payload};
    const digest = sdk_hash.blake3(&parts) catch return std.mem.zeroes(Hash);
    return digest.bytes;
}

/// Computes BLAKE3 and returns an arena-owned 32-byte slice suitable for OCaml `bytes`.
pub inline fn sol_blake3_alloc(arena: *Arena, payload: []const u8) []const u8 {
    const digest = sol_blake3(payload);
    var out: []u8 = undefined;
    arena.allocIntoOrTrap(u8, digest.len, &out);
    @memcpy(out, &digest);
    return out;
}

/// Recovers a 64-byte secp256k1 public key through Solana's SVM ABI.
///
/// The on-chain syscall ABI mirrors Solana's SDK exactly:
/// `(hash: *const u8, recovery_id: u64, signature: *const u8, result: *mut u8) -> u64`.
/// Invalid lengths or recovery IDs surface as a failure (`null`) rather than a
/// stdlib-side trap; callers that need OCaml `bytes` should use the arena
/// wrapper below, which maps failure to a 0-length slice.
pub inline fn sol_secp256k1_recover(hash: []const u8, recovery_id: i64, signature: []const u8) ?Secp256k1Pubkey {
    if (hash.len != secp256k1_hash_len or signature.len != secp256k1_signature_len) return null;
    if (recovery_id < 0 or recovery_id > 3) return null;

    const recovered = sdk_secp256k1_recover.recover(hash, @intCast(recovery_id), signature) catch return null;
    return recovered.bytes;
}

/// Recovers a secp256k1 pubkey directly into account data.
///
/// This helper intentionally avoids a 64-byte intermediate stack or arena
/// buffer. The BPF path passes `account_data.ptr` to the Solana syscall as the
/// result pointer, and the hosted fallback writes the deterministic
/// success-shaped bytes directly into `account_data[0..64]`.
pub inline fn sol_secp256k1_recover_into_account_data(account_data: []u8, hash: []const u8, recid: i64, signature: []const u8) i64 {
    if (account_data.len < secp256k1_pubkey_len) return 1;
    if (hash.len != secp256k1_hash_len) return 1;
    if (signature.len != secp256k1_signature_len) return 1;
    if (recid < 0 or recid > 3) return 1;

    const recovered = sdk_secp256k1_recover.recover(hash, @intCast(recid), signature) catch return 1;
    @memcpy(account_data[0..secp256k1_pubkey_len], &recovered.bytes);
    return 0;
}

/// Recovers a secp256k1 pubkey and returns arena-owned OCaml `bytes`.
///
/// On success the returned slice is exactly 64 bytes. On any runtime failure
/// (including recovery IDs outside 0-3) the returned slice has length 0.
pub inline fn sol_secp256k1_recover_alloc(arena: *Arena, hash: []const u8, recovery_id: i64, signature: []const u8) []const u8 {
    const pubkey = sol_secp256k1_recover(hash, recovery_id, signature) orelse return &[_]u8{};
    var out: []u8 = undefined;
    arena.allocIntoOrTrap(u8, pubkey.len, &out);
    @memcpy(out, &pubkey);
    return out;
}

/// Reads the Clock sysvar through Solana's `sol_get_clock_sysvar` syscall.
pub inline fn sol_get_clock_sysvar() Clock {
    if (comptime is_bpf) {
        const clock = sdk_clock.Clock.get() catch return .{};
        return .{
            .slot = clock.slot,
            .epoch_start_timestamp = clock.epoch_start_timestamp,
            .epoch = clock.epoch,
            .leader_schedule_epoch = clock.leader_schedule_epoch,
            .unix_timestamp = clock.unix_timestamp,
        };
    }
    return .{};
}

/// Reads the Rent sysvar through Solana's `sol_get_rent_sysvar` syscall.
pub inline fn sol_get_rent_sysvar() Rent {
    if (comptime is_bpf) {
        const rent = sdk_rent.Rent.get() catch return .{};
        return .{
            .lamports_per_byte_year = rent.lamports_per_byte_year,
            .exemption_threshold = rent.exemption_threshold,
            .burn_percent = rent.burn_percent,
        };
    }
    return .{};
}

/// Logs the currently consumed compute units through Solana's runtime.
pub inline fn sol_log_compute_units_() void {
    if (comptime is_bpf) {
        Syscall.sol_log_compute_units_();
    }
}

/// Returns the remaining compute units reported by Solana's runtime.
pub inline fn sol_remaining_compute_units() u64 {
    if (comptime is_bpf) {
        return sdk_compute_budget.remaining();
    }
    return 0;
}

test "syscall dispatch addresses match Solana MurmurHash3-32 values" {
    try std.testing.expectEqual(@as(usize, 0x207559bd), sol_log_address);
    try std.testing.expectEqual(@as(usize, 0x5c2a3178), sol_log_64_address);
    try std.testing.expectEqual(@as(usize, 0x7ef088ca), sol_log_pubkey_address);
    try std.testing.expectEqual(@as(usize, 0x11f49d86), sol_sha256_address);
    try std.testing.expectEqual(@as(usize, 0xd7793abb), sol_keccak256_address);
    try std.testing.expectEqual(@as(usize, 0x174c5122), sol_blake3_address);
    try std.testing.expectEqual(@as(usize, 0x17e40350), sol_secp256k1_recover_address);
    try std.testing.expectEqual(@as(usize, 0xd56b5fe9), sol_get_clock_sysvar_address);
    try std.testing.expectEqual(@as(usize, 0xbf7188f6), sol_get_rent_sysvar_address);
    try std.testing.expectEqual(@as(usize, 0x52ba5096), sol_log_compute_units_address);
    try std.testing.expectEqual(@as(usize, 0xedef5aee), sol_remaining_compute_units_address);
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

    const blake3 = sol_blake3("abc");
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x64, 0x37, 0xb3, 0xac, 0x38, 0x46, 0x51, 0x33, 0xff, 0xb6, 0x3b, 0x75, 0x27, 0x3a, 0x8d, 0xb5, 0x48, 0xc5, 0x58, 0x46, 0x5d, 0x79, 0xdb, 0x03, 0xfd, 0x35, 0x9c, 0x6c, 0xd5, 0xbd, 0x9d, 0x85 },
        &blake3,
    );
}

test "keccak256 arena wrapper returns fixed 32-byte digest" {
    var buf: [64]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&buf);

    const digest = sol_keccak256_alloc(&arena, "abc");
    try std.testing.expectEqual(@as(usize, 32), digest.len);
    try std.testing.expectEqual(@as(usize, 32), arena.offset);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x4e, 0x03, 0x65, 0x7a, 0xea, 0x45, 0xa9, 0x4f, 0xc7, 0xd4, 0x7b, 0xa8, 0x26, 0xc8, 0xd6, 0x67, 0xc0, 0xd1, 0xe6, 0xe3, 0x3a, 0x64, 0xa0, 0x36, 0xec, 0x44, 0xf5, 0x8f, 0xa1, 0x2d, 0x6c, 0x45 },
        digest,
    );
}

test "blake3 arena wrapper returns fixed 32-byte digest" {
    var buf: [64]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&buf);

    const digest = sol_blake3_alloc(&arena, "abc");
    try std.testing.expectEqual(@as(usize, 32), digest.len);
    try std.testing.expectEqual(@as(usize, 32), arena.offset);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x64, 0x37, 0xb3, 0xac, 0x38, 0x46, 0x51, 0x33, 0xff, 0xb6, 0x3b, 0x75, 0x27, 0x3a, 0x8d, 0xb5, 0x48, 0xc5, 0x58, 0x46, 0x5d, 0x79, 0xdb, 0x03, 0xfd, 0x35, 0x9c, 0x6c, 0xd5, 0xbd, 0x9d, 0x85 },
        digest,
    );
}

test "secp256k1_recover arena wrapper returns explicit zero-length sentinel off-chain" {
    var buf: [128]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&buf);
    const hash = [_]u8{0x11} ** secp256k1_hash_len;
    const signature = [_]u8{0x22} ** secp256k1_signature_len;

    const pubkey = sol_secp256k1_recover_alloc(&arena, &hash, 1, &signature);
    try std.testing.expectEqual(@as(usize, 0), pubkey.len);
    try std.testing.expectEqual(@as(usize, 0), arena.offset);
}

test "secp256k1_recover arena wrapper maps invalid recovery id to zero-length bytes" {
    var buf: [128]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&buf);
    const hash = [_]u8{0x11} ** secp256k1_hash_len;
    const signature = [_]u8{0x22} ** secp256k1_signature_len;

    const too_large = sol_secp256k1_recover_alloc(&arena, &hash, 4, &signature);
    try std.testing.expectEqual(@as(usize, 0), too_large.len);
    try std.testing.expectEqual(@as(usize, 0), arena.offset);

    const negative = sol_secp256k1_recover_alloc(&arena, &hash, -1, &signature);
    try std.testing.expectEqual(@as(usize, 0), negative.len);
    try std.testing.expectEqual(@as(usize, 0), arena.offset);
}

test "secp256k1_recover arena wrapper maps invalid input lengths to zero-length bytes" {
    var buf: [128]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&buf);
    const hash_short = [_]u8{0x11} ** 31;
    const hash = [_]u8{0x11} ** secp256k1_hash_len;
    const signature_short = [_]u8{0x22} ** 63;

    try std.testing.expectEqual(@as(usize, 0), sol_secp256k1_recover_alloc(&arena, &hash_short, 1, &signature_short).len);
    try std.testing.expectEqual(@as(usize, 0), sol_secp256k1_recover_alloc(&arena, &hash, 1, &signature_short).len);
    try std.testing.expectEqual(@as(usize, 0), arena.offset);
}

test "secp256k1_recover_into_account_data rejects recovery id out of range" {
    var account_data: [secp256k1_pubkey_len]u8 = undefined;
    const hash = [_]u8{0x11} ** secp256k1_hash_len;
    const signature = [_]u8{0x22} ** secp256k1_signature_len;

    try std.testing.expect(sol_secp256k1_recover_into_account_data(&account_data, &hash, 4, &signature) != 0);
    try std.testing.expect(sol_secp256k1_recover_into_account_data(&account_data, &hash, -1, &signature) != 0);
}

test "secp256k1_recover_into_account_data rejects short account data" {
    var account_data: [secp256k1_pubkey_len - 1]u8 = undefined;
    const hash = [_]u8{0x11} ** secp256k1_hash_len;
    const signature = [_]u8{0x22} ** secp256k1_signature_len;

    try std.testing.expect(sol_secp256k1_recover_into_account_data(&account_data, &hash, 1, &signature) != 0);
}

test "secp256k1_recover_into_account_data leaves caller buffer untouched off-chain" {
    var account_data = [_]u8{0xaa} ** (secp256k1_pubkey_len + 4);
    const hash = [_]u8{0x11} ** secp256k1_hash_len;
    const signature = [_]u8{0x22} ** secp256k1_signature_len;

    const rc = sol_secp256k1_recover_into_account_data(&account_data, &hash, 2, &signature);
    try std.testing.expect(rc != 0);
    try std.testing.expectEqual(@as(u8, 0xaa), account_data[0]);
    try std.testing.expectEqual(@as(u8, 0xaa), account_data[1]);
    try std.testing.expectEqual(@as(u8, 0xaa), account_data[secp256k1_pubkey_len - 1]);
    try std.testing.expectEqual(@as(u8, 0xaa), account_data[secp256k1_pubkey_len]);
}

test "unsupported hosted syscall fallbacks stay explicit" {
    const clock = sol_get_clock_sysvar();
    const rent = sol_get_rent_sysvar();

    try std.testing.expectEqual(@as(u64, 0), clock.slot);
    try std.testing.expectEqual(@as(i64, 0), clock.unix_timestamp);
    try std.testing.expectEqual(@as(u64, 0), rent.lamports_per_byte_year);
    try std.testing.expectEqual(@as(f64, 0), rent.exemption_threshold);
    try std.testing.expectEqual(@as(u8, 0), rent.burn_percent);
    try std.testing.expectEqual(@as(u64, 0), sol_remaining_compute_units());
}
