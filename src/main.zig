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
        try cmdNew(arena, io, stdout, argv[2..]);
    } else if (eql(cmd, "pack")) {
        try cmdPack(arena, io, stdout, argv[2..]);
    } else if (eql(cmd, "replay")) {
        try cmdReplay(arena, io, stdout, argv[2..]);
    } else if (eql(cmd, "demo")) {
        try cmdDemo(stdout);
    } else if (eql(cmd, "demo-cart")) {
        try cmdDemoCart(arena, io, stdout, argv[2..]);
    } else if (eql(cmd, "play")) {
        try cmdPlay(arena, io, stdout, argv[2..]);
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
        \\  glint replay <path.crash>  decode + pretty-print a crash artifact
        \\  glint demo                 open a 768x768 sokol palette-cycle window
        \\  glint play <cart>          open the cart in a real-time window (60Hz _draw)
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

    // Find code + manifest sections in one pass. Code is mandatory for
    // execution; the manifest text is preserved into any emitted .crash
    // artifact for postmortem context (schema_version, declared caps, ...).
    var code_section: ?[]const u8 = null;
    var manifest_section: []const u8 = "";
    for (cart.sections) |s| {
        switch (s.type) {
            .code => code_section = s.data,
            .meta => manifest_section = s.data,
            else => {},
        }
    }
    const code = code_section orelse {
        try w.writeAll("\n(no code section; nothing to execute)\n");
        return;
    };

    // Lua's loadString needs a 0-terminated buffer. The cart's code section
    // is a borrowed slice of `bytes`, so we duplicate-with-NUL into the
    // arena. ~1 KB extra; well below the 1024 KB cart heap budget.
    const code_z = alloc.dupeZ(u8, code) catch |err| {
        try w.print("glint run: out of memory copying code section: {s}\n", .{@errorName(err)});
        return err;
    };
    defer alloc.free(code_z);

    // Crash artifact path sits next to the cart with a .crash extension so
    // postmortem files don't collide with their source carts. Failure here
    // is OOM only; if the cart never errors the file is never written.
    const crash_path = defaultCrashPath(alloc, path) catch |err| {
        try w.print("glint run: out of memory deriving crash path: {s}\n", .{@errorName(err)});
        return err;
    };
    defer alloc.free(crash_path);

    const sink: CrashSink = .{
        .io = io,
        .cwd = cwd,
        .out_path = crash_path,
        .cart_id = cart.header.cart_id,
        .cart_blob = bytes,
        .manifest_toml = manifest_section,
        .glint_version = VERSION,
    };

    // Headless run: 60 frames at 60 Hz simulated. Builds enough state on
    // the framebuffer to compute a non-trivial hash; the hash doubles as a
    // determinism witness for the replay harness (W7+).
    try runCartHeadless(alloc, w, code_z, 60, sink);
}

