const std = @import("std");
const m2 = @import("solana_sdk_m2");

const bs58_alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const bs58_invalid_digit: u8 = 0xff;

fn bs58DecodeDigit(char: u8) ?u8 {
    const table = comptime makeBs58DecodeTable();
    const digit = table[char];
    return if (digit == bs58_invalid_digit) null else digit;
}

fn makeBs58DecodeTable() [256]u8 {
    var table = [_]u8{bs58_invalid_digit} ** 256;
    for (bs58_alphabet, 0..) |char, index| {
        table[char] = @intCast(index);
    }
    return table;
}

pub const pubkey = struct {
    const Key = [32]u8;

    pub const Pubkey = Key;
    pub const PUBKEY_BYTES: usize = @sizeOf(Key);

    pub fn comptimeFromBase58(comptime text: []const u8) Key {
        @setEvalBranchQuota(20_000);

        var leading_ones: usize = 0;
        while (leading_ones < text.len and text[leading_ones] == '1') {
            leading_ones += 1;
        }

        var bytes: [text.len]u8 = [_]u8{0} ** text.len;
        var byte_count: usize = 0;
        for (text[leading_ones..]) |char| {
            const digit = bs58DecodeDigit(char) orelse @compileError("invalid base58 pubkey literal");
            var carry: u32 = digit;
            var index: usize = 0;
            while (index < byte_count) : (index += 1) {
                carry += @as(u32, bytes[index]) * 58;
                bytes[index] = @intCast(carry & 0xff);
                carry >>= 8;
            }
            while (carry > 0) {
                bytes[byte_count] = @intCast(carry & 0xff);
                byte_count += 1;
                carry >>= 8;
            }
        }

        if (leading_ones + byte_count != @sizeOf(Key)) {
            @compileError("pubkey literal must decode to 32 bytes");
        }

        var out: Key = [_]u8{0} ** @sizeOf(Key);
        for (0..byte_count) |i| {
            out[leading_ones + i] = bytes[byte_count - 1 - i];
        }
        return out;
    }

    pub inline fn pubkeyEq(lhs: *const Key, rhs: *const Key) bool {
        return std.mem.eql(u8, lhs[0..], rhs[0..]);
    }

    pub inline fn pubkeyEqComptime(lhs: *const Key, comptime rhs: Key) bool {
        return std.mem.eql(u8, lhs[0..], rhs[0..]);
    }
};

pub const instruction = struct {
    pub fn comptimeInstructionData(comptime DiscInt: type, comptime Data: type) type {
        return struct {
            pub const bytes: usize = @sizeOf(DiscInt) + @sizeOf(Data);

            pub fn init(discriminant: DiscInt, data: Data) [bytes]u8 {
                return initWithDiscriminant(discriminant, data);
            }

            pub fn initWithDiscriminant(discriminant: anytype, data: Data) [bytes]u8 {
                const Wire = extern struct {
                    disc: DiscInt align(1),
                    payload: Data align(1),
                };

                const coerced: DiscInt = switch (@typeInfo(@TypeOf(discriminant))) {
                    .@"enum" => @intFromEnum(discriminant),
                    else => @as(DiscInt, @intCast(discriminant)),
                };

                var wire = Wire{
                    .disc = coerced,
                    .payload = data,
                };
                var out: [bytes]u8 = undefined;
                @memcpy(out[0..], std.mem.asBytes(&wire));
                return out;
            }
        };
    }
};

pub const program_error = struct {
    pub inline fn fail(src: std.builtin.SourceLocation, tag: []const u8, err: m2.program_error.ProgramError) m2.program_error.ProgramError {
        _ = src;
        _ = tag;
        return err;
    }
};

pub const cpi = m2.cpi;
pub const pda = m2.pda;

pub const Pubkey = pubkey.Pubkey;
pub const PUBKEY_BYTES = pubkey.PUBKEY_BYTES;
pub const ProgramError = m2.program_error.ProgramError;
pub const ProgramResult = m2.program_error.ProgramResult;

pub const system_program_id = pubkey.comptimeFromBase58("11111111111111111111111111111111");
pub const rent_id = pubkey.comptimeFromBase58("SysvarRent111111111111111111111111111111111");
pub const incinerator_id = pubkey.comptimeFromBase58("1nc1nerator11111111111111111111111111111111");
pub const spl_token_program_id: Pubkey = .{
    0x06, 0xdd, 0xf6, 0xe1, 0xd7, 0x65, 0xa1, 0x93,
    0xd9, 0xcb, 0xe1, 0x46, 0xce, 0xeb, 0x79, 0xac,
    0x1c, 0xb4, 0x85, 0xed, 0x5f, 0x5b, 0x37, 0x91,
    0x3a, 0x8c, 0xf5, 0x85, 0x7e, 0xff, 0x00, 0xa9,
};
pub const spl_token_2022_program_id: Pubkey = .{
    0x06, 0xdd, 0xf6, 0xe1, 0xee, 0x75, 0x8f, 0xde,
    0x18, 0x42, 0x5d, 0xbc, 0xe4, 0x6c, 0xcd, 0xda,
    0xb6, 0x1a, 0xfc, 0x4d, 0x83, 0xb9, 0x0d, 0x27,
    0xfe, 0xbd, 0xf9, 0x28, 0xd8, 0xa1, 0x8b, 0xfc,
};
pub const spl_associated_token_account_id: Pubkey = .{
    0x8c, 0x97, 0x25, 0x8f, 0x4e, 0x24, 0x89, 0xf1,
    0xbb, 0x3d, 0x10, 0x29, 0x14, 0x8e, 0x0d, 0x83,
    0x0b, 0x5a, 0x13, 0x99, 0xda, 0xff, 0x10, 0x84,
    0x04, 0x8e, 0x7b, 0xd8, 0xdb, 0xe9, 0xf8, 0x59,
};
pub const spl_memo_program_id: Pubkey = .{
    0x05, 0x4a, 0x53, 0x5a, 0x99, 0x29, 0x21, 0x06,
    0x4d, 0x24, 0xe8, 0x71, 0x60, 0xda, 0x38, 0x7c,
    0x7c, 0x35, 0xb5, 0xdd, 0xbc, 0x92, 0xbb, 0x81,
    0xe4, 0x1f, 0xa8, 0x40, 0x41, 0x05, 0x44, 0x8d,
};
