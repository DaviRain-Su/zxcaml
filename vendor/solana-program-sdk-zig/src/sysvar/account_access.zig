const shared = @import("shared.zig");

const AccountInfo = shared.AccountInfo;
const ProgramError = shared.ProgramError;

/// Get a zero-copy typed view of sysvar account data.
///
/// The account must contain at least `@sizeOf(T)` bytes. The returned
/// pointer aliases the account's runtime data buffer directly — no copy,
/// no allocation, just a typed view over `account.data()`.
///
/// Use this for repeated field access or larger sysvar layouts where the
/// SDK's zero-copy style is preferable.
pub fn getSysvarRef(comptime T: type, account: AccountInfo) ProgramError!*align(1) const T {
    const data = account.data();
    if (data.len < @sizeOf(T)) {
        return ProgramError.InvalidAccountData;
    }
    return account.dataAsConst(T);
}

/// Get sysvar data from an account by value.
///
/// This is the convenience copy-returning form built on top of
/// `getSysvarRef`. Use `getSysvarRef` when you want the zero-copy path.
pub fn getSysvar(comptime T: type, account: AccountInfo) ProgramError!T {
    return (try getSysvarRef(T, account)).*;
}
