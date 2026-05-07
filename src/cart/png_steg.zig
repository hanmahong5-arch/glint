//! PNG-steganography codec for the cart payload.
//!
//! A glint cart on disk is a 160x205 RGBA PNG. The cart's binary content
//! lives in the low 2 bits of each RGBA channel, giving 8 bits of payload
//! per pixel and a total capacity of 160 * 205 = 32800 bytes. The carrier
//! image's high 6 bits per channel are preserved so the PNG remains a
//! viewable image (and looks like cover art the cart author chose).
//!
//! Per-pixel layout:
//!   payload_byte = (A & 3) << 6
//!                | (R & 3) << 4
//!                | (G & 3) << 2
//!                | (B & 3)
//!
//! This module operates on raw RGBA buffers; the surrounding PNG IO
//! (deflate / chunk parsing / signature validation) is the responsibility
//! of `cart/png_io.zig` (W6 deliverable; will use lodepng via cImport).
//!
//! Reference: pico-8 wiki P8PNGFileFormat. The bit packing scheme matches
//! the de-facto fantasy-console steganography convention (so cart authors
//! migrating from pico-8 / TIC-80 don't have to re-learn). Project
//! differentiation lives at the layer above (cart magic bytes, section
//! headers, manifest TOML schema), not at the steganographic layer.

const std = @import("std");

/// Cart carrier dimensions. Fixed by spec — the encoder rejects any other.
pub const WIDTH: u32 = 160;
pub const HEIGHT: u32 = 205;
pub const PIXEL_COUNT: u32 = WIDTH * HEIGHT; // 32800
/// Total payload capacity in bytes (one byte per pixel).
pub const CAPACITY_BYTES: u32 = PIXEL_COUNT;
/// Total RGBA buffer length expected by encodeBuffer / decodeBuffer.
pub const RGBA_BUFFER_SIZE: u32 = PIXEL_COUNT * 4;

pub const Error = error{
    /// rgba buffer is not exactly RGBA_BUFFER_SIZE bytes long.
    WrongBufferSize,
    /// payload exceeds CAPACITY_BYTES.
    PayloadTooLarge,
    /// output buffer is smaller than CAPACITY_BYTES.
    OutputBufferTooSmall,
};

/// Encode one byte into an RGBA pixel's low 2 bits of each channel.
/// The high 6 bits of the carrier are preserved.
pub fn encodePixel(carrier: [4]u8, payload: u8) [4]u8 {
    const a_bits: u8 = (payload >> 6) & 0x03;
    const r_bits: u8 = (payload >> 4) & 0x03;
    const g_bits: u8 = (payload >> 2) & 0x03;
    const b_bits: u8 = payload & 0x03;
    return .{
        (carrier[0] & 0xFC) | r_bits,
        (carrier[1] & 0xFC) | g_bits,
        (carrier[2] & 0xFC) | b_bits,
        (carrier[3] & 0xFC) | a_bits,
    };
}

/// Decode one RGBA pixel back into a payload byte.
pub fn decodePixel(rgba: [4]u8) u8 {
    const r_bits: u8 = rgba[0] & 0x03;
    const g_bits: u8 = rgba[1] & 0x03;
    const b_bits: u8 = rgba[2] & 0x03;
    const a_bits: u8 = rgba[3] & 0x03;
    return (a_bits << 6) | (r_bits << 4) | (g_bits << 2) | b_bits;
}

/// Encode `payload` into `rgba_buffer` (must be exactly RGBA_BUFFER_SIZE
/// bytes). After the payload ends, remaining pixels are filled with zero
/// payload bytes (carrier high bits preserved) so a decoded buffer beyond
/// the payload contains deterministic zeros, not carrier-derived noise.
///
/// Returns the number of payload bytes actually written (== payload.len).
pub fn encodeBuffer(payload: []const u8, rgba_buffer: []u8) Error!u32 {
    if (rgba_buffer.len != RGBA_BUFFER_SIZE) return error.WrongBufferSize;
    if (payload.len > CAPACITY_BYTES) return error.PayloadTooLarge;

    var i: u32 = 0;
    while (i < payload.len) : (i += 1) {
        encodeOnePixel(rgba_buffer, i, payload[i]);
    }
    // Pad the rest with zero so decoded bytes past payload are deterministic.
    while (i < CAPACITY_BYTES) : (i += 1) {
        encodeOnePixel(rgba_buffer, i, 0);
    }
    return @intCast(payload.len);
}

/// Decode the full CAPACITY_BYTES from `rgba_buffer` into `out_buffer`
/// (must be at least CAPACITY_BYTES).
pub fn decodeBuffer(rgba_buffer: []const u8, out_buffer: []u8) Error!u32 {
    if (rgba_buffer.len != RGBA_BUFFER_SIZE) return error.WrongBufferSize;
    if (out_buffer.len < CAPACITY_BYTES) return error.OutputBufferTooSmall;

    var i: u32 = 0;
    while (i < CAPACITY_BYTES) : (i += 1) {
        const off = i * 4;
        out_buffer[i] = decodePixel(.{
            rgba_buffer[off + 0],
            rgba_buffer[off + 1],
            rgba_buffer[off + 2],
            rgba_buffer[off + 3],
        });
    }
    return CAPACITY_BYTES;
}

