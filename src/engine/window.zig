//! engine/window.zig — sokol-backed demo window.
//!
//! Opens a 768x768 native window (128*6 = pixel-perfect 6x integer scale).
//! Each frame, the engine writes a procedural test pattern into a 128x128
//! indexed framebuffer (`runtime.pixel.Framebuffer`), translates it through
//! the project palette into RGBA8, uploads to a GPU texture, and draws a
//! single fullscreen textured quad with NEAREST sampling — the entire pixel
//! path the cart runtime will use, minus the cart's Lua `_draw` callback.
//!
//! WHY sokol_gl: immediate-mode 2D removes the need for a hand-rolled
//! shader pipeline at this stage. Once the shader-LUT path lands (W6) the
//! quad becomes a custom pipeline that does palette decoding on the GPU.
//!
//! WHY 128x128 RGBA upload (instead of R8 indexed + GPU LUT): RGBA upload
//! is 64 KB/frame at 60 Hz = 3.84 MB/s — trivially within 16ms budget on
//! every target the spec cares about. The CPU palette pass is also where
//! the dev panel's "screen-debug" overlays (palette swap, dither) will hook
//! in cheaply during W6.
//!
//! Inputs in this demo:
//!   - Arrows (cart d-pad) : move the highlight sprite
//!   - Z (cart 'a')        : toggle pause
//!   - X (cart 'b')        : cycle test-pattern variant
//!   - Esc                 : quit

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sgl = sokol.gl;
const sapp = sokol.app;
const sglue = sokol.glue;
const slog = sokol.log;

const pixel = @import("../runtime/pixel.zig");
const input = @import("../runtime/input.zig");
const lua_vm = @import("../lua/vm.zig");
const cart_ctx_mod = @import("../lua/cart_ctx.zig");

const FB_W: u16 = pixel.Framebuffer.WIDTH;
const FB_H: u16 = pixel.Framebuffer.HEIGHT;
const FB_PIXELS: u32 = pixel.Framebuffer.PIXELS;

/// Window content selector. `runDemo()` opens in `.demo` mode (procedural
/// palette+sprite test pattern); `runCart()` opens in `.cart` mode and
/// drives the framebuffer from the cart's Lua _draw callback.
const Mode = enum { demo, cart };

/// Module-level state in a struct's `var` block. The C-callbacks below have
/// no userdata channel, so this is the canonical "globals for the demo"
/// home. Once the engine kernel is real (W6), this state moves into a
/// proper Engine struct with explicit pass-through.
const state = struct {
    var mode: Mode = .demo;
    var pass_action: sg.PassAction = .{};
    var inp: input.State = .{};

    /// Indexed framebuffer the demo draws into every frame.
    var fb: pixel.Framebuffer = .{ .pixels = [_]u8{0} ** FB_PIXELS };
    /// CPU-side scratch buffer holding the palette-translated RGBA bytes
    /// uploaded to `fb_image` at the top of every frame. 64 KB.
    var rgba: [FB_PIXELS * 4]u8 = [_]u8{0} ** (FB_PIXELS * 4);

    var fb_image: sg.Image = .{};
    var fb_view: sg.View = .{};
    var fb_sampler: sg.Sampler = .{};

    var frame_counter: u64 = 0;
    var paused: bool = false;
    /// Test-pattern selector, cycled by X press (cart 'b').
    var pattern: u8 = 0;
    /// Highlight sprite world-position (in framebuffer pixels), moved by arrows.
    var sprite_x: i32 = 60;
    var sprite_y: i32 = 60;

    // ---- cart mode bits (unused in demo mode) ----
    /// Cart's Lua source bytes. Owned by main.zig's arena across runCart()'s
    /// blocking sapp.run lifetime. NUL-terminated so loadString accepts it.
    var cart_code: [:0]const u8 = "";
    /// Allocator passed by the embedder; used to build the VM and (later)
    /// any per-cart engine state. Required to outlive sapp.run().
    var cart_alloc: std.mem.Allocator = undefined;
    /// VM driving the cart's _init / _update / _draw. Initialized in
    /// demoInit when mode == .cart, deinitialized in demoCleanup.
    var cart_vm: ?lua_vm.VM = null;
    /// Engine state pointer the cart-author API bindings reach for via
    /// Lua closure upvalues. Lives in static storage; safe forever.
    var cart_runtime: cart_ctx_mod.CartContext = undefined;
};

