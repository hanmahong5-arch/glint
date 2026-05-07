//! Rasterization primitives — line / rect / rectfill / circle / circfill.
//!
//! All routines take a `*pixel.Framebuffer`, integer coordinates (which
//! may be out of range), and a u4 palette index. Out-of-bounds pixels
//! are silently dropped per the dx-spec error policy. Algorithms use only
//! integer arithmetic + the LUT-backed `isqrt` from runtime/fixed.zig so
//! identical inputs produce identical pixels on every supported target.
//!
//! Why integer-only: rollback netcode replays cart frames verbatim. A
//! line that uses `std.math.sqrt(f32)` to choose pixels would drift one
//! pixel between hosts, the rollback would diverge, and the net session
//! would desync. Same constraint applies to circle's filled scan-lines.
//!
//! Algorithms:
//!   line     — Bresenham with explicit sign management (no overflow)
//!   rect     — four `line` calls (top / bottom / left / right)
//!   rectFill — scan-line loop with min/max swap-tolerance
//!   circle   — Bresenham midpoint circle (8-fold symmetry)
//!   circleFill — same outline traversal, each step paints horizontal spans

const std = @import("std");
const pixel = @import("pixel.zig");

const FB_W: i32 = pixel.Framebuffer.WIDTH;
const FB_H: i32 = pixel.Framebuffer.HEIGHT;

/// Set one framebuffer pixel, dropping silently if out of bounds. Hot
/// inner loop helper for every primitive in this file.
inline fn setPixel(fb: *pixel.Framebuffer, x: i32, y: i32, color: u4) void {
    if (x < 0 or y < 0) return;
    if (x >= FB_W or y >= FB_H) return;
    fb.set(@intCast(x), @intCast(y), color);
}

/// Inclusive horizontal scanline from (x0, y) to (x1, y). Used by the
/// fill primitives so they share one OOB-safe loop.
fn hline(fb: *pixel.Framebuffer, x0: i32, x1: i32, y: i32, color: u4) void {
    if (y < 0 or y >= FB_H) return;
    const lx = @max(0, @min(x0, x1));
    const rx = @min(FB_W - 1, @max(x0, x1));
    if (lx > rx) return;
    var x = lx;
    while (x <= rx) : (x += 1) {
        fb.set(@intCast(x), @intCast(y), color);
    }
}

