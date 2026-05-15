const std = @import("std");
const shared = @import("shared.zig");
const bpf = shared.bpf;
const Pubkey = shared.Pubkey;
const PUBKEY_BYTES = shared.PUBKEY_BYTES;

/// Compare two pubkeys for equality
///
/// On BPF, Pubkeys handed out by the runtime (account keys, owners,
/// instruction program_id) are always 8-byte aligned, so we go straight
/// to the four-u64 fast path. On host targets we keep the runtime
/// alignment check to be safe against arbitrarily aligned callers.
pub inline fn pubkeyEq(a: *const Pubkey, b: *const Pubkey) bool {
    if (bpf.is_bpf_program) {
        return pubkeyEqAligned(a, b);
    }

    const a_addr = @intFromPtr(a);
    const b_addr = @intFromPtr(b);
    if (a_addr & 7 == 0 and b_addr & 7 == 0) {
        return pubkeyEqAligned(a, b);
    }

    // Fallback: byte-wise comparison (handles unaligned pointers)
    var i: usize = 0;
    while (i < PUBKEY_BYTES) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

/// Compare two pubkeys for equality — assumes pointers are 8-byte aligned
///
/// ⚠️ SAFETY: Caller must ensure both pointers are 8-byte aligned.
///            Use this when comparing pubkeys from serialized account data
///            where alignment is guaranteed by the runtime.
///
/// This is ~33% faster than pubkeyEq when alignment is known.
pub inline fn pubkeyEqAligned(a: *const Pubkey, b: *const Pubkey) bool {
    const a_chunks: *const [4]u64 = @ptrCast(@alignCast(a));
    const b_chunks: *const [4]u64 = @ptrCast(@alignCast(b));
    // Kept as `and`-chain (not xor-or) — runtime-vs-runtime compares
    // benefit from BPFv2's cmp+jmp fusion that lets each pair be
    // `ldxdw + ldxdw + jne` (2 ALU + 1 cond branch = 3 inst/pair).
    // The xor-or shape costs +9 CU on `pubkey_cmp_unchecked` because
    // it forces a full materialization of all 4 differences. For
    // **comptime** RHS we use xor-or instead (see `pubkeyEqComptime`)
    // — there the immediate-load is the dominant cost so collapsing
    // 4 branches into 1 is a net win.
    return a_chunks[0] == b_chunks[0] and
        a_chunks[1] == b_chunks[1] and
        a_chunks[2] == b_chunks[2] and
        a_chunks[3] == b_chunks[3];
}

/// Compare a runtime pubkey against a compile-time-known pubkey.
///
/// The expected value is split into four `u64` immediates at compile
/// time, so the generated BPF code reads four `u64`s from the runtime
/// pubkey and compares each against an `imm64` — no second pointer to
/// dereference, no `&MY_ID` rodata load (which on BPF can land at an
/// invalid low address).
///
/// Prefer this over `pubkeyEq(a, &MY_PROGRAM_ID)` whenever the right
/// operand is a `pub const` / literal pubkey.
pub inline fn pubkeyEqComptime(
    a: *const Pubkey,
    comptime expected: Pubkey,
) bool {
    const e: [4]u64 = comptime blk: {
        var out: [4]u64 = undefined;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            out[i] = std.mem.readInt(u64, expected[i * 8 ..][0..8], .little);
        }
        break :blk out;
    };

    if (bpf.is_bpf_program) {
        const a_chunks: *const [4]u64 = @ptrCast(@alignCast(a));
        // XOR-OR shape: gives LLVM the option to use a single final
        // compare (one branch) instead of an `and`-chain that early-
        // outs on each mismatch. On BPFv2 the immediate-load cost
        // (`mov32`+`hor64`) is the same either way, so collapsing 4
        // branches into 1 saves ~3 CU on the happy path. Mirrors the
        // pattern used in Pinocchio's `Pubkey::eq` on Solana SBPF.
        const diff = (a_chunks[0] ^ e[0]) |
            (a_chunks[1] ^ e[1]) |
            (a_chunks[2] ^ e[2]) |
            (a_chunks[3] ^ e[3]);
        return diff == 0;
    }

    // Host: unaligned-safe path
    var buf: [4]u64 = undefined;
    @memcpy(std.mem.sliceAsBytes(buf[0..]), a[0..]);
    return buf[0] == e[0] and buf[1] == e[1] and buf[2] == e[2] and buf[3] == e[3];
}

/// Compare a runtime pubkey against multiple comptime-known pubkeys.
///
/// Returns `true` if `a` matches **any** of the entries in
/// `comptime allowed`. Each comparison uses the same 4×u64 immediate
/// shape as `pubkeyEqComptime`, so a 2-way check is ~2× the CU of a
/// single `pubkeyEqComptime` call.
///
/// Typical use: a program accepting either SPL Token or Token-2022 as
/// the mint/account owner:
///
/// ```zig
/// if (!sol.pubkey.pubkeyEqAny(mint.owner(), &.{
///     sol.spl_token_program_id,
///     sol.spl_token_2022_program_id,
/// })) return error.IncorrectProgramId;
/// ```
///
/// The `inline for` unrolls at compile time; for N == 1 this folds to
/// `pubkeyEqComptime` exactly.
pub inline fn pubkeyEqAny(
    a: *const Pubkey,
    comptime allowed: []const Pubkey,
) bool {
    inline for (allowed) |expected| {
        if (pubkeyEqComptime(a, expected)) return true;
    }
    return false;
}
