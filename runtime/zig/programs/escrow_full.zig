//! Runtime entrypoint for the escrow_full example.

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
const accountInfoFromView = cpi.accountInfoFromView;
const invoke = cpi.invoke;
const isSystemProgramKey = common.isSystemProgramKey;
const isZeroPubkeyBytes = common.isZeroPubkeyBytes;
const programIdFromInput = common.programIdFromInput;
const pubkeyEq = common.pubkeyEq;
const readU64LeSlice = common.readU64LeSlice;
const sol_create_program_address = cpi.sol_create_program_address;
const writeSystemTransferData = common.writeSystemTransferData;
const writeU64Le = common.writeU64Le;

const success: u64 = 0;

/// Processes the zignocchio-compatible escrow make/accept/refund dispatch.
///
/// zignocchio's source creates the escrow PDA with a System Program CPI. The
/// current Mollusk fixture preallocates that canonical bump-255 PDA as a
/// program-owned account so this helper can mutate lamports and the state bytes
/// directly, matching the established mocked-account pattern used by the
/// token_vault tests.
pub fn zxcaml_escrow_full_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len == 0) return 1;

    const program_id = programIdFromInput(input);
    return switch (instruction_data[0]) {
        0 => zxcamlEscrowMake(program_id, views, instruction_data),
        1 => zxcamlEscrowAccept(program_id, views),
        2 => zxcamlEscrowRefund(program_id, views),
        else => 1,
    };
}

const escrow_state_len: usize = 80;
const escrow_discriminator: u8 = 0xe5;
const escrow_taker_offset: usize = 33;
const escrow_amount_offset: usize = 72;
const escrow_rent_lamports: u64 = 6960;

fn zxcamlEscrowMake(program_id: *const Pubkey, views: []account.AccountView, instruction_data: []const u8) u64 {
    if (views.len < 3) return 1;
    if (instruction_data.len != 41) return 1;

    const maker = views[0];
    const escrow = views[1];
    const system_program = views[2];
    if (!maker.is_signer or !maker.is_writable) return 1;
    if (!escrow.is_writable) return 1;
    if (!isSystemProgramKey(system_program.key)) return 1;
    if (!pubkeyEq(escrow.owner, program_id)) return 1;
    if (!escrowPdaMatches(escrow.key, maker.key, program_id)) return 1;
    if (escrow.lamportsValue() != 0) return 1;
    if (escrow.data.len < escrow_state_len) return 1;

    const amount = readU64LeSlice(instruction_data[33..41]);
    if (amount == 0) return 1;
    const escrow_total = std.math.add(u64, amount, escrow_rent_lamports) catch return 1;
    if (maker.lamportsValue() < escrow_total) return 1;

    var data: [12]u8 = undefined;
    writeSystemTransferData(data[0..], escrow_total);

    var system_program_id = system_program.key.*;
    var metas = [_]SolAccountMeta{
        .{ .pubkey = maker.key, .is_writable = 1, .is_signer = 1 },
        .{ .pubkey = escrow.key, .is_writable = 1, .is_signer = 0 },
    };
    const instruction = SolInstruction.fromSlices(&system_program_id, metas[0..], data[0..]);
    var infos = [_]SolAccountInfo{
        accountInfoFromView(maker),
        accountInfoFromView(escrow),
    };
    if (invoke(&instruction, infos[0..]) != success) return 1;

    @memset(escrow.data[0..escrow_state_len], 0);
    escrow.data[0] = escrow_discriminator;
    @memcpy(escrow.data[1..33], maker.key[0..]);
    @memcpy(escrow.data[escrow_taker_offset..][0..32], instruction_data[1..33]);
    writeU64Le(escrow.data[escrow_amount_offset..][0..8], amount);
    return 0;
}

