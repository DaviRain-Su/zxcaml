//! Vendored Solana SDK adapter shell.
//!
//! Keep this root intentionally narrow: importing the full upstream
//! `solana-program-sdk-zig` root pulls in large host-only helper/test surfaces
//! that the current `solana-zig` toolchain trips over during direct BPF builds.
//! M2 only needs the syscall/sysvar primitives below, so this shell re-exports
//! those focused modules plus the already-vendored companion packages.

pub const solana_program_sdk = struct {
    pub const hash = @import("solana_sdk_m2").hash;
    pub const secp256k1_recover = @import("solana_sdk_m2").secp256k1_recover;
    pub const clock = @import("solana_sdk_m2").clock;
    pub const rent = @import("solana_sdk_m2").rent;
    pub const compute_budget = @import("solana_sdk_m2").compute_budget;
    pub const account = @import("solana_sdk_m2").account;
    pub const cpi = @import("solana_sdk_m2").cpi;
    pub const entrypoint = @import("solana_sdk_m2").entrypoint;
    pub const pda = @import("solana_sdk_m2").pda;
    pub const program_error = @import("solana_sdk_m2").program_error;
};
