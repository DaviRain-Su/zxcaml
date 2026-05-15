//! Cryptographic primitives — aggregated namespace.
//!
//! This folder groups hash / curve / modular-arithmetic syscalls and the
//! native signature-verification instruction builders/parsers so related
//! code lives together physically as well as logically.

pub const hash = @import("hash.zig");
pub const secp256k1_recover = @import("secp256k1_recover.zig");
pub const alt_bn128 = @import("alt_bn128.zig");
pub const poseidon = @import("poseidon.zig");
pub const big_mod_exp = @import("big_mod_exp.zig");

pub const instructions = struct {
    pub const ed25519 = @import("instructions/ed25519.zig");
    pub const secp256k1 = @import("instructions/secp256k1.zig");
    pub const secp256r1 = @import("instructions/secp256r1.zig");
};

// Backwards-compatible aliases for the precompile instruction helpers.
pub const ed25519_instruction = instructions.ed25519;
pub const secp256k1_instruction = instructions.secp256k1;
pub const secp256r1_instruction = instructions.secp256r1;

// Most-used helpers re-exported flat so the common case stays short.
pub const Hash = hash.Hash;
pub const sha256 = hash.sha256;
pub const keccak256 = hash.keccak256;
pub const blake3 = hash.blake3;
pub const hashv = hash.hashv;
pub const bigModExp = big_mod_exp.bigModExp;
