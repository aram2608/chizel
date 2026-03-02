const std = @import("std");

tag: Tag,
help: []const u8 = "",
count: u32 = 0,

pub const Tag = enum {
    boolean,
    string,
    int,
    float,
    string_slice,
};
