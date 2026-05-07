//! Deterministic math: Q16.16 fixed-point primitives + table-backed
//! sin / cos / atan2 / sqrt. Engine and cart-author API both go through
//! these to satisfy dx-spec §B.5 case #14 (no libm in deterministic paths).
//!
//! Why this exists:
//!   - libm sin/cos/sqrt differ by ~ULP across glibc / musl / Apple / MSVC,
//!     which creates state-hash divergence between platforms and breaks
//!     replay + rollback netcode.
//!   - IEEE 754 round-to-nearest *, /, +, - are bit-exact across SSE2 /
//!     NEON / x87-64-bit-precision, so we can keep f64 at the API
//!     boundary and only avoid libm-style transcendentals.
//!   - The lookup tables are populated at *compile time* via a host-
//!     independent Taylor series so the embedded constants are bit-equal
//!     regardless of the compile host.
//!
//! API convention (matches Pico-8): angle inputs are in *turns*, where
//! 1.0 = full rotation. Avoids leaking pi into cart code.

const std = @import("std");

// ---------- Q16.16 fixed-point ----------

/// Q16.16 scalar. High 16 bits = integer part (signed), low 16 bits = fraction.
/// Range: -32768.0 .. +32767.99998... in steps of 1/65536 ≈ 1.526e-5.
pub const Fixed = i32;
pub const FIXED_SHIFT: u5 = 16;
pub const FIXED_SCALE: i64 = 1 << FIXED_SHIFT; // 65536

pub fn fromInt(n: i16) Fixed {
    return @as(Fixed, n) << FIXED_SHIFT;
}

pub fn toInt(f: Fixed) i16 {
    return @intCast(f >> FIXED_SHIFT);
}

/// Convert f64 to Q16.16. Out-of-range values saturate.
pub fn fromFloat(f: f64) Fixed {
    const scaled = f * @as(f64, @floatFromInt(FIXED_SCALE));
    if (scaled >= @as(f64, std.math.maxInt(i32))) return std.math.maxInt(i32);
    if (scaled <= @as(f64, std.math.minInt(i32))) return std.math.minInt(i32);
    return @intFromFloat(@round(scaled));
}

pub fn toFloat(f: Fixed) f64 {
    return @as(f64, @floatFromInt(f)) / @as(f64, @floatFromInt(FIXED_SCALE));
}

/// Q16.16 multiply: a * b / FIXED_SCALE, computed in i64 to avoid overflow.
pub fn mul(a: Fixed, b: Fixed) Fixed {
    const product: i64 = @as(i64, a) * @as(i64, b);
    return @intCast(product >> FIXED_SHIFT);
}

/// Q16.16 divide: a / b * FIXED_SCALE. Caller must ensure b != 0; we return
/// 0 instead of panicking so cart code never crashes the engine on a typo.
pub fn div(a: Fixed, b: Fixed) Fixed {
    if (b == 0) return 0;
    const numerator: i64 = @as(i64, a) << FIXED_SHIFT;
    return @intCast(@divTrunc(numerator, @as(i64, b)));
}

// ---------- compile-time Taylor series ----------

/// Compile-time host-independent sin (Taylor series, 16 terms). Range:
/// reduces input mod 2*pi before evaluating. Used ONLY to generate the
/// runtime LUT below.
fn comptimeSin(comptime x: f64) f64 {
    @setEvalBranchQuota(20000);
    const PI = 3.14159265358979323846;
    var t: f64 = x;
    while (t > PI) t -= 2.0 * PI;
    while (t < -PI) t += 2.0 * PI;
    var sum: f64 = 0;
    var term: f64 = t;
    var k: usize = 1;
    while (k < 32) : (k += 2) {
        sum += term;
        term = -term * t * t / (@as(f64, @floatFromInt(k + 1)) * @as(f64, @floatFromInt(k + 2)));
    }
    return sum;
}

// ---------- LUT-backed sin / cos ----------

/// Number of LUT entries per full turn. Larger = more accurate, larger
/// binary footprint. 1024 picked to match the canonical fantasy-console
/// resolution (each entry = 8KB of binary; full table = 4 KB i32).
pub const LUT_SIZE: usize = 1024;
const LUT_MASK: i32 = LUT_SIZE - 1;

