//! Instructions sysvar — introspect the currently-executing transaction.
//!
//! Solana exposes the entire transaction's serialized instructions through
//! the `Sysvar1nstructions1111111111111111111111111` account. Reading it
//! lets a program:
//!
//!   - Detect that a specific instruction (e.g. an ed25519 / secp256k1
//!     verification) was included earlier in the same transaction.
//!   - Enforce that a particular instruction MUST appear before / after
//!     ours (sandwich defence, pre-checks).
//!   - Read its own position in the transaction (`current_index`).
//!
//! Unlike Clock / Rent / EpochSchedule, the instructions sysvar has **no**
//! `sol_get_*_sysvar` syscall — the caller must pass the sysvar account
//! into the instruction's account list, and we parse its raw bytes.
//!
//! Wire format (matches `solana-program::sysvar::instructions`):
//! ```
//! [0..2)      u16 LE   num_instructions = N
//! [2..2+2N)   u16 LE[] instruction_offset[i] — start of instruction i
//! ... instructions packed back-to-back ...
//! [len-2..)   u16 LE   current_instruction_index
//! ```
//!
//! Each instruction at `offset[i]`:
//! ```
//! [+0..2)            u16 LE   num_accounts = K
//! repeat K times:
//!   [+0..1)          u8       meta_byte  (bit 0 = is_signer, bit 1 = is_writable)
//!   [+1..33)         [32]u8   pubkey
//! [+33K+2..33K+34)   [32]u8   program_id
//! [+33K+34..33K+36)  u16 LE   data_len = D
//! [+33K+36..)        [D]u8    data
//! ```
//!
//! All multi-byte fields are unaligned little-endian.
//!
//! Cost: O(K + D) byte reads per `loadInstructionAt` (no syscall —
//! just walks the buffer). For programs that already need the sysvar
//! account in their input, the marginal cost is just the parsing.
//!
//! Physical layout:
//! - `shared.zig` — common imports, sysvar ID, endian helpers
//! - `model.zig` — zero-copy introspected instruction / meta views
//! - `parser.zig` — checked readers and relative lookup helpers
//!
//! The public API stays flattened as `sol.sysvar_instructions.*`, plus
//! the root aliases `sol.loadCurrentIndexChecked(...)`,
//! `sol.loadInstructionAtChecked(...)`, `sol.getInstructionRelative(...)`,
//! and `sol.IntrospectedInstruction`.

const std = @import("std");
const shared = @import("shared.zig");
const testing = std.testing;
const Pubkey = shared.Pubkey;
const readU16LE = shared.readU16LE;
const model_mod = @import("model.zig");
const parser_mod = @import("parser.zig");
const deserialize = parser_mod.deserialize;

/// Canonical sysvar program ID.
pub const ID = shared.ID;

/// Zero-copy introspection model types.
pub const IntrospectedInstruction = model_mod.IntrospectedInstruction;
pub const IntrospectedAccountMeta = model_mod.IntrospectedAccountMeta;
pub const AccountIterator = model_mod.AccountIterator;

/// Checked parser entrypoints over the instructions-sysvar payload.
pub const loadCurrentIndexChecked = parser_mod.loadCurrentIndexChecked;
pub const loadInstructionAtChecked = parser_mod.loadInstructionAtChecked;
pub const getInstructionRelative = parser_mod.getInstructionRelative;

// =============================================================================
// Tests
// =============================================================================

/// Build a synthetic instructions-sysvar payload for unit tests.
/// Mirrors the Rust `construct_instructions_data` exactly.
fn buildSysvarPayload(
    comptime instructions: []const TestInstruction,
    current_index: u16,
) []u8 {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    // num_instructions
    buf.appendSlice(std.mem.asBytes(&@as(u16, @intCast(instructions.len)))) catch unreachable;
    // offset table (filled in below)
    for (instructions) |_| {
        buf.appendSlice(&[_]u8{ 0, 0 }) catch unreachable;
    }

    for (instructions, 0..) |ix, i| {
        const start: u16 = @intCast(buf.items.len);
        const table_offset = 2 + i * 2;
        @memcpy(buf.items[table_offset..][0..2], std.mem.asBytes(&start));

        buf.appendSlice(std.mem.asBytes(&@as(u16, @intCast(ix.accounts.len)))) catch unreachable;
        for (ix.accounts) |a| {
            const flags: u8 =
                (if (a.is_signer) @as(u8, 0b01) else 0) |
                (if (a.is_writable) @as(u8, 0b10) else 0);
            buf.append(flags) catch unreachable;
            buf.appendSlice(&a.pubkey) catch unreachable;
        }
        buf.appendSlice(&ix.program_id) catch unreachable;
        buf.appendSlice(std.mem.asBytes(&@as(u16, @intCast(ix.data.len)))) catch unreachable;
        buf.appendSlice(ix.data) catch unreachable;
    }

    // current index trailer
    buf.appendSlice(std.mem.asBytes(&current_index)) catch unreachable;

    return buf.toOwnedSlice() catch unreachable;
}

