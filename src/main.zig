//! glint — fantasy console with built-in local LLM
//!
//! CLI dispatcher: subcommand routes to engine entry points. Engine logic
//! lives in @import("glint") (src/root.zig). This file is intentionally
//! thin so the engine library can be embedded in other Zig programs without
//! pulling in CLI argument parsing.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const glint = @import("glint");

pub const VERSION = "0.0.1";

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 2) {
        try printUsage(stdout);
        return;
    }

    const cmd = argv[1];
    if (eql(cmd, "version") or eql(cmd, "-v") or eql(cmd, "--version")) {
        try cmdVersion(stdout);
    } else if (eql(cmd, "run")) {
        try cmdRun(stdout, argv[2..]);
    } else if (eql(cmd, "new")) {
        try cmdNew(stdout, argv[2..]);
    } else if (eql(cmd, "pack")) {
        try cmdPack(stdout, argv[2..]);
    } else if (eql(cmd, "replay")) {
        try cmdReplay(stdout, argv[2..]);
    } else if (eql(cmd, "help") or eql(cmd, "-h") or eql(cmd, "--help")) {
        try printUsage(stdout);
    } else {
        try stdout.print("glint: unknown subcommand '{s}'\n\n", .{cmd});
        try printUsage(stdout);
        return error.UnknownSubcommand;
    }
}

/// Tight wrapper for byte-slice equality; reads better at call sites than
/// `std.mem.eql(u8, a, b)` repeated three times in a chain of conditions.
inline fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn printUsage(w: *Io.Writer) !void {
    try w.writeAll(
        \\glint — fantasy console with built-in local LLM
        \\
        \\usage:
        \\  glint version              print version + build info
        \\  glint run <cart>           run a cart (.glint or .glint.png)
        \\  glint new <name>           scaffold new cart project
        \\  glint pack <dir/>          pack a cart directory into .glint.png
        \\  glint replay <inputs.bin> <cart>
        \\                             1000x headless replay; assert state hash invariance
        \\
        \\see doc/design.md for architecture, doc/dx-reliability-spec.md for cart-author API
        \\
    );
}

fn cmdVersion(w: *Io.Writer) !void {
    // Build + target info is what users actually need when reporting bugs.
    try w.print(
        \\glint {s}
        \\  zig:    {s}
        \\  target: {s}-{s}
        \\  mode:   {s}
        \\
    , .{
        VERSION,
        builtin.zig_version_string,
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        @tagName(builtin.mode),
    });
}

fn cmdRun(w: *Io.Writer, sub: []const []const u8) !void {
    if (sub.len < 1) {
        try w.writeAll("glint run: missing cart path. usage: glint run <cart>\n");
        return error.MissingArgument;
    }
    try w.print("glint run: stub — would load cart '{s}'\n", .{sub[0]});
    try w.writeAll("(engine integration pending W1-W6 milestones; see doc/roadmap.md)\n");
}

fn cmdNew(w: *Io.Writer, sub: []const []const u8) !void {
    if (sub.len < 1) {
        try w.writeAll("glint new: missing project name. usage: glint new <name>\n");
        return error.MissingArgument;
    }
    try w.print("glint new: stub — would scaffold cart project '{s}/'\n", .{sub[0]});
}

fn cmdPack(w: *Io.Writer, sub: []const []const u8) !void {
    _ = sub;
    try w.writeAll("glint pack: stub — cart format pending W6 deliverable\n");
}

fn cmdReplay(w: *Io.Writer, sub: []const []const u8) !void {
    _ = sub;
    try w.writeAll("glint replay: stub — determinism harness pending post-W10\n");
}

test "subcommand-name equality discriminator works" {
    try std.testing.expect(eql("run", "run"));
    try std.testing.expect(!eql("run", "new"));
    // case-sensitive on purpose: cart formats and commands are lowercase
    try std.testing.expect(!eql("run", "RUN"));
}

test "version constant is non-empty and starts with a digit" {
    try std.testing.expect(VERSION.len > 0);
    try std.testing.expect(std.ascii.isDigit(VERSION[0]));
}