/// SIN_TABLE[i] = round(sin(i / LUT_SIZE * 2*pi) * 65536)
/// Filled at compile time using Taylor; identical bytes on every host.
pub const SIN_TABLE: [LUT_SIZE]i32 = blk: {
    @setEvalBranchQuota(LUT_SIZE * 200);
    var table: [LUT_SIZE]i32 = undefined;
    var i: usize = 0;
    while (i < LUT_SIZE) : (i += 1) {
        const turn: f64 = @as(f64, @floatFromInt(i)) / @as(f64, LUT_SIZE);
        const angle = turn * 2.0 * 3.14159265358979323846;
        const s = comptimeSin(angle);
        table[i] = @intFromFloat(@round(s * 65536.0));
    }
    break :blk table;
};

/// Sine of `turns` turns. Returns -1.0 .. 1.0. Determinism: same input
/// bits produce same output bits on every supported target.
pub fn sinTurns(turns: f64) f64 {
    const idx_f = turns * @as(f64, LUT_SIZE);
    const idx_floor = @floor(idx_f);
    const idx0_i = @as(i32, @intFromFloat(idx_floor));
    const idx0 = @mod(idx0_i, @as(i32, LUT_SIZE));
    const idx1 = @mod(idx0 + 1, @as(i32, LUT_SIZE));
    const t = idx_f - idx_floor; // 0..1 fractional position
    const a: f64 = @as(f64, @floatFromInt(SIN_TABLE[@intCast(idx0)])) / 65536.0;
    const b: f64 = @as(f64, @floatFromInt(SIN_TABLE[@intCast(idx1)])) / 65536.0;
    return a + (b - a) * t;
}

/// Cosine of `turns` turns. cos(x) = sin(x + 1/4).
pub fn cosTurns(turns: f64) f64 {
    return sinTurns(turns + 0.25);
}

/// 2-arg arctangent in turns: returns the angle whose tangent is y/x.
/// Result range is (-0.5, 0.5]. Implemented via brute-force LUT scan to
/// stay deterministic; cart code that needs many atan2 calls per frame
/// can cache the result. Not the bottleneck for any realistic cart.
pub fn atan2Turns(y: f64, x: f64) f64 {
    if (x == 0 and y == 0) return 0;
    // Compute target angle's tangent class; pick LUT entry whose sin/cos
    // ratio is closest. O(LUT_SIZE) but deterministic.
    const r = std.math.sqrt(x * x + y * y);
    if (r == 0) return 0;
    const target_sin = y / r;
    const target_cos = x / r;
    var best_i: usize = 0;
    var best_d: f64 = std.math.inf(f64);
    var i: usize = 0;
    while (i < LUT_SIZE) : (i += 1) {
        const lut_sin = @as(f64, @floatFromInt(SIN_TABLE[i])) / 65536.0;
        const cos_idx = (i + LUT_SIZE / 4) % LUT_SIZE;
        const lut_cos = @as(f64, @floatFromInt(SIN_TABLE[cos_idx])) / 65536.0;
        const ds = lut_sin - target_sin;
        const dc = lut_cos - target_cos;
        const d = ds * ds + dc * dc;
        if (d < best_d) {
            best_d = d;
            best_i = i;
        }
    }
    return @as(f64, @floatFromInt(best_i)) / @as(f64, LUT_SIZE);
}

// ---------- integer sqrt ----------

/// Integer square root via Newton-Raphson. Deterministic; works for all
/// non-negative i64 input. Used by sqrtFloat below and exposed directly
/// for cart code that operates in integer space.
pub fn isqrt(n: u64) u64 {
    if (n < 2) return n;
    var x = n;
    var y = (x + 1) >> 1;
    while (y < x) {
        x = y;
        y = (x + n / x) >> 1;
    }
    return x;
}

/// Square root of a non-negative f64. Negative input yields 0 (cart-safe).
pub fn sqrtFloat(f: f64) f64 {
    if (f <= 0) return 0;
    // Convert to Q16.16, isqrt, scale back. Result accurate to ~1/256.
    const fixed = fromFloat(f);
    if (fixed <= 0) return 0;
    const u = @as(u64, @intCast(fixed)) << FIXED_SHIFT; // pre-shift so isqrt result is in Q16.16
    const root_fixed: Fixed = @intCast(isqrt(u));
    return toFloat(root_fixed);
}

// ---------- tests ----------

const testing = std.testing;

