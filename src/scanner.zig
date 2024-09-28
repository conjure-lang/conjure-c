// @author: ruka-lang
// @created: 2024-03-04

// Responsible for scanning the source file contained in the compiler which
// owns this scanner

const rukac = @import("root.zig").prelude;
const Compiler = rukac.Compiler;

const std = @import("std");

pub const Token = @import("scanner/token.zig");

const Scanner = @This();

current_pos: rukac.Position,
token_pos: rukac.Position,
index: usize,

prev_char: u8,
read_char: u8,
peek_char: u8,
peep_char: u8,

compiler: *Compiler,

/// Creates a new scanner instance
pub fn init(compiler: *Compiler) Scanner {
    return Scanner {
        .current_pos = .init(1, 1),
        .token_pos = .init(1, 1),
        .index = 0,

        .prev_char = undefined,
        .read_char = compiler.transport.readByte() catch '\x00',
        .peek_char = compiler.transport.readByte() catch '\x00',
        .peep_char = compiler.transport.readByte() catch '\x00',

        .compiler = compiler,
    };
}

/// Returns the next token from the files, when eof is reached,
/// will repeatedly return eof tokens
pub fn nextToken(self: *Scanner) !Token {
    self.skipWhitespace();
    self.token_pos = self.current_pos;

    const byte = self.read();
    const token = switch(byte) {
        // Strings
        '"' => block: {
            break :block switch (self.peek()) {
                '|' => try self.readMultiString(),
                else => try self.readSingleString()
            };
        },
        // Characters
        '\'' => {
            return try self.readCharacter() orelse block: {
                self.advance(1);
                break :block self.nextToken();
            };
        },
        // Comments or '/'
        '/' => block: {
            switch (self.peek()) {
                '/' => {
                    self.skipSingleComment();
                    break :block self.nextToken();
                },
                '*' => {
                    try self.skipMultiComment();
                    break :block self.nextToken();
                },
                else => {
                    self.advance(1);
                    break :block self.createToken(.slash);
                }
            }
        },
        // Operators which may be multiple characters long
        '=' => block: {
            var kind = try self.tryCompoundOperator(.{
                .{2, "=>", Token.Kind.wide_arrow},
                .{2, "==", Token.Kind.equal}
            });

            if (kind == null) {
                self.advance(1);
                kind = Token.Kind.assign;
            }

            break :block self.createToken(kind.?);
        },
        ':' => block: {
            var kind = try self.tryCompoundOperator(.{
                .{2, ":=", Token.Kind.assign_exp}
            });

            if (kind == null) {
                self.advance(1);
                kind = Token.Kind.colon;
            }

            break :block self.createToken(kind.?);
        },
        '>' => block: {
            var kind = try self.tryCompoundOperator(.{
                .{2, ">=", Token.Kind.greater_eq},
                .{2, ">>", Token.Kind.rshift}
            });

            if (kind == null) {
                self.advance(1);
                kind = Token.Kind.greater;
            }

            break :block self.createToken(kind.?);
        },
        '<' => block: {
            var kind = try self.tryCompoundOperator(.{
                .{2, "<=", Token.Kind.lesser_eq},
                .{2, "<<", Token.Kind.lshift},
                .{2, "<|", Token.Kind.forward_app},
                .{2, "<>", Token.Kind.concat}
            });

            if (kind == null) {
                self.advance(1);
                kind = Token.Kind.lesser;
            }

            break :block self.createToken(kind.?);
        },
        '-' => block: {
            var kind = try self.tryCompoundOperator(.{
                .{2, "->", Token.Kind.arrow},
                .{2, "--", Token.Kind.decrement}
            });

            if (kind == null) {
                self.advance(1);
                kind = Token.Kind.minus;
            }

            break :block self.createToken(kind.?);
        },
        '+' => block: {
            var kind = try self.tryCompoundOperator(.{
                .{2, "++", Token.Kind.increment}
            });

            if (kind == null) {
                self.advance(1);
                kind = Token.Kind.plus;
            }

            break :block self.createToken(kind.?);
        },
        '*' => block: {
            var kind = try self.tryCompoundOperator(.{
                .{2, "**", Token.Kind.square}
            });

            if (kind == null) {
                self.advance(1);
                kind = Token.Kind.asterisk;
            }

            break :block self.createToken(kind.?);
        },
        '.' => block: {
            var kind = try self.tryCompoundOperator(.{
                .{3, "..=", Token.Kind.range_inc},
                .{2, "..", Token.Kind.range_exc}
            });

            if (kind == null) {
                self.advance(1);
                kind = Token.Kind.dot;
            }

            break :block self.createToken(kind.?);
        },
        '!' => block: {
            var kind = try self.tryCompoundOperator(.{
                .{2, "!=", Token.Kind.not_equal}
            });

            if (kind == null) {
                self.advance(1);
                kind = Token.Kind.bang;
            }

            break :block self.createToken(kind.?);
        },
        '|' => block: {
            var kind = try self.tryCompoundOperator(.{
                .{2, "|>", Token.Kind.reverse_app}
            });

            if (kind == null) {
                self.advance(1);
                kind = Token.Kind.pipe;
            }

            break :block self.createToken(kind.?);
        },
        '\x00' => self.createToken(Token.Kind.eof),
        // Single characters, identifiers, keywords, modes, numbers
        else => block: {
            if (rukac.isAlphabetical(byte)) {
                break :block try self.readIdentifierKeywordMode();
            } else if (rukac.isIntegral(byte)) {
                break :block try self.readIntegerFloat();
            }

            // Single character
            self.advance(1);
            break :block self.createToken(Token.Kind.fromByte(byte));
        }
    };

    return token;
}

