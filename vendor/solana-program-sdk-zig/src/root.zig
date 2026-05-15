//! Top-level `solana_program_sdk` namespace.
//!
//! This file is the import hub that keeps the public API flat even though many
//! core families now live under directory-backed `root.zig` modules:
//!
//! - `sol.account.*` → `src/account/`
//! - `sol.account_cursor.*` → `src/account_cursor/`
//! - `sol.allocator.*` → `src/allocator/`
//! - `sol.pubkey.*` → `src/pubkey/`
//! - `sol.cpi.*` → `src/cpi/`
//! - `sol.entrypoint.*` → `src/entrypoint/`
//! - `sol.program_error.*` → `src/program_error/`
//! - `sol.instruction.*` → `src/instruction/`
//! - `sol.log.*` → `src/log/`
//! - `sol.math.*` → `src/math/`
//! - `sol.memory.*` → `src/memory/`
//! - `sol.pda.*` → `src/pda/`
//! - `sol.system.*` → `src/system/`
//! - `sol.sysvar.*` → `src/sysvar/`
//! - `sol.sysvar_instructions.*` → `src/sysvar_instructions/`
//! - `sol.typed_account.*` / `sol.TypedAccount(...)` → `src/typed_account/`
//! - `sol.event.*` → `src/event/`
//! - `sol.error_code.*` → `src/error_code/`
//! - `sol.require_mod.*` → `src/require/`
//! - `sol.stack.*` → `src/stack/`
//! - `sol.stake_history.*` → `src/stake_history/`
//!
//! The rest of this file groups those module namespaces, then re-exports the
//! short Pinocchio-style aliases (`sol.AccountInfo`, `sol.ProgramResult`,
//! `sol.verifyPda`, ... ) used in examples and downstream programs.

const std = @import("std");

// Foundational runtime-facing modules.
pub const pubkey = @import("pubkey/root.zig");
pub const account = @import("account/root.zig");
pub const account_cursor = @import("account_cursor/root.zig");
pub const program_error = @import("program_error/root.zig");
pub const entrypoint = @import("entrypoint/root.zig");
pub const instruction = @import("instruction/root.zig");
pub const cpi = @import("cpi/root.zig");
pub const system = @import("system/root.zig");
pub const sysvar = @import("sysvar/root.zig");
pub const sysvar_instructions = @import("sysvar_instructions/root.zig");
pub const typed_account = @import("typed_account/root.zig");

// Developer-facing utilities and supporting runtime helpers.
pub const log = @import("log/root.zig");
pub const allocator = @import("allocator/root.zig");
pub const hint = @import("hint.zig");
pub const memory = @import("memory/root.zig");
pub const stack = @import("stack/root.zig");
pub const math = @import("math/root.zig");
pub const compute_budget = @import("compute_budget.zig");
pub const bpf = @import("bpf.zig");

// Constraint / framework-style building blocks.
pub const discriminator = @import("discriminator.zig");
pub const error_code = @import("error_code/root.zig");
pub const event = @import("event/root.zig");
pub const require_mod = @import("require/root.zig");
pub const pda = @import("pda/root.zig");

// Additional protocol / sysvar data layouts and syscall wrappers.
pub const clock = @import("clock.zig");
pub const rent = @import("rent.zig");
pub const slot_hashes = @import("slot_hashes.zig");
pub const stake_history = @import("stake_history/root.zig");
pub const stake = @import("stake.zig");

// Cryptographic primitives — now physically grouped under `src/crypto/`.
// Flat aliases stay exported for backwards compatibility.
pub const crypto = @import("crypto/root.zig");
pub const hash = crypto.hash;
pub const secp256k1_recover = crypto.secp256k1_recover;
pub const alt_bn128 = crypto.alt_bn128;
pub const poseidon = crypto.poseidon;
pub const big_mod_exp = crypto.big_mod_exp;
pub const ed25519_instruction = crypto.ed25519_instruction;
pub const secp256k1_instruction = crypto.secp256k1_instruction;
pub const secp256r1_instruction = crypto.secp256r1_instruction;

// Panic handler namespace
/// Usage in your program: `pub const panic = solana_program_sdk.panic.Panic;`
pub const panic = @import("panic.zig");

