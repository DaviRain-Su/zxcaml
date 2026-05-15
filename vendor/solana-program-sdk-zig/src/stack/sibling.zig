const shared = @import("shared.zig");

const std = shared.std;
const Pubkey = shared.Pubkey;
const AccountMeta = shared.AccountMeta;
const is_solana = shared.is_solana;

/// FFI shape that the `sol_get_processed_sibling_instruction` syscall
/// reads/writes. `#[repr(C)]` in Rust → identical layout in `extern struct`.
pub const ProcessedSiblingMeta = extern struct {
    /// Length of the instruction data buffer the caller must provide on
    /// the second syscall invocation.
    data_len: u64,
    /// Number of `AccountMeta` entries the caller must provide on the
    /// second syscall invocation.
    accounts_len: u64,
};

extern fn sol_get_processed_sibling_instruction(
    index: u64,
    meta: *ProcessedSiblingMeta,
    program_id: *Pubkey,
    data: [*]u8,
    accounts: [*]AccountMeta,
) callconv(.c) u64;

/// Probe a sibling instruction without copying its data/accounts.
///
/// Returns:
///   - `meta.data_len`, `meta.accounts_len` — required buffer sizes.
///   - `program_id` — pubkey of the sibling's program.
///   - `null` if no sibling exists at `index`.
///
/// Intended for "do I have N siblings?" or "is the previous sibling
/// program X?" checks where the data/accounts aren't actually needed.
pub fn siblingMeta(index: u64) ?struct {
    meta: ProcessedSiblingMeta,
    program_id: Pubkey,
} {
    if (comptime !is_solana) return null;

    var meta: ProcessedSiblingMeta = .{ .data_len = 0, .accounts_len = 0 };
    var pid: Pubkey = @splat(0);
    // Single-byte stubs — runtime ignores them on the discovery call,
    // but the syscall ABI doesn't accept null pointers, so we hand it
    // a real address.
    var data_stub: [1]u8 = .{0};
    var accts_stub: [1]AccountMeta = undefined;

    const present = sol_get_processed_sibling_instruction(
        index,
        &meta,
        &pid,
        &data_stub,
        &accts_stub,
    );
    if (present != 1) return null;
    return .{ .meta = meta, .program_id = pid };
}

/// Sibling instruction view backed by caller-provided buffers.
pub const ProcessedSibling = struct {
    program_id: Pubkey,
    /// Filled-in instruction data (subset of caller's buffer if
    /// `data_buf.len > meta.data_len`).
    data: []u8,
    /// Filled-in account metas (subset of caller's slice).
    accounts: []AccountMeta,
};

/// Two-call protocol with caller-provided scratch buffers.
///
/// Pass buffers at least `meta.data_len` / `meta.accounts_len` long
/// (use `siblingMeta(index)` first to learn the sizes). Returns `null`
/// if no sibling exists at `index`.
///
/// If the runtime reports lengths larger than the caller-provided
/// buffers, the returned slices are clamped to the copied prefix
/// instead of slicing past local buffer bounds.
pub fn getProcessedSiblingInstruction(
    index: u64,
    data_buf: []u8,
    accounts_buf: []AccountMeta,
) ?ProcessedSibling {
    if (comptime !is_solana) return null;

    var meta: ProcessedSiblingMeta = .{
        .data_len = data_buf.len,
        .accounts_len = accounts_buf.len,
    };
    var pid: Pubkey = @splat(0);

    const present = sol_get_processed_sibling_instruction(
        index,
        &meta,
        &pid,
        data_buf.ptr,
        accounts_buf.ptr,
    );
    if (present != 1) return null;
    return .{
        .program_id = pid,
        .data = data_buf[0..copiedSiblingSliceLen(data_buf.len, meta.data_len)],
        .accounts = accounts_buf[0..copiedSiblingSliceLen(accounts_buf.len, meta.accounts_len)],
    };
}

fn copiedSiblingSliceLen(buffer_len: usize, reported_len: u64) usize {
    const capped: usize = if (reported_len > std.math.maxInt(usize))
        std.math.maxInt(usize)
    else
        @intCast(reported_len);
    return @min(buffer_len, capped);
}

/// Convenience: probe → allocate → fetch. Useful when the sibling sizes
/// aren't known at compile time.
pub fn getProcessedSiblingInstructionAlloc(
    index: u64,
    allocator: std.mem.Allocator,
) !?ProcessedSibling {
    const probe = siblingMeta(index) orelse return null;
    const data_buf = try allocator.alloc(u8, @intCast(probe.meta.data_len));
    errdefer allocator.free(data_buf);
    const accts_buf = try allocator.alloc(
        AccountMeta,
        @intCast(probe.meta.accounts_len),
    );
    errdefer allocator.free(accts_buf);
    return getProcessedSiblingInstruction(index, data_buf, accts_buf);
}

test "sibling: copied slice lengths clamp to caller buffers" {
    try std.testing.expectEqual(@as(usize, 0), copiedSiblingSliceLen(0, 0));
    try std.testing.expectEqual(@as(usize, 2), copiedSiblingSliceLen(4, 2));
    try std.testing.expectEqual(@as(usize, 4), copiedSiblingSliceLen(4, 4));
    try std.testing.expectEqual(@as(usize, 4), copiedSiblingSliceLen(4, 9));
}