/// Bresenham line from (x0, y0) to (x1, y1). Endpoints inclusive.
pub fn line(fb: *pixel.Framebuffer, x0_in: i32, y0_in: i32, x1: i32, y1: i32, color: u4) void {
    var x0 = x0_in;
    var y0 = y0_in;
    const dx: i32 = if (x1 > x0) x1 - x0 else x0 - x1;
    const dy: i32 = -(if (y1 > y0) y1 - y0 else y0 - y1);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err: i32 = dx + dy;
    // Cap iterations defensively. Diagonal of 128x128 = 256 px; allow a
    // generous 512 to absorb numerical fuzz, then bail. Cart authors that
    // pass huge coords get partial output rather than an infinite loop.
    var safety: u32 = 512;
    while (true) {
        setPixel(fb, x0, y0, color);
        if (x0 == x1 and y0 == y1) break;
        if (safety == 0) break;
        safety -= 1;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

/// Rectangle outline. Argument order matches Pico-8: top-left then
/// bottom-right; either ordering is tolerated thanks to line()'s
/// sign-aware bresenham.
pub fn rect(fb: *pixel.Framebuffer, x0: i32, y0: i32, x1: i32, y1: i32, color: u4) void {
    line(fb, x0, y0, x1, y0, color);
    line(fb, x0, y1, x1, y1, color);
    line(fb, x0, y0, x0, y1, color);
    line(fb, x1, y0, x1, y1, color);
}

/// Filled rectangle. Scanline-by-scanline.
pub fn rectFill(fb: *pixel.Framebuffer, x0: i32, y0: i32, x1: i32, y1: i32, color: u4) void {
    const ty = @min(y0, y1);
    const by = @max(y0, y1);
    var y = ty;
    while (y <= by) : (y += 1) {
        hline(fb, x0, x1, y, color);
    }
}

/// Circle outline via Bresenham midpoint. r < 0 is a no-op.
pub fn circle(fb: *pixel.Framebuffer, cx: i32, cy: i32, r: i32, color: u4) void {
    if (r < 0) return;
    if (r == 0) {
        setPixel(fb, cx, cy, color);
        return;
    }
    var x: i32 = r;
    var y: i32 = 0;
    var err: i32 = 0;
    while (x >= y) {
        // Eight-fold symmetry: each loop iteration emits 8 octant pixels.
        setPixel(fb, cx + x, cy + y, color);
        setPixel(fb, cx + y, cy + x, color);
        setPixel(fb, cx - y, cy + x, color);
        setPixel(fb, cx - x, cy + y, color);
        setPixel(fb, cx - x, cy - y, color);
        setPixel(fb, cx - y, cy - x, color);
        setPixel(fb, cx + y, cy - x, color);
        setPixel(fb, cx + x, cy - y, color);
        if (err <= 0) {
            y += 1;
            err += 2 * y + 1;
        }
        if (err > 0) {
            x -= 1;
            err -= 2 * x + 1;
        }
    }
}

/// Filled circle via Bresenham midpoint with horizontal-span fill at
/// each step. r < 0 is a no-op.
pub fn circleFill(fb: *pixel.Framebuffer, cx: i32, cy: i32, r: i32, color: u4) void {
    if (r < 0) return;
    if (r == 0) {
        setPixel(fb, cx, cy, color);
        return;
    }
    var x: i32 = r;
    var y: i32 = 0;
    var err: i32 = 0;
    while (x >= y) {
        hline(fb, cx - x, cx + x, cy + y, color);
        hline(fb, cx - x, cx + x, cy - y, color);
        hline(fb, cx - y, cx + y, cy + x, color);
        hline(fb, cx - y, cx + y, cy - x, color);
        if (err <= 0) {
            y += 1;
            err += 2 * y + 1;
        }
        if (err > 0) {
            x -= 1;
            err -= 2 * x + 1;
        }
    }
}

// ---------------- tests ----------------

const testing = std.testing;

fn fbZero() pixel.Framebuffer {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    return fb;
}

test "line endpoints both painted" {
    var fb = fbZero();
    line(&fb, 5, 10, 100, 70, 11);
    try testing.expectEqual(@as(u4, 11), fb.get(5, 10));
    try testing.expectEqual(@as(u4, 11), fb.get(100, 70));
}

test "line with x0 > x1 still renders" {
    var fb = fbZero();
    line(&fb, 100, 50, 5, 50, 7);
    try testing.expectEqual(@as(u4, 7), fb.get(5, 50));
    try testing.expectEqual(@as(u4, 7), fb.get(100, 50));
    try testing.expectEqual(@as(u4, 7), fb.get(50, 50)); // any midpoint hit
}

test "horizontal line covers every column" {
    var fb = fbZero();
    line(&fb, 0, 64, 127, 64, 9);
    var x: u16 = 0;
    while (x < 128) : (x += 1) {
        try testing.expectEqual(@as(u4, 9), fb.get(x, 64));
    }
}

test "vertical line covers every row" {
    var fb = fbZero();
    line(&fb, 64, 0, 64, 127, 12);
    var y: u16 = 0;
    while (y < 128) : (y += 1) {
        try testing.expectEqual(@as(u4, 12), fb.get(64, y));
    }
}

test "line out-of-bounds is silently dropped" {
    var fb = fbZero();
    line(&fb, -50, -50, 200, 200, 11);
    // In-bounds part should still be drawn; nothing written outside.
    try testing.expectEqual(@as(u4, 11), fb.get(0, 0));
    try testing.expectEqual(@as(u4, 11), fb.get(127, 127));
}

test "rect outline writes corners not interior" {
    var fb = fbZero();
    rect(&fb, 10, 10, 20, 20, 13);
    try testing.expectEqual(@as(u4, 13), fb.get(10, 10));
    try testing.expectEqual(@as(u4, 13), fb.get(20, 10));
    try testing.expectEqual(@as(u4, 13), fb.get(10, 20));
    try testing.expectEqual(@as(u4, 13), fb.get(20, 20));
    try testing.expectEqual(@as(u4, 0), fb.get(15, 15)); // interior unchanged
}

test "rectFill writes interior" {
    var fb = fbZero();
    rectFill(&fb, 10, 10, 20, 20, 13);
    try testing.expectEqual(@as(u4, 13), fb.get(15, 15));
    try testing.expectEqual(@as(u4, 13), fb.get(10, 10));
    try testing.expectEqual(@as(u4, 13), fb.get(20, 20));
    try testing.expectEqual(@as(u4, 0), fb.get(9, 15));
    try testing.expectEqual(@as(u4, 0), fb.get(21, 15));
}

test "rectFill tolerates inverted args" {
    var fb = fbZero();
    rectFill(&fb, 20, 20, 10, 10, 7);
    try testing.expectEqual(@as(u4, 7), fb.get(15, 15));
    try testing.expectEqual(@as(u4, 7), fb.get(10, 10));
    try testing.expectEqual(@as(u4, 7), fb.get(20, 20));
}

test "circle of radius 1 draws the cardinal pixels" {
    var fb = fbZero();
    circle(&fb, 64, 64, 1, 11);
    try testing.expectEqual(@as(u4, 11), fb.get(65, 64));
    try testing.expectEqual(@as(u4, 11), fb.get(63, 64));
    try testing.expectEqual(@as(u4, 11), fb.get(64, 65));
    try testing.expectEqual(@as(u4, 11), fb.get(64, 63));
    try testing.expectEqual(@as(u4, 0), fb.get(64, 64)); // center untouched on outline
}

test "circle radius 0 paints just center" {
    var fb = fbZero();
    circle(&fb, 64, 64, 0, 11);
    try testing.expectEqual(@as(u4, 11), fb.get(64, 64));
    try testing.expectEqual(@as(u4, 0), fb.get(65, 64));
}

test "circleFill radius 1 paints a small plus" {
    var fb = fbZero();
    circleFill(&fb, 64, 64, 1, 11);
    try testing.expectEqual(@as(u4, 11), fb.get(64, 64));
    try testing.expectEqual(@as(u4, 11), fb.get(65, 64));
    try testing.expectEqual(@as(u4, 11), fb.get(63, 64));
    try testing.expectEqual(@as(u4, 11), fb.get(64, 65));
    try testing.expectEqual(@as(u4, 11), fb.get(64, 63));
}

test "circleFill radius 5 has filled center" {
    var fb = fbZero();
    circleFill(&fb, 64, 64, 5, 11);
    try testing.expectEqual(@as(u4, 11), fb.get(64, 64));
    try testing.expectEqual(@as(u4, 11), fb.get(64, 60));
    try testing.expectEqual(@as(u4, 11), fb.get(60, 64));
    try testing.expectEqual(@as(u4, 11), fb.get(68, 64));
    try testing.expectEqual(@as(u4, 11), fb.get(64, 68));
    // Outside radius 5 — should not be painted.
    try testing.expectEqual(@as(u4, 0), fb.get(70, 64));
    try testing.expectEqual(@as(u4, 0), fb.get(64, 70));
}

test "negative radius is a no-op" {
    var fb = fbZero();
    circle(&fb, 64, 64, -3, 11);
    circleFill(&fb, 64, 64, -3, 11);
    var i: u32 = 0;
    while (i < pixel.Framebuffer.PIXELS) : (i += 1) {
        try testing.expectEqual(@as(u8, 0), fb.pixels[i]);
    }
}