// Short type aliases (Pinocchio-style naming convention).
pub const Pubkey = pubkey.Pubkey;
pub const PUBKEY_BYTES = pubkey.PUBKEY_BYTES;
pub const Account = account.Account;
pub const AccountInfo = account.AccountInfo;
pub const CpiAccountInfo = account.CpiAccountInfo;
pub const AccountCursor = account_cursor.AccountCursor;
pub const AccountWindow = account_cursor.AccountWindow;
pub const DuplicatePolicy = account_cursor.DuplicatePolicy;
pub const MaybeAccount = account.MaybeAccount;
pub const BumpAllocator = allocator.BumpAllocator;
pub const StakeHistory = stake_history.StakeHistory;
pub const StakeHistoryEntry = stake_history.Entry;
pub const InstructionContext = entrypoint.InstructionContext;
pub const IxDataCursor = instruction.IxDataCursor;
pub const IxDataStaging = instruction.IxDataStaging;
pub const CpiAccountStaging = cpi.CpiAccountStaging;
pub const ProgramError = program_error.ProgramError;
pub const ProgramResult = program_error.ProgramResult;
pub const SUCCESS = program_error.SUCCESS;
pub const customError = program_error.customError;

// Diagnostic helpers — log a tag before failing so deployed programs
// can pinpoint which constraint blew up without changing the wire
// return code. See `src/require/root.zig` for the full `require_*!` family.
pub const fail = program_error.fail;
pub const failFmt = program_error.failFmt;
pub const require = require_mod.require;
pub const requireEq = require_mod.requireEq;
pub const requireNeq = require_mod.requireNeq;
pub const requireKeysEq = require_mod.requireKeysEq;
pub const requireKeysNeq = require_mod.requireKeysNeq;

// High-frequency convenience aliases used directly in handlers.
pub const TypedAccount = typed_account.TypedAccount;
pub const ErrorCode = error_code.ErrorCode;
pub const discriminatorFor = discriminator.forAccount;
pub const eventDiscriminatorFor = discriminator.forEvent;
pub const DISCRIMINATOR_LEN = discriminator.DISCRIMINATOR_LEN;
pub const emit = event.emit;
pub const verifyPda = pda.verifyPda;
pub const verifyPdaCanonical = pda.verifyPdaCanonical;
pub const getStackHeight = stack.getStackHeight;
pub const TRANSACTION_LEVEL_STACK_HEIGHT = stack.TRANSACTION_LEVEL_STACK_HEIGHT;

// Instructions-sysvar introspection — Anchor `Sysvar<Instructions>` parity.
pub const loadCurrentIndexChecked = sysvar_instructions.loadCurrentIndexChecked;
pub const loadInstructionAtChecked = sysvar_instructions.loadInstructionAtChecked;
pub const getInstructionRelative = sysvar_instructions.getInstructionRelative;
pub const IntrospectedInstruction = sysvar_instructions.IntrospectedInstruction;

// Runtime-introspection and syscall-backed convenience aliases.
pub const remainingComputeUnits = compute_budget.remaining;
pub const getEpochStake = stake.getEpochStake;
pub const getSysvar = sysvar.getSysvar;
pub const getSysvarRef = sysvar.getSysvarRef;
pub const getSysvarBytes = sysvar.getSysvarBytes;
pub const bigModExp = big_mod_exp.bigModExp;

// Hash aliases — the three syscall-backed families and the `Hash` newtype.
pub const Hash = hash.Hash;
pub const sha256 = hash.sha256;
pub const keccak256 = hash.keccak256;
pub const blake3 = hash.blake3;
pub const hashv = hash.hashv;

// Constants
pub const lamports_per_sol = 1_000_000_000;

// Well-known program / sysvar IDs.
//
// ⚠️ These are module-scope `const` `Pubkey` values. On Zig 0.16 BPF
// builds, taking `&foo_id` and passing it to a syscall is unsafe — the
// rodata segment can be placed at low VM addresses that the runtime
// rejects. Use these constants only for comparisons (`pubkeyEq`,
// equality checks). For CPI calls, derive the program ID from a parsed
// `CpiAccountInfo` (e.g. `system_program.key()`) that the caller passed
// in as part of the instruction's accounts.

// Program IDs (comparison-only — see warning above re: rodata addresses)
pub const native_loader_id = pubkey.comptimeFromBase58("NativeLoader1111111111111111111111111111111");
pub const incinerator_id = pubkey.comptimeFromBase58("1nc1nerator11111111111111111111111111111111");
pub const sysvar_id = pubkey.comptimeFromBase58("Sysvar1111111111111111111111111111111111111");
pub const instructions_id = pubkey.comptimeFromBase58("Sysvar1nstructions1111111111111111111111111");
pub const ed25519_program_id = pubkey.comptimeFromBase58("Ed25519SigVerify111111111111111111111111111");
pub const secp256k1_program_id = pubkey.comptimeFromBase58("KeccakSecp256k11111111111111111111111111111");
pub const secp256r1_program_id = pubkey.comptimeFromBase58("Secp256r1SigVerify1111111111111111111111111");

