const std = @import("std");
const Allocator = std.mem.Allocator;
const fields = std.meta.fields;

pub const CompletionShell = enum { fish, zsh, bash };

/// Generate shell completion script for the given `Options` struct.
///
/// `Options` must be the same struct type passed to `Chizel`. Only the
/// comptime shape of `Options` is used — no parser instance is needed.
///
/// - `.fish` — emits a file suitable for `~/.config/fish/completions/<prog>.fish`
/// - `.bash` — emits a `complete` function suitable for sourcing in `.bashrc`
/// - `.zsh`  — emits a `complete` function suitable for sourcing in `.zshrc`.
pub fn genCompletions(
    comptime Options: type,
    target: CompletionShell,
    allocator: Allocator,
    prog: []const u8,
) ![]const u8 {
    return switch (target) {
        .fish => genFishCompletions(Options, allocator, prog),
        .bash => genBashCompletions(Options, allocator, prog),
        .zsh => genZshCompletions(Options, allocator, prog),
    };
}

fn genZshCompletions(
    comptime Options: type,
    allocator: Allocator,
    prog: []const u8,
) ![]const u8 {
    var buff = std.io.Writer.Allocating.init(allocator);
    errdefer buff.deinit();

    try buff.writer.print("#compdef {s}\n\n", .{prog});
    try buff.writer.print("_{s}() {{\n", .{prog});
    try buff.writer.print("    _arguments -s -w \\\n", .{});

    inline for (fields(Options)) |field| {
        const base_type = switch (@typeInfo(field.type)) {
            .optional => |o| o.child,
            else => field.type,
        };
        const is_bool = base_type == bool;
        const has_short = @hasDecl(Options, "shorts") and @hasField(@TypeOf(Options.shorts), field.name);
        const has_help = @hasDecl(Options, "help") and @hasField(@TypeOf(Options.help), field.name);
        const help_text: []const u8 = if (has_help) @field(Options.help, field.name) else field.name;

        if (is_bool) {
            if (has_short) {
                const s: u8 = @field(Options.shorts, field.name);
                try buff.writer.print("        '(-{c} --{s})-{c}[{s}]' \\\n", .{ s, field.name, s, help_text });
                try buff.writer.print("        '(-{c} --{s})--{s}[{s}]' \\\n", .{ s, field.name, field.name, help_text });
            } else {
                try buff.writer.print("        '--{s}[{s}]' \\\n", .{ field.name, help_text });
            }
            try buff.writer.print("        '--no-{s}[Negate {s}]' \\\n", .{ field.name, field.name });
        } else {
            if (has_short) {
                const s: u8 = @field(Options.shorts, field.name);
                try buff.writer.print("        '(-{c} --{s})-{c}+[{s}]:{s}: ' \\\n", .{ s, field.name, s, help_text, field.name });
                try buff.writer.print("        '(-{c} --{s})--{s}=[{s}]:{s}: ' \\\n", .{ s, field.name, field.name, help_text, field.name });
            } else {
                try buff.writer.print("        '--{s}=[{s}]:{s}: ' \\\n", .{ field.name, help_text, field.name });
            }
        }
    }

    try buff.writer.print("        '--help[Print this help message]' && return 0\n", .{});
    try buff.writer.print("}}\n", .{});
    try buff.writer.print("_{s} \"$@\"\n", .{prog});

    return buff.toOwnedSlice();
}

fn genFishCompletions(
    comptime Options: type,
    allocator: Allocator,
    prog: []const u8,
) ![]const u8 {
    var buff = std.io.Writer.Allocating.init(allocator);
    errdefer buff.deinit();
    try buff.writer.print("# ~/.config/fish/completions/{s}.fish\n", .{prog});

    inline for (std.meta.fields(Options)) |field| {
        const base_type = switch (@typeInfo(field.type)) {
            .optional => |o| o.child,
            else => field.type,
        };
        const kind: []const u8 = if (base_type == bool) "-f" else "-r -f";
        const has_short = @hasDecl(Options, "shorts") and @hasField(@TypeOf(Options.shorts), field.name);
        const has_help = @hasDecl(Options, "help") and @hasField(@TypeOf(Options.help), field.name);
        if (has_help) {
            const help: []const u8 = @field(Options.help, field.name);
            if (has_short) {
                const s: u8 = @field(Options.shorts, field.name);
                try buff.writer.print("complete -c {s} -s {c} -l {s} {s} -d \"{s}\"\n", .{ prog, s, field.name, kind, help });
            } else {
                try buff.writer.print("complete -c {s} -l {s} {s} -d \"{s}\"\n", .{ prog, field.name, kind, help });
            }
        } else {
            if (has_short) {
                const s: u8 = @field(Options.shorts, field.name);
                try buff.writer.print("complete -c {s} -s {c} -l {s} {s}\n", .{ prog, s, field.name, kind });
            } else {
                try buff.writer.print("complete -c {s} -l {s} {s}\n", .{ prog, field.name, kind });
            }
        }
    }

    return buff.toOwnedSlice();
}

fn genBashCompletions(
    comptime Options: type,
    allocator: Allocator,
    prog: []const u8,
) ![]const u8 {
    var buff = std.io.Writer.Allocating.init(allocator);
    errdefer buff.deinit();

    try buff.writer.print("_{s}() {{\n", .{prog});
    try buff.writer.print("    local cur prev opts\n", .{});
    try buff.writer.print("    _init_completion || return\n", .{});

    try buff.writer.print("    opts=\"--help -h", .{});
    inline for (std.meta.fields(Options)) |field| {
        try buff.writer.print(" --{s}", .{field.name});
        const has_short = @hasDecl(Options, "shorts") and @hasField(@TypeOf(Options.shorts), field.name);
        if (has_short) {
            const s: u8 = @field(Options.shorts, field.name);
            try buff.writer.print(" -{c}", .{s});
        }
    }
    try buff.writer.print("\"\n", .{});

    try buff.writer.print("    case \"$prev\" in\n", .{});
    inline for (std.meta.fields(Options)) |field| {
        const base_type = switch (@typeInfo(field.type)) {
            .optional => |o| o.child,
            else => field.type,
        };
        if (base_type == bool) continue;
        const has_short = @hasDecl(Options, "shorts") and
            @hasField(@TypeOf(Options.shorts), field.name);
        if (has_short) {
            const s: u8 = @field(Options.shorts, field.name);
            try buff.writer.print("        --{s}|-{c})\n", .{ field.name, s });
        } else {
            try buff.writer.print("        --{s})\n", .{field.name});
        }
        try buff.writer.print("            return ;;\n", .{});
    }

    try buff.writer.print("    esac\n", .{});

    try buff.writer.print("    COMPREPLY=($(compgen -W \"$opts\" -- \"$cur\"))\n", .{});
    try buff.writer.print("}}\n", .{});
    try buff.writer.print("complete -F _{s} {s}\n", .{ prog, prog });

    return buff.toOwnedSlice();
}