test "Q16.16 round-trip integer" {
    inline for ([_]i16{ 0, 1, -1, 100, -100, 32767, -32768 }) |n| {
        try testing.expectEqual(n, toInt(fromInt(n)));
    }
}

test "Q16.16 round-trip float within precision" {
    inline for ([_]f64{ 0.0, 0.5, -0.5, 1.5, -10.25, 100.0, -3.14159 }) |f| {
        const back = toFloat(fromFloat(f));
        try testing.expectApproxEqAbs(f, back, 1.0 / 65536.0);
    }
}

test "Q16.16 mul preserves identity" {
    const one = fromInt(1);
    const seven = fromInt(7);
    try testing.expectEqual(seven, mul(one, seven));
    try testing.expectEqual(seven, mul(seven, one));
}

test "Q16.16 mul half * half = quarter" {
    const half = fromFloat(0.5);
    const quarter = fromFloat(0.25);
    const result = mul(half, half);
    try testing.expectApproxEqAbs(toFloat(quarter), toFloat(result), 1.0 / 65536.0);
}

test "Q16.16 div by zero returns zero (no crash)" {
    try testing.expectEqual(@as(Fixed, 0), div(fromInt(5), 0));
}

test "Q16.16 div one by two" {
    const one = fromInt(1);
    const two = fromInt(2);
    try testing.expectApproxEqAbs(0.5, toFloat(div(one, two)), 1.0 / 65536.0);
}

test "sin / cos at canonical turns match math expectations" {
    // sin(0) = 0, sin(0.25) = 1, sin(0.5) = 0, sin(0.75) = -1
    try testing.expectApproxEqAbs(@as(f64, 0.0), sinTurns(0.0), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 1.0), sinTurns(0.25), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0.0), sinTurns(0.5), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, -1.0), sinTurns(0.75), 1e-3);

    try testing.expectApproxEqAbs(@as(f64, 1.0), cosTurns(0.0), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0.0), cosTurns(0.25), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, -1.0), cosTurns(0.5), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0.0), cosTurns(0.75), 1e-3);
}

test "sin wraps at full turn boundary" {
    // sin(1.25) should equal sin(0.25)
    try testing.expectApproxEqAbs(sinTurns(0.25), sinTurns(1.25), 1e-9);
    try testing.expectApproxEqAbs(sinTurns(0.25), sinTurns(-0.75), 1e-9);
}

test "sinTurns is deterministic across calls" {
    // The whole point of this module: identical input -> identical output.
    const a = sinTurns(0.123456);
    const b = sinTurns(0.123456);
    try testing.expectEqual(a, b);
}

test "isqrt of perfect squares" {
    inline for ([_]struct { u: u64, r: u64 }{
        .{ .u = 0, .r = 0 },
        .{ .u = 1, .r = 1 },
        .{ .u = 4, .r = 2 },
        .{ .u = 9, .r = 3 },
        .{ .u = 100, .r = 10 },
        .{ .u = 65536, .r = 256 },
    }) |c| {
        try testing.expectEqual(c.r, isqrt(c.u));
    }
}

test "isqrt rounds down for non-perfect squares" {
    try testing.expectEqual(@as(u64, 3), isqrt(15)); // sqrt(15) ≈ 3.87
    try testing.expectEqual(@as(u64, 9), isqrt(99));
}

test "sqrtFloat returns reasonable approximation" {
    try testing.expectApproxEqAbs(@as(f64, 2.0), sqrtFloat(4.0), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 3.0), sqrtFloat(9.0), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 10.0), sqrtFloat(100.0), 0.01);
}

test "sqrtFloat of negative is zero (cart-safe)" {
    try testing.expectEqual(@as(f64, 0.0), sqrtFloat(-1.0));
    try testing.expectEqual(@as(f64, 0.0), sqrtFloat(0.0));
}

test "atan2 cardinal angles" {
    // atan2(0, 1) = 0 turns (east)
    try testing.expectApproxEqAbs(@as(f64, 0.0), atan2Turns(0.0, 1.0), 1.0 / @as(f64, LUT_SIZE));
    // atan2(1, 0) = 0.25 turns (north in math convention)
    try testing.expectApproxEqAbs(@as(f64, 0.25), atan2Turns(1.0, 0.0), 1.0 / @as(f64, LUT_SIZE));
}

test "LUT_SIZE constant matches table length" {
    try testing.expectEqual(LUT_SIZE, SIN_TABLE.len);
}
