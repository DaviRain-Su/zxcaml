//! Lexer for the ZxCaml frontend bridge S-expression dialect.
//!
//! RESPONSIBILITIES:
//! - Tokenize whitespace, parentheses, atoms, identifiers, integers, and strings.
//! - Reject characters that are outside the narrow wire-format atom alphabet.
//! - Keep allocation explicit by decoding string literals through the caller arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Token emitted by the S-expression lexer.
pub const Token = union(enum) {
    l_paren,
    r_paren,
    atom: []const u8,
    identifier: []const u8,
    integer: i64,
    string: []const u8,
    eof,
};

/// Errors that can occur while scanning wire-format bytes.
pub const LexError = error{
    BadAtom,
    UnterminatedString,
    BadStringEscape,
    IntegerOverflow,
} || Allocator.Error;

/// Stateful lexer over a single S-expression byte slice.
pub const Lexer = struct {
    allocator: Allocator,
    input: []const u8,
    index: usize = 0,

    /// Creates a lexer using `allocator` for decoded string literal payloads.
    pub fn init(allocator: Allocator, input: []const u8) Lexer {
        return .{ .allocator = allocator, .input = input };
    }

    /// Returns the next token, skipping inter-token whitespace.
    pub fn next(self: *Lexer) LexError!Token {
        self.skipWhitespace();
        if (self.index >= self.input.len) return .eof;

        const ch = self.input[self.index];
        switch (ch) {
            '(' => {
                self.index += 1;
                return .l_paren;
            },
            ')' => {
                self.index += 1;
                return .r_paren;
            },
            '"' => return self.lexString(),
            else => return self.lexAtomLike(),
        }
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.index < self.input.len) : (self.index += 1) {
            switch (self.input[self.index]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn lexAtomLike(self: *Lexer) LexError!Token {
        const start = self.index;
        while (self.index < self.input.len and !isDelimiter(self.input[self.index])) {
            if (!isAtomChar(self.input[self.index])) return error.BadAtom;
            self.index += 1;
        }
        if (self.index == start) return error.BadAtom;

        const bytes = self.input[start..self.index];
        if (isIntegerLiteral(bytes)) {
            const value = std.fmt.parseInt(i64, bytes, 10) catch return error.IntegerOverflow;
            return .{ .integer = value };
        }
        if (isIdentifier(bytes)) return .{ .identifier = bytes };
        return .{ .atom = bytes };
    }

    fn lexString(self: *Lexer) LexError!Token {
        self.index += 1; // opening quote
        var decoded = std.ArrayList(u8).empty;
        errdefer decoded.deinit(self.allocator);

        while (self.index < self.input.len) {
            const ch = self.input[self.index];
            self.index += 1;

            switch (ch) {
                '"' => return .{ .string = try decoded.toOwnedSlice(self.allocator) },
                '\\' => {
                    if (self.index >= self.input.len) return error.UnterminatedString;
                    const escaped = self.input[self.index];
                    self.index += 1;
                    const decoded_ch: u8 = switch (escaped) {
                        '"' => '"',
                        '\\' => '\\',
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'b' => 0x08,
                        'f' => 0x0c,
                        else => return error.BadStringEscape,
                    };
                    try decoded.append(self.allocator, decoded_ch);
                },
                else => try decoded.append(self.allocator, ch),
            }
        }

        return error.UnterminatedString;
    }
};

fn isDelimiter(ch: u8) bool {
    return ch == '(' or ch == ')' or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn isAtomChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '\'' or ch == '.';
}

fn isIdentifier(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    if (!(std.ascii.isAlphabetic(bytes[0]) or bytes[0] == '_')) return false;
    for (bytes[1..]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '\'')) return false;
    }
    return true;
}

fn isIntegerLiteral(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    var start: usize = 0;
    if (bytes[0] == '-') {
        if (bytes.len == 1) return false;
        start = 1;
    }
    for (bytes[start..]) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

test "lexer tokenizes atoms identifiers integers strings and parens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexer = Lexer.init(arena.allocator(), "(let entrypoint \"x\\n\" -42 0.1)");
    try std.testing.expectEqual(Token.l_paren, try lexer.next());
    try expectIdentifier("let", try lexer.next());
    try expectIdentifier("entrypoint", try lexer.next());
    try expectString("x\n", try lexer.next());
    try expectInteger(-42, try lexer.next());
    try expectAtom("0.1", try lexer.next());
    try std.testing.expectEqual(Token.r_paren, try lexer.next());
    try std.testing.expectEqual(Token.eof, try lexer.next());
}

test "lexer rejects a bad atom character" {
    var lexer = Lexer.init(std.testing.allocator, "(bad@atom)");
    try std.testing.expectEqual(Token.l_paren, try lexer.next());
    try std.testing.expectError(error.BadAtom, lexer.next());
}

fn expectAtom(expected: []const u8, token: Token) !void {
    switch (token) {
        .atom => |actual| try std.testing.expectEqualStrings(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectIdentifier(expected: []const u8, token: Token) !void {
    switch (token) {
        .identifier => |actual| try std.testing.expectEqualStrings(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectInteger(expected: i64, token: Token) !void {
    switch (token) {
        .integer => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectString(expected: []const u8, token: Token) !void {
    switch (token) {
        .string => |actual| try std.testing.expectEqualStrings(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}
