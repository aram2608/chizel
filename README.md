# chizel

A simple CLI argument parser for Zig supporting `bool`, `i64`, `f64`, `[]const u8`, and `[][]const u8` option types.

## Fetching as a dependency

```sh
zig fetch --save "git+https://github.com/aram2608/chizel#main"
```

This adds chizel to your `build.zig.zon`. Then wire it into your `build.zig`:

```zig
const chizel = b.dependency("chizel", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("chizel", chizel.module("chizel"));
```

## Usage

```zig
const std = @import("std");
const chizel = @import("chizel");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();
    var parser = try chizel.ArgParser.init(allocator, args);
    defer parser.deinit();

    try parser.addOption(.{ .name = "verbose", .tag = .boolean, .short = 'v', .help = "Enable verbose output" });
    try parser.addOption(.{ .name = "count",   .tag = .int,     .short = 'n', .help = "Number of iterations", .default = .{ .int = 1 } });
    try parser.addOption(.{ .name = "name",    .tag = .string,               .help = "Your name", .required = true });
    try parser.addOption(.{ .name = "tags",    .tag = .string_slice,         .help = "List of tags" });

    var result = try parser.parse();
    defer result.deinit();

    if (result.hadHelp()) {
        try result.printHelp();
        return;
    }

    if (result.isPresent("verbose")) std.debug.print("verbose on\n", .{});
    if (result.getInt("count"))      |n| std.debug.print("count: {}\n",  .{n});
    if (result.getString("name"))    |s| std.debug.print("name: {s}\n",  .{s});
    if (result.getStringSlice("tags")) |tags| {
        for (tags) |tag| std.debug.print("tag: {s}\n", .{tag});
    }

    const positionals = result.getPositionals();
    for (positionals) |p| std.debug.print("positional: {s}\n", .{p});
}
```

Run it:

```sh
./myapp --name alice -v -n 5 --tags foo bar baz extra_arg
./myapp --help
```

Help output is automatically aligned and annotated:

```
Usage: myapp [OPTIONS]
Options:
-v, --verbose             Enable verbose output
-n, --count <int>         Number of iterations (default: 1)
    --name <string>       Your name (required)
    --tags <string...>    List of tags
    --help                Print this help message
```

## API

### `ArgParser`

| Function | Description |
|---|---|
| `init(allocator, args) !ArgParser` | Create a parser from a `std.process.ArgIterator` |
| `deinit()` | Free all resources |
| `addOption(config) !void` | Register an option (see `Option.Config` below) |
| `parse() !ParseResult` | Parse argv; errors if called more than once |
| `dumpOptions(writer) !void` | Write registered option names and tags to a writer |
| `dumpUnknown(writer) !void` | Write unrecognised option names to a writer |

#### `Option.Config`

All fields except `name` and `tag` are optional.

```zig
chizel.Option.Config{
    .name     = "port",           // long flag name, e.g. --port
    .short    = 'p',              // short alias, e.g. -p  (optional)
    .tag      = .int,             // .boolean | .int | .float | .string | .string_slice
    .help     = "Port to use",    // shown in --help output
    .required = true,             // parse() returns error.MissingRequiredOption if absent
    .env      = "APP_PORT",       // fall back to this env var when flag is absent
    .default  = .{ .int = 8080 }, // used when flag and env var are both absent
    .validate = &myValidateFn,    // fn(Option.Value) bool — parse() errors on false
}
```

**Priority order:** `--flag` › `--no-flag` › environment variable › default value.

**`required`** is satisfied by a CLI flag or an env-var fallback; a `default` alone does not count.

**`string_slice` defaults** are not supported. Use `getStringSlice("x") orelse &.{...}` at the call site.

#### Errors from `addOption`

| Error | Cause |
|---|---|
| `error.ReservedOptionName` | `"help"` is built-in and cannot be registered |
| `error.DuplicateOption` | The name was already registered |
| `error.StringSliceDefaultNotSupported` | See note above |

#### Errors from `parse`

| Error | Cause |
|---|---|
| `error.AlreadyParsed` | `parse()` was called more than once |
| `error.MissingValue` | A non-boolean option had no value following it |
| `error.MissingRequiredOption` | A `required` option was absent from CLI and env |
| `error.ValidationFailed` | A `validate` callback returned `false` |
| `error.ArgumentBufferOverflow` | Total argv length exceeded 4096 bytes |

### `ParseResult`

| Function | Return | Description |
|---|---|---|
| `isPresent(name)` | `bool` | For `.boolean` options: the effective boolean value. For all others: `true` if the flag appeared on CLI or was set via env var |
| `getInt(name)` | `?i64` | Parsed integer value |
| `getFloat(name)` | `?f64` | Parsed float value |
| `getString(name)` | `?[]const u8` | Parsed string value |
| `getStringSlice(name)` | `?[][]const u8` | Parsed list of strings |
| `getPositionals()` | `[]const []const u8` | Non-flag arguments, in order |
| `getCount(name)` | `u32` | Times the option appeared (useful for `-v -v -v`) |
| `hadHelp()` | `bool` | `true` if `--help` was passed |
| `printHelp()` | `!void` | Write the generated usage message to stdout |
| `deinit()` | `void` | Free result resources |

All `get*` methods return `null` when the option was absent and had no default.

#### Lifetime note

`getString` and `getStringSlice` element pointers remain valid only while the `ArgParser` is alive. In typical usage both are deferred in the same scope, so this is not an issue — but avoid storing these slices beyond `parser.deinit()`.

