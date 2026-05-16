//! Runtime entrypoint for the vault_v2 example.

const std = @import("std");
const Arena = @import("../arena.zig").Arena;
const account = @import("../account.zig");
const cpi = @import("../cpi.zig");
const common = @import("common.zig");

const Pubkey = cpi.Pubkey;
const SolAccountMeta = cpi.SolAccountMeta;
const SolInstruction = cpi.SolInstruction;
const SolAccountInfo = cpi.SolAccountInfo;
const SolSignerSeed = cpi.SolSignerSeed;
const SolSignerSeedsC = cpi.SolSignerSeedsC;
const accountInfoFromView = cpi.accountInfoFromView;
const invoke = cpi.invoke;
const sol_invoke_signed_c = cpi.sol_invoke_signed_c;
const sol_try_find_program_address = cpi.sol_try_find_program_address;
const pubkeyEq = common.pubkeyEq;
const programIdFromInput = common.programIdFromInput;
const readU64LeSlice = common.readU64LeSlice;
const writeSystemTransferData = common.writeSystemTransferData;

/// Processes the zignocchio-compatible vault_v2 example's deposit/withdraw dispatch.
pub fn zxcaml_vault_v2_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    if (views.len < 3) return 1;
    if (instruction_data.len == 0) return 1;
    if (!views[0].is_signer) return 1;

    const system_program_id: Pubkey = [_]u8{0} ** 32;
    if (!pubkeyEq(views[1].owner, &system_program_id)) return 1;
    if (!pubkeyEq(views[2].key, &system_program_id)) return 1;
    return zxcaml_vault_v2_process_with_program_id(arena, programIdFromInput(input), views, instruction_data);
}

pub fn zxcaml_vault_v2_process_with_program_id(arena: *Arena, program_id: *const Pubkey, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    if (views.len < 3) return 1;
    if (instruction_data.len == 0) return 1;
    if (!views[0].is_signer) return 1;

    const system_program_id: Pubkey = [_]u8{0} ** 32;
    if (!pubkeyEq(views[1].owner, &system_program_id)) return 1;
    if (!pubkeyEq(views[2].key, &system_program_id)) return 1;

    const derived = deriveVaultPda(views[0].key, program_id) orelse return 1;
    if (!pubkeyEq(views[1].key, &derived.address)) return 1;

    return switch (instruction_data[0]) {
        0 => zxcamlVaultV2Deposit(views, instruction_data),
        1 => zxcamlVaultV2Withdraw(views, derived.bump),
        else => 1,
    };
}

const DerivedVault = struct {
    address: Pubkey,
    bump: u8,
};

fn deriveVaultPda(owner_key: *const Pubkey, program_id: *const Pubkey) ?DerivedVault {
    var vault_seed: [5]u8 = .{ 'v', 'a', 'u', 'l', 't' };
    const seeds = [_]SolSignerSeed{
        SolSignerSeed.fromSlice(vault_seed[0..]),
        SolSignerSeed.fromSlice(owner_key[0..]),
    };
    var address: Pubkey = undefined;
    var bump: u8 = 0;
    if (sol_try_find_program_address(seeds[0..], program_id, &address, &bump) != 0) return null;
    return .{ .address = address, .bump = bump };
}

fn zxcamlVaultV2Deposit(views: []account.AccountView, instruction_data: []const u8) u64 {
    if (instruction_data.len != 9) return 1;
    if (views[1].lamportsValue() != 0) return 1;
    const amount = readU64LeSlice(instruction_data[1..9]);
    if (amount == 0) return 1;

    var data: [12]u8 = undefined;
    writeSystemTransferData(data[0..], amount);

    var program_id = views[2].key.*;
    var metas = [_]SolAccountMeta{
        .{ .pubkey = views[0].key, .is_writable = 1, .is_signer = 1 },
        .{ .pubkey = views[1].key, .is_writable = 1, .is_signer = 0 },
    };
    const instruction = SolInstruction.fromSlices(&program_id, metas[0..], data[0..]);
    var infos = [_]SolAccountInfo{
        accountInfoFromView(views[0]),
        accountInfoFromView(views[1]),
    };
    return invoke(&instruction, infos[0..]);
}