fn zxcamlEscrowAccept(program_id: *const Pubkey, views: []account.AccountView) u64 {
    if (views.len < 3) return 1;

    const taker = views[0];
    const escrow = views[1];
    const maker = views[2];
    if (!taker.is_signer or !taker.is_writable) return 1;
    if (!escrow.is_writable) return 1;
    if (!pubkeyEq(escrow.owner, program_id)) return 1;
    if (!escrowPdaMatches(escrow.key, maker.key, program_id)) return 1;
    if (!escrowStateIsInitialized(escrow.data)) return 1;

    const restricted_taker = escrow.data[escrow_taker_offset..][0..32];
    if (!isZeroPubkeyBytes(restricted_taker) and !std.mem.eql(u8, restricted_taker, taker.key[0..])) return 1;

    const amount = readU64LeSlice(escrow.data[escrow_amount_offset..][0..8]);
    if (amount == 0) return 1;
    const escrow_lamports = escrow.lamportsValue();
    if (escrow_lamports == 0) return 1;
    const taker_lamports = std.math.add(u64, taker.lamportsValue(), escrow_lamports) catch return 1;

    escrow.lamports.* = 0;
    taker.lamports.* = taker_lamports;
    escrow.data[0] = 0;
    return 0;
}

fn zxcamlEscrowRefund(program_id: *const Pubkey, views: []account.AccountView) u64 {
    if (views.len < 2) return 1;

    const maker = views[0];
    const escrow = views[1];
    if (!maker.is_signer or !maker.is_writable) return 1;
    if (!escrow.is_writable) return 1;
    if (!pubkeyEq(escrow.owner, program_id)) return 1;
    if (!escrowPdaMatches(escrow.key, maker.key, program_id)) return 1;
    if (!escrowStateIsInitialized(escrow.data)) return 1;

    const amount = readU64LeSlice(escrow.data[escrow_amount_offset..][0..8]);
    if (amount == 0) return 1;
    const escrow_lamports = escrow.lamportsValue();
    if (escrow_lamports == 0) return 1;
    const maker_lamports = std.math.add(u64, maker.lamportsValue(), escrow_lamports) catch return 1;

    escrow.lamports.* = 0;
    maker.lamports.* = maker_lamports;
    escrow.data[0] = 0;
    return 0;
}

fn escrowStateIsInitialized(data: []const u8) bool {
    return data.len >= escrow_state_len and data[0] == escrow_discriminator;
}

fn escrowPdaMatches(escrow_key: *const Pubkey, maker_key: *const Pubkey, program_id: *const Pubkey) bool {
    var escrow_seed: [6]u8 = .{ 'e', 's', 'c', 'r', 'o', 'w' };
    var maker_seed = maker_key.*;
    var bump_seed: [1]u8 = .{255};
    var seeds = [_]SolSignerSeed{
        SolSignerSeed.fromSlice(escrow_seed[0..]),
        SolSignerSeed.fromSlice(maker_seed[0..]),
        SolSignerSeed.fromSlice(bump_seed[0..]),
    };
    var expected: Pubkey = undefined;
    if (sol_create_program_address(seeds[0..], program_id, &expected) != success) return false;
    return pubkeyEq(escrow_key, &expected);
}

const EscrowFullTestAccount = struct {
    key: Pubkey = [_]u8{0} ** 32,
    owner: Pubkey = [_]u8{0} ** 32,
    lamports: u64 = 0,
    rent_epoch: u64 = 0,
    data: [escrow_state_len]u8 = [_]u8{0} ** escrow_state_len,

    fn view(self: *EscrowFullTestAccount, is_signer: bool, is_writable: bool, data_len: usize) account.AccountView {
        return .{
            .is_signer = is_signer,
            .is_writable = is_writable,
            .executable = false,
            .key = &self.key,
            .lamports = &self.lamports,
            .data = self.data[0..data_len],
            .owner = &self.owner,
            .rent_epoch = &self.rent_epoch,
        };
    }
};