// Returns the character actual_token the current index
fn read(self: *Scanner) u8 {
    return self.read_char;
}

// Returns the character after the current index
fn peek(self: *Scanner) u8 {
    return self.peek_char;
}

// Returns the character previous to the current index
fn prev(self: *Scanner) u8 {
    return self.prev_char;
}

// Advances the scanner count number of times
fn advance(self: *Scanner, count: usize) void {
    for (0..count) |_| {
        self.prev_char = self.read_char;
        self.read_char = self.peek_char;
        self.peek_char = self.peep_char;
        self.peep_char = self.compiler.transport.readByte() catch '\x00';

        self.index = self.index + 1;

        self.current_pos.col = self.current_pos.col + 1;
        if (self.prev() == '\n') {
            self.current_pos.line = self.current_pos.line + 1;
            self.current_pos.col = 1;
        }
    }
}


// Creates a new token of the kind passed in
fn createToken(self: *Scanner, kind: Token.Kind) Token {
    return Token.init(
        kind,
        self.compiler.input,
        self.token_pos
    );
}

fn createError(self: *Scanner, msg: []const u8) !void {
    try self.compiler.createError(self, "scanner error", msg);
}

// Creates an escape character compilation error
fn createEscapeError(self: *Scanner, i: usize, slice: []const u8) !void {
    if (i + 1 > slice.len) {
        return try self.createError("unterminated escape character");
    }

    var buf = [_]u8{0} ** 40;
    try self.createError(try std.fmt.bufPrint(&buf,
        "unrecognized escape character: //{}",
        .{slice[i + 1]}
    ));
}

// Skips characters until the current character is not a space or tab
fn skipWhitespace(self: *Scanner) void {
    switch (self.read()) {
        inline ' ', '\t' => {
            self.advance(1);
            self.skipWhitespace();
        },
        else => {}
    }
}

// Skips a single line comment
fn skipSingleComment(self: *Scanner) void {
    switch (self.read()) {
        '\n', '\x00' => {},
        else => {
            self.advance(1);
            self.skipSingleComment();
        }
    }
}

// Skips a multi line comment
fn skipMultiComment(self: *Scanner) !void {
    var next = self.peek();

    while (self.read() != '\x00'): (next = self.peek()) {
        if (self.read() == '*' and next == '/') {
            self.advance(2);
            break;
        }

        self.advance(1);
    }

    if (next != '/') {
        try self.createError("unterminated multiline comment");
    }
}