fn cmdPlay(alloc: std.mem.Allocator, io: Io, w: *Io.Writer, sub: []const []const u8) !void {
    if (sub.len < 1) {
        try w.writeAll("glint play: missing cart path. usage: glint play <cart>\n");
        return error.MissingArgument;
    }
    const path = sub[0];

    const cwd = Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, path, alloc, .limited(glint.cart_format.MAX_CART_BYTES)) catch |err| {
        try w.print("glint play: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    // Don't free bytes: the decoded cart's section data borrows from this
    // buffer, and the borrowed code slice is what we hand to the VM. The
    // arena reclaims it at process exit, after sapp.run returns.

    const cart = glint.cart_format.decode(alloc, bytes) catch |err| {
        try w.print("glint play: decode failed: {s}\n", .{@errorName(err)});
        return err;
    };
    // Same lifetime story as bytes: keep cart alive for sapp.run.

    var code_slice: ?[]const u8 = null;
    for (cart.sections) |s| {
        if (s.type == .code) {
            code_slice = s.data;
            break;
        }
    }
    const code = code_slice orelse {
        try w.writeAll("glint play: cart has no code section; nothing to run\n");
        return error.NoCodeSection;
    };
    const code_z = try alloc.dupeZ(u8, code);
    // Same: don't free; the VM holds borrowed substrings of code_z.

    try w.print("glint play: opening window for '{s}' (Esc to quit)\n", .{path});
    try w.flush();
    glint.runCart(alloc, code_z);
}

/// Cart pipeline phase the engine was in when a Lua-side error landed.
/// Embedded in the `cause` and `log_tail` records of any emitted crash so
/// postmortems distinguish "syntax broke at load" from "runtime broke at
/// frame 47 inside _draw".
const Phase = enum { load, init, update, draw };

/// Context the run loop needs to write a postmortem `.crash` artifact.
/// Optional in `runCartHeadless` so unit tests can drive the loop without
/// touching the filesystem.
const CrashSink = struct {
    io: Io,
    cwd: Io.Dir,
    /// Where the artifact gets written. Caller owns the bytes.
    out_path: []const u8,
    /// Cart binary's identity (xxh3-64 lo, zeros hi for now).
    cart_id: u128,
    /// Original cart bytes, used to write the cart_blob_sha256 record.
    cart_blob: []const u8,
    /// Cart's manifest TOML text, copied into the artifact verbatim.
    /// Empty slice if the cart has no meta section (legacy / smoke-test
    /// artefacts).
    manifest_toml: []const u8,
    /// Engine version string written into the crash header's glint_ver
    /// field. Always `VERSION` in production; explicit so tests can override.
    glint_version: []const u8,
};

/// Crash artifacts are bounded by cart size + a few small TLV records, so
/// 1 MB is generous. Used by the replay reader to refuse pathological
/// inputs without scanning them.
const MAX_CRASH_BYTES: u64 = 1 << 20;

/// Derive `<cart_basename>.crash` from a cart path, stripping whatever
/// extension the cart has (.glint / .glint.png / etc.). When the path has
/// no extension, append `.crash` directly. Caller frees.
fn defaultCrashPath(alloc: std.mem.Allocator, cart_path: []const u8) ![]u8 {
    const ext = std.fs.path.extension(cart_path);
    if (ext.len > 0) {
        const base = cart_path[0 .. cart_path.len - ext.len];
        return std.fmt.allocPrint(alloc, "{s}.crash", .{base});
    }
    return std.fmt.allocPrint(alloc, "{s}.crash", .{cart_path});
}

/// Build + write a crash artifact for a cart-side failure. Best-effort:
/// any error inside this function is logged via `w` and otherwise
/// swallowed, so the original cart error is the one returned upstream.
fn emitCrash(
    alloc: std.mem.Allocator,
    w: *Io.Writer,
    fb: *glint.pixel.Framebuffer,
    sink: CrashSink,
    phase: Phase,
    frame: u32,
    err: anyerror,
    lua_msg: []const u8,
) void {
    var body = glint.crash.TlvWriter.init(alloc);
    defer body.deinit();

    var cart_id_bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &cart_id_bytes, sink.cart_id, .little);
    body.write(.cart_id, &cart_id_bytes) catch return;

    var sha: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(sink.cart_blob, &sha, .{});
    body.write(.cart_blob_sha256, &sha) catch return;

    if (sink.manifest_toml.len > 0) {
        body.write(.manifest_toml, sink.manifest_toml) catch return;
    }

    var fb_hash_bytes: [8]u8 = undefined;
    const fb_hash = glint.state_hash.hashBytes(&fb.pixels);
    std.mem.writeInt(u64, &fb_hash_bytes, fb_hash, .little);
    body.write(.state_hash_trace, &fb_hash_bytes) catch return;

    const cause_text = std.fmt.allocPrint(
        alloc,
        "{s}: {s}: {s}",
        .{ @tagName(phase), @errorName(err), lua_msg },
    ) catch return;
    defer alloc.free(cause_text);
    body.write(.cause, cause_text) catch return;

    const log_text = std.fmt.allocPrint(
        alloc,
        "phase={s} frame={d} err={s}",
        .{ @tagName(phase), frame, @errorName(err) },
    ) catch return;
    defer alloc.free(log_text);
    body.write(.log_tail, log_text) catch return;

    const body_bytes = body.finalize() catch return;
    defer alloc.free(body_bytes);

    const artifact = glint.crash.encode(alloc, sink.glint_version, body_bytes) catch return;
    defer alloc.free(artifact);

    sink.cwd.writeFile(sink.io, .{ .sub_path = sink.out_path, .data = artifact }) catch |e| {
        w.print("  (crash artifact write failed: {s})\n", .{@errorName(e)}) catch {};
        return;
    };

    w.print("  crash artifact: {s} ({d} B)\n", .{ sink.out_path, artifact.len }) catch {};
}

