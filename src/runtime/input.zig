//! Cart-author input abstraction (8 logical buttons + edge detection).
//!
//! Per dx-reliability-spec §A.2 inp.* surface, the cart sees 8 logical
//! buttons mapped onto OS-level events. This module is the engine-side
//! adapter: sokol_app key events come in via updateOnKeyDown/Up, the cart
//! reads via isHeld/wasPressed.
//!
//! W2 wires only the keyboard path. Gamepad / joystick / touch arrive at
//! W4+ once the lighthouse cart needs them.

const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;

/// Eight-button arcade-style logical layout. The cart sees these names.
pub const Button = enum(u3) {
    left = 0,
    right = 1,
    up = 2,
    down = 3,
    a = 4, // primary action (Z by default)
    b = 5, // secondary action (X by default)
    x = 6, // tertiary (C)
    y = 7, // quaternary (V)
};

/// Bitfield over the Button enum. Bit i = button i held / pressed-this-frame.
pub const ButtonMask = u8;

/// Per-frame edge-aware button state. The engine drives held via key events,
/// then calls beginFrame() once per frame to compute the edge-triggered
/// pressed mask.
pub const State = struct {
    held: ButtonMask = 0,
    pressed: ButtonMask = 0,
    prev_held: ButtonMask = 0,

    pub fn isHeld(self: State, b: Button) bool {
        return (self.held & maskOf(b)) != 0;
    }

    pub fn wasPressed(self: State, b: Button) bool {
        return (self.pressed & maskOf(b)) != 0;
    }
};

/// Default Pico-8-ish keyboard layout: arrows + Z/X/C/V. Returns null when
/// the key is not bound to any logical button (cart code never sees it).
pub fn keyToButton(k: sapp.Keycode) ?Button {
    return switch (k) {
        .LEFT => .left,
        .RIGHT => .right,
        .UP => .up,
        .DOWN => .down,
        .Z => .a,
        .X => .b,
        .C => .x,
        .V => .y,
        else => null,
    };
}

/// Mark a logical button as held. Idempotent.
pub fn updateOnKeyDown(s: *State, k: sapp.Keycode) void {
    if (keyToButton(k)) |b| {
        s.held |= maskOf(b);
    }
}

/// Mark a logical button as released. Idempotent.
pub fn updateOnKeyUp(s: *State, k: sapp.Keycode) void {
    if (keyToButton(k)) |b| {
        s.held &= ~maskOf(b);
    }
}

/// Call once per frame BEFORE the cart `_update` runs. Computes
/// `pressed = held & ~prev_held` so that single-frame edge events are
/// observable via wasPressed().
pub fn beginFrame(s: *State) void {
    s.pressed = s.held & ~s.prev_held;
    s.prev_held = s.held;
}

inline fn maskOf(b: Button) ButtonMask {
    return @as(ButtonMask, 1) << @intFromEnum(b);
}

test "isHeld and wasPressed read the bitfield" {
    var s: State = .{};
    s.held = maskOf(.left) | maskOf(.right);
    try std.testing.expect(s.isHeld(.left));
    try std.testing.expect(s.isHeld(.right));
    try std.testing.expect(!s.isHeld(.up));
}

test "edge detection fires only on press transition" {
    var s: State = .{};
    updateOnKeyDown(&s, .Z);
    beginFrame(&s);
    try std.testing.expect(s.wasPressed(.a)); // first frame Z is down

    beginFrame(&s);
    try std.testing.expect(!s.wasPressed(.a)); // sticky-held -> no new press
    try std.testing.expect(s.isHeld(.a));

    updateOnKeyUp(&s, .Z);
    beginFrame(&s);
    try std.testing.expect(!s.isHeld(.a));
    try std.testing.expect(!s.wasPressed(.a));
}

test "unbound keys are no-ops" {
    var s: State = .{};
    updateOnKeyDown(&s, .ENTER);
    updateOnKeyDown(&s, .SPACE);
    updateOnKeyDown(&s, .ESCAPE);
    try std.testing.expectEqual(@as(ButtonMask, 0), s.held);
}
