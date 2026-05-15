pub const account = @import("../account/root.zig");
pub const program_error = @import("../program_error/root.zig");

pub const Account = account.Account;
pub const AccountInfo = account.AccountInfo;
pub const MAX_PERMITTED_DATA_INCREASE = account.MAX_PERMITTED_DATA_INCREASE;
pub const MAX_TX_ACCOUNTS = account.MAX_TX_ACCOUNTS;
pub const NON_DUP_MARKER = account.NON_DUP_MARKER;
pub const ProgramError = program_error.ProgramError;
pub const alignPointer = account.alignPointer;