// Reads a character literal from the file
fn readCharacter(self: *Scanner) !?Token {
    var string = std.ArrayList(u8).init(self.compiler.allocator);
    defer string.deinit();

    // Iterate until the final delimiter or EOF is reached
    while (self.peek() != '\'' and self.peek() != '\x00') {
        try string.append(self.peek());
        self.advance(1);
    }

    // Check if character literal contains a escape character
    string = try self.handleEscapeCharacters(try string.toOwnedSlice(), self.compiler.arena.allocator());

    // Create errors if string length isn't 1
    if (string.items.len > 1) {
        try self.createError("too many characters in character literal");
    } else if (string.items.len < 1) {
        try self.createError("character literal is empty");
    }

    self.advance(2);
    return self.createToken(.{ .character = string.items[0] });
}

const Match = std.meta.Tuple(&.{usize, []const u8, Token.Kind});
// Tries to create a token.Kind based on the passed in tuple of tuples
fn tryCompoundOperator(self: *Scanner, comptime matches: anytype) !?Token.Kind {
    var string = std.ArrayList(u8).init(self.compiler.allocator);
    defer string.deinit();

    try string.append(self.read());
    try string.append(self.peek());

    // Iterate through each passed in sub-tuple, checking if the second
    // element matches the following chars in the file, if it does
    // return the third element of the sub-tuple
    inline for (matches) |match| {
        if (match[0] == 3) {
            try string.append(self.peep_char);
        }

        if (std.mem.eql(u8, string.items[0..match[1].len], match[1])) {
            self.advance(match[0]);
            return match[2];
        }
    }

    return null;
}

/// Checks if a string represents an escape character, if it does return that character
fn tryEscapeChar(str: []const u8) ?u8 {
    // Check for \u{xxxxxx} and \x{xx}
    return escapes.get(str);
}

// Map representing escape sequences and their string representation
const escapes = std.StaticStringMap(u8).initComptime(.{
    .{"\\n", '\n'},
    .{"\\r", '\r'},
    .{"\\t", '\t'},
    .{"\\\\", '\\'},
    .{"\\|", '|'},
    .{"\\'", '\''},
    .{"\\\"", '"'},
    .{"\\0", '\x00'}
});

// Replaces escape characters
// TODO make this more efficient
fn handleEscapeCharacters(self: *Scanner, slice: [] const u8, allocator: std.mem.Allocator) !std.ArrayList(u8) {
    var string = std.ArrayList(u8).init(allocator);
    errdefer string.deinit();
    defer self.compiler.allocator.free(slice);

    var i: usize = 0;
    while (i < slice.len) {
        switch (slice[i]) {
            '\\' => {
                // Adjust to check for hex and unicode escape characters
                const esc_ch = tryEscapeChar(slice[i..i+2]);

                if (esc_ch) |esc| {
                    i = i + 2;
                    try string.append(esc);
                } else {
                    try self.createEscapeError(i, slice);

                    i = i + 1;
                    try string.append('\\');
                }
            },
            else => |ch| {
                i = i + 1;
                try string.append(ch);
            }
        }
    }

    return string;
}

// Reads an identifier, keyword, or mode literal from the file
fn readIdentifierKeywordMode(self: *Scanner) !Token {
    var string = std.ArrayList(u8).init(self.compiler.allocator);
    errdefer string.deinit();

    var byte = self.read();
    while (rukac.isAlphanumerical(byte)) {
        try string.append(byte);
        self.advance(1);
        byte = self.read();
    }

    var is_identifier = false;
    var kind = Token.Kind.tryMode(string.items);
    if (kind == null) {
        kind = Token.Kind.tryKeyword(string.items);

        // If string doesn't represent a keyword or mode,
        // then kind is identifier
        if (kind == null) {
            kind = .{ .identifier = string };
            is_identifier = true;
        }
    }

    if (!is_identifier) string.deinit();

    return self.createToken(kind.?);
}

// Reads a integer or float literal from the file
fn readIntegerFloat(self: *Scanner) !Token {
    var string = std.ArrayList(u8).init(self.compiler.allocator);
    errdefer string.deinit();

    // Iterate while self.read() is numeric, if self.read() is a '.',
    // read only integer values afterwards
    var float = false;
    var byte = self.read();
    while (rukac.isNumeric(byte)) {
        if (byte == '.') {
            try string.append(byte);
            try self.readMantissa(&string);
            float = true;
            break;
        }

        try string.append(byte);
        self.advance(1);
        byte = self.read();
    }

    const kind: Token.Kind = switch (float) {
        false => .{ .integer = string },
        true  => .{ .float = string }
    };

    return self.createToken(kind);
}