const EscrowFullTestFixture = struct {
    program_id: Pubkey = [_]u8{0x31} ** 32,
    maker: EscrowFullTestAccount = .{ .key = [_]u8{1} ** 32, .lamports = 100_000 },
    taker: EscrowFullTestAccount = .{ .key = [_]u8{2} ** 32, .lamports = 3_000 },
    escrow: EscrowFullTestAccount = .{ .lamports = 9_000 },
    system: EscrowFullTestAccount = .{ .key = [_]u8{0} ** 32 },

    fn init() EscrowFullTestFixture {
        var fixture = EscrowFullTestFixture{};
        fixture.maker.key = findEscrowFullMakerForBump255(&fixture.program_id);
        fixture.escrow.key = deriveEscrowFullPda(&fixture.program_id, &fixture.maker.key);
        fixture.escrow.owner = fixture.program_id;
        return fixture;
    }

    fn initializeState(self: *EscrowFullTestFixture, restricted_taker: ?*const Pubkey, amount: u64) void {
        @memset(self.escrow.data[0..], 0);
        self.escrow.data[0] = escrow_discriminator;
        @memcpy(self.escrow.data[1..33], self.maker.key[0..]);
        if (restricted_taker) |key| {
            @memcpy(self.escrow.data[escrow_taker_offset..][0..32], key[0..]);
        }
        writeU64Le(self.escrow.data[escrow_amount_offset..][0..8], amount);
    }

    fn acceptViews(self: *EscrowFullTestFixture, taker_signer: bool) [3]account.AccountView {
        return .{
            self.taker.view(taker_signer, true, escrow_state_len),
            self.escrow.view(false, true, escrow_state_len),
            self.maker.view(false, false, escrow_state_len),
        };
    }

    fn refundViews(self: *EscrowFullTestFixture, maker_signer: bool) [2]account.AccountView {
        return .{
            self.maker.view(maker_signer, true, escrow_state_len),
            self.escrow.view(false, true, escrow_state_len),
        };
    }

    fn makeViews(self: *EscrowFullTestFixture, maker_signer: bool) [3]account.AccountView {
        return .{
            self.maker.view(maker_signer, true, escrow_state_len),
            self.escrow.view(false, true, escrow_state_len),
            self.system.view(false, false, escrow_state_len),
        };
    }
};

fn findEscrowFullMakerForBump255(program_id: *const Pubkey) Pubkey {
    for (0..256) |byte| {
        const maker: Pubkey = [_]u8{@intCast(byte)} ** 32;
        var escrow_seed: [6]u8 = .{ 'e', 's', 'c', 'r', 'o', 'w' };
        var maker_seed = maker;
        var bump_seed: [1]u8 = .{255};
        var seeds = [_]SolSignerSeed{
            SolSignerSeed.fromSlice(escrow_seed[0..]),
            SolSignerSeed.fromSlice(maker_seed[0..]),
            SolSignerSeed.fromSlice(bump_seed[0..]),
        };
        var expected: Pubkey = undefined;
        if (sol_create_program_address(seeds[0..], program_id, &expected) == success) return maker;
    }
    @panic("unable to find bump-255 escrow PDA fixture");
}

fn deriveEscrowFullPda(program_id: *const Pubkey, maker: *const Pubkey) Pubkey {
    var escrow_seed: [6]u8 = .{ 'e', 's', 'c', 'r', 'o', 'w' };
    var maker_seed = maker.*;
    var bump_seed: [1]u8 = .{255};
    var seeds = [_]SolSignerSeed{
        SolSignerSeed.fromSlice(escrow_seed[0..]),
        SolSignerSeed.fromSlice(maker_seed[0..]),
        SolSignerSeed.fromSlice(bump_seed[0..]),
    };
    var expected: Pubkey = undefined;
    if (sol_create_program_address(seeds[0..], program_id, &expected) != success) @panic("invalid escrow PDA fixture");
    return expected;
}

fn writeEscrowFullProgramInput(out: []u8, program_id: Pubkey) void {
    @memset(out, 0);
    writeU64Le(out[0..8], 0);
    writeU64Le(out[8..16], 0);
    @memcpy(out[16..48], program_id[0..]);
}

fn writeEscrowFullMakeIx(out: []u8, taker: Pubkey, amount: u64) void {
    out[0] = 0;
    @memcpy(out[1..33], taker[0..]);
    writeU64Le(out[33..41], amount);
}

