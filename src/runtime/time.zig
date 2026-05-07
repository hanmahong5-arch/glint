//! Fixed-step accumulator for 60Hz logic + variable render rate.
//!
//! The cart's `_update` runs at exactly 60Hz; rendering can run as fast as
//! the display allows. Without an accumulator, faster machines would tick
//! `_update` more often than 60Hz (breaking determinism) or slower machines
//! would tick less often (breaking deterministic replays).
//!
//! Glenn Fiedler's classic "Fix Your Timestep!" algorithm:
//!     accumulator += real_dt
//!     while accumulator >= dt: _update(); accumulator -= dt
//!     _draw(alpha = accumulator / dt)
//!
//! Where `dt` is the fixed logic step (1/60 s = 16.67 ms).
//!
//! This module provides only the accumulator state machine — the `step`
//! method returns how many fixed `_update` calls the caller should issue,
//! plus an `alpha` for interpolation in `_draw`. Wall-clock measurement
//! (std.time.Timer) is the caller's responsibility so the engine can also
//! measure time deterministically inside the replay harness (where wall
//! clock is replaced by the input stream's frame counter).

const std = @import("std");

/// Logic step in nanoseconds. 1/60 s exactly.
pub const FIXED_STEP_NS: u64 = 16_666_667;

/// Maximum number of catch-up `_update` calls per render frame. Caps the
/// "spiral of death" when the machine cannot keep up — better to drop
/// frames than to keep falling further behind. Per dx-spec §B.7 logic
/// frames are sacred, but at some point we must concede.
pub const MAX_CATCHUP_STEPS: u32 = 5;

/// Fixed-step accumulator. Initialize with `.init()`, call `tick(real_dt)`
/// each render frame and run `_update` exactly the returned number of
/// times.
pub const Accumulator = struct {
    accumulator_ns: u64 = 0,

    pub fn init() Accumulator {
        return .{};
    }

    /// Advance the accumulator by `real_dt_ns` and report (steps_to_run,
    /// interpolation_alpha). Steps is clamped to MAX_CATCHUP_STEPS to
    /// prevent spiral-of-death. Alpha is 0.0..1.0 for `_draw` interp.
    pub fn tick(self: *Accumulator, real_dt_ns: u64) struct { steps: u32, alpha: f32 } {
        self.accumulator_ns +|= real_dt_ns;

        var steps: u32 = 0;
        while (self.accumulator_ns >= FIXED_STEP_NS and steps < MAX_CATCHUP_STEPS) {
            self.accumulator_ns -= FIXED_STEP_NS;
            steps += 1;
        }

        // If we hit the cap, drop the residual to stop accumulating debt.
        if (steps == MAX_CATCHUP_STEPS) {
            self.accumulator_ns = 0;
        }

        const alpha: f32 = @as(f32, @floatFromInt(self.accumulator_ns)) /
            @as(f32, @floatFromInt(FIXED_STEP_NS));
        return .{ .steps = steps, .alpha = alpha };
    }

    /// Reset to zero. Used at scene transitions and on cart load to avoid
    /// processing leftover time.
    pub fn reset(self: *Accumulator) void {
        self.accumulator_ns = 0;
    }
};

test "60Hz tick produces exactly one step at exact dt" {
    var a = Accumulator.init();
    const out = a.tick(FIXED_STEP_NS);
    try std.testing.expectEqual(@as(u32, 1), out.steps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out.alpha, 0.001);
}

test "two-thirds dt accumulates without stepping" {
    var a = Accumulator.init();
    const out = a.tick(FIXED_STEP_NS * 2 / 3);
    try std.testing.expectEqual(@as(u32, 0), out.steps);
    try std.testing.expect(out.alpha > 0.6);
    try std.testing.expect(out.alpha < 0.7);
}

test "catch-up runs multiple steps when behind" {
    var a = Accumulator.init();
    const out = a.tick(FIXED_STEP_NS * 3);
    try std.testing.expectEqual(@as(u32, 3), out.steps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out.alpha, 0.01);
}

test "spiral-of-death cap clamps to MAX_CATCHUP_STEPS and drops residual" {
    var a = Accumulator.init();
    const out = a.tick(FIXED_STEP_NS * 100); // pretend the OS froze us
    try std.testing.expectEqual(MAX_CATCHUP_STEPS, out.steps);
    try std.testing.expectEqual(@as(u64, 0), a.accumulator_ns);
}

test "leftover accumulates across ticks" {
    var a = Accumulator.init();
    const half = FIXED_STEP_NS / 2;

    var out = a.tick(half);
    try std.testing.expectEqual(@as(u32, 0), out.steps);

    out = a.tick(half + 100); // should now cross the boundary
    try std.testing.expectEqual(@as(u32, 1), out.steps);
}

test "reset clears accumulator" {
    var a = Accumulator.init();
    _ = a.tick(FIXED_STEP_NS / 2);
    try std.testing.expect(a.accumulator_ns > 0);
    a.reset();
    try std.testing.expectEqual(@as(u64, 0), a.accumulator_ns);
}
