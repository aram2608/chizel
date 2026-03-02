# chizel

Chizel. A simple CLI argument parser for Zig supporting `bool`, `i32`, `f32`, `[]const u8`, and `[][]const u8` option types.

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

// Add the import to your executable or library module
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

    try parser.addOption("verbose", .boolean, "Enable verbose output");
    try parser.addOption("count", .int, "Number of iterations");
    try parser.addOption("name", .string, "Your name");
    try parser.addOption("tags", .string_slice, "List of tags");

    var result = try parser.parse();
    defer result.deinit();

    if (result.had_help) {
        result.printHelp();
        return;
    }

    if (result.getBool("verbose")) |v| {
        std.debug.print("verbose: {}\n", .{v});
    }
    if (result.getInt("count")) |n| {
        std.debug.print("count: {}\n", .{n});
    }
    if (result.getString("name")) |s| {
        std.debug.print("name: {s}\n", .{s});
    }
    if (result.getStringSlice("tags")) |tags| {
        for (tags) |tag| std.debug.print("tag: {s}\n", .{tag});
    }
}
```

Run it:

```sh
./myapp --verbose --count 3 --name alice --tags foo bar baz
./myapp --help
```

## API

### `ArgParser`

| Function | Description |
|---|---|
| `init(allocator, args) !ArgParser` | Create a parser from a `std.process.ArgIterator` |
| `deinit()` | Free all resources |
| `addOption(name, tag, help) !void` | Register an option by name, type tag, and help text |
| `parse() !ParseResult` | Parse arguments; errors if called more than once |

Option tags: `.boolean`, `.int`, `.float`, `.string`, `.string_slice`

### `ParseResult`

| Function | Return type | Description |
|---|---|---|
| `getBool(name)` | `?bool` | Get a boolean flag value |
| `getInt(name)` | `?i32` | Get an integer value |
| `getFloat(name)` | `?f32` | Get a float value |
| `getString(name)` | `?[]const u8` | Get a string value |
| `getStringSlice(name)` | `?[][]const u8` | Get a list of strings |
| `isPresent(name)` | `bool` | Check if an option was provided |
| `getCount(name)` | `u32` | Number of times the option appeared |
| `printHelp()` | | Print the generated help message to stdout |
| `deinit()` | | Free result resources |

`had_help bool` — set to `true` if `--help` was passed. Check this before reading results and call `printHelp()` to print the auto-generated usage message.

All `get*` methods return `null` if the option was not provided or the type does not match.
