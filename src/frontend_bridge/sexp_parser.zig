//! Generic S-expression parser for the ZxCaml frontend bridge.
//!
//! RESPONSIBILITIES:
//! - Convert the lexer token stream into an arena-allocated generic Sexp tree.
//! - Detect malformed list structure such as unmatched parentheses.
//! - Preserve atom, integer, and string leaves for the typed mirror layer.

const std = @import("std");
const sexp_lexer = @import("sexp_lexer.zig");

/// Generic S-expression node used before typed ttree decoding.
pub const Sexp = union(enum) {
    list: []const *const Sexp,
    atom: []const u8,
    integer: i64,
    string: []const u8,

    /// Returns atom-like payloads (`atom` and `string`) as bytes.
    pub fn atomLike(self: *const Sexp) ?[]const u8 {
        return switch (self.*) {
            .atom => |bytes| bytes,
            .string => |bytes| bytes,
            else => null,
        };
    }
};

/// Errors that can occur while parsing a generic S-expression tree.
pub const ParseError = sexp_lexer.LexError || error{
    EmptyInput,
    ExpectedExpression,
    UnmatchedParen,
    UnexpectedRightParen,
    TrailingInput,
};

/// Stateful parser over lexer tokens.
pub const Parser = struct {
    arena: *std.heap.ArenaAllocator,
    lexer: sexp_lexer.Lexer,
    current: sexp_lexer.Token,

    /// Initializes a parser and reads the first token.
    pub fn init(arena: *std.heap.ArenaAllocator, input: []const u8) ParseError!Parser {
        var lexer = sexp_lexer.Lexer.init(arena.allocator(), input);
        const current = try lexer.next();
        return .{ .arena = arena, .lexer = lexer, .current = current };
    }

    /// Parses exactly one S-expression and requires EOF afterwards.
    pub fn parseOne(self: *Parser) ParseError!*const Sexp {
        if (self.current == .eof) return error.EmptyInput;
        const root = try self.parseExpr();
        if (self.current != .eof) return error.TrailingInput;
        return root;
    }

    fn parseExpr(self: *Parser) ParseError!*const Sexp {
        switch (self.current) {
            .l_paren => return self.parseList(),
            .r_paren => return error.UnexpectedRightParen,
            .eof => return error.ExpectedExpression,
            .atom => |bytes| {
                try self.advance();
                return self.make(.{ .atom = bytes });
            },
            .identifier => |bytes| {
                try self.advance();
                return self.make(.{ .atom = bytes });
            },
            .integer => |value| {
                try self.advance();
                return self.make(.{ .integer = value });
            },
            .string => |bytes| {
                try self.advance();
                return self.make(.{ .string = bytes });
            },
        }
    }

    fn parseList(self: *Parser) ParseError!*const Sexp {
        try self.advance(); // consume '('
        var items = std.ArrayList(*const Sexp).empty;
        errdefer items.deinit(self.arena.allocator());

        while (true) {
            switch (self.current) {
                .r_paren => {
                    try self.advance();
                    const owned = try items.toOwnedSlice(self.arena.allocator());
                    return self.make(.{ .list = owned });
                },
                .eof => return error.UnmatchedParen,
                else => try items.append(self.arena.allocator(), try self.parseExpr()),
            }
        }
    }

    fn advance(self: *Parser) ParseError!void {
        self.current = try self.lexer.next();
    }

    fn make(self: *Parser, node: Sexp) ParseError!*const Sexp {
        const ptr = try self.arena.allocator().create(Sexp);
        ptr.* = node;
        return ptr;
    }
};

/// Parses exactly one generic S-expression tree from `input`.
pub fn parse(arena: *std.heap.ArenaAllocator, input: []const u8) ParseError!*const Sexp {
    var parser = try Parser.init(arena, input);
    return parser.parseOne();
}

test "parser handles a nested module sexp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parse(&arena, "(zxcaml-cir 0.1 (module))");
    const items = switch (root.*) {
        .list => |list| list,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try expectAtom("zxcaml-cir", items[0]);
}

test "parser rejects unmatched paren" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.UnmatchedParen, parse(&arena, "(module"));
}

test "parser rejects empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.EmptyInput, parse(&arena, " \n\t "));
}

fn expectAtom(expected: []const u8, node: *const Sexp) !void {
    const actual = node.atomLike() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected, actual);
}
