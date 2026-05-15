const std = @import("std");
pub const log = @import("../log/root.zig");
pub const discriminator = @import("../discriminator.zig");
pub const bpf = @import("../bpf.zig");
pub const stdlib = std;

pub const DISCRIMINATOR_LEN = discriminator.DISCRIMINATOR_LEN;

/// Soft upper bound on a single emitted event payload (discriminator
/// + value). The runtime caps `sol_log_data` at a few KB anyway; we
/// pin to 256 bytes to discourage giant events that would dominate
/// the program's CU budget (`sol_log_data` charges ~1 CU per byte).
pub const MAX_EVENT_SIZE: usize = 256;