// Reads only integral numbers from the file, no decimals allowed
fn readMantissa(self: *Scanner, string: *std.ArrayList(u8)) !void {
    self.advance(1);

    var byte = self.read();

    if (!rukac.isIntegral(byte)) {
        try string.append('0');
        return;
    }

    while (rukac.isIntegral(byte)) {
        try string.append(byte);
        self.advance(1);
        byte = self.read();
    }
}

// Reads a single line string
fn readSingleString(self: *Scanner) !Token {
    var string = std.ArrayList(u8).init(self.compiler.allocator);
    errdefer string.deinit();

    while (self.peek() != '"' and self.peek() != '\x00') {
        try string.append(self.peek());
        self.advance(1);
    }

    self.advance(2);

    if (self.prev() != '"') {
        try self.createError("unterminated string literal");
    }

    string = try self.handleEscapeCharacters(try string.toOwnedSlice(), self.compiler.allocator);
    return self.createToken(.{ .string = string });
}

// Reads a multi line string
fn readMultiString(self: *Scanner) !Token {
    var string = std.ArrayList(u8).init(self.compiler.allocator);
    errdefer string.deinit();

    self.advance(1);
    while (self.peek() != '"' and self.peek() != '\x00') {
        switch (self.peek()) {
            '\n' => {
                try string.append('\n');
                self.advance(2);
                self.skipWhitespace();

                switch (self.read()) {
                    '|' => {
                        switch (self.peek()) {
                            '"' => break,
                            else => |ch| try string.append(ch)
                        }
                    },
                    else => try self.createError("missing start of line delimiter '|'")
                }
            },
            else => |ch| try string.append(ch)
        }

        self.advance(1);
    }

    self.advance(2);

    if (self.prev() != '"') {
        try self.createError("unterminated string literal");
    }

    string = try self.handleEscapeCharacters(try string.toOwnedSlice(), self.compiler.allocator);
    return self.createToken(.{ .string = string });
}

test "test all scanner modules" {
    _ = Token;
    _ = tests;
}

