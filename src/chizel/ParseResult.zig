const std = @import("std");
const ResultMap = std.StringHashMap(Result);
const Allocator = std.mem.Allocator;
const Option = @import("Option.zig");
const ParseResult = @This();

gpa: Allocator,
results: ResultMap,
had_help: bool = false,
help_message: []const u8 = undefined,

pub fn init(gpa: Allocator) ParseResult {
    return .{
        .gpa = gpa,
        .results = ResultMap.init(gpa),
    };
}

pub fn deinit(self: *ParseResult) void {
    var iter = self.results.valueIterator();
    while (iter.next()) |result| {
        switch (result.value) {
            .string_slice => |slice| self.gpa.free(slice),
            else => {},
        }
    }
    self.gpa.free(self.help_message);
    self.results.deinit();
}

/// Helper method to dump the `Results`.
/// Primarily used for debugging.
pub fn dumpResults(self: *const ParseResult) void {
    var iter = self.results.iterator();
    while (iter.next()) |pair| {
        const name = pair.key_ptr.*;
        const result = pair.value_ptr.*;
        std.debug.print("Opt: {s} || Value: {} || Count: {}\n", .{ name, result.value, result.count });
    }
}

pub fn getBool(self: *const ParseResult, opt: []const u8) ?bool {
    const result = self.results.get(opt) orelse return null;
    return switch (result.value) {
        .boolean => |v| v,
        else => null,
    };
}

pub fn getInt(self: *const ParseResult, opt: []const u8) ?i32 {
    const result = self.results.get(opt) orelse return null;
    return switch (result.value) {
        .int => |v| v,
        else => null,
    };
}

pub fn getFloat(self: *const ParseResult, opt: []const u8) ?f32 {
    const result = self.results.get(opt) orelse return null;
    return switch (result.value) {
        .float => |v| v,
        else => null,
    };
}

pub fn getString(self: *const ParseResult, opt: []const u8) ?[]const u8 {
    const result = self.results.get(opt) orelse return null;
    return switch (result.value) {
        .string => |v| v,
        else => null,
    };
}

pub fn getStringSlice(self: *const ParseResult, opt: []const u8) ?[][]const u8 {
    const result = self.results.get(opt) orelse return null;
    return switch (result.value) {
        .string_slice => |v| v,
        else => null,
    };
}

pub fn printHelp(self: *const ParseResult) void {
    std.fs.File.stdout().writeAll(self.help_message) catch {};
}

pub fn isPresent(self: *const ParseResult, opt: []const u8) bool {
    const result = self.results.get(opt) orelse return false;
    return result.count > 0;
}

pub fn getCount(self: *const ParseResult, opt: []const u8) u32 {
    const result = self.results.get(opt) orelse return 0;
    return result.count;
}

pub fn hadHelp(self: *const ParseResult) bool {
    return self.had_help;
}

pub const Result = struct {
    value: Value,
    count: u32,

    pub const Value = union(enum) {
        boolean: bool,
        int: i32,
        float: f32,
        string: []const u8,
        string_slice: [][]const u8,
    };
};