test "escrow_full accept transfers escrow lamports to unrestricted taker" {
    var arena: Arena = undefined;
    var fixture = EscrowFullTestFixture.init();
    fixture.initializeState(null, 5_000);
    var views = fixture.acceptViews(true);
    var input: [48]u8 = undefined;
    writeEscrowFullProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(success, zxcaml_escrow_full_process(&arena, input[0..].ptr, views[0..], &.{1}));
    try std.testing.expectEqual(@as(u64, 12_000), fixture.taker.lamports);
    try std.testing.expectEqual(@as(u64, 0), fixture.escrow.lamports);
    try std.testing.expectEqual(@as(u8, 0), fixture.escrow.data[0]);
}

test "escrow_full accept rejects restricted taker mismatch" {
    var arena: Arena = undefined;
    var fixture = EscrowFullTestFixture.init();
    const other_taker: Pubkey = [_]u8{9} ** 32;
    fixture.initializeState(&other_taker, 5_000);
    var views = fixture.acceptViews(true);
    var input: [48]u8 = undefined;
    writeEscrowFullProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_escrow_full_process(&arena, input[0..].ptr, views[0..], &.{1}));
}

test "escrow_full accept rejects second accept after state is closed" {
    var arena: Arena = undefined;
    var fixture = EscrowFullTestFixture.init();
    fixture.initializeState(null, 5_000);
    var views = fixture.acceptViews(true);
    var input: [48]u8 = undefined;
    writeEscrowFullProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(success, zxcaml_escrow_full_process(&arena, input[0..].ptr, views[0..], &.{1}));
    try std.testing.expectEqual(@as(u64, 1), zxcaml_escrow_full_process(&arena, input[0..].ptr, views[0..], &.{1}));
}

test "escrow_full refund returns escrow lamports to maker" {
    var arena: Arena = undefined;
    var fixture = EscrowFullTestFixture.init();
    fixture.initializeState(&fixture.taker.key, 5_000);
    var views = fixture.refundViews(true);
    var input: [48]u8 = undefined;
    writeEscrowFullProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(success, zxcaml_escrow_full_process(&arena, input[0..].ptr, views[0..], &.{2}));
    try std.testing.expectEqual(@as(u64, 109_000), fixture.maker.lamports);
    try std.testing.expectEqual(@as(u64, 0), fixture.escrow.lamports);
    try std.testing.expectEqual(@as(u8, 0), fixture.escrow.data[0]);
}

test "escrow_full refund rejects second refund after state is closed" {
    var arena: Arena = undefined;
    var fixture = EscrowFullTestFixture.init();
    fixture.initializeState(null, 5_000);
    var views = fixture.refundViews(true);
    var input: [48]u8 = undefined;
    writeEscrowFullProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(success, zxcaml_escrow_full_process(&arena, input[0..].ptr, views[0..], &.{2}));
    try std.testing.expectEqual(@as(u64, 1), zxcaml_escrow_full_process(&arena, input[0..].ptr, views[0..], &.{2}));
}

test "make rejects non-signer maker before CPI" {
    var arena: Arena = undefined;
    var fixture = EscrowFullTestFixture.init();
    fixture.escrow.lamports = 0;
    var views = fixture.makeViews(false);
    var input: [48]u8 = undefined;
    writeEscrowFullProgramInput(input[0..], fixture.program_id);
    var ix: [41]u8 = undefined;
    writeEscrowFullMakeIx(ix[0..], fixture.taker.key, 5_000);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_escrow_full_process(&arena, input[0..].ptr, views[0..], ix[0..]));
}

test "make rejects zero escrow amount before CPI" {
    var arena: Arena = undefined;
    var fixture = EscrowFullTestFixture.init();
    fixture.escrow.lamports = 0;
    var views = fixture.makeViews(true);
    var input: [48]u8 = undefined;
    writeEscrowFullProgramInput(input[0..], fixture.program_id);
    var ix: [41]u8 = undefined;
    writeEscrowFullMakeIx(ix[0..], fixture.taker.key, 0);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_escrow_full_process(&arena, input[0..].ptr, views[0..], ix[0..]));
}
