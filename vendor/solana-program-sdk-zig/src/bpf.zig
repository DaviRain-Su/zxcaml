const std = @import("std");
const builtin = @import("builtin");
const pubkey_mod = @import("pubkey/root.zig");
const pda_mod = @import("pda/root.zig");

const PublicKey = pubkey_mod.Pubkey;

pub const bpf_loader_deprecated_program_id = pubkey_mod.comptimeFromBase58("BPFLoader1111111111111111111111111111111111");
pub const bpf_loader_program_id = pubkey_mod.comptimeFromBase58("BPFLoader2111111111111111111111111111111111");
pub const bpf_upgradeable_loader_program_id = pubkey_mod.comptimeFromBase58("BPFLoaderUpgradeab1e11111111111111111111111");

pub const UpgradeableLoaderState = union(enum(u32)) {
    pub const ProgramData = struct {
        slot: u64,
        upgrade_authority_id: ?PublicKey,
    };

    uninitialized: void,
    buffer: struct {
        authority_id: ?PublicKey,
    },
    program: struct {
        program_data_id: PublicKey,
    },
    program_data: ProgramData,
};

/// Derive the upgradeable loader's ProgramData address for `program_id`.
///
/// Equivalent to Rust:
/// `Pubkey::find_program_address(&[program_id.as_ref()], &bpf_loader_upgradeable::id()).0`.
pub fn getUpgradeableLoaderProgramDataId(program_id: *const PublicKey) !PublicKey {
    const loader_id = bpf_upgradeable_loader_program_id;
    const pda = try pda_mod.findProgramAddress(
        &[_][]const u8{program_id[0..]},
        &loader_id,
    );
    return pda.address;
}

pub const is_bpf_program = !builtin.is_test and
    ((builtin.os.tag == .freestanding and builtin.cpu.arch == .bpfel) or
        builtin.cpu.arch == .sbf);

// =============================================================================
// Tests
// =============================================================================

test "bpf: getUpgradeableLoaderProgramDataId compiles & runs on host" {
    const dummy = pubkey_mod.comptimeFromBase58("11111111111111111111111111111111");
    _ = try getUpgradeableLoaderProgramDataId(&dummy);
}
