const std = @import("std");

const defaultValue = std.builtin.Type.StructField.defaultValue;
const startsWith = std.mem.startsWith;

// Example
const Opts = struct {
    port: i32 = 300,
    verbose: bool = false,
};

fn initDefaults(comptime T: type) T {
    var val: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        if (defaultValue(field)) |def| {
            @field(val, field.name) = def;
        }
    }
    return val;
}

pub fn parse(comptime T: type, iter: anytype, gpa: std.mem.Allocator) !T {
    // Fail fast for any non struct values
    if (@typeInfo(T) != .@"struct") @compileError("Invalid `Option` type.");

    var defaults = initDefaults(T);

    while (iter.next()) |opt| {
        const key = if (startsWith(u8, opt, "--")) opt[2..] else continue;

        inline for (std.meta.fields(T)) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                @field(defaults, field.name) = try parseNext(field.type, iter, gpa);
            }
        }
    }

    return defaults;
}

fn parseNext(comptime T: type, iter: anytype, gpa: std.mem.Allocator) !T {
    return switch (T) {
        bool => true,

        []const u8 => blk: {
            const s = iter.next() orelse return error.MissingValue;
            break :blk try gpa.dupe(u8, s);
        },

        else => switch (@typeInfo(T)) {
            .int => blk: {
                const s = iter.next() orelse return error.MissingValue;
                break :blk try std.fmt.parseInt(T, s, 10);
            },
            .float => blk: {
                const s = iter.next() orelse return error.MissingValue;
                break :blk try std.fmt.parseFloat(T, s);
            },
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        },
    };
}
