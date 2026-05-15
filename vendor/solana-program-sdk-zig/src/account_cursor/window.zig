const shared = @import("shared.zig");

const AccountInfo = shared.AccountInfo;
const ProgramError = shared.ProgramError;

pub const DuplicatePolicy = enum {
    allow,
    reject,
    assume_unique,
};

pub const AccountWindow = struct {
    accounts: []const AccountInfo,

    const Self = @This();

    pub const Iterator = struct {
        accounts: []const AccountInfo,
        index: usize = 0,

        pub inline fn next(self: *Iterator) ?AccountInfo {
            if (self.index >= self.accounts.len) return null;
            defer self.index += 1;
            return self.accounts[self.index];
        }
    };

    pub inline fn len(self: Self) usize {
        return self.accounts.len;
    }

    pub inline fn isEmpty(self: Self) bool {
        return self.accounts.len == 0;
    }

    pub inline fn slice(self: Self) []const AccountInfo {
        return self.accounts;
    }

    pub inline fn get(self: Self, index: usize) ?AccountInfo {
        if (index >= self.accounts.len) return null;
        return self.accounts[index];
    }

    pub inline fn at(self: Self, index: usize) AccountInfo {
        return self.accounts[index];
    }

    pub inline fn iterator(self: Self) Iterator {
        return .{ .accounts = self.accounts };
    }

    pub inline fn expectEach(self: Self, comptime spec: anytype) ProgramError!void {
        for (self.accounts) |acc| {
            try acc.expect(spec);
        }
    }
};