## Boolean flags

Boolean options are presence flags — passing `--verbose` sets the value to `true`. Every boolean option also has an implicit `--no-<name>` counterpart that sets it to `false`, which is useful for overriding an environment variable or a default:

```sh
./myapp --verbose          # verbose = true
./myapp --no-verbose       # verbose = false
```

Use `isPresent` to read the effective value:

```zig
if (result.isPresent("verbose")) { ... }
```

Resolution order for boolean options:

```
--flag  >  --no-flag  >  env var  >  default
```

`--no-<name>` is only recognised for options registered with `.tag = .boolean`; using it on any other type treats it as an unknown option.

## Short flags

Register a single-character alias with `.short`:

```zig
try parser.addOption(.{ .name = "verbose", .tag = .boolean, .short = 'v', .help = "..." });
```

Both `-v` and `--verbose` then map to the same option.

## Positional arguments

Any token that does not begin with `-` is treated as a positional argument and collected in order. Flags and positionals can be freely mixed:

```sh
./myapp file1.txt --verbose file2.txt
```

```zig
const files = result.getPositionals(); // ["file1.txt", "file2.txt"]
```

Note: `string_slice` options are greedy — they consume all following bare words until the next flag. Place positionals before a `string_slice` option, or after all options, to avoid ambiguity.

## Environment variable fallbacks

```zig
try parser.addOption(.{ .name = "host", .tag = .string, .env = "APP_HOST", .help = "Server host" });
```

```sh
APP_HOST=localhost ./myapp   # same as --host localhost
./myapp --host example.com   # CLI wins
```

For `.string_slice`, the env var value is split on spaces.
For `.boolean`, `"1"`, `"true"`, and `"yes"` are all accepted.

## Validation

```zig
try parser.addOption(.{
    .name     = "port",
    .tag      = .int,
    .help     = "Port (1–65535)",
    .validate = struct {
        fn check(v: chizel.Option.Value) bool {
            return v.int > 0 and v.int <= 65535;
        }
    }.check,
});
```

`parse()` returns `error.ValidationFailed` if the callback returns `false`.

---

## ZiggyParse

A lighter-weight alternative to `ArgParser` for simple use cases. Define your CLI options as a plain Zig struct and ZiggyParse handles the rest — all config lives in the struct, no runtime setup required.

```zig
const std = @import("std");
const chizel = @import("chizel");
const ArgIterator = std.process.ArgIterator;

const Opts = struct {
    host:    []const u8 = "localhost",
    port:    u16        = 8080,
    verbose: bool       = false,

    // Short aliases — only declare fields that need one.
    pub const shorts = .{ .host = 'h', .port = 'p', .verbose = 'v' };

    // Help text per field — used by Result.printHelp().
    pub const help = .{
        .host    = "Server host",
        .port    = "Server port",
        .verbose = "Enable verbose output",
    };

    // Parser behaviour — all fields are optional, shown here with their defaults.
    pub const config = .{
        .help_enabled  = true,   // intercept --help / -h → Result.had_help
        .allow_unknown = false,  // collect unknown flags instead of erroring
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    const arena = std.heap.ArenaAllocator.init(alloc);
    var parser = chizel.ZiggyParse(Opts, *ArgIterator).init(&args, arena);
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

### Supported field types

| Zig type              | CLI behaviour                                          |
|-----------------------|--------------------------------------------------------|
| `bool`                | `--flag` → `true`; `--no-flag` → `false`              |
| `[]const u8`          | Consumes the next token                                |
| `[]const []const u8`  | Consumes tokens until the next flag or end of args     |
| `i*` / `u*`           | Parses the next token as an integer                    |
| `f*`                  | Parses the next token as a float                       |
| `?T`                  | Parses as `T` when the flag is present, else `null`    |

Every field must have a default value. For logically required fields use `?T = null` — the type system then forces the caller to handle the missing case.

### `pub const config` options

| Field           | Default | Description |
|-----------------|---------|-------------|
| `help_enabled`  | `true`  | When true, `--help` and `-h` are intercepted and set `Result.had_help`. Disable to free `-h` for your own use. |
| `allow_unknown` | `false` | When true, unrecognised flags are collected in `Result.unknown_options` instead of returning `error.UnknownOption`. |

Omit `pub const config` entirely to get the defaults.

### Shell completions

```zig
const script = try chizel.genCompletions(Opts, .fish, allocator, "myprog");
defer allocator.free(script);
// write script to ~/.config/fish/completions/myprog.fish
```

Supported targets: `.fish`, `.bash`. `.zsh` returns `error.NotImplemented`.

### Errors from `parse`

| Error | Cause |
|-------|-------|
| `error.AlreadyParsed` | `parse()` called more than once |
| `error.MissingProgramName` | Iterator was empty (no `argv[0]`) |
| `error.MissingValue` | A non-boolean flag had no following token |
| `error.CannotNegate` | `--no-` applied to a non-boolean field |
| `error.UnknownOption` | Unrecognised flag and `allow_unknown = false` |
| `error.InvalidCharacter` / `error.Overflow` | Integer parse failure |

### Lifetime

All strings in `Result` are owned by the parser's arena. Access them only while the parser is alive:

```zig
var parser = chizel.ZiggyParse(Opts, *ArgIterator).init(&args, arena);
defer parser.deinit();              // frees everything
const result = try parser.parse(); // result borrows from arena
```