export fn demoInit() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    sgl.setup(.{
        .logger = .{ .func = slog.func },
    });

    // Indexed-pixel framebuffer is uploaded as RGBA8 every frame. Mark
    // it stream_update so the GPU driver knows we'll be respecifying
    // contents on every Update call (lets it pick a fast upload path).
    state.fb_image = sg.makeImage(.{
        .width = FB_W,
        .height = FB_H,
        .pixel_format = .RGBA8,
        .usage = .{ .stream_update = true },
    });
    state.fb_view = sg.makeView(.{
        .texture = .{ .image = state.fb_image },
    });
    // Sharp pixels: nearest-neighbour everywhere. This is what makes the
    // 6x integer upscale read as crisp pixel art instead of mush.
    state.fb_sampler = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });

    // Black backdrop behind the textured quad. Anything outside the quad
    // (which is none of the visible area at integer scale, but the GPU
    // doesn't know that) shows ink black.
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = palToClearColor(0),
    };

    if (state.mode == .cart) {
        // Boot the cart: spin up a sandboxed VM, register the cart-author
        // API surface bound to our framebuffer, run the top-level cart
        // source (defines _init/_update/_draw as globals), then call _init
        // exactly once. Errors fall through to a stderr log + clear
        // framebuffer so the user sees a recoverable failure rather than
        // a closed window.
        const vm = lua_vm.VM.init(state.cart_alloc) catch |err| {
            std.debug.print("glint: VM init failed: {s}\n", .{@errorName(err)});
            return;
        };
        state.cart_vm = vm;
        state.cart_runtime = .{ .fb = &state.fb };
        state.cart_runtime.registerApi(&state.cart_vm.?);
        state.cart_vm.?.exec(state.cart_code) catch |err| {
            std.debug.print("glint: cart load failed: {s}\n", .{@errorName(err)});
        };
        state.cart_vm.?.exec("if _init then _init() end") catch |err| {
            std.debug.print("glint: cart _init failed: {s}\n", .{@errorName(err)});
        };
    }
}

export fn demoFrame() void {
    input.beginFrame(&state.inp);

    if (!state.paused) state.frame_counter +%= 1;

    switch (state.mode) {
        .demo => demoFramePopulateFb(),
        .cart => cartFramePopulateFb(),
    }

    // Translate indexed pixels to RGBA8 via palette lookup.
    fbToRgba(&state.fb, &state.rgba);

    // Upload the freshly written RGBA8 pixels to the GPU texture.
    var img_data: sg.ImageData = .{};
    img_data.mip_levels[0] = sg.asRange(state.rgba[0..]);
    sg.updateImage(state.fb_image, img_data);

    // ---- record textured fullscreen quad in sokol_gl ----
    sgl.defaults();
    sgl.matrixModeProjection();
    sgl.loadIdentity();
    sgl.matrixModeModelview();
    sgl.loadIdentity();
    sgl.enableTexture();
    sgl.texture(state.fb_view, state.fb_sampler);
    sgl.beginQuads();
    // NDC fullscreen, with UVs flipped on Y so framebuffer pixel (0,0)
    // shows at the top of the window (matches indexed-image convention).
    sgl.v2fT2f(-1.0, 1.0, 0.0, 0.0);
    sgl.v2fT2f(1.0, 1.0, 1.0, 0.0);
    sgl.v2fT2f(1.0, -1.0, 1.0, 1.0);
    sgl.v2fT2f(-1.0, -1.0, 0.0, 1.0);
    sgl.end();

    // ---- render the recorded commands inside the swapchain pass ----
    sg.beginPass(.{
        .action = state.pass_action,
        .swapchain = sglue.swapchain(),
    });
    sgl.draw();
    sg.endPass();
    sg.commit();
}

