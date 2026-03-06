# chizel

A lightweight, comptime-driven CLI argument parser for Zig.

Define your options as a plain Zig struct with default values. No runtime setup, no registration calls. All config lives in the struct. For programs with subcommands, pass a `union(enum)` instead.

## Installation

```sh
zig fetch --save "git+https://github.com/aram2608/chizel#main"
```

Wire it into your `build.zig`:

```zig
const chizel = b.dependency("chizel", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("chizel", chizel.module("chizel"));
```

## Quick start

```zig
const std = @import("std");
const chizel = @import("chizel");

const Opts = struct {
    host:    []const u8 = "localhost",
    port:    u16        = 8080,
    verbose: bool       = false,

    pub const shorts = .{ .host = 'h', .port = 'p', .verbose = 'v' };
    pub const help   = .{
        .host    = "Server host",
        .port    = "Server port",
        .verbose = "Enable verbose output",
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    const arena = std.heap.ArenaAllocator.init(alloc);
    var parser = chizel.Chizel(Opts).init(&args, arena);
    defer parser.deinit();

    const result = try parser.parse();

    if (result.had_help) {
        const out = try result.printHelp(alloc);
        defer alloc.free(out);
        std.debug.print("{s}\n", .{out});
        return;
    }

    std.debug.print("host={s} port={} verbose={}\n", .{
        result.opts.host,
        result.opts.port,
        result.opts.verbose,
    });
}
```

Run it:

```sh
./myapp --host example.com -p 9090 -v
./myapp --help
```

## Subcommands

Pass a `union(enum)` to `Chizel` instead of a struct. Each variant names a subcommand and must be a struct whose fields follow the same rules (all defaulted, optional `pub const shorts`):

```zig
const Cmds = union(enum) {
    serve: struct {
        port:    u16  = 8080,
        verbose: bool = false,
        pub const shorts = .{ .port = 'p' };
    },
    build: struct {
        release: bool = false,
    },
};

var parser = chizel.Chizel(Cmds).init(&args, arena);
defer parser.deinit();

const result = try parser.parse();
switch (result.opts) {
    .serve => |s| std.debug.print("serving on port {}\n", .{s.port}),
    .build => |b| std.debug.print("release={}\n", .{b.release}),
}
```

The first token after `argv[0]` is consumed as the subcommand name. Remaining tokens are parsed as flags for that subcommand's struct. Positionals are collected as normal.

## Defining options

Every field in your `Options` struct must have a default value; this is enforced at compile time. For fields that are logically required (no sensible default), use `?T = null`. The type system then forces you to handle the missing case at the call site:

```zig
const Opts = struct {
    name:    ?[]const u8        = null,   // required; handle null explicitly
    port:    u16                = 8080,
    tags:    []const []const u8 = &.{},
    verbose: bool               = false,
};
```

### Supported field types

| Zig type              | CLI behaviour                                          |
|-----------------------|--------------------------------------------------------|
| `bool`                | `--flag` → `true`; `--no-flag` → `false`              |
| `[]const u8`          | Consumes the next token                                |
| `[]const []const u8`  | Consumes tokens until the next flag or end of args     |
| `i*` / `u*`           | Parses the next token as an integer (any width)        |
| `f*`                  | Parses the next token as a float (any precision)       |
| `?T`                  | Parses as `T` when the flag is present, else `null`    |

### `pub const shorts`

Map field names to single-character short aliases. Only declare fields that need one:

```zig
pub const shorts = .{ .host = 'h', .port = 'p' };
```

Both `-h value` and `--host value` then map to the same field.

### `pub const help`

Provide help text per field. Used by `Result.printHelp()`:

```zig
pub const help = .{
    .host    = "Server host",
    .port    = "Server port (1-65535)",
    .verbose = "Enable verbose output",
};
```

If `pub const help` is absent, calling `result.printHelp()` is a compile error.

### `pub const config`

Control parser behaviour. All fields are optional; omit the entire declaration to use defaults:

```zig
pub const config = .{
    .help_enabled  = true,   // intercept --help / -h → Result.had_help
    .allow_unknown = false,  // collect unrecognised flags instead of erroring
};
```

| Field           | Default | Description |
|-----------------|---------|-------------|
| `help_enabled`  | `true`  | When true, `--help` and `-h` set `Result.had_help`. Disable to free `-h` for your own use. |
| `allow_unknown` | `false` | When true, unrecognised flags are collected in `Result.unknown_options` instead of returning `error.UnknownOption`. |

## Flag syntax

| Syntax             | Meaning                                              |
|--------------------|------------------------------------------------------|
| `--name value`     | Long flag with a value                               |
| `--name=value`     | Inline value (equivalent to above)                   |
| `--flag`           | Boolean flag → `true`                                |
| `--no-flag`        | Boolean negation → `false`                           |
| `-s value`         | Short alias (declared via `pub const shorts`)        |
| `--`               | End of flags; all remaining tokens become positionals |

Applying `--no-` to a non-boolean field is `error.CannotNegate`.

## Result

`parse()` returns a `Result` struct:

| Field              | Type                    | Description |
|--------------------|-------------------------|-------------|
| `prog`             | `[]const u8`            | `argv[0]` basename |
| `opts`             | `Options`               | Populated options struct |
| `positionals`      | `[]const []const u8`    | Non-flag tokens in order |
| `unknown_options`  | `[]const []const u8`    | Unrecognised flags (only when `allow_unknown = true`) |
| `had_help`         | `bool`                  | `true` when `--help` or `-h` appeared |

### Methods

**`result.printHelp(allocator) ![]const u8`**: Generates a formatted help message. Caller owns the returned slice. Requires `pub const help` in `Options`.

**`result.emitParsed(allocator) ![]const u8`**: Debug dump of all parsed values. Caller owns the returned slice.

## Shell completions

```zig
const script = try chizel.genCompletions(Opts, .fish, allocator, "myprog");
defer allocator.free(script);
// write script to ~/.config/fish/completions/myprog.fish
```

Supported targets: `.fish`, `.bash`, `.zsh`.

## Errors from `parse`

| Error | Cause |
|-------|-------|
| `error.AlreadyParsed` | `parse()` was called more than once |
| `error.MissingProgramName` | Iterator was empty (no `argv[0]`) |
| `error.MissingSubcommand` | Union mode: no subcommand token followed `argv[0]` |
| `error.UnknownSubcommand` | Union mode: the subcommand token matched no variant |
| `error.MissingValue` | A non-boolean flag had no following token |
| `error.CannotNegate` | `--no-` applied to a non-boolean field |
| `error.BoolCannotHaveValue` | `--flag=value` used on a boolean field |
| `error.UnknownOption` | Unrecognised flag and `allow_unknown = false` |
| `error.InvalidCharacter` / `error.Overflow` | Integer or float parse failure |

## Lifetime

All strings in `Result` (including `opts` string fields, positionals, unknowns) are owned by the parser's arena. Access them only while the parser is alive:

```zig
const arena = std.heap.ArenaAllocator.init(alloc);
var parser = chizel.Chizel(Opts).init(&args, arena);
defer parser.deinit();              // frees everything

const result = try parser.parse(); // result borrows from arena
// use result here; do NOT store slices beyond this scope
```