fn zxcamlVaultV2Withdraw(views: []account.AccountView, bump: u8) u64 {
    const amount = views[1].lamportsValue();
    if (amount == 0) return 1;

    var data: [12]u8 = undefined;
    writeSystemTransferData(data[0..], amount);

    var program_id = views[2].key.*;
    var metas = [_]SolAccountMeta{
        .{ .pubkey = views[1].key, .is_writable = 1, .is_signer = 1 },
        .{ .pubkey = views[0].key, .is_writable = 1, .is_signer = 0 },
    };
    const instruction = SolInstruction.fromSlices(&program_id, metas[0..], data[0..]);
    var infos = [_]SolAccountInfo{
        accountInfoFromView(views[1]),
        accountInfoFromView(views[0]),
    };

    var vault_seed: [5]u8 = .{ 'v', 'a', 'u', 'l', 't' };
    var owner_seed = views[0].key.*;
    var bump_seed: [1]u8 = .{bump};
    var c_seeds = [_]SolSignerSeed{
        SolSignerSeed.fromSlice(vault_seed[0..]),
        SolSignerSeed.fromSlice(owner_seed[0..]),
        SolSignerSeed.fromSlice(bump_seed[0..]),
    };
    var seed_groups = [_]SolSignerSeedsC{.{ .addr = c_seeds[0..].ptr, .len = c_seeds.len }};
    return sol_invoke_signed_c(&instruction, infos[0..], seed_groups[0..]);
}

const VaultV2TestAccount = struct {
    key: Pubkey = [_]u8{0} ** 32,
    owner: Pubkey = [_]u8{0} ** 32,
    lamports: u64 = 0,
    rent_epoch: u64 = 0,
    data: [8]u8 = [_]u8{0} ** 8,

    fn view(self: *VaultV2TestAccount, is_signer: bool, is_writable: bool) account.AccountView {
        return .{
            .is_signer = is_signer,
            .is_writable = is_writable,
            .executable = false,
            .key = &self.key,
            .lamports = &self.lamports,
            .data = self.data[0..],
            .owner = &self.owner,
            .rent_epoch = &self.rent_epoch,
        };
    }
};

const VaultV2TestFixture = struct {
    program_id: Pubkey = [_]u8{9} ** 32,
    owner: VaultV2TestAccount = .{ .key = [_]u8{1} ** 32, .lamports = 10_000 },
    vault: VaultV2TestAccount = .{ .key = [_]u8{2} ** 32 },
    system: VaultV2TestAccount = .{ .key = [_]u8{0} ** 32 },

    fn views(self: *VaultV2TestFixture, owner_signer: bool) [3]account.AccountView {
        return .{
            self.owner.view(owner_signer, true),
            self.vault.view(false, true),
            self.system.view(false, false),
        };
    }
};

fn writeVaultV2RuntimeInput(program_id: Pubkey) [48]u8 {
    var input: [48]u8 = [_]u8{0} ** 48;
    std.mem.writeInt(u64, input[0..8], 0, .little);
    std.mem.writeInt(u64, input[8..16], 0, .little);
    @memcpy(input[16..48], program_id[0..]);
    return input;
}