const tests = struct {
    const testing = std.testing;
    const expect = testing.expect;
    const expectEqual = testing.expectEqual;
    const eql = std.mem.eql;

    fn compareTokens(expected_token: *const Token, actual_token: *const Token) !void {
        switch (expected_token.kind) {
            .identifier => |e_identifier| switch (actual_token.kind) {
                .identifier => |a_identifier| try expect(eql(u8, e_identifier.items, a_identifier.items)),
                else => try expectEqual(expected_token.kind, actual_token.kind)
            },
            .string => |e_string| switch (actual_token.kind) {
                .string => |a_string| try expect(eql(u8, e_string.items, a_string.items)),
                else => try expectEqual(expected_token.kind, actual_token.kind)
            },
            .character => |e_character| switch (actual_token.kind) {
                .character => |a_character| try expectEqual(e_character, a_character),
                else => try expectEqual(expected_token.kind, actual_token.kind)
            },
            .integer => |e_integer| switch (actual_token.kind) {
                .integer => |a_integer| try expect(eql(u8, e_integer.items, a_integer.items)),
                else => try expectEqual(expected_token.kind, actual_token.kind)
            },
            .float => |e_float| switch (actual_token.kind) {
                .float => |a_float| try expect(eql(u8, e_float.items, a_float.items)),
                else => try expectEqual(expected_token.kind, actual_token.kind)
            },
            .keyword => |e_keyword| switch (actual_token.kind) {
                .keyword => |a_keyword| try expectEqual(e_keyword, a_keyword),
                else => try expectEqual(expected_token.kind, actual_token.kind)
            },
            .mode => |e_mode| switch (actual_token.kind) {
                .mode => |a_mode| try expectEqual(e_mode, a_mode),
                else => try expectEqual(expected_token.kind, actual_token.kind)
            },
            else => {
                try expectEqual(expected_token.kind, actual_token.kind);
            }
        }

        try expect(eql(u8, expected_token.file, actual_token.file));
        try expectEqual(expected_token.pos, actual_token.pos);
    }

    fn checkResults(scanner: *Scanner, e: []const Token) !void {
        var i: usize = 0;

        var token = try scanner.nextToken();
        while (token.kind != .eof): (token = try scanner.nextToken()) {
            try compareTokens(&e[i], &token);
            i = i + 1;
            token.deinit();
        }

        try compareTokens(&e[i], &token);
        try expectEqual(e.len, i + 1);
    }

    test "next token" {
        const source = "let x = 12_000 12_000.50 '\\n'";
        var input = std.io.fixedBufferStream(source);

        var buf: [10]u8 = undefined;
        var output = std.io.fixedBufferStream(&buf);

        var compiler = try Compiler.init(.testing(input.reader().any(), output.writer().any()));
        defer compiler.deinit();
        var scanner = Scanner.init(compiler);

        const allocator = compiler.arena.allocator();

        const expected = [_]Token{
            .init(.{ .keyword = .let }, "test source", .init(1, 1)),
            .init(try .initIdentifier("x", allocator), "test source", .init(1, 5)),
            .init(.assign, "test source", .init(1, 7)),
            .init(try .initInteger("12_000", allocator), "test source", .init(1, 9)),
            .init(try .initFloat("12_000.50", allocator), "test source", .init(1, 16)),
            .init(.{ .character = '\n' }, "test source", .init(1, 26)),
            .init(.eof, "test source", .init(1, 30)),
        };

        try checkResults(&scanner, &expected);
    }

    test "compound operators" {
        const source = "== != >= <= |> <| << <> >> ++ -- ** -> => .. ..= :=";
        var input = std.io.fixedBufferStream(source);

        var buf: [10]u8 = undefined;
        var output = std.io.fixedBufferStream(&buf);

        var compiler = try Compiler.init(.testing(input.reader().any(), output.writer().any()));
        defer compiler.deinit();
        var scanner = Scanner.init(compiler);

        const expected = [_]Token{
            .init(.equal, "test source", .init(1, 1)),
            .init(.not_equal, "test source", .init(1, 4)),
            .init(.greater_eq, "test source", .init(1, 7)),
            .init(.lesser_eq, "test source", .init(1, 10)),
            .init(.reverse_app, "test source", .init(1, 13)),
            .init(.forward_app, "test source", .init(1, 16)),
            .init(.lshift, "test source", .init(1, 19)),
            .init(.concat, "test source", .init(1, 22)),
            .init(.rshift, "test source", .init(1, 25)),
            .init(.increment, "test source", .init(1, 28)),
            .init(.decrement, "test source", .init(1, 31)),
            .init(.square, "test source", .init(1, 34)),
            .init(.arrow, "test source", .init(1, 37)),
            .init(.wide_arrow, "test source", .init(1, 40)),
            .init(.range_exc, "test source", .init(1, 43)),
            .init(.range_inc, "test source", .init(1, 46)),
            .init(.assign_exp, "test source", .init(1, 50)),
            .init(.eof, "test source", .init(1, 52))
        };

        try checkResults(&scanner, &expected);
    }

    test "string reading" {
        const source = "let x = \"Hello, world!\"";
        var input = std.io.fixedBufferStream(source);

        var buf: [10]u8 = undefined;
        var output = std.io.fixedBufferStream(&buf);

        var compiler = try Compiler.init(.testing(input.reader().any(), output.writer().any()));
        defer compiler.deinit();
        var scanner = Scanner.init(compiler);

        const allocator = compiler.arena.allocator();

        const expected = [_]Token{
            .init(.{ .keyword = .let }, "test source", .init(1, 1)),
            .init(try .initIdentifier("x", allocator), "test source", .init(1, 5)),
            .init(.assign, "test source", .init(1, 7)),
            .init(try .initString("Hello, world!", allocator), "test source", .init(1, 9)),
            .init(.eof, "test source", .init(1, 24)),
        };

        try checkResults(&scanner, &expected);
    }

    test "multi string reading" {
        const source = \\let x = "|
                       \\         | Hello, world!
                       \\         |"
                       ;
        var input = std.io.fixedBufferStream(source);

        var buf: [10]u8 = undefined;
        var output = std.io.fixedBufferStream(&buf);

        var compiler = try Compiler.init(.testing(input.reader().any(), output.writer().any()));
        defer compiler.deinit();
        var scanner = Scanner.init(compiler);

        const allocator = compiler.arena.allocator();

        const expected = [_]Token{
            .init(.{ .keyword = .let }, "test source", .init(1, 1)),
            .init(try .initIdentifier("x", allocator), "test source", .init(1, 5)),
            .init(.assign, "test source", .init(1, 7)),
            .init(try .initString("\n Hello, world!\n", allocator), "test source", .init(1, 9)),
            .init(.eof, "test source", .init(3, 12)),
        };

        try checkResults(&scanner, &expected);
    }

    test "escape charaters" {
        const source = "let x = \"Hello, \\n\\sworld!\"";
        var input = std.io.fixedBufferStream(source);

        var buf: [10]u8 = undefined;
        var output = std.io.fixedBufferStream(&buf);

        var compiler = try Compiler.init(.testing(input.reader().any(), output.writer().any()));
        defer compiler.deinit();
        var scanner = Scanner.init(compiler);

        const allocator = compiler.arena.allocator();

        const expected = [_]Token{
            .init(.{ .keyword = .let }, "test source", .init(1, 1)),
            .init(try .initIdentifier("x", allocator), "test source", .init(1, 5)),
            .init(.assign, "test source", .init(1, 7)),
            .init(try .initString("Hello, \n\\sworld!", allocator), "test source", .init(1, 9)),
            .init(.eof, "test source", .init(1, 28)),
        };

        try checkResults(&scanner, &expected);
    }

    test "read function identifier" {
        const source = "let x = hello()";
        var input = std.io.fixedBufferStream(source);

        var buf: [10]u8 = undefined;
        var output = std.io.fixedBufferStream(&buf);

        var compiler = try Compiler.init(.testing(input.reader().any(), output.writer().any()));
        defer compiler.deinit();
        var scanner = Scanner.init(compiler);

        const allocator = compiler.arena.allocator();

        const expected = [_]Token{
            .init(.{ .keyword = .let}, "test source", .init(1, 1)),
            .init(try .initIdentifier("x", allocator), "test source", .init(1, 5)),
            .init(.assign, "test source", .init(1, 7)),
            .init(try .initIdentifier("hello", allocator), "test source", .init(1, 9)),
            .init(.lparen, "test source", .init(1, 14)),
            .init(.rparen, "test source", .init(1, 15)),
            .init(.eof, "test source", .init(1, 16))
        };

        try checkResults(&scanner, &expected);
    }

    test "skip single comment" {
        const source = "let x = //12_000 12_000.50";
        var input = std.io.fixedBufferStream(source);

        var buf: [10]u8 = undefined;
        var output = std.io.fixedBufferStream(&buf);

        var compiler = try Compiler.init(.testing(input.reader().any(), output.writer().any()));
        defer compiler.deinit();
        var scanner = Scanner.init(compiler);

        const allocator = compiler.arena.allocator();

        const expected = [_]Token{
            .init(.{ .keyword = .let }, "test source", .init(1, 1)),
            .init(try .initIdentifier("x", allocator), "test source", .init(1, 5)),
            .init(.assign, "test source", .init(1, 7)),
            .init(.eof, "test source", .init(1, 27))
        };

        try checkResults(&scanner, &expected);
    }

    test "skip multi comment" {
        const source = \\let x = /*
                       \\12_000 12_000.50
                       \\*/
                       ;
        var input = std.io.fixedBufferStream(source);

        var buf: [10]u8 = undefined;
        var output = std.io.fixedBufferStream(&buf);

        var compiler = try Compiler.init(.testing(input.reader().any(), output.writer().any()));
        defer compiler.deinit();
        var scanner = Scanner.init(compiler);

        const allocator = compiler.arena.allocator();

        const expected = [_]Token{
            .init(.{ .keyword = .let}, "test source", .init(1, 1)),
            .init(try .initIdentifier("x", allocator), "test source", .init(1, 5)),
            .init(.assign, "test source", .init(1, 7 )),
            .init(.eof, "test source", .init(3, 3))
        };

        try checkResults(&scanner, &expected);
    }
};
