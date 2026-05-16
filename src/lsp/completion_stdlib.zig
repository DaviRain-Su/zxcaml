//! Static `textDocument/completion` whitelist for the bundled stdlib.
//!
//! This list mirrors the "Stdlib" bullet in `README.md` plus the additional
//! `Bytes`, `Sysvar`, and `Cpi` surface that the runtime exposes. Items are
//! intentionally kept in code so the LSP can answer completion without
//! invoking `omlz check`. Type strings are one-line OCaml-style signatures
//! sourced from `stdlib/core.ml`; for items where the Core IR-derived type
//! is not statically known (for example most `external` declarations and
//! the runtime CPI helpers), the `detail` field falls back to the module
//! path so editors can still show context.

const std = @import("std");

/// LSP `CompletionItemKind` codes used by this whitelist. The LSP 3.17 spec
/// numbers `Function = 3`, `Value = 12`, `Constant = 13`.
pub const Kind = enum(u8) {
    function = 3,
    constant = 13,
};

pub const Item = struct {
    label: []const u8,
    kind: Kind,
    detail: []const u8,
};

pub const items = [_]Item{
    // List
    .{ .label = "List.length", .kind = .function, .detail = "'a list -> int" },
    .{ .label = "List.map", .kind = .function, .detail = "('a -> 'b) -> 'a list -> 'b list" },
    .{ .label = "List.filter", .kind = .function, .detail = "('a -> bool) -> 'a list -> 'a list" },
    .{ .label = "List.fold_left", .kind = .function, .detail = "('acc -> 'a -> 'acc) -> 'acc -> 'a list -> 'acc" },
    .{ .label = "List.rev", .kind = .function, .detail = "'a list -> 'a list" },
    .{ .label = "List.append", .kind = .function, .detail = "'a list -> 'a list -> 'a list" },
    .{ .label = "List.hd", .kind = .function, .detail = "'a list -> 'a" },
    .{ .label = "List.tl", .kind = .function, .detail = "'a list -> 'a list" },
    .{ .label = "List.nth", .kind = .function, .detail = "'a list -> int -> 'a" },
    .{ .label = "List.exists", .kind = .function, .detail = "('a -> bool) -> 'a list -> bool" },
    .{ .label = "List.for_all", .kind = .function, .detail = "('a -> bool) -> 'a list -> bool" },
    .{ .label = "List.find", .kind = .function, .detail = "('a -> bool) -> 'a list -> 'a" },
    .{ .label = "List.sort", .kind = .function, .detail = "('a -> 'a -> int) -> 'a list -> 'a list" },
    .{ .label = "List.combine", .kind = .function, .detail = "'a list -> 'b list -> ('a * 'b) list" },
    .{ .label = "List.split", .kind = .function, .detail = "('a * 'b) list -> 'a list * 'b list" },
    .{ .label = "List.iter", .kind = .function, .detail = "('a -> unit) -> 'a list -> unit" },

    // Option
    .{ .label = "Option.is_none", .kind = .function, .detail = "'a option -> bool" },
    .{ .label = "Option.is_some", .kind = .function, .detail = "'a option -> bool" },
    .{ .label = "Option.value", .kind = .function, .detail = "'a option -> 'a -> 'a" },
    .{ .label = "Option.get", .kind = .function, .detail = "'a option -> 'a" },
    .{ .label = "Option.fold", .kind = .function, .detail = "none:'b -> some:('a -> 'b) -> 'a option -> 'b" },
    .{ .label = "Option.map", .kind = .function, .detail = "('a -> 'b) -> 'a option -> 'b option" },
    .{ .label = "Option.bind", .kind = .function, .detail = "'a option -> ('a -> 'b option) -> 'b option" },

    // Result
    .{ .label = "Result.is_ok", .kind = .function, .detail = "('a, 'e) result -> bool" },
    .{ .label = "Result.is_error", .kind = .function, .detail = "('a, 'e) result -> bool" },
    .{ .label = "Result.ok", .kind = .function, .detail = "('a, 'e) result -> 'a option" },
    .{ .label = "Result.error", .kind = .function, .detail = "('a, 'e) result -> 'e option" },
    .{ .label = "Result.map", .kind = .function, .detail = "('a -> 'b) -> ('a, 'e) result -> ('b, 'e) result" },
    .{ .label = "Result.map_error", .kind = .function, .detail = "('e -> 'f) -> ('a, 'e) result -> ('a, 'f) result" },
    .{ .label = "Result.map_err", .kind = .function, .detail = "('e -> 'f) -> ('a, 'e) result -> ('a, 'f) result" },
    .{ .label = "Result.bind", .kind = .function, .detail = "('a, 'e) result -> ('a -> ('b, 'e) result) -> ('b, 'e) result" },

    // Fun
    .{ .label = "Fun.id", .kind = .function, .detail = "'a -> 'a" },
    .{ .label = "Fun.const", .kind = .function, .detail = "'a -> 'b -> 'a" },
    .{ .label = "Fun.flip", .kind = .function, .detail = "('a -> 'b -> 'c) -> 'b -> 'a -> 'c" },

    // Map
    .{ .label = "Map.empty", .kind = .function, .detail = "('k -> 'k -> int) -> ('k, 'v) Map.t" },
    .{ .label = "Map.singleton", .kind = .function, .detail = "'k -> 'v -> ('k -> 'k -> int) -> ('k, 'v) Map.t" },
    .{ .label = "Map.add", .kind = .function, .detail = "'k -> 'v -> ('k, 'v) Map.t -> ('k, 'v) Map.t" },
    .{ .label = "Map.find", .kind = .function, .detail = "'k -> ('k, 'v) Map.t -> 'v option" },
    .{ .label = "Map.remove", .kind = .function, .detail = "'k -> ('k, 'v) Map.t -> ('k, 'v) Map.t" },
    .{ .label = "Map.mem", .kind = .function, .detail = "'k -> ('k, 'v) Map.t -> bool" },
    .{ .label = "Map.size", .kind = .function, .detail = "('k, 'v) Map.t -> int" },
    .{ .label = "Map.to_list", .kind = .function, .detail = "('k, 'v) Map.t -> ('k * 'v) list" },

    // Set
    .{ .label = "Set.empty", .kind = .function, .detail = "('a -> 'a -> int) -> 'a Set.t" },
    .{ .label = "Set.singleton", .kind = .function, .detail = "'a -> ('a -> 'a -> int) -> 'a Set.t" },
    .{ .label = "Set.add", .kind = .function, .detail = "'a -> 'a Set.t -> 'a Set.t" },
    .{ .label = "Set.mem", .kind = .function, .detail = "'a -> 'a Set.t -> bool" },
    .{ .label = "Set.remove", .kind = .function, .detail = "'a -> 'a Set.t -> 'a Set.t" },
    .{ .label = "Set.size", .kind = .function, .detail = "'a Set.t -> int" },
    .{ .label = "Set.to_list", .kind = .function, .detail = "'a Set.t -> 'a list" },
    .{ .label = "Set.union", .kind = .function, .detail = "'a Set.t -> 'a Set.t -> 'a Set.t" },
    .{ .label = "Set.inter", .kind = .function, .detail = "'a Set.t -> 'a Set.t -> 'a Set.t" },

    // String
    .{ .label = "String.length", .kind = .function, .detail = "string -> int" },
    .{ .label = "String.get", .kind = .function, .detail = "string -> int -> char" },
    .{ .label = "String.sub", .kind = .function, .detail = "string -> int -> int -> string" },

    // Char
    .{ .label = "Char.code", .kind = .function, .detail = "char -> int" },
    .{ .label = "Char.chr", .kind = .function, .detail = "int -> char" },

    // Crypto
    .{ .label = "Crypto.sha256", .kind = .function, .detail = "bytes -> bytes" },
    .{ .label = "Crypto.keccak256", .kind = .function, .detail = "bytes -> bytes" },
    .{ .label = "Crypto.blake3", .kind = .function, .detail = "bytes -> bytes" },
    .{ .label = "Crypto.secp256k1_recover", .kind = .function, .detail = "bytes -> int -> bytes -> bytes" },

    // Pubkey
    .{ .label = "Pubkey.zero", .kind = .constant, .detail = "pubkey" },
    .{ .label = "Pubkey.token_program", .kind = .constant, .detail = "pubkey" },
    .{ .label = "Pubkey.of_hex", .kind = .function, .detail = "string -> pubkey" },

    // Bytes
    .{ .label = "Bytes.create", .kind = .function, .detail = "int -> bytes" },
    .{ .label = "Bytes.set", .kind = .function, .detail = "bytes -> int -> char -> unit" },
    .{ .label = "Bytes.get", .kind = .function, .detail = "bytes -> int -> char" },
    .{ .label = "Bytes.length", .kind = .function, .detail = "bytes -> int" },
    .{ .label = "Bytes.sub", .kind = .function, .detail = "bytes -> int -> int -> bytes" },
    .{ .label = "Bytes.of_string", .kind = .function, .detail = "string -> bytes" },
    .{ .label = "Bytes.blit", .kind = .function, .detail = "bytes -> int -> bytes -> int -> int -> unit" },
    .{ .label = "Bytes.fill", .kind = .function, .detail = "bytes -> int -> int -> char -> unit" },
    .{ .label = "Bytes.iter", .kind = .function, .detail = "(char -> unit) -> bytes -> unit" },
    .{ .label = "Bytes.iteri", .kind = .function, .detail = "(int -> char -> unit) -> bytes -> unit" },
    .{ .label = "Bytes.fold_left", .kind = .function, .detail = "('acc -> char -> 'acc) -> 'acc -> bytes -> 'acc" },
    .{ .label = "Bytes.equal", .kind = .function, .detail = "bytes -> bytes -> bool" },
    .{ .label = "Bytes.compare", .kind = .function, .detail = "bytes -> bytes -> int" },

    // Account
    .{ .label = "Account.key", .kind = .function, .detail = "account -> pubkey" },
    .{ .label = "Account.owner", .kind = .function, .detail = "account -> pubkey" },
    .{ .label = "Account.data", .kind = .function, .detail = "account -> bytes" },
    .{ .label = "Account.lamports", .kind = .function, .detail = "account -> int" },
    .{ .label = "Account.data_len", .kind = .function, .detail = "account -> int" },
    .{ .label = "Account.is_signer", .kind = .function, .detail = "account -> bool" },
    .{ .label = "Account.is_writable", .kind = .function, .detail = "account -> bool" },
    .{ .label = "Account.is_executable", .kind = .function, .detail = "account -> bool" },
    .{ .label = "Account.has_key", .kind = .function, .detail = "account -> pubkey -> bool" },
    .{ .label = "Account.is_owned_by", .kind = .function, .detail = "account -> pubkey -> bool" },

    // Fixed / Amount
    .{ .label = "Fixed.scale", .kind = .constant, .detail = "int" },
    .{ .label = "Fixed.zero", .kind = .constant, .detail = "Fixed.t" },
    .{ .label = "Fixed.one", .kind = .constant, .detail = "Fixed.t" },
    .{ .label = "Fixed.of_scaled", .kind = .function, .detail = "int -> Fixed.t" },
    .{ .label = "Fixed.to_scaled", .kind = .function, .detail = "Fixed.t -> int" },
    .{ .label = "Fixed.of_int", .kind = .function, .detail = "int -> Fixed.t" },
    .{ .label = "Fixed.to_int_trunc", .kind = .function, .detail = "Fixed.t -> int" },
    .{ .label = "Fixed.to_int_floor", .kind = .function, .detail = "Fixed.t -> int" },
    .{ .label = "Fixed.to_int_ceil", .kind = .function, .detail = "Fixed.t -> int" },
    .{ .label = "Fixed.to_int_round", .kind = .function, .detail = "Fixed.t -> int" },
    .{ .label = "Fixed.add", .kind = .function, .detail = "Fixed.t -> Fixed.t -> Fixed.t" },
    .{ .label = "Fixed.sub", .kind = .function, .detail = "Fixed.t -> Fixed.t -> Fixed.t" },
    .{ .label = "Fixed.mul", .kind = .function, .detail = "Fixed.t -> Fixed.t -> Fixed.t" },
    .{ .label = "Fixed.div", .kind = .function, .detail = "Fixed.t -> Fixed.t -> Fixed.t" },
    .{ .label = "Fixed.ratio", .kind = .function, .detail = "int -> int -> Fixed.t" },
    .{ .label = "Fixed.bps", .kind = .function, .detail = "int -> Fixed.t" },
    .{ .label = "Fixed.apply", .kind = .function, .detail = "int -> Fixed.t -> int" },
    .{ .label = "Amount.fee_bps", .kind = .function, .detail = "int -> int -> int" },
    .{ .label = "Amount.discount_bps", .kind = .function, .detail = "int -> int -> int" },
    .{ .label = "Amount.premium_bps", .kind = .function, .detail = "int -> int -> int" },
    .{ .label = "Amount.apply_rate", .kind = .function, .detail = "int -> Fixed.t -> int" },

    // Format
    .{ .label = "Format.int_to_string", .kind = .function, .detail = "int -> string" },
    .{ .label = "Format.hex_of_int", .kind = .function, .detail = "int -> int -> string" },

    // Syscall / Crypto
    .{ .label = "Syscall.sol_log", .kind = .function, .detail = "string -> unit" },
    .{ .label = "Syscall.sol_log_64", .kind = .function, .detail = "int -> int -> int -> int -> int -> unit" },
    .{ .label = "Syscall.sol_log_pubkey", .kind = .function, .detail = "pubkey -> unit" },
    .{ .label = "Syscall.sol_sha256", .kind = .function, .detail = "bytes -> bytes" },
    .{ .label = "Syscall.sol_get_clock_sysvar", .kind = .function, .detail = "unit -> clock" },
    .{ .label = "Syscall.sol_get_rent_lamports_per_byte_year", .kind = .function, .detail = "unit -> int" },
    .{ .label = "Syscall.sol_log_compute_units", .kind = .function, .detail = "unit -> unit" },
    .{ .label = "Syscall.sol_remaining_compute_units", .kind = .function, .detail = "unit -> int" },
    .{ .label = "Crypto.sha256", .kind = .function, .detail = "bytes -> bytes" },
    .{ .label = "Crypto.keccak256", .kind = .function, .detail = "bytes -> bytes" },
    .{ .label = "Crypto.blake3", .kind = .function, .detail = "bytes -> bytes" },
    .{ .label = "Crypto.secp256k1_recover", .kind = .function, .detail = "bytes -> int -> bytes -> bytes" },

    // Sysvar
    .{ .label = "Sysvar.clock_from_account", .kind = .function, .detail = "account_data -> clock" },
    .{ .label = "Sysvar.rent_from_account", .kind = .function, .detail = "account_data -> rent" },
    .{ .label = "Sysvar.instructions_header_from_account", .kind = .function, .detail = "account_data -> instructions_header" },
    .{ .label = "Sysvar.instruction_at", .kind = .function, .detail = "account_data -> int -> instruction" },
    .{ .label = "Sysvar.stake_history_latest_from_account", .kind = .function, .detail = "account_data -> int -> stake_history_entry array" },
    .{ .label = "Sysvar.epoch_schedule_from_account", .kind = .function, .detail = "account_data -> epoch_schedule" },

    // SplToken
    .{ .label = "SplToken.program_id", .kind = .function, .detail = "unit -> pubkey" },
    .{ .label = "SplToken.transfer_data", .kind = .function, .detail = "int -> bytes" },
    .{ .label = "SplToken.transfer_account_metas", .kind = .function, .detail = "pubkey -> pubkey -> pubkey -> account_meta array" },
    .{ .label = "SplToken.transfer_instruction", .kind = .function, .detail = "pubkey -> pubkey -> pubkey -> int -> instruction" },

    // Cpi (runtime helpers; types not statically known here)
    .{ .label = "Cpi.invoke", .kind = .function, .detail = "Cpi" },
    .{ .label = "Cpi.invoke_signed", .kind = .function, .detail = "Cpi" },
    .{ .label = "Cpi.set_return_data", .kind = .function, .detail = "Cpi" },
    .{ .label = "Cpi.get_return_data", .kind = .function, .detail = "Cpi" },
    .{ .label = "Cpi.get_return_program_id", .kind = .function, .detail = "Cpi" },
};

test "stdlib whitelist contains expected anchors" {
    var saw_list_length = false;
    var saw_option_is_some = false;
    var saw_pubkey_zero = false;
    var saw_account_is_signer = false;
    var saw_fixed_apply = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "List.length")) saw_list_length = true;
        if (std.mem.eql(u8, item.label, "Option.is_some")) saw_option_is_some = true;
        if (std.mem.eql(u8, item.label, "Pubkey.zero")) saw_pubkey_zero = true;
        if (std.mem.eql(u8, item.label, "Account.is_signer")) saw_account_is_signer = true;
        if (std.mem.eql(u8, item.label, "Fixed.apply")) saw_fixed_apply = true;
    }
    try std.testing.expect(saw_list_length);
    try std.testing.expect(saw_option_is_some);
    try std.testing.expect(saw_pubkey_zero);
    try std.testing.expect(saw_account_is_signer);
    try std.testing.expect(saw_fixed_apply);
}
