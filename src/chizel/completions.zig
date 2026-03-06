const std = @import("std");
const Allocator = std.mem.Allocator;
const fields = std.meta.fields;

pub const CompletionShell = enum { fish, zsh, bash };

/// Generate shell completion script for the given `Options` struct or union.
///
/// `Options` must be the same struct/union type passed to `Chizel`. Only the
/// comptime shape of `Options` is used; no parser instance is needed.
///
/// - `.fish`: emits a file suitable for `~/.config/fish/completions/<prog>.fish`
/// - `.bash`: emits a `complete` function suitable for sourcing in `.bashrc`
/// - `.zsh`:  emits a `complete` function suitable for sourcing in `.zshrc`.
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

    if (@typeInfo(Options) == .@"union") {
        // State-machine approach: first word dispatches to a subcommand.
        try buff.writer.print("    local state\n", .{});
        try buff.writer.print("    _arguments \\\n", .{});
        try buff.writer.print("        '1: :->subcmd' \\\n", .{});
        try buff.writer.print("        '*: :->args'\n\n", .{});
        try buff.writer.print("    case $state in\n", .{});
        try buff.writer.print("        subcmd)\n", .{});
        try buff.writer.print("            local subcommands\n", .{});
        try buff.writer.print("            subcommands=(\n", .{});
        inline for (fields(Options)) |f| {
            const has_help = @hasDecl(f.type, "help") and @hasField(@TypeOf(f.type.help), "_cmd");
            const desc: []const u8 = if (has_help) @field(f.type.help, "_cmd") else f.name;
            try buff.writer.print("                '{s}:{s}'\n", .{ f.name, desc });
        }
        try buff.writer.print("            )\n", .{});
        try buff.writer.print("            _describe 'subcommand' subcommands\n", .{});
        try buff.writer.print("            ;;\n", .{});
        try buff.writer.print("        args)\n", .{});
        try buff.writer.print("            case $words[2] in\n", .{});
        inline for (fields(Options)) |f| {
            try buff.writer.print("                {s})\n", .{f.name});
            try buff.writer.print("                    _arguments -s -w \\\n", .{});
            try writeZshStructArgs(f.type, "                        ", &buff.writer);
            try buff.writer.print("                        '--help[Print this help message]' && return 0\n", .{});
            try buff.writer.print("                    ;;\n", .{});
        }
        try buff.writer.print("            esac\n", .{});
        try buff.writer.print("            ;;\n", .{});
        try buff.writer.print("    esac\n", .{});
    } else {
        try buff.writer.print("    _arguments -s -w \\\n", .{});
        try writeZshStructArgs(Options, "        ", &buff.writer);
        try buff.writer.print("        '--help[Print this help message]' && return 0\n", .{});
    }

    try buff.writer.print("}}\n", .{});
    try buff.writer.print("_{s} \"$@\"\n", .{prog});

    return buff.toOwnedSlice();
}

fn writeZshStructArgs(comptime Opts: type, comptime indent: []const u8, writer: anytype) !void {
    inline for (fields(Opts)) |field| {
        const base_type = switch (@typeInfo(field.type)) {
            .optional => |o| o.child,
            else => field.type,
        };
        const is_bool = base_type == bool;
        const has_short = @hasDecl(Opts, "shorts") and @hasField(@TypeOf(Opts.shorts), field.name);
        const has_help = @hasDecl(Opts, "help") and @hasField(@TypeOf(Opts.help), field.name);
        const help_text: []const u8 = if (has_help) @field(Opts.help, field.name) else field.name;

        if (is_bool) {
            if (has_short) {
                const s: u8 = @field(Opts.shorts, field.name);
                try writer.print(indent ++ "'(-{c} --{s})-{c}[{s}]' \\\n", .{ s, field.name, s, help_text });
                try writer.print(indent ++ "'(-{c} --{s})--{s}[{s}]' \\\n", .{ s, field.name, field.name, help_text });
            } else {
                try writer.print(indent ++ "'--{s}[{s}]' \\\n", .{ field.name, help_text });
            }
            try writer.print(indent ++ "'--no-{s}[Negate {s}]' \\\n", .{ field.name, field.name });
        } else {
            if (has_short) {
                const s: u8 = @field(Opts.shorts, field.name);
                try writer.print(indent ++ "'(-{c} --{s})-{c}+[{s}]:{s}: ' \\\n", .{ s, field.name, s, help_text, field.name });
                try writer.print(indent ++ "'(-{c} --{s})--{s}=[{s}]:{s}: ' \\\n", .{ s, field.name, field.name, help_text, field.name });
            } else {
                try writer.print(indent ++ "'--{s}=[{s}]:{s}: ' \\\n", .{ field.name, help_text, field.name });
            }
        }
    }
}

