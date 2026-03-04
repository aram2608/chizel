const std = @import("std");
const Allocator = std.mem.Allocator;
const Option = @import("Option.zig");
const OptionsMap = std.StringHashMap(Option);
const ArgParser = @import("ArgParser.zig");
const Completions = @This();

gpa: Allocator,
options: OptionsMap,
short_map: std.AutoHashMap(u8, []const u8),
program_name: []const u8,
option_order: std.ArrayList([]const u8) = .empty,

/// Create a `Completions` instance for the given program name.
///
/// `program_name` is copied; the caller does not need to keep it alive.
/// Call `deinit()` when done.
pub fn init(gpa: Allocator, program_name: []const u8) !Completions {
    return .{
        .gpa = gpa,
        .program_name = try gpa.dupe(u8, program_name),
        .short_map = std.AutoHashMap(u8, []const u8).init(gpa),
        .options = OptionsMap.init(gpa),
    };
}

pub fn initFromParser(gpa: Allocator, parser: *ArgParser) !Completions {
    return .{
        .gpa = gpa,
        .option_order = try parser.option_order.clone(gpa),
        .options = try parser.options.clone(),
        .program_name = try gpa.dupe(u8, parser.program_name),
        .short_map = try parser.short_map.clone(),
    };
}

pub fn deinit(self: *Completions) void {
    self.gpa.free(self.program_name);
    self.option_order.deinit(self.gpa);
    self.options.deinit();
    self.short_map.deinit();
}

pub fn addOption(self: *Completions, config: Option.Config) !void {
    if (std.mem.eql(u8, config.name, "help")) return error.ReservedOptionName;

    if (self.options.contains(config.name)) return error.DuplicateOption;
    if (config.default) |d| {
        if (d == .string_slice) return error.StringSliceDefaultNotSupported;
    }

    if (config.short) |s| {
        if (!std.ascii.isAlphanumeric(s)) return error.InvalidShortFlag;
        if (s == 'h') return error.ReservedShortFlag;
        try self.short_map.put(s, config.name);
    }

    try self.option_order.append(self.gpa, config.name);
    try self.options.put(config.name, .{
        .tag = config.tag,
        .help = config.help,
        .short = config.short,
        .required = config.required,
        .env = config.env,
        .validate = config.validate,
        .default = config.default,
    });
}

/// Generate a shell completion script for `target` and return it as an
/// owned `[]u8`.  The caller is responsible for freeing the returned slice.
///
/// To install the script, write the returned bytes to the appropriate path:
///   - bash: `~/.bashrc` source line, or `/etc/bash_completion.d/<prog>`
///   - fish: `~/.config/fish/completions/<prog>.fish`
///   - zsh:  a directory on `$fpath`, named `_<prog>`
pub fn createAutoCompletion(self: *Completions, target: AutoCompTarget) ![]const u8 {
    return switch (target) {
        .fish => self.createFishCompletion(),
        .bash => self.createBashCompletion(),
        .zsh => self.createZshCompletion(),
    };
}

fn createBashCompletion(self: *Completions) ![]const u8 {
    const prog = std.fs.path.basename(self.program_name);
    var buff = std.Io.Writer.Allocating.init(self.gpa);
    errdefer buff.deinit();

    try buff.writer.print("# Source this in ~/.bashrc or place in /etc/bash_completion.d/{s}\n", .{prog});
    try buff.writer.print("_{s}() {{\n", .{prog});
    try buff.writer.print("    local cur prev opts\n", .{});
    try buff.writer.print("    _init_completion || return\n", .{});

    try buff.writer.print("    opts=\"--help -h", .{});
    for (self.option_order.items) |name| {
        const opt = self.options.get(name).?;
        try buff.writer.print(" --{s}", .{name});
        if (opt.short) |s| try buff.writer.print(" -{c}", .{s});
    }
    try buff.writer.print("\"\n", .{});

    try buff.writer.print("    case \"$prev\" in\n", .{});
    for (self.option_order.items) |name| {
        const opt = self.options.get(name).?;
        switch (opt.tag) {
            .float, .int, .string, .string_slice => {
                if (opt.short) |s| {
                    try buff.writer.print("        --{s}|-{c})\n", .{ name, s });
                } else {
                    try buff.writer.print("        --{s})\n", .{name});
                }
                try buff.writer.print("            return ;;\n", .{});
            },
            .boolean => continue,
        }
    }
    try buff.writer.print("    esac\n", .{});

    try buff.writer.print("    COMPREPLY=($(compgen -W \"$opts\" -- \"$cur\"))\n", .{});
    try buff.writer.print("}}\n", .{});
    try buff.writer.print("complete -F _{s} {s}\n", .{ prog, prog });

    return buff.toOwnedSlice();
}

fn createFishCompletion(self: *Completions) ![]const u8 {
    const prog = std.fs.path.basename(self.program_name);
    var buff = std.Io.Writer.Allocating.init(self.gpa);
    errdefer buff.deinit();

    try buff.writer.print("# ~/.config/fish/completions/{s}.fish\n", .{prog});

    for (self.option_order.items) |name| {
        const opt = self.options.get(name).?;
        // -f disables file completion for the flag itself.
        // -r additionally marks that the option requires an argument.
        const kind: []const u8 = if (opt.tag == .boolean) "-f" else "-r -f";
        if (opt.short) |s| {
            try buff.writer.print("complete -c {s} -s {c} -l {s} {s} -d \"{s}\"\n", .{ prog, s, name, kind, opt.help });
        } else {
            try buff.writer.print("complete -c {s} -l {s} {s} -d \"{s}\"\n", .{ prog, name, kind, opt.help });
        }
    }
    try buff.writer.print("complete -c {s} -s h -l help -f -d \"Print help\"\n", .{prog});

    return buff.toOwnedSlice();
}

fn createZshCompletion(self: *Completions) ![]const u8 {
    const prog = std.fs.path.basename(self.program_name);
    var buff = std.Io.Writer.Allocating.init(self.gpa);
    errdefer buff.deinit();

    try buff.writer.print("#compdef {s}\n\n", .{prog});
    try buff.writer.print("_{s}() {{\n", .{prog});
    try buff.writer.print("    _arguments -s -w \\\n", .{});

    for (self.option_order.items) |name| {
        const opt = self.options.get(name).?;
        const help = opt.help;

        if (opt.short) |s| {
            switch (opt.tag) {
                .boolean => try buff.writer.print("        '(-{c} --{s})'{{-{c},--{s}}}'[{s}]' \\\n", .{ s, name, s, name, help }),
                .string_slice => try buff.writer.print("        '*'{{-{c},--{s}}}'[{s}]:value: ' \\\n", .{ s, name, help }),
                .float, .int, .string => try buff.writer.print("        '(-{c} --{s})'{{-{c},--{s}}}'[{s}]:value: ' \\\n", .{ s, name, s, name, help }),
            }
        } else {
            switch (opt.tag) {
                .boolean => try buff.writer.print("        '--{s}[{s}]' \\\n", .{ name, help }),
                .string_slice => try buff.writer.print("        '*--{s}[{s}]:value: ' \\\n", .{ name, help }),
                .float, .int, .string => try buff.writer.print("        '--{s}[{s}]:value: ' \\\n", .{ name, help }),
            }
        }
    }

    try buff.writer.print("        '--help[Print this help message]' && return 0\n", .{});
    try buff.writer.print("}}\n", .{});

    return buff.toOwnedSlice();
}

pub const AutoCompTarget = enum {
    bash,
    fish,
    zsh,
};
