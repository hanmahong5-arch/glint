//! engine/window.zig — sokol-backed demo window for early development.
//!
//! Opens a 768x768 native window. Each frame the clear color cycles through
//! the project's 16-color palette so a viewer can see the engine breathing.
//! Holding the keyboard arrow keys (mapped via runtime.input to up/down)
//! adjusts the cycle speed; Esc exits. Z/X/C/V (a/b/x/y in the cart layout)
//! pause / freeze the cycle so a screenshot can be taken.
//!
//! WHY 768x768: 128 * 6 = 768. Integer scale of the eventual fantasy-console
//! resolution (128x128) at 6x for readability without fractional artifacts.
//!
//! W6+ replaces this scratchpad with a real framebuffer + palette LUT shader
//! pipeline driven from src/runtime/pixel.Framebuffer; for now the clear
//! color animation is enough to verify the loop, the input plumbing, and
//! that our 16 palette entries actually look the way the spec described.

const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const slog = sokol.log;

const pixel = @import("../runtime/pixel.zig");
const input = @import("../runtime/input.zig");

// Module-level state held in a struct's `var` block so the C-callback `export
// fn`s below can reach it without a closure (sokol's C runtime invokes plain
// function pointers; no userdata channel for this demo).
const state = struct {
    var pass_action: sg.PassAction = .{};
    var inp: input.State = .{};
    var frame_counter: u64 = 0;
    /// Frames per palette step. Lower = faster cycle. Up arrow speeds up,
    /// down arrow slows down. Hard-clamped to [4, 240] to avoid degenerate
    /// or seizure-inducing rates.
    var frames_per_step: u32 = 30; // ~0.5s per color at 60Hz
    /// When true, freeze the cycle at the current step (Z to toggle).
    var paused: bool = false;
    /// Override-color when paused; chosen by Z press, then cleared on Z release.
    var paused_step: u4 = 0;
};

export fn demoInit() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    setClearColor(0); // start on c00 ink black
}

export fn demoFrame() void {
    input.beginFrame(&state.inp);

    // Adjust cycle speed via vertical D-pad.
    if (state.inp.wasPressed(.up)) {
        state.frames_per_step = @max(4, state.frames_per_step -| 5);
    }
    if (state.inp.wasPressed(.down)) {
        state.frames_per_step = @min(240, state.frames_per_step + 5);
    }
    // Z toggles pause; pause snapshots the current step so it's visible.
    if (state.inp.wasPressed(.a)) {
        state.paused = !state.paused;
        if (state.paused) {
            state.paused_step = currentStep();
        }
    }

    if (!state.paused) {
        state.frame_counter +%= 1;
        setClearColor(currentStep());
    } else {
        setClearColor(state.paused_step);
    }

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

inline fn currentStep() u4 {
    const step = (state.frame_counter / state.frames_per_step) % @as(u64, pixel.palette.len);
    return @intCast(step);
}

fn setClearColor(idx: u4) void {
    const rgba = pixel.palette[idx];
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{
            .r = @as(f32, @floatFromInt(rgba[0])) / 255.0,
            .g = @as(f32, @floatFromInt(rgba[1])) / 255.0,
            .b = @as(f32, @floatFromInt(rgba[2])) / 255.0,
            .a = 1.0,
        },
    };
}

/// Open a 768x768 window that cycles through the project palette. Blocks
/// until the user closes it (Esc, window close button). Safe to call from
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
        .window_title = "glint v0.0.1 — demo (arrows: speed, Z: pause, Esc: quit)",
        .logger = .{ .func = slog.func },
        .win32 = .{ .console_attach = true },
    });
}
