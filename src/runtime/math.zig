//! Cart-author math helpers (mid / lerp / saturate / approachTo).
//!
//! Pico-8 / Lua-conventional names; deterministic by definition since
//! they are pure arithmetic on inputs.
//!
//! Trig + sqrt live in `runtime/fixed.zig` (LUT-backed for cross-platform
//! determinism); rng lives in `runtime/rng.zig`. This file is the small
//! everyday helpers the cart uses every frame.

const std = @import("std");

/// Pico-8-style "median of three" — equivalent to clamp but more
/// recognisable to fantasy-console authors. mid(0, x, 100) clamps x to
/// [0, 100] regardless of order of the bounds in the call.
pub fn mid(a: f64, b: f64, c: f64) f64 {
    // Sort 3 values; return the middle.
    const lo = @min(a, @min(b, c));
    const hi = @max(a, @max(b, c));
    return a + b + c - lo - hi;
}

/// Linear interpolation: returns a + (b - a) * t. Clamped: when t=0
/// returns a, t=1 returns b. Caller is responsible for sane t; pass
/// saturate(t) to enforce [0, 1].
pub fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * t;
}

/// Saturate to [0, 1].
pub fn saturate(v: f64) f64 {
    return @max(0.0, @min(1.0, v));
}

/// Move `current` toward `target` by at most `step`. Returns the new
/// position. Useful for camera follow / value smoothing without jitter
/// at the destination.
pub fn approachTo(current: f64, target: f64, step: f64) f64 {
    if (current < target) return @min(target, current + step);
    if (current > target) return @max(target, current - step);
    return target;
}

/// True/false sign as -1/0/+1 (i32). Zero returns 0.
pub fn signI(v: f64) i32 {
    if (v > 0) return 1;
    if (v < 0) return -1;
    return 0;
}

/// Smoothstep: cubic Hermite interpolation. Useful for fading + easing.
/// Returns 0 below `edge0`, 1 above `edge1`, smooth curve in between.
pub fn smoothstep(edge0: f64, edge1: f64, x: f64) f64 {
    const t = saturate((x - edge0) / (edge1 - edge0));
    return t * t * (3.0 - 2.0 * t);
}

// ---------- tests ----------

const testing = std.testing;

test "mid acts as clamp" {
    try testing.expectEqual(@as(f64, 50.0), mid(0.0, 50.0, 100.0));
    try testing.expectEqual(@as(f64, 100.0), mid(0.0, 200.0, 100.0));
    try testing.expectEqual(@as(f64, 0.0), mid(0.0, -50.0, 100.0));
    // Argument order doesn't matter:
    try testing.expectEqual(@as(f64, 50.0), mid(50.0, 100.0, 0.0));
    try testing.expectEqual(@as(f64, 50.0), mid(100.0, 50.0, 0.0));
}

test "lerp endpoints and midpoint" {
    try testing.expectEqual(@as(f64, 10.0), lerp(10.0, 20.0, 0.0));
    try testing.expectEqual(@as(f64, 20.0), lerp(10.0, 20.0, 1.0));
    try testing.expectEqual(@as(f64, 15.0), lerp(10.0, 20.0, 0.5));
}

test "lerp extrapolates past endpoints when t out of range" {
    try testing.expectEqual(@as(f64, 30.0), lerp(10.0, 20.0, 2.0));
    try testing.expectEqual(@as(f64, 0.0), lerp(10.0, 20.0, -1.0));
}

test "saturate clamps to [0, 1]" {
    try testing.expectEqual(@as(f64, 0.0), saturate(-1.0));
    try testing.expectEqual(@as(f64, 0.0), saturate(0.0));
    try testing.expectEqual(@as(f64, 0.5), saturate(0.5));
    try testing.expectEqual(@as(f64, 1.0), saturate(1.0));
    try testing.expectEqual(@as(f64, 1.0), saturate(2.0));
}

test "approachTo moves toward target without overshoot" {
    try testing.expectEqual(@as(f64, 5.0), approachTo(0.0, 10.0, 5.0));
    try testing.expectEqual(@as(f64, 10.0), approachTo(0.0, 10.0, 100.0));
    try testing.expectEqual(@as(f64, 8.0), approachTo(10.0, 5.0, 2.0));
    try testing.expectEqual(@as(f64, 5.0), approachTo(10.0, 5.0, 100.0));
}

test "approachTo at target stays" {
    try testing.expectEqual(@as(f64, 5.0), approachTo(5.0, 5.0, 1.0));
}

test "signI three-way sign" {
    try testing.expectEqual(@as(i32, 1), signI(5.0));
    try testing.expectEqual(@as(i32, -1), signI(-5.0));
    try testing.expectEqual(@as(i32, 0), signI(0.0));
}

test "smoothstep at boundaries" {
    try testing.expectEqual(@as(f64, 0.0), smoothstep(0.0, 1.0, -1.0));
    try testing.expectEqual(@as(f64, 0.0), smoothstep(0.0, 1.0, 0.0));
    try testing.expectEqual(@as(f64, 1.0), smoothstep(0.0, 1.0, 1.0));
    try testing.expectEqual(@as(f64, 1.0), smoothstep(0.0, 1.0, 5.0));
    // midpoint should be 0.5 exactly
    try testing.expectApproxEqAbs(@as(f64, 0.5), smoothstep(0.0, 1.0, 0.5), 1e-12);
}