fn writeVaultV2U64LeTest(out: []u8, value: u64) void {
    var remaining = value;
    for (out[0..8]) |*byte| {
        byte.* = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
}

test "vault_v2 deposit rejects missing account views" {
    var arena: Arena = undefined;
    var views: [2]account.AccountView = undefined;
    try std.testing.expectEqual(@as(u64, 1), zxcaml_vault_v2_process(&arena, undefined, views[0..], &.{0}));
}

test "vault_v2 deposit rejects empty instruction data" {
    var arena: Arena = undefined;
    var fixture = VaultV2TestFixture{};
    var views = fixture.views(true);
    var input = writeVaultV2RuntimeInput(fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_vault_v2_process(&arena, input[0..].ptr, views[0..], &.{}));
}

test "vault_v2 deposit rejects non-signer owner before CPI" {
    var arena: Arena = undefined;
    var fixture = VaultV2TestFixture{};
    var views = fixture.views(false);
    var input = writeVaultV2RuntimeInput(fixture.program_id);
    var data: [9]u8 = undefined;
    data[0] = 0;
    writeVaultV2U64LeTest(data[1..9], 1);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_vault_v2_process(&arena, input[0..].ptr, views[0..], data[0..]));
}

test "vault_v2 deposit rejects vault owner mismatch before CPI" {
    var arena: Arena = undefined;
    var fixture = VaultV2TestFixture{};
    fixture.vault.owner = [_]u8{9} ** 32;
    var views = fixture.views(true);
    var input = writeVaultV2RuntimeInput(fixture.program_id);
    var data: [9]u8 = undefined;
    data[0] = 0;
    writeVaultV2U64LeTest(data[1..9], 1);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_vault_v2_process(&arena, input[0..].ptr, views[0..], data[0..]));
}

test "vault_v2 deposit rejects non-system program account before CPI" {
    var arena: Arena = undefined;
    var fixture = VaultV2TestFixture{};
    fixture.system.key = [_]u8{7} ** 32;
    var views = fixture.views(true);
    var input = writeVaultV2RuntimeInput(fixture.program_id);
    var data: [9]u8 = undefined;
    data[0] = 0;
    writeVaultV2U64LeTest(data[1..9], 1);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_vault_v2_process(&arena, input[0..].ptr, views[0..], data[0..]));
}

test "vault_v2 deposit rejects non-exact amount payload before CPI" {
    var arena: Arena = undefined;
    var fixture = VaultV2TestFixture{};
    var views = fixture.views(true);
    var input = writeVaultV2RuntimeInput(fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_vault_v2_process(&arena, input[0..].ptr, views[0..], &.{ 0, 1, 2 }));
}

test "vault_v2 deposit rejects pre-funded vault before CPI" {
    var arena: Arena = undefined;
    var fixture = VaultV2TestFixture{};
    fixture.vault.lamports = 1;
    var views = fixture.views(true);
    var input = writeVaultV2RuntimeInput(fixture.program_id);
    var data: [9]u8 = undefined;
    data[0] = 0;
    writeVaultV2U64LeTest(data[1..9], 5);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_vault_v2_process(&arena, input[0..].ptr, views[0..], data[0..]));
}

test "vault_v2 deposit rejects zero amount before CPI" {
    var arena: Arena = undefined;
    var fixture = VaultV2TestFixture{};
    var views = fixture.views(true);
    var input = writeVaultV2RuntimeInput(fixture.program_id);
    var data: [9]u8 = undefined;
    data[0] = 0;
    writeVaultV2U64LeTest(data[1..9], 0);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_vault_v2_process(&arena, input[0..].ptr, views[0..], data[0..]));
}

test "vault_v2 withdraw rejects empty vault before CPI" {
    var arena: Arena = undefined;
    var fixture = VaultV2TestFixture{};
    var views = fixture.views(true);
    var input = writeVaultV2RuntimeInput(fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_vault_v2_process(&arena, input[0..].ptr, views[0..], &.{1}));
}

test "vault_v2 dispatch rejects unknown discriminator" {
    var arena: Arena = undefined;
    var fixture = VaultV2TestFixture{};
    var views = fixture.views(true);
    var input = writeVaultV2RuntimeInput(fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_vault_v2_process(&arena, input[0..].ptr, views[0..], &.{99}));
}
