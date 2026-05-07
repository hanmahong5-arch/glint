//! 128x128 framebuffer + 16-color palette.
//!
//! The palette is custom — explicitly NOT pico-8 — and is the project's
//! visual identity. Hex values mirror those locked in
//! `doc/lighthouse-cart-gym-beef.md` §1 (cart manifest [palette] block) so
//! that the lighthouse cart and the engine share one truth.
//!
//! Design intent (per cart-1 spec):
//!   - c00-c05 : 6-step neutral ramp (deep slate -> paper white) for UI
//!   - c06,c07 : warm parchment / leather, for player-side highlights, signage
//!   - c08,c09 : damage / HP-critical signaling
//!   - c10-c14 : five element accents (fire / electric / grass / water / psychic)
//!   - c15     : bruise background, cooler than black so c11 sparkbright pops

const std = @import("std");

/// One palette entry as straight RGBA (no premultiplied alpha).
pub const RGBA = [4]u8;

/// The 16-color palette. Index ranges 0..=15. Alpha is always 0xFF.
pub const palette: [16]RGBA = .{
    .{ 0x0E, 0x0E, 0x12, 0xFF }, // 0  ink black
    .{ 0x1F, 0x22, 0x33, 0xFF }, // 1  deep slate
    .{ 0x3A, 0x44, 0x66, 0xFF }, // 2  muted indigo
    .{ 0x68, 0x78, 0xA6, 0xFF }, // 3  cool steel
    .{ 0xA0, 0xB0, 0xCC, 0xFF }, // 4  pale slate
    .{ 0xE6, 0xEC, 0xF2, 0xFF }, // 5  paper white
    .{ 0xE0, 0xC9, 0x7F, 0xFF }, // 6  parchment
    .{ 0xA4, 0x70, 0x32, 0xFF }, // 7  leather brown
    .{ 0x5A, 0x28, 0x28, 0xFF }, // 8  blood maroon
    .{ 0xC0, 0x40, 0x40, 0xFF }, // 9  signal red
    .{ 0xE6, 0x8A, 0x3A, 0xFF }, // 10 ember orange
    .{ 0xF4, 0xD0, 0x3F, 0xFF }, // 11 sparkbright
    .{ 0x5B, 0xB0, 0x4F, 0xFF }, // 12 leaf green
    .{ 0x39, 0x78, 0xC0, 0xFF }, // 13 water blue
    .{ 0x7C, 0x4F, 0xB5, 0xFF }, // 14 arcane violet
    .{ 0x2A, 0x1F, 0x36, 0xFF }, // 15 bruise
};

/// 128x128 indexed framebuffer. Each cell is a 4-bit palette index, stored
/// as u8 with the high nibble unused — saves the cost of u4 packing while
/// staying inside the same logical 16-color discipline. Memory cost: 16 KB.
pub const Framebuffer = struct {
    pub const WIDTH: u16 = 128;
    pub const HEIGHT: u16 = 128;
    pub const PIXELS: u32 = @as(u32, WIDTH) * @as(u32, HEIGHT);

    pixels: [PIXELS]u8,

    /// Fill the framebuffer with a single palette color.
    pub fn clear(self: *Framebuffer, color: u4) void {
        @memset(&self.pixels, @as(u8, color));
    }

    /// Set a single pixel. Out-of-bounds writes are silently dropped per
    /// the dx-reliability-spec error policy ("silent-clamp"). Cart authors
    /// can rely on `pset` never crashing the engine.
    pub fn set(self: *Framebuffer, x: u16, y: u16, color: u4) void {
        if (x >= WIDTH or y >= HEIGHT) return;
        self.pixels[@as(u32, y) * WIDTH + x] = @as(u8, color);
    }

    /// Read a single pixel. Out-of-bounds reads return 0 (paranoid default).
    pub fn get(self: *const Framebuffer, x: u16, y: u16) u4 {
        if (x >= WIDTH or y >= HEIGHT) return 0;
        return @truncate(self.pixels[@as(u32, y) * WIDTH + x]);
    }
};

test "palette has 16 entries with full alpha" {
    try std.testing.expectEqual(@as(usize, 16), palette.len);
    for (palette) |rgba| {
        try std.testing.expectEqual(@as(u8, 0xFF), rgba[3]);
    }
}

test "framebuffer clear writes uniform color across all pixels" {
    var fb: Framebuffer = undefined;
    fb.clear(7);
    try std.testing.expectEqual(@as(u4, 7), fb.get(0, 0));
    try std.testing.expectEqual(@as(u4, 7), fb.get(127, 127));
    try std.testing.expectEqual(@as(u4, 7), fb.get(64, 64));
}

test "framebuffer set/get roundtrips at arbitrary coords" {
    var fb: Framebuffer = undefined;
    fb.clear(0);
    fb.set(10, 20, 11);
    try std.testing.expectEqual(@as(u4, 11), fb.get(10, 20));
    try std.testing.expectEqual(@as(u4, 0), fb.get(11, 20));
}

test "framebuffer set silent-clamps out-of-bounds writes" {
    var fb: Framebuffer = undefined;
    fb.clear(0);
    fb.set(128, 0, 7);
    fb.set(0, 128, 7);
    fb.set(9999, 9999, 15);
    // engine must not crash; in-bounds pixels remain untouched
    try std.testing.expectEqual(@as(u4, 0), fb.get(0, 0));
    try std.testing.expectEqual(@as(u4, 0), fb.get(127, 127));
}