fn genFishCompletions(
    comptime Options: type,
    allocator: Allocator,
    prog: []const u8,
) ![]const u8 {
    var buff = std.io.Writer.Allocating.init(allocator);
    errdefer buff.deinit();
    try buff.writer.print("# ~/.config/fish/completions/{s}.fish\n", .{prog});

    if (@typeInfo(Options) == .@"union") {
        // Build a space-separated list of all subcommand names for use in conditions.
        const all_subcmds = comptime blk: {
            var s: []const u8 = "";
            for (fields(Options), 0..) |f, i| {
                if (i > 0) s = s ++ " ";
                s = s ++ f.name;
            }
            break :blk s;
        };

        // Subcommand name completions (only shown before a subcommand is given).
        inline for (fields(Options)) |f| {
            const has_help = @hasDecl(f.type, "help") and @hasField(@TypeOf(f.type.help), "_cmd");
            const desc: []const u8 = if (has_help) @field(f.type.help, "_cmd") else f.name;
            try buff.writer.print(
                "complete -c {s} -f -n 'not __fish_seen_subcommand_from {s}' -a {s} -d \"{s}\"\n",
                .{ prog, all_subcmds, f.name, desc },
            );
        }

        // Per-subcommand flag completions.
        inline for (fields(Options)) |f| {
            const cond = "__fish_seen_subcommand_from " ++ f.name;
            try writeFishStructFlags(f.type, &buff.writer, prog, cond);
        }
    } else {
        try writeFishStructFlags(Options, &buff.writer, prog, "");
    }

    return buff.toOwnedSlice();
}

fn writeFishStructFlags(
    comptime Opts: type,
    writer: anytype,
    prog: []const u8,
    cond: []const u8,
) !void {
    inline for (fields(Opts)) |field| {
        const base_type = switch (@typeInfo(field.type)) {
            .optional => |o| o.child,
            else => field.type,
        };
        const kind: []const u8 = if (base_type == bool) "-f" else "-r -f";
        const has_short = @hasDecl(Opts, "shorts") and @hasField(@TypeOf(Opts.shorts), field.name);
        const has_help = @hasDecl(Opts, "help") and @hasField(@TypeOf(Opts.help), field.name);

        if (has_help) {
            const help: []const u8 = @field(Opts.help, field.name);
            if (cond.len > 0) {
                if (has_short) {
                    const s: u8 = @field(Opts.shorts, field.name);
                    try writer.print("complete -c {s} -n '{s}' -s {c} -l {s} {s} -d \"{s}\"\n", .{ prog, cond, s, field.name, kind, help });
                } else {
                    try writer.print("complete -c {s} -n '{s}' -l {s} {s} -d \"{s}\"\n", .{ prog, cond, field.name, kind, help });
                }
            } else {
                if (has_short) {
                    const s: u8 = @field(Opts.shorts, field.name);
                    try writer.print("complete -c {s} -s {c} -l {s} {s} -d \"{s}\"\n", .{ prog, s, field.name, kind, help });
                } else {
                    try writer.print("complete -c {s} -l {s} {s} -d \"{s}\"\n", .{ prog, field.name, kind, help });
                }
            }
        } else {
            if (cond.len > 0) {
                if (has_short) {
                    const s: u8 = @field(Opts.shorts, field.name);
                    try writer.print("complete -c {s} -n '{s}' -s {c} -l {s} {s}\n", .{ prog, cond, s, field.name, kind });
                } else {
                    try writer.print("complete -c {s} -n '{s}' -l {s} {s}\n", .{ prog, cond, field.name, kind });
                }
            } else {
                if (has_short) {
                    const s: u8 = @field(Opts.shorts, field.name);
                    try writer.print("complete -c {s} -s {c} -l {s} {s}\n", .{ prog, s, field.name, kind });
                } else {
                    try writer.print("complete -c {s} -l {s} {s}\n", .{ prog, field.name, kind });
                }
            }
        }
    }
}

