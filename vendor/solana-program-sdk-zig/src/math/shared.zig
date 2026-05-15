const std = @import("std");
const program_error = @import("../program_error/root.zig");

pub const ProgramError = program_error.ProgramError;

pub const ArithmeticError = error{
    InvalidArgument,
    ArithmeticOverflow,
};

pub const SlippageError = error{SlippageExceeded};
pub const RouterMathError = ArithmeticError || SlippageError;

pub const Rounding = enum {
    down,
    up,
};

pub const SlippageBound = enum {
    min_out,
    max_in,
};

pub const BASIS_POINTS_DENOMINATOR: u64 = 10_000;
pub const PARTS_PER_MILLION_DENOMINATOR: u64 = 1_000_000;

pub inline fn requireUnsignedInt(comptime T: type) void {
    comptime {
        const info = @typeInfo(T);
        if (info != .int or info.int.signedness != .unsigned) {
            @compileError("router math helpers require an unsigned integer type");
        }
    }
}
