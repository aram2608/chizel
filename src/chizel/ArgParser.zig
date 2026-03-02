const std = @import("std");
const ArgIterator = std.process.ArgIterator;
const Allocator = std.mem.Allocator;
const ParseResult = @import("ParseResult.zig");
const Option = @import("Option.zig");
const Parser = @This();
const OptionsMap = std.StringHashMap(Option);

gpa: Allocator,
options: OptionsMap,
buffer: []const u8,
start: usize = 0,
current: usize = 0,
program_name: []const u8 = "",
option_order: std.ArrayList([]const u8) = .empty,
unknown_options: std.ArrayList([]const u8) = .empty,
parsed: bool = false,

pub fn init(gpa: Allocator, args: ArgIterator) !Parser {
    var temp: [4096]u8 = undefined;
    var pos: usize = 0;
    var temp_args = args;
    const name = temp_args.next().?; // argv[0]
    while (temp_args.next()) |arg| {
        if (pos + arg.len + 1 > temp.len) @panic("argument buffer overflow");
        @memcpy(temp[pos..][0..arg.len], arg);
        temp[pos + arg.len] = ' ';
        pos += arg.len + 1;
    }
    return .{
        .gpa = gpa,
        .program_name = try gpa.dupe(u8, name),
        .buffer = try gpa.dupe(u8, temp[0..pos]),
        .options = OptionsMap.init(gpa),
    };
}

pub fn deinit(self: *Parser) void {
    self.gpa.free(self.buffer);
    self.gpa.free(self.program_name);
    self.option_order.deinit(self.gpa);
    self.options.deinit();
    self.unknown_options.deinit(self.gpa);
}

pub fn addOption(
    self: *Parser,
    name: []const u8,
    tag: Option.Tag,
    help: []const u8,
) !void {
    try self.option_order.append(self.gpa, name);
    try self.options.put(name, .{ .tag = tag, .help = help });
}

pub fn parse(self: *Parser) !ParseResult {
    if (self.parsed) return error.AlreadyParsed;
    self.parsed = true;
    var parse_result = ParseResult.init(self.gpa);

    while (!self.isEnd()) {
        self.start = self.current;
        const c = self.advance();

        if (c == ' ') continue;

        const key = switch (c) {
            '-' => self.parseOption(),
            else => break,
        };
        if (std.mem.eql(u8, key, "help")) {
            parse_result.had_help = true;
            continue;
        }

        const parse_attempt = self.options.getPtr(key);
        if (parse_attempt) |option| {
            option.count += 1;
            // Results that store a value need a space then their value
            if (option.tag != .boolean) {
                if (self.isEnd() or self.buffer[self.current] != ' ') return error.MissingValue;
                // The current position needs skipped over
                _ = self.advance();
            }
            self.start = self.current;
            const value = try self.parsePayload(option.tag);
            try parse_result.results.put(key, .{ .value = value, .count = option.count });
        } else {
            try self.unknown_options.append(self.gpa, key);
        }
    }
    parse_result.help_message = try self.buildHelpMessage();

    return parse_result;
}

fn buildHelpMessage(self: *Parser) ![]u8 {
    const prefix = "--";
    const col_gap: usize = 2;

    var buff = std.Io.Writer.Allocating.init(self.gpa);
    errdefer buff.deinit();

    try buff.writer.print("Usage: {s} [OPTIONS]\nOptions:\n", .{self.program_name});

    // Seed with "--help" so it's always included in alignment
    var max_left: usize = prefix.len + "help".len;
    for (self.option_order.items) |name| {
        const opt = self.options.get(name).?;
        const hint = typeHint(opt.tag);
        const left = prefix.len + name.len + if (hint.len > 0) 1 + hint.len else 0;
        if (left > max_left) max_left = left;
    }

    for (self.option_order.items) |name| {
        const opt = self.options.get(name).?;
        const hint = typeHint(opt.tag);
        var left: usize = prefix.len + name.len;
        try buff.writer.print("{s}{s}", .{ prefix, name });
        if (hint.len > 0) {
            try buff.writer.print(" {s}", .{hint});
            left += 1 + hint.len;
        }
        try buff.writer.splatByteAll(' ', max_left - left + col_gap);
        try buff.writer.print("{s}\n", .{opt.help});
    }

    const help_left = prefix.len + "help".len;
    try buff.writer.print("{s}help", .{prefix});
    try buff.writer.splatByteAll(' ', max_left - help_left + col_gap);
    try buff.writer.print("Print this help message\n", .{});

    return buff.toOwnedSlice();
}

fn typeHint(tag: Option.Tag) []const u8 {
    return switch (tag) {
        .boolean => "",
        .int => "<int>",
        .float => "<float>",
        .string => "<string>",
        .string_slice => "<string...>",
    };
}

fn advance(self: *Parser) u8 {
    if (self.isEnd()) return 0;
    const c: u8 = self.buffer[self.current];
    self.current += 1;
    return c;
}

fn parseOption(self: *Parser) []const u8 {
    while (!self.isEnd() and !self.checkBuffer(' ')) {
        _ = self.advance();
    }
    const prefix_len: usize = if (self.start + 1 < self.buffer.len and self.buffer[self.start + 1] == '-') 2 else 1;
    return self.buffer[self.start + prefix_len .. self.current];
}

fn parsePayload(self: *Parser, tag: Option.Tag) !ParseResult.Result.Value {
    return switch (tag) {
        .boolean => .{ .boolean = true },
        .int => .{ .int = try self.parseInt() },
        .float => .{ .float = try self.parseFloat() },
        .string => .{ .string = try self.parseString() },
        .string_slice => .{ .string_slice = try self.parseStringSlice() },
    };
}

fn parseString(self: *Parser) ![]const u8 {
    const arg = self.nextToken();
    if (arg.len == 0) return error.MissingValue;
    return arg;
}

fn parseInt(self: *Parser) !i32 {
    return std.fmt.parseInt(i32, self.nextToken(), 10);
}

fn parseFloat(self: *Parser) !f32 {
    return std.fmt.parseFloat(f32, self.nextToken());
}

fn parseStringSlice(self: *Parser) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(self.gpa);

    while (!self.isEnd() and !self.checkBuffer('-')) {
        self.start = self.current;
        const token = self.nextToken();
        if (token.len > 0) try list.append(self.gpa, token);
        if (!self.isEnd()) _ = self.advance();
    }

    if (list.items.len == 0) return error.MissingValue;
    return list.toOwnedSlice(self.gpa);
}

fn nextToken(self: *Parser) []const u8 {
    while (!self.isEnd() and !self.checkBuffer(' ')) {
        _ = self.advance();
    }
    return self.buffer[self.start..self.current];
}

fn checkBuffer(self: *const Parser, c: u8) bool {
    return self.peekBuffer() == c;
}

fn peekBuffer(self: *const Parser) u8 {
    if (self.current >= self.buffer.len) return 0;
    return self.buffer[self.current];
}

fn isEnd(self: *const Parser) bool {
    return self.current >= self.buffer.len;
}

pub fn dumpUnknown(self: *const Parser) void {
    for (self.unknown_options.items) |result| {
        std.debug.print("Unknown opt: {s}\n", .{result});
    }
}

pub fn dumpOptions(self: *const Parser) void {
    var iter = self.options.iterator();
    while (iter.next()) |opt| {
        std.debug.print("Key: {s} || Value: {}\n", .{ opt.key_ptr.*, opt.value_ptr.* });
    }
}