/// Execute a cart's Lua code in a fresh VM with the full cart-author API
/// surface registered, then call `_init` once and `_update / _draw` for
/// `frames` iterations. Prints the resulting framebuffer hash so two runs
/// of the same cart on the same engine version produce identical output.
///
/// On failure inside any cart entry point, if `crash_sink` is non-null an
/// artifact is written to `crash_sink.out_path` capturing cart identity,
/// the failure cause, and the framebuffer hash at the moment of failure.
fn runCartHeadless(
    alloc: std.mem.Allocator,
    w: *Io.Writer,
    code: [:0]const u8,
    frames: u32,
    crash_sink: ?CrashSink,
) !void {
    // Heap-allocate the framebuffer (16 KB) so the stack stays cool.
    const fb = alloc.create(glint.pixel.Framebuffer) catch |err| {
        try w.print("glint run: out of memory allocating framebuffer: {s}\n", .{@errorName(err)});
        return err;
    };
    defer alloc.destroy(fb);
    fb.clear(0);

    // Headless run has no real input source; use a zero State so btn /
    // btnp always return false. RNG seeds from a fixed constant so the
    // determinism contract (same cart -> same hash) holds across hosts.
    var inp: glint.input.State = .{};
    var ctx: glint.cart_ctx.CartContext = .{
        .fb = fb,
        .inp = &inp,
        .rng = glint.rng.Xorshift32.init(1),
    };
    var vm = glint.lua_vm.VM.init(alloc) catch |err| {
        try w.print("glint run: VM init failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer vm.deinit();
    ctx.registerApi(&vm);

    // Top-level cart code defines _init / _update / _draw as globals.
    vm.exec(code) catch |err| {
        try w.print("\nglint run: cart load failed: {s}\n  Lua: {s}\n", .{ @errorName(err), vm.lastError() });
        if (crash_sink) |s| emitCrash(alloc, w, fb, s, .load, 0, err, vm.lastError());
        return err;
    };

    // Each entry-point call is wrapped in `if FN then FN() end` so carts
    // can omit any of the three (e.g. a static demo with only _draw).
    vm.exec("if _init then _init() end") catch |err| {
        try w.print("\nglint run: _init failed: {s}\n  Lua: {s}\n", .{ @errorName(err), vm.lastError() });
        if (crash_sink) |s| emitCrash(alloc, w, fb, s, .init, 0, err, vm.lastError());
        return err;
    };

    var i: u32 = 0;
    while (i < frames) : (i += 1) {
        vm.exec("if _update then _update() end") catch |err| {
            try w.print(
                "\nglint run: _update failed at frame {d}: {s}\n  Lua: {s}\n",
                .{ i, @errorName(err), vm.lastError() },
            );
            if (crash_sink) |s| emitCrash(alloc, w, fb, s, .update, i, err, vm.lastError());
            return err;
        };
        vm.exec("if _draw then _draw() end") catch |err| {
            try w.print(
                "\nglint run: _draw failed at frame {d}: {s}\n  Lua: {s}\n",
                .{ i, @errorName(err), vm.lastError() },
            );
            if (crash_sink) |s| emitCrash(alloc, w, fb, s, .draw, i, err, vm.lastError());
            return err;
        };
    }

    // Hash the entire framebuffer pixel array. Same cart + same frame
    // count must produce the same hash on every supported target — this
    // is the determinism contract the replay harness checks against.
    const fb_hash = glint.state_hash.hashBytes(&fb.pixels);
    try w.print("\nglint run: ran {d} frames; framebuffer hash 0x{x:0>16}\n", .{ frames, fb_hash });
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

fn cmdNew(alloc: std.mem.Allocator, io: Io, w: *Io.Writer, sub: []const []const u8) !void {
    if (sub.len < 1) {
        try w.writeAll("glint new: missing project name. usage: glint new <name>\n");
        return error.MissingArgument;
    }
    const name = sub[0];
    if (!isValidCartName(name)) {
        try w.print(
            "glint new: '{s}' is not a valid cart name " ++
                "(1..16 ASCII chars, alphanumeric/-/_, must start with alphanumeric)\n",
            .{name},
        );
        return error.InvalidCartName;
    }

    const cwd = Io.Dir.cwd();
    cwd.createDir(io, name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try w.print("glint new: '{s}/' already exists; refusing to overwrite\n", .{name});
            return err;
        },
        else => {
            try w.print("glint new: cannot create '{s}/': {s}\n", .{ name, @errorName(err) });
            return err;
        },
    };

    // Manifest template uses the sandbox-friendly defaults from
    // cart/manifest.zig, with the [caps] / [limits] sections commented in
    // so cart authors can opt in by uncommenting rather than guessing
    // syntax.
    const manifest_text = try std.fmt.allocPrint(alloc,
        \\# glint cart manifest — see doc/dx-reliability-spec.md §A.4 for the schema
        \\
        \\[glint]
        \\schema_version = 1
        \\title = "{s}"
        \\author = "you"
        \\min_engine = "{s}"
        \\
        \\# Uncomment to declare host capabilities:
        \\#[caps]
        \\#ai = "optional"      # talk to a local LLM via NPC API
        \\#save = "optional"    # persistent cart-local key/value store
        \\#net = "optional"     # outbound HTTP (cart marketplace, etc.)
        \\
        \\# Uncomment to override soft limits (defaults shown):
        \\#[limits]
        \\#heap_kb = 1024
        \\#ai_tokens_per_sec = 60
        \\
    , .{ name, VERSION });
    defer alloc.free(manifest_text);

    // Lua skeleton mirrors the three engine entry points the runtime
    // calls every cart on. cls(0) renders ink-black so the first run is
    // visibly "alive" rather than an empty window.
    const code_text =
        \\-- glint cart entry points
        \\-- _init runs once on load; _update at 60Hz; _draw every frame
        \\
        \\function _init()
        \\  t = 0
        \\end
        \\
        \\function _update()
        \\  t = t + 1
        \\end
        \\
        \\function _draw()
        \\  cls(0)
        \\  pset(64, 64, 11) -- single sparkbright pixel center-screen
        \\end
        \\
    ;

    const manifest_path = try std.fs.path.join(alloc, &.{ name, "manifest.toml" });
    defer alloc.free(manifest_path);
    const code_path = try std.fs.path.join(alloc, &.{ name, "code.lua" });
    defer alloc.free(code_path);

    cwd.writeFile(io, .{ .sub_path = manifest_path, .data = manifest_text }) catch |err| {
        try w.print("glint new: cannot write '{s}': {s}\n", .{ manifest_path, @errorName(err) });
        return err;
    };
    cwd.writeFile(io, .{ .sub_path = code_path, .data = code_text }) catch |err| {
        try w.print("glint new: cannot write '{s}': {s}\n", .{ code_path, @errorName(err) });
        return err;
    };

    try w.print(
        \\glint new: scaffolded '{s}/'
        \\  manifest.toml ({d} B)
        \\  code.lua ({d} B)
        \\
        \\next:
        \\  glint pack {s}
        \\  glint run {s}/{s}.glint
        \\
    , .{ name, manifest_text.len, code_text.len, name, name, name });
}

/// Cart name = directory name + cart title. Both must round-trip through
/// the cart binary's 16-byte ASCII title field, so the same constraint
/// applies: 1..16 chars from {A-Z, a-z, 0-9, '-', '_'}, leading char must
/// be alphanumeric (so the name doesn't look like a CLI flag).
fn isValidCartName(s: []const u8) bool {
    if (s.len == 0 or s.len > glint.manifest.TITLE_MAX) return false;
    if (!std.ascii.isAlphanumeric(s[0])) return false;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') continue;
        return false;
    }
    return true;
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

fn cmdReplay(alloc: std.mem.Allocator, io: Io, w: *Io.Writer, sub: []const []const u8) !void {
    if (sub.len < 1) {
        try w.writeAll("glint replay: missing artifact path. usage: glint replay <path.crash>\n");
        return error.MissingArgument;
    }
    const path = sub[0];

    const cwd = Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, path, alloc, .limited(MAX_CRASH_BYTES)) catch |err| {
        try w.print("glint replay: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer alloc.free(bytes);

    const decoded = glint.crash.decode(bytes) catch |err| {
        try w.print("glint replay: invalid crash artifact: {s}\n", .{@errorName(err)});
        return err;
    };

    try w.print(
        \\glint crash artifact: {s}
        \\  format_ver:  {d}
        \\  glint_ver:   {s}
        \\  flags:       0x{x:0>4}
        \\  body_len:    {d} B
        \\  body_crc32:  0x{x:0>8}
        \\  records:
        \\
    , .{
        path,
        decoded.header.format_ver,
        trimAscii(&decoded.header.glint_ver),
        decoded.header.flags,
        decoded.header.body_len,
        decoded.header.body_crc32,
    });

    var r = glint.crash.TlvReader.init(decoded.body);
    var idx: usize = 0;
    while (try r.next()) |rec| : (idx += 1) {
        try printTlvRecord(w, idx, rec);
    }
}

/// Pretty-print one TLV record. Header line for every tag; the payload
/// preview is shaped to the tag's known semantics (hex for IDs, quoted
/// text for human-readable causes, bar-prefixed lines for the manifest).
fn printTlvRecord(w: *Io.Writer, idx: usize, rec: glint.crash.TlvReader.Record) !void {
    try w.print("    [{d}] {s} (tag=0x{x:0>4}, {d} B)\n", .{
        idx, tlvTagName(rec.tag), @intFromEnum(rec.tag), rec.payload.len,
    });
    switch (rec.tag) {
        .cart_id => if (rec.payload.len == 16) {
            const cid = std.mem.readInt(u128, rec.payload[0..16], .little);
            try w.print("        0x{x:0>32}\n", .{cid});
        },
        .cart_blob_sha256 => {
            try w.writeAll("        ");
            for (rec.payload) |b| try w.print("{x:0>2}", .{b});
            try w.writeByte('\n');
        },
        .state_hash_trace => if (rec.payload.len == 8) {
            const h = std.mem.readInt(u64, rec.payload[0..8], .little);
            try w.print("        0x{x:0>16}\n", .{h});
        },
        .cause, .log_tail, .cart_version => {
            const cap: usize = 200;
            const slice = rec.payload[0..@min(rec.payload.len, cap)];
            try w.print("        \"{s}\"{s}\n", .{ slice, if (rec.payload.len > cap) "..." else "" });
        },
        .manifest_toml => {
            // Cap at six lines × 80 chars: enough to identify the cart at
            // a glance without flooding the postmortem report.
            var lines: usize = 0;
            var it = std.mem.splitScalar(u8, rec.payload, '\n');
            while (it.next()) |raw_line| : (lines += 1) {
                if (lines >= 6) {
                    try w.writeAll("        ...\n");
                    break;
                }
                const slice = raw_line[0..@min(raw_line.len, 80)];
                try w.print("        | {s}\n", .{slice});
            }
        },
        else => {},
    }
}

/// Map a `crash.Tag` to its dx-spec name. Open-enum unknown values get
/// a placeholder so future engine versions don't break replay's output.
fn tlvTagName(t: glint.crash.Tag) []const u8 {
    return switch (t) {
        .cart_id => "cart_id",
        .cart_version => "cart_version",
        .cart_blob_sha256 => "cart_blob_sha256",
        .manifest_toml => "manifest_toml",
        .caps_granted => "caps_granted",
        .input_stream => "input_stream",
        .state_snapshot => "state_snapshot",
        .state_hash_trace => "state_hash_trace",
        .log_tail => "log_tail",
        .ai_inbox_snapshot => "ai_inbox_snapshot",
        .ai_model_info => "ai_model_info",
        .net_session_id => "net_session_id",
        .net_input_history => "net_input_history",
        .cause => "cause",
        _ => "(unknown)",
    };
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

test "defaultCrashPath strips a known cart extension" {
    const out = try defaultCrashPath(std.testing.allocator, "samples/demo/demo.glint");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("samples/demo/demo.crash", out);
}

test "defaultCrashPath without extension appends .crash" {
    const out = try defaultCrashPath(std.testing.allocator, "demo");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("demo.crash", out);
}

test "defaultCrashPath strips just the trailing extension" {
    // .glint.png is two extensions; we strip the last one (.png) so a
    // PNG-stego cart's crash sits next to it as `<base>.glint.crash`.
    const out = try defaultCrashPath(std.testing.allocator, "carts/abc.glint.png");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("carts/abc.glint.crash", out);
}
