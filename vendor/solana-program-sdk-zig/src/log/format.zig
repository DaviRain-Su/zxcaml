const shared = @import("shared.zig");
const raw = @import("raw.zig");

const std = shared.stdlib;
const hostPrint = shared.hostPrint;
const bpf = shared.bpf;
const log = raw.log;

/// Default formatted-log scratch buffer (BPF only).
///
/// 256 B keeps stack pressure low — BPF programs only have ~4 KiB of
/// stack and the entrypoint has already consumed some of it. If you
/// need bigger formatted logs use `printBuffered` with a custom buffer.
pub const default_print_buffer_size: usize = 256;

/// Log a formatted message.
///
/// On host, falls through to `std.debug.print`.
/// On BPF, formats into a 256-byte stack buffer and emits via
/// `sol_log_`. Output longer than the buffer is silently truncated;
/// use `printBuffered` for larger messages.
pub fn print(comptime format: []const u8, args: anytype) void {
    if (!bpf.is_bpf_program) {
        return hostPrint(format, args);
    }

    if (args.len == 0) {
        return log(format);
    }

    var buffer: [default_print_buffer_size]u8 = undefined;
    return printBuffered(&buffer, format, args);
}

/// Like `print`, but lets the caller provide the scratch buffer used
/// for formatting on BPF. Useful when 256 bytes isn't enough and you'd
/// rather pay the stack cost explicitly.
pub fn printBuffered(buffer: []u8, comptime format: []const u8, args: anytype) void {
    if (!bpf.is_bpf_program) {
        return hostPrint(format, args);
    }

    const message = std.fmt.bufPrint(buffer, format, args) catch buffer;
    log(message);
}
