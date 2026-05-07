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
        try cmdRun(arena, io, stdout, argv[2..]);
    } else if (eql(cmd, "new")) {
        try cmdNew(stdout, argv[2..]);
    } else if (eql(cmd, "pack")) {
        try cmdPack(arena, io, stdout, argv[2..]);
    } else if (eql(cmd, "replay")) {
        try cmdReplay(stdout, argv[2..]);
    } else if (eql(cmd, "demo")) {
        try cmdDemo(stdout);
    } else if (eql(cmd, "demo-cart")) {
        try cmdDemoCart(arena, io, stdout, argv[2..]);
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
        \\  glint pack <dir/>          pack a cart directory (manifest.toml + code.lua) into .glint
        \\  glint replay <inputs.bin> <cart>
        \\                             1000x headless replay; assert state hash invariance
        \\  glint demo                 open a 768x768 sokol palette-cycle window
        \\  glint demo-cart <out>      write a sample .glint binary for testing
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

fn cmdRun(alloc: std.mem.Allocator, io: Io, w: *Io.Writer, sub: []const []const u8) !void {
    if (sub.len < 1) {
        try w.writeAll("glint run: missing cart path. usage: glint run <cart>\n");
        return error.MissingArgument;
    }
    const path = sub[0];

    // Read the whole cart binary in one shot. Carts are bounded by
    // PNG-steg capacity (32800 B) so this is always small.
    const cwd = Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, path, alloc, .limited(glint.cart_format.MAX_CART_BYTES)) catch |err| {
        try w.print("glint run: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer alloc.free(bytes);

    var cart = glint.cart_format.decode(alloc, bytes) catch |err| {
        try w.print("glint run: decode failed for '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer cart.deinit(alloc);

    // Print a tight summary; deferred Luau host will replace this with the
    // actual run loop once W5 lands.
    try w.print(
        \\glint cart summary
        \\  path:     {s}
        \\  bytes:    {d}
        \\  cart_id:  0x{x}
        \\  author:   {s}
        \\  title:    {s}
        \\  flags:    0x{x}{s}{s}{s}
        \\  sections: {d}
        \\
    , .{
        path,
        bytes.len,
        cart.header.cart_id,
        trimAscii(&cart.header.author),
        trimAscii(&cart.header.title),
        cart.header.flags,
        if (cart.header.flags & glint.cart_format.Header.FLAG_NEEDS_NET != 0) " net" else "",
        if (cart.header.flags & glint.cart_format.Header.FLAG_NEEDS_LLM != 0) " llm" else "",
        if (cart.header.flags & glint.cart_format.Header.FLAG_MULTIPLAYER != 0) " mp" else "",
        cart.sections.len,
    });
    for (cart.sections, 0..) |s, i| {
        try w.print("    [{d}] {s} ({d} bytes)\n", .{ i, sectionTypeName(s.type), s.data.len });
    }
    try w.writeAll("\n(execution pending Luau VM integration; see doc/roadmap.md W5)\n");
}

fn cmdDemoCart(alloc: std.mem.Allocator, io: Io, w: *Io.Writer, sub: []const []const u8) !void {
    if (sub.len < 1) {
        try w.writeAll("glint demo-cart: missing output path. usage: glint demo-cart <out.glint>\n");
        return error.MissingArgument;
    }
    const out_path = sub[0];

    // Sample cart contents. Real cart will be authored in Lua + assets
    // and packed via `glint pack`; this is a smoke-test artefact for the
    // binary container before the cart toolchain is online.
    const sample_code =
        \\-- glint demo cart (placeholder; real Luau host pending W5)
        \\function _init()
        \\  pal_index = 0
        \\end
        \\function _update()
        \\  pal_index = (pal_index + 1) % 16
        \\end
        \\function _draw()
        \\  cls(pal_index)
        \\end
        \\
    ;
    const sample_meta = "title=demo\nauthor=glint-team\ndescription=palette cycle smoke test\n";

    const sections = [_]glint.cart_format.Section{
        .{ .type = .code, .data = sample_code },
        .{ .type = .meta, .data = sample_meta },
    };
    const header: glint.cart_format.Header = .{
        .cart_id = 0x0123_4567_89AB_CDEF_FEDC_BA98_7654_3210,
        .author = padFixed("glint-team"),
        .title = padFixed("demo"),
        .flags = 0,
        .n_sections = 0, // overwritten by encode()
    };

    const bin = glint.cart_format.encode(alloc, header, &sections) catch |err| {
        try w.print("glint demo-cart: encode failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer alloc.free(bin);

    const cwd = Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = out_path, .data = bin }) catch |err| {
        try w.print("glint demo-cart: cannot write '{s}': {s}\n", .{ out_path, @errorName(err) });
        return err;
    };

    try w.print("glint demo-cart: wrote {d} bytes to '{s}'\n", .{ bin.len, out_path });
    try w.print("  sections: code ({d} B), meta ({d} B)\n", .{ sample_code.len, sample_meta.len });
    try w.print("  next:     glint run {s}\n", .{out_path});
}

/// Trim trailing NUL bytes from a fixed-size ASCII field for display.
fn trimAscii(s: []const u8) []const u8 {
    const n = std.mem.indexOfScalar(u8, s, 0) orelse s.len;
    return s[0..n];
}

/// Pad an ASCII string into a 16-byte null-padded field. Truncates silently
/// past 16 bytes — header struct enforces the max via type system.
fn padFixed(s: []const u8) [16]u8 {
    var out: [16]u8 = [_]u8{0} ** 16;
    const n = @min(s.len, 16);
    @memcpy(out[0..n], s[0..n]);
    return out;
}

/// Pretty-print a SectionType. Open enum: unknown values get a placeholder
/// rather than crashing the summary output.
fn sectionTypeName(t: glint.cart_format.SectionType) []const u8 {
    return switch (t) {
        .code => "code",
        .sprite => "sprite",
        .map => "map",
        .music => "music",
        .sfx => "sfx",
        .ai => "ai",
        .meta => "meta",
        .icon => "icon",
        _ => "(unknown)",
    };
}

fn cmdNew(w: *Io.Writer, sub: []const []const u8) !void {
    if (sub.len < 1) {
        try w.writeAll("glint new: missing project name. usage: glint new <name>\n");
        return error.MissingArgument;
    }
    try w.print("glint new: stub — would scaffold cart project '{s}/'\n", .{sub[0]});
}

fn cmdPack(alloc: std.mem.Allocator, io: Io, w: *Io.Writer, sub: []const []const u8) !void {
    if (sub.len < 1) {
        try w.writeAll("glint pack: missing cart directory. usage: glint pack <dir/>\n");
        return error.MissingArgument;
    }
    const dir_path = sub[0];

    // Resolve manifest + code paths inside the cart directory. Both are
    // mandatory: manifest is the cart's identity, code.lua is its body.
    const manifest_path = try std.fs.path.join(alloc, &.{ dir_path, "manifest.toml" });
    defer alloc.free(manifest_path);
    const code_path = try std.fs.path.join(alloc, &.{ dir_path, "code.lua" });
    defer alloc.free(code_path);

    const cwd = Io.Dir.cwd();
    const manifest_text = cwd.readFileAlloc(io, manifest_path, alloc, .limited(glint.cart_format.MAX_CART_BYTES)) catch |err| {
        try w.print("glint pack: cannot read '{s}': {s}\n", .{ manifest_path, @errorName(err) });
        return err;
    };
    defer alloc.free(manifest_text);
    var m = glint.manifest.parse(alloc, manifest_text) catch |err| {
        try w.print("glint pack: manifest invalid: {s}\n", .{@errorName(err)});
        return err;
    };
    defer m.deinit(alloc);

    const code_bytes = cwd.readFileAlloc(io, code_path, alloc, .limited(glint.cart_format.MAX_CART_BYTES)) catch |err| {
        try w.print("glint pack: cannot read '{s}': {s}\n", .{ code_path, @errorName(err) });
        return err;
    };
    defer alloc.free(code_bytes);

    // Translate manifest capability declarations into the cart-binary flag
    // bits the engine reads at load time. Only required-mode caps imply a
    // non-skippable runtime dependency; optional caps are recorded in the
    // meta blob and resolved at run time against host policy.
    var flags: u32 = 0;
    for (m.capabilities) |c| {
        if (c.mode != .required) continue;
        switch (c.name) {
            .ai => flags |= glint.cart_format.Header.FLAG_NEEDS_LLM,
            .net => flags |= glint.cart_format.Header.FLAG_NEEDS_NET,
            else => {},
        }
    }

    // Deterministic cart_id: xxh3-64 of (manifest text || code text). Two
    // identical source dirs produce identical IDs across hosts; mutating
    // either source byte changes the ID. Embedded in low 64 bits, leaving
    // upper 64 for future namespace bits (publisher, signing).
    var hasher = std.hash.XxHash3.init(0);
    hasher.update(manifest_text);
    hasher.update(code_bytes);
    const cart_id_lo: u64 = hasher.final();

    const header: glint.cart_format.Header = .{
        .cart_id = @as(u128, cart_id_lo),
        .author = padFixed(m.author),
        .title = padFixed(m.title),
        .flags = flags,
        .n_sections = 0, // overwritten by encode
    };
    const sections = [_]glint.cart_format.Section{
        .{ .type = .code, .data = code_bytes },
        .{ .type = .meta, .data = manifest_text },
    };
    const bin = glint.cart_format.encode(alloc, header, &sections) catch |err| {
        try w.print("glint pack: encode failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer alloc.free(bin);

    // Output sits next to the source files: <dir>/<title>.glint
    const out_name = try std.fmt.allocPrint(alloc, "{s}.glint", .{m.title});
    defer alloc.free(out_name);
    const out_path = try std.fs.path.join(alloc, &.{ dir_path, out_name });
    defer alloc.free(out_path);

    cwd.writeFile(io, .{ .sub_path = out_path, .data = bin }) catch |err| {
        try w.print("glint pack: cannot write '{s}': {s}\n", .{ out_path, @errorName(err) });
        return err;
    };

    try w.print(
        \\glint pack: {s}
        \\  cart_id:  0x{x}
        \\  title:    {s}
        \\  author:   {s}
        \\  flags:    0x{x}
        \\  caps:     {d}
        \\  bytes:    {d} (code {d}, meta {d})
        \\
    , .{
        out_path,
        header.cart_id,
        m.title,
        m.author,
        flags,
        m.capabilities.len,
        bin.len,
        code_bytes.len,
        manifest_text.len,
    });
}

fn cmdReplay(w: *Io.Writer, sub: []const []const u8) !void {
    _ = sub;
    try w.writeAll("glint replay: stub — determinism harness pending post-W10\n");
}

fn cmdDemo(w: *Io.Writer) !void {
    // Flush usage/banner before sokol takes over the console + main thread.
    try w.writeAll("glint demo: opening sokol window, Esc to quit\n");
    try w.flush();
    glint.runDemo();
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