export fn demoCleanup() void {
    if (state.mode == .cart) {
        if (state.cart_vm) |*vm| vm.deinit();
        state.cart_vm = null;
    }
    sg.destroySampler(state.fb_sampler);
    sg.destroyView(state.fb_view);
    sg.destroyImage(state.fb_image);
    sgl.shutdown();
    sg.shutdown();
}

/// Demo-mode per-frame: read input, animate the procedural test pattern.
/// (Pre-cart-runtime placeholder; will retire once the engine kernel
/// formalizes a "scene" concept that subsumes both demo and cart paths.)
fn demoFramePopulateFb() void {
    if (state.inp.wasPressed(.a)) state.paused = !state.paused;
    if (state.inp.wasPressed(.b)) state.pattern +%= 1;
    if (state.inp.isHeld(.left)) state.sprite_x -= 2;
    if (state.inp.isHeld(.right)) state.sprite_x += 2;
    if (state.inp.isHeld(.up)) state.sprite_y -= 2;
    if (state.inp.isHeld(.down)) state.sprite_y += 2;
    state.sprite_x = std.math.clamp(state.sprite_x, 0, @as(i32, FB_W) - 8);
    state.sprite_y = std.math.clamp(state.sprite_y, 0, @as(i32, FB_H) - 8);

    drawTestPattern(&state.fb, state.pattern, state.frame_counter);
    drawHighlightSprite(&state.fb, state.sprite_x, state.sprite_y);
}

/// Cart-mode per-frame: drive _update + _draw on the cart's VM. Lua
/// errors during a frame print to stderr but do not bring the window
/// down — the framebuffer reflects whatever the cart wrote up to the
/// failure point, and the user can iterate.
fn cartFramePopulateFb() void {
    if (state.cart_vm == null) return;
    var vm = &state.cart_vm.?;
    vm.exec("if _update then _update() end") catch |err| {
        std.debug.print("glint: _update failed: {s}\n", .{@errorName(err)});
    };
    vm.exec("if _draw then _draw() end") catch |err| {
        std.debug.print("glint: _draw failed: {s}\n", .{@errorName(err)});
    };
}

export fn demoEvent(ev: ?*const sapp.Event) void {
    const e = ev orelse return;
    switch (e.type) {
        .KEY_DOWN => {
            if (e.key_code == .ESCAPE) {
                sapp.requestQuit();
                return;
            }
            input.updateOnKeyDown(&state.inp, e.key_code);
        },
        .KEY_UP => input.updateOnKeyUp(&state.inp, e.key_code),
        else => {},
    }
}

/// Translate the project palette index into a sokol-gfx clear color.
fn palToClearColor(idx: u4) sg.Color {
    const rgba = pixel.palette[idx];
    return .{
        .r = @as(f32, @floatFromInt(rgba[0])) / 255.0,
        .g = @as(f32, @floatFromInt(rgba[1])) / 255.0,
        .b = @as(f32, @floatFromInt(rgba[2])) / 255.0,
        .a = 1.0,
    };
}

/// Expand the indexed framebuffer to RGBA8 via palette lookup. Hot path —
/// runs every frame at 60 Hz on 16384 pixels. Tight loop, no branches.
fn fbToRgba(fb: *const pixel.Framebuffer, dst: *[FB_PIXELS * 4]u8) void {
    var i: u32 = 0;
    while (i < FB_PIXELS) : (i += 1) {
        const idx: u4 = @truncate(fb.pixels[i]);
        const rgba = pixel.palette[idx];
        const o = i * 4;
        dst[o + 0] = rgba[0];
        dst[o + 1] = rgba[1];
        dst[o + 2] = rgba[2];
        dst[o + 3] = rgba[3];
    }
}

