const shared = @import("shared.zig");

const std = shared.stdlib;
const log = shared.log;
const discriminator = shared.discriminator;
const bpf = shared.bpf;
const DISCRIMINATOR_LEN = shared.DISCRIMINATOR_LEN;
const MAX_EVENT_SIZE = shared.MAX_EVENT_SIZE;

/// Pull the `DISCRIMINATOR` decl off `T` if it has one, otherwise
/// compute `sha256("event:" ++ @typeName(T))[..8]`.
pub fn discriminatorFor(comptime T: type) [DISCRIMINATOR_LEN]u8 {
    if (@hasDecl(T, "DISCRIMINATOR")) {
        const d = @field(T, "DISCRIMINATOR");
        if (@TypeOf(d) == [DISCRIMINATOR_LEN]u8) return d;
    }
    const name = comptime trimTypeName(@typeName(T));
    return discriminator.forEvent(name);
}

/// Strip everything before the last `.` in a fully-qualified type name
/// so `mymod.MyEvent` and `MyEvent` produce the same discriminator.
pub fn trimTypeName(comptime full: []const u8) []const u8 {
    return comptime blk: {
        var idx: usize = full.len;
        while (idx > 0) : (idx -= 1) {
            if (full[idx - 1] == '.') break;
        }
        break :blk full[idx..];
    };
}

/// Emit a structured event. `T` must be an `extern struct` and its
/// total wire size (8-byte discriminator + sizeof T) must fit in
/// `MAX_EVENT_SIZE`.
///
/// On host the call is a no-op (well, prints to stderr); on BPF it
/// dispatches `sol_log_data` with the assembled slice.
pub fn emit(value: anytype) void {
    const T = @TypeOf(value);
    comptime {
        const info = @typeInfo(T);
        if (info != .@"struct") {
            @compileError("emit(value): value must be an extern struct, got " ++ @typeName(T));
        }
        if (info.@"struct".layout != .@"extern") {
            @compileError("emit(value): value must be an extern struct (got layout " ++
                @tagName(info.@"struct".layout) ++ ")");
        }
        if (DISCRIMINATOR_LEN + @sizeOf(T) > MAX_EVENT_SIZE) {
            @compileError("emit(value): payload exceeds MAX_EVENT_SIZE — " ++
                "split into smaller events or raise MAX_EVENT_SIZE");
        }
    }

    const disc = comptime discriminatorFor(T);

    const Packed = extern struct {
        disc: [DISCRIMINATOR_LEN]u8 align(1),
        payload: T align(1),
    };
    const packed_val = Packed{ .disc = disc, .payload = value };
    const buf: [@sizeOf(Packed)]u8 = @bitCast(packed_val);
    const payload: []const u8 = &buf;

    if (bpf.is_bpf_program) {
        const slices = [_][]const u8{payload};
        log.logData(&slices);
    } else {
        std.debug.print(
            "[solana] event {s}: payload_size={d}\n",
            .{ trimTypeName(@typeName(T)), @sizeOf(T) },
        );
    }
}
