//! engine/window.zig — sokol-backed demo window for early development.
//!
//! Opens a 768x768 native window, clears to black each frame, exits on Esc.
//! This is the scratchpad mode invoked via `glint demo`. Once cart loading
//! lands (W6, see doc/roadmap.md), this code is replaced by a real
//! framebuffer + cart event pump driven from src/runtime/.
//!
//! WHY 768x768: 128 * 6 = 768. The integer-scaled debug window matches the
//! eventual fantasy-console resolution (128x128) at 6x for readability without
//! introducing fractional scaling that would betray the pixel grid.

const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const slog = sokol.log;

// Module-level state held in a struct's `var` block so that the C-callback
// `export fn`s below can reach it without a Zig closure (sokol's C runtime
// invokes plain function pointers, no userdata channel for this demo).
const state = struct {
    var pass_action: sg.PassAction = .{};
};

export fn demoInit() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
    };
}

export fn demoFrame() void {
    sg.beginPass(.{
        .action = state.pass_action,
        .swapchain = sglue.swapchain(),
    });
    sg.endPass();
    sg.commit();
}

export fn demoCleanup() void {
    sg.shutdown();
}

export fn demoEvent(ev: ?*const sapp.Event) void {
    // Esc closes the window. Future: route to engine.input.dispatch().
    if (ev) |e| {
        if (e.type == .KEY_DOWN and e.key_code == .ESCAPE) {
            sapp.requestQuit();
        }
    }
}

/// Open a black 768x768 window. Blocks until the user closes it (Esc or
/// the window's close button). Safe to call from any thread that holds
/// the OS main thread on macOS / Windows.
pub fn runDemo() void {
    sapp.run(.{
        .init_cb = demoInit,
        .frame_cb = demoFrame,
        .cleanup_cb = demoCleanup,
        .event_cb = demoEvent,
        .width = 768,
        .height = 768,
        .icon = .{ .sokol_default = true },
        .window_title = "glint v0.0.1 — demo (Esc to quit)",
        .logger = .{ .func = slog.func },
        .win32 = .{ .console_attach = true },
    });
}