/// Procedural test pattern. Three variants cycled by X (cart 'b'):
///   0 — palette swatch bands, 8-pixel wide each, with a sweep beam
///   1 — diagonal gradient across the full palette
///   2 — concentric rings, color-shifted over time
fn drawTestPattern(fb: *pixel.Framebuffer, variant: u8, t: u64) void {
    fb.clear(15); // bruise backdrop, lets c11 sparkbright pop
    switch (variant % 3) {
        0 => {
            // 16 vertical bands × 8 px wide = 128 px wide exactly.
            var y: u16 = 0;
            while (y < FB_H) : (y += 1) {
                var x: u16 = 0;
                while (x < FB_W) : (x += 1) {
                    const band: u4 = @truncate(x / 8);
                    fb.set(x, y, band);
                }
            }
            // Vertical sweep beam: paper-white horizontal line moving down.
            const beam_y: u16 = @intCast(t % FB_H);
            var bx: u16 = 0;
            while (bx < FB_W) : (bx += 1) fb.set(bx, beam_y, 5);
        },
        1 => {
            // Diagonal ramp: palette index = (x + y) / 16 mod 16
            var y: u16 = 0;
            while (y < FB_H) : (y += 1) {
                var x: u16 = 0;
                while (x < FB_W) : (x += 1) {
                    const c: u4 = @truncate((x + y + (t / 2)) / 16);
                    fb.set(x, y, c);
                }
            }
        },
        else => {
            // Concentric rings centered on the framebuffer.
            const cx: i32 = FB_W / 2;
            const cy: i32 = FB_H / 2;
            const phase: i32 = @intCast(t % 16);
            var y: i32 = 0;
            while (y < FB_H) : (y += 1) {
                var x: i32 = 0;
                while (x < FB_W) : (x += 1) {
                    const dx = x - cx;
                    const dy = y - cy;
                    const d2 = dx * dx + dy * dy;
                    // sqrt is fine here: not on the determinism-critical path.
                    const r: i32 = @intFromFloat(@sqrt(@as(f32, @floatFromInt(d2))));
                    const c: u4 = @truncate(@as(u32, @intCast(@mod(r + phase, 16))));
                    fb.set(@intCast(x), @intCast(y), c);
                }
            }
        },
    }
}

/// 8x8 highlight sprite drawn at (x, y). Sparkbright fill with a paper-white
/// border. Visible against every palette band so users can see input working.
fn drawHighlightSprite(fb: *pixel.Framebuffer, x: i32, y: i32) void {
    const w: i32 = 8;
    const h: i32 = 8;
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) {
            const px = x + dx;
            const py = y + dy;
            if (px < 0 or py < 0 or px >= FB_W or py >= FB_H) continue;
            const is_border = (dx == 0 or dy == 0 or dx == w - 1 or dy == h - 1);
            const color: u4 = if (is_border) 5 else 11; // paper-white edge, sparkbright fill
            fb.set(@intCast(px), @intCast(py), color);
        }
    }
}

/// Open a 768x768 window in demo mode (palette test pattern). Blocks
/// until the user closes it. Safe to call from the OS main thread on
/// Windows / macOS / Linux.
pub fn runDemo() void {
    state.mode = .demo;
    sapp.run(.{
        .init_cb = demoInit,
        .frame_cb = demoFrame,
        .cleanup_cb = demoCleanup,
        .event_cb = demoEvent,
        .width = 768,
        .height = 768,
        .icon = .{ .sokol_default = true },
        .window_title = "glint v0.0.1 — demo (arrows: move, Z: pause, X: pattern, Esc: quit)",
        .logger = .{ .func = slog.func },
        .win32 = .{ .console_attach = true },
    });
}

/// Open a 768x768 window in cart mode and run the cart's _draw at 60 Hz
/// for as long as the user keeps the window open. `code` must outlive
/// this call (alive for the duration of sapp.run). Esc closes the window.
pub fn runCart(alloc: std.mem.Allocator, code: [:0]const u8) void {
    state.mode = .cart;
    state.cart_alloc = alloc;
    state.cart_code = code;
    sapp.run(.{
        .init_cb = demoInit,
        .frame_cb = demoFrame,
        .cleanup_cb = demoCleanup,
        .event_cb = demoEvent,
        .width = 768,
        .height = 768,
        .icon = .{ .sokol_default = true },
        .window_title = "glint v0.0.1 — cart (Esc: quit)",
        .logger = .{ .func = slog.func },
        .win32 = .{ .console_attach = true },
    });
}
