const std = @import("std");

pub const Alignment = std.mem.Alignment;

/// Heap start address for BPF programs (Solana convention).
pub const HEAP_START_ADDRESS: u64 = 0x300000000;

/// Default heap length (32KB).
pub const HEAP_LENGTH: usize = 32 * 1024;

/// Maximum heap length (256KB, as of Solana v1.17+).
pub const MAX_HEAP_LENGTH: usize = 256 * 1024;
