const shared = @import("shared.zig");
const std = shared.std;

/// Helper for no-alloc instruction data serialization.
///
/// By providing a discriminant and data type, the dynamic type can be
/// constructed in-place and used for instruction data:
///
/// ```zig
/// const Discriminant = enum(u32) {
///     one,
/// };
/// const Data = packed struct {
///     field: u64
/// };
/// const data = InstructionData(Discriminant, Data){
///     .discriminant = Discriminant.one,
///     .data = .{ .field = 1 }
/// };
/// const instruction = cpi.Instruction{
///     .program_id = &program_id,
///     .accounts = &accounts,
///     .data = data.asBytes(),
/// };
/// ```
pub fn InstructionData(comptime Discriminant: type, comptime Data: type) type {
    comptime {
        if (@bitSizeOf(Discriminant) % 8 != 0) {
            @panic("Discriminant bit size is not divisible by 8");
        }
        if (@bitSizeOf(Data) % 8 != 0) {
            @panic("Data bit size is not divisible by 8");
        }
    }
    return packed struct {
        discriminant: Discriminant,
        data: Data,

        const Self = @This();

        /// Get the instruction data as a byte slice
        pub fn asBytes(self: *const Self) []const u8 {
            return std.mem.asBytes(self)[0..((@bitSizeOf(Discriminant) + @bitSizeOf(Data)) / 8)];
        }
    };
}

/// Compile-time instruction data builder.
///
/// Creates a fixed-size instruction data buffer where the discriminant
/// is set at compile time, and only variable fields are filled at runtime.
///
/// Example:
/// ```zig
/// const CreateAccountData = comptimeInstructionData(u32, struct {
///     lamports: u64,
///     space: u64,
///     owner: [32]u8,
/// });
/// var data = CreateAccountData.init(.{
///     .discriminant = 0,  // CreateAccount
///     .lamports = 500,
///     .space = 128,
///     .owner = owner_pubkey,
/// });
/// ```
pub fn comptimeInstructionData(
    comptime Discriminant: type,
    comptime Data: type,
) type {
    comptime {
        if (@bitSizeOf(Discriminant) % 8 != 0) {
            @panic("Discriminant bit size is not divisible by 8");
        }
        if (@bitSizeOf(Data) % 8 != 0) {
            @panic("Data bit size is not divisible by 8");
        }
    }

    const total_bytes = (@bitSizeOf(Discriminant) + @bitSizeOf(Data)) / 8;

    return struct {
        pub const bytes = total_bytes;

        /// Initialize instruction data with compile-time discriminant and runtime data.
        pub inline fn init(comptime discriminant: Discriminant, data: Data) [total_bytes]u8 {
            return initWithDiscriminant(discriminant, data);
        }

        /// Create instruction data with a compile-time fixed discriminant.
        /// Only data fields are passed at runtime.
        ///
        /// Builds an extern struct on the stack with the comptime
        /// discriminant baked into the field initializer, then
        /// bitcasts to the byte array. This lets LLVM emit a single
        /// sized-immediate store for the discriminant instead of a
        /// `@memcpy` of 1-8 bytes — matches what Pinocchio's
        /// `CreateAccount.invoke_signed` does with raw
        /// `copy_nonoverlapping` calls.
        pub inline fn initWithDiscriminant(comptime discriminant: Discriminant, data: Data) [total_bytes]u8 {
            const Packed = extern struct {
                disc: Discriminant align(1),
                payload: Data align(1),
            };
            const packed_val = Packed{ .disc = discriminant, .payload = data };
            return @bitCast(packed_val);
        }
    };
}

/// Compile-time fixed instruction data with no variable fields.
/// Useful for instructions that only need a discriminant.
pub inline fn comptimeDiscriminantOnly(comptime discriminant: anytype) [(@bitSizeOf(@TypeOf(discriminant)) / 8)]u8 {
    return std.mem.asBytes(&discriminant).*;
}