// BPF Loader variants
pub const bpf_loader_id = bpf.bpf_loader_program_id;
pub const bpf_loader_deprecated_id = bpf.bpf_loader_deprecated_program_id;
pub const bpf_loader_upgradeable_id = bpf.bpf_upgradeable_loader_program_id;

// SPL Token / Token-2022 / Associated Token Account
//
// Use these for owner checks (e.g.
// `mint_account.isOwnedByComptime(sol.spl_token_program_id)`) and for
// constructing CPI instruction-data buffers. For CPI program-id args,
// always derive the address from a parsed `CpiAccountInfo` that was
// passed in by the caller — see the warning above re: rodata.
pub const spl_token_program_id = pubkey.comptimeFromBase58("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
pub const spl_token_2022_program_id = pubkey.comptimeFromBase58("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");
pub const spl_associated_token_account_id = pubkey.comptimeFromBase58("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
pub const spl_memo_program_id = pubkey.comptimeFromBase58("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr");

// Sysvar IDs
pub const clock_id = sysvar.CLOCK_ID;
pub const rent_id = sysvar.RENT_ID;
pub const epoch_schedule_id = sysvar.EPOCH_SCHEDULE_ID;
pub const slot_hashes_id = sysvar.SLOT_HASHES_ID;
pub const stake_history_id = sysvar.STAKE_HISTORY_ID;
pub const instructions_sysvar_id = sysvar.INSTRUCTIONS_ID;

// System Program — see warning above; for CPI use `system_program.key()`
// from a parsed `CpiAccountInfo`.
pub const system_program_id = system.SYSTEM_PROGRAM_ID;

const EmbeddedSource = struct {
    path: []const u8,
    text: []const u8,
};

const execution_source_files = [_]EmbeddedSource{
    .{ .path = "src/account_cursor/root.zig", .text = @embedFile("account_cursor/root.zig") },
    .{ .path = "src/account_cursor/shared.zig", .text = @embedFile("account_cursor/shared.zig") },
    .{ .path = "src/account_cursor/window.zig", .text = @embedFile("account_cursor/window.zig") },
    .{ .path = "src/account_cursor/cursor.zig", .text = @embedFile("account_cursor/cursor.zig") },
    .{ .path = "src/pubkey/root.zig", .text = @embedFile("pubkey/root.zig") },
    .{ .path = "src/pubkey/shared.zig", .text = @embedFile("pubkey/shared.zig") },
    .{ .path = "src/pubkey/base58.zig", .text = @embedFile("pubkey/base58.zig") },
    .{ .path = "src/pubkey/equality.zig", .text = @embedFile("pubkey/equality.zig") },
    .{ .path = "src/pubkey/curve.zig", .text = @embedFile("pubkey/curve.zig") },
    .{ .path = "src/instruction/root.zig", .text = @embedFile("instruction/root.zig") },
    .{ .path = "src/instruction/builders.zig", .text = @embedFile("instruction/builders.zig") },
    .{ .path = "src/instruction/reader.zig", .text = @embedFile("instruction/reader.zig") },
    .{ .path = "src/instruction/cursor.zig", .text = @embedFile("instruction/cursor.zig") },
    .{ .path = "src/instruction/staging.zig", .text = @embedFile("instruction/staging.zig") },
    .{ .path = "src/cpi/root.zig", .text = @embedFile("cpi/root.zig") },
    .{ .path = "src/cpi/instruction.zig", .text = @embedFile("cpi/instruction.zig") },
    .{ .path = "src/cpi/seeds.zig", .text = @embedFile("cpi/seeds.zig") },
    .{ .path = "src/cpi/staging.zig", .text = @embedFile("cpi/staging.zig") },
    .{ .path = "src/cpi/invoke.zig", .text = @embedFile("cpi/invoke.zig") },
    .{ .path = "src/cpi/return_data.zig", .text = @embedFile("cpi/return_data.zig") },
    .{ .path = "src/compute_budget.zig", .text = @embedFile("compute_budget.zig") },
    .{ .path = "src/math/root.zig", .text = @embedFile("math/root.zig") },
    .{ .path = "src/math/shared.zig", .text = @embedFile("math/shared.zig") },
    .{ .path = "src/math/checked.zig", .text = @embedFile("math/checked.zig") },
    .{ .path = "src/math/router.zig", .text = @embedFile("math/router.zig") },
};

const mock_only_source_paths = [_][]const u8{
    "examples/hello.zig",
    "examples/token_dispatch.zig",
    "examples/cpi.zig",
    "examples/pubkey.zig",
    "examples/vault.zig",
    "examples/escrow.zig",
    "examples/counter.zig",
    "examples/mock_router.zig",
    "examples/mock_adapter.zig",
    "program-test/build.zig",
    "program-test/tests/hello.rs",
    "program-test/tests/token_2022.rs",
    "program-test/tests/escrow.rs",
    "program-test/tests/counter.rs",
    "program-test/tests/spl_token.rs",
    "program-test/tests/spl_ata.rs",
    "program-test/tests/pubkey.rs",
    "program-test/tests/cpi.rs",
    "program-test/tests/spl_memo.rs",
    "program-test/tests/mock_router.rs",
};

const banned_offchain_terms = [_][]const u8{
    "solana_client",
    "solana_tx",
    "solana_keypair",
    "raydium",
    "orca",
    "meteora",
    "jupiter",
    "okx",
    "quote engine",
    "tx builder",
    "tx-builder",
    "searcher",
    "rpc client",
    "geyser",
    "jito",
};

fn containsAllocatorType(comptime T: type) bool {
    if (T == std.mem.Allocator) return true;

    return switch (@typeInfo(T)) {
        .array => |array_info| containsAllocatorType(array_info.child),
        .optional => |optional_info| containsAllocatorType(optional_info.child),
        .pointer => |pointer_info| containsAllocatorType(pointer_info.child),
        .@"struct" => |struct_info| blk: {
            inline for (struct_info.fields) |field| {
                if (containsAllocatorType(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn expectStructFieldsAllocatorFree(comptime T: type) !void {
    const info = @typeInfo(T);
    try std.testing.expect(info == .@"struct");
    inline for (info.@"struct".fields) |field| {
        try std.testing.expect(!containsAllocatorType(field.type));
    }
}

fn expectNoAllocatorParams(comptime func: anytype) !void {
    const info = @typeInfo(@TypeOf(func));
    try std.testing.expect(info == .@"fn");
    inline for (info.@"fn".params) |param| {
        if (param.type) |ParamT| {
            try std.testing.expect(!containsAllocatorType(ParamT));
        }
    }
}

fn indexOfAsciiIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn expectTextOmitsTerms(file_path: []const u8, text: []const u8, banned_terms: []const []const u8) !void {
    for (banned_terms) |term| {
        if (indexOfAsciiIgnoreCase(text, term)) |idx| {
            std.debug.print("forbidden term \"{s}\" found in {s} at byte {d}\n", .{ term, file_path, idx });
            return error.TestUnexpectedResult;
        }
    }
}

fn expectRepoFileOmitsTerms(file_path: []const u8, banned_terms: []const []const u8) !void {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const text = try std.Io.Dir.cwd().readFileAlloc(
        threaded.io(),
        file_path,
        std.testing.allocator,
        .limited(1 << 20),
    );
    defer std.testing.allocator.free(text);
    try expectTextOmitsTerms(file_path, text, banned_terms);
}

test "well-known program ids are canonical and non-conflicting" {
    var classic_out: [44]u8 = undefined;
    var token_2022_out: [44]u8 = undefined;
    var ata_out: [44]u8 = undefined;
    var bpf_loader_out: [44]u8 = undefined;
    var bpf_loader_deprecated_out: [44]u8 = undefined;
    var bpf_loader_upgradeable_out: [44]u8 = undefined;

    const classic_len = pubkey.encodeBase58(&spl_token_program_id, &classic_out);
    const token_2022_len = pubkey.encodeBase58(&spl_token_2022_program_id, &token_2022_out);
    const ata_len = pubkey.encodeBase58(&spl_associated_token_account_id, &ata_out);
    const bpf_loader_len = pubkey.encodeBase58(&bpf_loader_id, &bpf_loader_out);
    const bpf_loader_deprecated_len = pubkey.encodeBase58(&bpf_loader_deprecated_id, &bpf_loader_deprecated_out);
    const bpf_loader_upgradeable_len = pubkey.encodeBase58(&bpf_loader_upgradeable_id, &bpf_loader_upgradeable_out);

    try std.testing.expectEqualStrings(
        "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
        classic_out[0..classic_len],
    );
    try std.testing.expectEqualStrings(
        "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",
        token_2022_out[0..token_2022_len],
    );
    try std.testing.expectEqualStrings(
        "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL",
        ata_out[0..ata_len],
    );
    try std.testing.expectEqualStrings(
        "BPFLoader2111111111111111111111111111111111",
        bpf_loader_out[0..bpf_loader_len],
    );
    try std.testing.expectEqualStrings(
        "BPFLoader1111111111111111111111111111111111",
        bpf_loader_deprecated_out[0..bpf_loader_deprecated_len],
    );
    try std.testing.expectEqualStrings(
        "BPFLoaderUpgradeab1e11111111111111111111111",
        bpf_loader_upgradeable_out[0..bpf_loader_upgradeable_len],
    );
    try std.testing.expect(!pubkey.pubkeyEq(&spl_token_program_id, &spl_token_2022_program_id));
    try std.testing.expect(!pubkey.pubkeyEq(&spl_token_program_id, &spl_associated_token_account_id));
    try std.testing.expect(!pubkey.pubkeyEq(&spl_token_2022_program_id, &spl_associated_token_account_id));
    try std.testing.expect(!pubkey.pubkeyEq(&bpf_loader_id, &bpf_loader_deprecated_id));
    try std.testing.expect(!pubkey.pubkeyEq(&bpf_loader_id, &bpf_loader_upgradeable_id));
    try std.testing.expect(!pubkey.pubkeyEq(&bpf_loader_deprecated_id, &bpf_loader_upgradeable_id));
    try std.testing.expect(pubkey.pubkeyEq(&bpf_loader_id, &bpf.bpf_loader_program_id));
    try std.testing.expect(pubkey.pubkeyEq(&bpf_loader_deprecated_id, &bpf.bpf_loader_deprecated_program_id));
    try std.testing.expect(pubkey.pubkeyEq(&bpf_loader_upgradeable_id, &bpf.bpf_upgradeable_loader_program_id));
}

test "execution primitive root exports stay wired to core modules" {
    try std.testing.expect(BumpAllocator == allocator.BumpAllocator);
    try std.testing.expect(StakeHistory == stake_history.StakeHistory);
    try std.testing.expect(StakeHistoryEntry == stake_history.Entry);
    try std.testing.expect(IxDataStaging == instruction.IxDataStaging);
    try std.testing.expect(CpiAccountStaging == cpi.CpiAccountStaging);
    try std.testing.expect(@TypeOf(remainingComputeUnits) == @TypeOf(compute_budget.remaining));
    try std.testing.expectEqual(compute_budget.remaining(), remainingComputeUnits());
}

test "execution primitive hot-path APIs stay allocator free" {
    try expectStructFieldsAllocatorFree(IxDataCursor);
    try expectStructFieldsAllocatorFree(IxDataStaging);
    try expectStructFieldsAllocatorFree(CpiAccountStaging);

    try expectNoAllocatorParams(instruction.IxDataCursor.init);
    try expectNoAllocatorParams(instruction.IxDataStaging.init);
    try expectNoAllocatorParams(instruction.IxDataStaging.appendBytes);
    try expectNoAllocatorParams(cpi.stageDynamicAccountsWithPubkeys);
    try expectNoAllocatorParams(cpi.CpiAccountStaging.init);
    try expectNoAllocatorParams(cpi.CpiAccountStaging.appendAccount);
    try expectNoAllocatorParams(cpi.CpiAccountStaging.appendMetaInfo);
    try expectNoAllocatorParams(cpi.CpiAccountStaging.appendMetaInfoUnchecked);
    try expectNoAllocatorParams(cpi.CpiAccountStaging.appendProgram);
    try expectNoAllocatorParams(cpi.CpiAccountStaging.instructionFromProgram);
    try expectNoAllocatorParams(compute_budget.remaining);
    try expectNoAllocatorParams(compute_budget.hasAtLeast);
    try expectNoAllocatorParams(compute_budget.requireAtLeast);
    try expectNoAllocatorParams(compute_budget.requireRemaining);
}

test "execution primitive sources avoid off-chain product scope" {
    for (execution_source_files) |file| {
        try expectTextOmitsTerms(file.path, file.text, &banned_offchain_terms);
    }
}

test "examples and program-test remain mock only" {
    for (mock_only_source_paths) |file_path| {
        try expectRepoFileOmitsTerms(file_path, &banned_offchain_terms);
    }
}

test {
    std.testing.refAllDecls(@This());
}