fn genBashCompletions(
    comptime Options: type,
    allocator: Allocator,
    prog: []const u8,
) ![]const u8 {
    var buff = std.io.Writer.Allocating.init(allocator);
    errdefer buff.deinit();

    try buff.writer.print("_{s}() {{\n", .{prog});
    try buff.writer.print("    local cur prev\n", .{});
    try buff.writer.print("    _init_completion || return\n\n", .{});

    if (@typeInfo(Options) == .@"union") {
        // Emit subcommand names.
        try buff.writer.print("    local subcommands=\"", .{});
        inline for (fields(Options), 0..) |f, i| {
            if (i > 0) try buff.writer.print(" ", .{});
            try buff.writer.print("{s}", .{f.name});
        }
        try buff.writer.print("\"\n\n", .{});

        // Detect the active subcommand from COMP_WORDS.
        try buff.writer.print("    local subcmd=\"\"\n", .{});
        try buff.writer.print("    local word\n", .{});
        try buff.writer.print("    for word in \"${{COMP_WORDS[@]:1}}\"; do\n", .{});
        try buff.writer.print("        case \"$word\" in\n", .{});
        try buff.writer.print("            ", .{});
        inline for (fields(Options), 0..) |f, i| {
            if (i > 0) try buff.writer.print("|", .{});
            try buff.writer.print("{s}", .{f.name});
        }
        try buff.writer.print(") subcmd=\"$word\"; break ;;\n", .{});
        try buff.writer.print("        esac\n", .{});
        try buff.writer.print("    done\n\n", .{});

        // If no subcommand yet, complete subcommand names.
        try buff.writer.print("    if [[ -z \"$subcmd\" ]]; then\n", .{});
        try buff.writer.print("        COMPREPLY=($(compgen -W \"$subcommands\" -- \"$cur\"))\n", .{});
        try buff.writer.print("        return\n", .{});
        try buff.writer.print("    fi\n\n", .{});

        // Per-subcommand flag completion.
        try buff.writer.print("    local opts\n", .{});
        try buff.writer.print("    case \"$subcmd\" in\n", .{});
        inline for (fields(Options)) |f| {
            try buff.writer.print("        {s})\n", .{f.name});
            // value-taking flags need early return when $prev matches them
            try buff.writer.print("            case \"$prev\" in\n", .{});
            inline for (fields(f.type)) |sub_field| {
                const base_type = switch (@typeInfo(sub_field.type)) {
                    .optional => |o| o.child,
                    else => sub_field.type,
                };
                if (base_type == bool) continue;
                const has_short = @hasDecl(f.type, "shorts") and
                    @hasField(@TypeOf(f.type.shorts), sub_field.name);
                if (has_short) {
                    const s: u8 = @field(f.type.shorts, sub_field.name);
                    try buff.writer.print("                --{s}|-{c}) return ;;\n", .{ sub_field.name, s });
                } else {
                    try buff.writer.print("                --{s}) return ;;\n", .{sub_field.name});
                }
            }
            try buff.writer.print("            esac\n", .{});
            // Build opts string.
            try buff.writer.print("            opts=\"--help -h", .{});
            inline for (fields(f.type)) |sub_field| {
                const base_type = switch (@typeInfo(sub_field.type)) {
                    .optional => |o| o.child,
                    else => sub_field.type,
                };
                try buff.writer.print(" --{s}", .{sub_field.name});
                if (base_type == bool) try buff.writer.print(" --no-{s}", .{sub_field.name});
                const has_short = @hasDecl(f.type, "shorts") and
                    @hasField(@TypeOf(f.type.shorts), sub_field.name);
                if (has_short) {
                    const s: u8 = @field(f.type.shorts, sub_field.name);
                    try buff.writer.print(" -{c}", .{s});
                }
            }
            try buff.writer.print("\"\n", .{});
            try buff.writer.print("            ;;\n", .{});
        }
        try buff.writer.print("    esac\n\n", .{});
    } else {
        try buff.writer.print("    local opts=\"--help -h", .{});
        inline for (fields(Options)) |field| {
            try buff.writer.print(" --{s}", .{field.name});
            const has_short = @hasDecl(Options, "shorts") and @hasField(@TypeOf(Options.shorts), field.name);
            if (has_short) {
                const s: u8 = @field(Options.shorts, field.name);
                try buff.writer.print(" -{c}", .{s});
            }
        }
        try buff.writer.print("\"\n\n", .{});

        try buff.writer.print("    case \"$prev\" in\n", .{});
        inline for (fields(Options)) |field| {
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
        try buff.writer.print("    esac\n\n", .{});
    }

    try buff.writer.print("    COMPREPLY=($(compgen -W \"$opts\" -- \"$cur\"))\n", .{});
    try buff.writer.print("}}\n", .{});
    try buff.writer.print("complete -F _{s} {s}\n", .{ prog, prog });

    return buff.toOwnedSlice();
}
