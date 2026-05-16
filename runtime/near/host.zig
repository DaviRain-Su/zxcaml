//! Minimal NEAR host ABI wrapper for the no-storage adapter MVP.
//!
//! RESPONSIBILITIES:
//! - Centralise the exact imported NEAR host signatures.
//! - Read raw method payload bytes through the NEAR register flow.
//! - Route observable return/log/panic behavior through NEAR host imports only.

const std = @import("std");

pub const input_register_id: u64 = 0;
pub const missing_register_len: u64 = std.math.maxInt(u64);
pub const max_input_bytes: usize = 64 * 1024;

extern "env" fn input(register_id: u64) void;
extern "env" fn register_len(register_id: u64) u64;
extern "env" fn read_register(register_id: u64, ptr: u64) void;
extern "env" fn value_return(len: u64, ptr: u64) void;
extern "env" fn log_utf8(len: u64, ptr: u64) void;
extern "env" fn panic_utf8(len: u64, ptr: u64) noreturn;

fn nearPtr(bytes: []const u8) u64 {
    return @intCast(@intFromPtr(bytes.ptr));
}

fn nearMutablePtr(bytes: []u8) u64 {
    return @intCast(@intFromPtr(bytes.ptr));
}

pub fn requireInput(storage: []u8) []const u8 {
    input(input_register_id);
    const payload_len = register_len(input_register_id);
    if (payload_len == missing_register_len) panic("near input register was not populated");
    if (payload_len == 0) panic("near input payload must not be empty");
    if (payload_len > max_input_bytes) panic("near input payload exceeds adapter limit");
    if (payload_len > storage.len) panic("near input payload does not fit adapter buffer");

    const bounded_len: usize = @intCast(payload_len);
    read_register(input_register_id, nearMutablePtr(storage));
    return storage[0..bounded_len];
}

pub fn finish(bytes: []const u8) void {
    value_return(@intCast(bytes.len), nearPtr(bytes));
}

pub fn log(message: []const u8) void {
    if (message.len == 0) return;
    log_utf8(@intCast(message.len), nearPtr(message));
}

pub fn panic(message: []const u8) noreturn {
    if (message.len == 0) {
        const fallback = "near adapter panic";
        panic_utf8(@intCast(fallback.len), nearPtr(fallback));
    }
    panic_utf8(@intCast(message.len), nearPtr(message));
}

pub fn encodeStatus(status: u64, storage: *[8]u8) []const u8 {
    std.mem.writeInt(u64, storage, status, .little);
    return storage[0..];
}