inline fn encodeOnePixel(rgba_buffer: []u8, pixel_idx: u32, byte: u8) void {
    const off = pixel_idx * 4;
    const enc = encodePixel(.{
        rgba_buffer[off + 0],
        rgba_buffer[off + 1],
        rgba_buffer[off + 2],
        rgba_buffer[off + 3],
    }, byte);
    rgba_buffer[off + 0] = enc[0];
    rgba_buffer[off + 1] = enc[1];
    rgba_buffer[off + 2] = enc[2];
    rgba_buffer[off + 3] = enc[3];
}

test "single pixel round-trips arbitrary bytes" {
    const carrier: [4]u8 = .{ 0xAB, 0xCD, 0xEF, 0x12 };
    inline for ([_]u8{ 0x00, 0x01, 0x55, 0xAA, 0xFF, 0x42, 0x80 }) |byte| {
        const enc = encodePixel(carrier, byte);
        try std.testing.expectEqual(byte, decodePixel(enc));
    }
}

test "encoding preserves high 6 bits of carrier" {
    const carrier: [4]u8 = .{ 0xAB, 0xCD, 0xEF, 0x12 };
    const enc = encodePixel(carrier, 0xFF);
    // Each channel keeps high 6 bits, low 2 set to 0b11.
    try std.testing.expectEqual(@as(u8, (0xAB & 0xFC) | 0x03), enc[0]);
    try std.testing.expectEqual(@as(u8, (0xCD & 0xFC) | 0x03), enc[1]);
    try std.testing.expectEqual(@as(u8, (0xEF & 0xFC) | 0x03), enc[2]);
    try std.testing.expectEqual(@as(u8, (0x12 & 0xFC) | 0x03), enc[3]);
}

test "encoding zero payload preserves carrier exactly" {
    const carrier: [4]u8 = .{ 0xAB, 0xCC, 0xEC, 0x10 }; // already &0xFC = same
    const enc = encodePixel(carrier, 0);
    try std.testing.expectEqualSlices(u8, &carrier, &enc);
}

test "encodeBuffer + decodeBuffer round-trip a payload" {
    const test_alloc = std.testing.allocator;
    const rgba = try test_alloc.alloc(u8, RGBA_BUFFER_SIZE);
    defer test_alloc.free(rgba);
    @memset(rgba, 0x80); // mid-gray carrier

    const payload = "Hello, glint cart! 0123456789 abcdefghijklmnop";
    const written = try encodeBuffer(payload, rgba);
    try std.testing.expectEqual(@as(u32, payload.len), written);

    const decoded = try test_alloc.alloc(u8, CAPACITY_BYTES);
    defer test_alloc.free(decoded);
    _ = try decodeBuffer(rgba, decoded);

    try std.testing.expectEqualSlices(u8, payload, decoded[0..payload.len]);
}

test "padding past payload is zeroes" {
    const test_alloc = std.testing.allocator;
    const rgba = try test_alloc.alloc(u8, RGBA_BUFFER_SIZE);
    defer test_alloc.free(rgba);
    @memset(rgba, 0xFF); // bright carrier

    const payload = [_]u8{ 1, 2, 3, 4, 5 };
    _ = try encodeBuffer(&payload, rgba);

    const decoded = try test_alloc.alloc(u8, CAPACITY_BYTES);
    defer test_alloc.free(decoded);
    _ = try decodeBuffer(rgba, decoded);

    try std.testing.expectEqualSlices(u8, &payload, decoded[0..payload.len]);
    // Everything past the payload must be zero (engine relies on this for
    // deterministic cart parsing past unused trailing pixels).
    for (decoded[payload.len..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "encodeBuffer rejects wrong-size buffer" {
    const test_alloc = std.testing.allocator;
    const rgba_small = try test_alloc.alloc(u8, 100);
    defer test_alloc.free(rgba_small);
    try std.testing.expectError(error.WrongBufferSize, encodeBuffer("x", rgba_small));
}

test "encodeBuffer rejects payload too large" {
    const test_alloc = std.testing.allocator;
    const rgba = try test_alloc.alloc(u8, RGBA_BUFFER_SIZE);
    defer test_alloc.free(rgba);
    const huge = try test_alloc.alloc(u8, CAPACITY_BYTES + 1);
    defer test_alloc.free(huge);
    try std.testing.expectError(error.PayloadTooLarge, encodeBuffer(huge, rgba));
}

test "decodeBuffer rejects wrong-size input" {
    const test_alloc = std.testing.allocator;
    const small_rgba = try test_alloc.alloc(u8, 100);
    defer test_alloc.free(small_rgba);
    var out_buf: [CAPACITY_BYTES]u8 = undefined;
    try std.testing.expectError(error.WrongBufferSize, decodeBuffer(small_rgba, &out_buf));
}

test "decodeBuffer rejects too-small output buffer" {
    const test_alloc = std.testing.allocator;
    const rgba = try test_alloc.alloc(u8, RGBA_BUFFER_SIZE);
    defer test_alloc.free(rgba);
    var small_out: [100]u8 = undefined;
    try std.testing.expectError(error.OutputBufferTooSmall, decodeBuffer(rgba, &small_out));
}

test "capacity matches spec (160 * 205 = 32800)" {
    try std.testing.expectEqual(@as(u32, 32800), CAPACITY_BYTES);
    try std.testing.expectEqual(@as(u32, 131200), RGBA_BUFFER_SIZE);
}
