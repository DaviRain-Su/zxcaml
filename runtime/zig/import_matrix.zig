const std = @import("std");

const runtime = @import("root.zig");
const legacy_arena = @import("arena.zig");
const legacy_account = @import("account.zig");
const legacy_cpi = @import("cpi.zig");
const legacy_entry_context = @import("entry_context.zig");
const legacy_transfer_sol = @import("programs/transfer_sol.zig");

test "runtime public import matrix resolves canonical roots and legacy aliases" {
    try std.testing.expectEqual(@sizeOf(runtime.core.Arena), @sizeOf(legacy_arena.Arena));
    try std.testing.expectEqual(@sizeOf(runtime.solana.AccountView), @sizeOf(legacy_account.AccountView));
    try std.testing.expectEqual(@sizeOf(runtime.solana.Pubkey), @sizeOf(legacy_cpi.Pubkey));
    try std.testing.expectEqual(@sizeOf(runtime.shims.InstructionContext), @sizeOf(legacy_entry_context.InstructionContext));

    try std.testing.expectEqual(@as(usize, 32), runtime.sdk.solana_program_sdk.hash.HASH_BYTES);
    try std.testing.expectEqual(@as(usize, 32), runtime.solana.spl_token.pubkey_len);
    try std.testing.expectEqual(@as(usize, 44), runtime.core.bs58.pubkey32_encoded_len);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(runtime.sdk.solana_program_sdk.entrypoint.InstructionContext));
    _ = runtime.programs.transfer_sol.zxcaml_transfer_sol_process;
    _ = legacy_transfer_sol.zxcaml_transfer_sol_process;

    _ = runtime.programs.ata;
    _ = runtime.programs.transfer_sol;
    _ = runtime.programs.vault;
    _ = runtime.programs.vault_v2;

    try std.testing.expectEqualStrings("runtime/zig/bpf_entry.zig", runtime.shims.bpf_entry_source);
    try std.testing.expectEqualStrings("runtime/zig/native_entry.zig", runtime.shims.native_entry_source);
}