const TestAccount = struct {
    pubkey: Pubkey,
    is_signer: bool,
    is_writable: bool,
};
const TestInstruction = struct {
    program_id: Pubkey,
    accounts: []const TestAccount,
    data: []const u8,
};

test "sysvar_instructions: deserialize single instruction round-trip" {
    const pid = [_]u8{0x11} ** 32;
    const k1 = [_]u8{0x22} ** 32;
    const ixs = [_]TestInstruction{
        .{
            .program_id = pid,
            .accounts = &.{
                .{ .pubkey = k1, .is_signer = true, .is_writable = false },
            },
            .data = &.{ 0xde, 0xad, 0xbe, 0xef },
        },
    };
    const buf = buildSysvarPayload(&ixs, 0);
    defer std.testing.allocator.free(buf);

    const parsed = try deserialize(0, buf);
    try testing.expectEqual(@as(u16, 1), parsed.numAccounts());

    const meta = parsed.account(0);
    try testing.expect(meta.isSigner());
    try testing.expect(!meta.isWritable());
    try testing.expectEqualSlices(u8, &k1, meta.pubkey);

    try testing.expectEqualSlices(u8, &pid, parsed.programId());
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, parsed.data());
}

test "sysvar_instructions: deserialize index out of bounds → InvalidArgument" {
    const pid = [_]u8{0x33} ** 32;
    const ixs = [_]TestInstruction{
        .{ .program_id = pid, .accounts = &.{}, .data = &.{} },
    };
    const buf = buildSysvarPayload(&ixs, 0);
    defer std.testing.allocator.free(buf);

    try testing.expectError(error.InvalidArgument, deserialize(1, buf));
}

test "sysvar_instructions: multi-instruction layout" {
    const pid_a = [_]u8{0xa1} ** 32;
    const pid_b = [_]u8{0xb2} ** 32;
    const acc = [_]u8{0xcc} ** 32;
    const ixs = [_]TestInstruction{
        .{
            .program_id = pid_a,
            .accounts = &.{.{ .pubkey = acc, .is_signer = false, .is_writable = true }},
            .data = &.{ 0x01, 0x02 },
        },
        .{
            .program_id = pid_b,
            .accounts = &.{},
            .data = &.{ 0xff, 0xee, 0xdd },
        },
    };
    const buf = buildSysvarPayload(&ixs, 1);
    defer std.testing.allocator.free(buf);

    const second = try deserialize(1, buf);
    try testing.expectEqualSlices(u8, &pid_b, second.programId());
    try testing.expectEqual(@as(u16, 0), second.numAccounts());
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xee, 0xdd }, second.data());

    const first = try deserialize(0, buf);
    try testing.expectEqualSlices(u8, &pid_a, first.programId());
    var it = first.accounts();
    const m = it.next().?;
    try testing.expect(!m.isSigner());
    try testing.expect(m.isWritable());
}

test "sysvar_instructions: current index trailer" {
    const pid = [_]u8{0x99} ** 32;
    const ixs = [_]TestInstruction{
        .{ .program_id = pid, .accounts = &.{}, .data = &.{} },
        .{ .program_id = pid, .accounts = &.{}, .data = &.{} },
        .{ .program_id = pid, .accounts = &.{}, .data = &.{} },
    };
    const buf = buildSysvarPayload(&ixs, 2);
    defer std.testing.allocator.free(buf);

    // Read trailer directly — `loadCurrentIndexChecked` would also
    // verify the account key, which we can't synthesise without a
    // full AccountInfo here.
    const idx = readU16LE(buf, buf.len - 2);
    try testing.expectEqual(@as(u16, 2), idx);
}
