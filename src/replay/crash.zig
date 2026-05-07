//! Crash artifact (.crash) file format.
//!
//! Layout (dx-spec §B.3.1, simplified for v1 — body uncompressed):
//!
//!   header (32 bytes, uncompressed):
//!     +0   magic        u8[4]   = "GCRH"
//!     +4   format_ver   u16     = 1
//!     +6   flags        u16     bit 0 = body_compressed (v1: always 0)
//!     +8   body_len     u32     length of the TLV body in bytes
//!     +12  body_crc32   u32     crc32 over the body bytes
//!     +16  glint_ver    u8[12]  ascii semver, null-padded e.g. "0.0.1"
//!     +28  reserved     u8[4]   zero
//!
//!   body (body_len bytes; TLV stream):
//!     each record: tag u16 LE | len u32 LE | payload[len]
//!
//! Forward-compat policy: readers MUST skip unknown tags rather than
//! errored. A v1 reader handed a v1.1 file with an extra tag should
//! still load all the v1 tags it knows.
//!
//! Writers should use TlvWriter; readers iterate via TlvReader.
//! Higher-level "build a crash dump" / "replay a crash dump" helpers
//! live above this layer (engine/replay.zig once it exists).

const std = @import("std");

pub const MAGIC: [4]u8 = "GCRH".*;
pub const FORMAT_VER: u16 = 1;
pub const HEADER_SIZE: usize = 32;
pub const GLINT_VER_FIELD_SIZE: usize = 12;

pub const FLAG_BODY_COMPRESSED: u16 = 1 << 0;

/// Known TLV tags. Open enum: unknown values must NOT be errored at parse
/// time (forward-compat). Extending this list is a non-breaking change.
pub const Tag = enum(u16) {
    cart_id = 0x0001,
    cart_version = 0x0002,
    cart_blob_sha256 = 0x0003,
    manifest_toml = 0x0004,
    caps_granted = 0x0005,
    input_stream = 0x0010,
    state_snapshot = 0x0011,
    state_hash_trace = 0x0012,
    log_tail = 0x0020,
    ai_inbox_snapshot = 0x0030,
    ai_model_info = 0x0031,
    net_session_id = 0x0040,
    net_input_history = 0x0041,
    cause = 0x00FF,
    _,
};

pub const Error = error{
    /// File too short to contain a header.
    Truncated,
    /// MAGIC bytes do not match — not a crash artifact.
    BadMagic,
    /// format_ver larger than this engine knows.
    UnsupportedFormatVersion,
    /// Body length declared in header does not match actual remainder.
    BodyLengthMismatch,
    /// CRC32 over the body does not match recorded value.
    BodyCrcMismatch,
    /// A TLV record's len would read past the end of the body.
    TlvOverflow,
    OutOfMemory,
};

pub const Header = struct {
    format_ver: u16,
    flags: u16,
    body_len: u32,
    body_crc32: u32,
    /// Ascii semver, null-padded, exactly GLINT_VER_FIELD_SIZE bytes.
    glint_ver: [GLINT_VER_FIELD_SIZE]u8,

    pub fn isCompressed(self: Header) bool {
        return (self.flags & FLAG_BODY_COMPRESSED) != 0;
    }
};

/// Build a TLV body in a growing buffer. Caller frees the returned slice.
pub const TlvWriter = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) TlvWriter {
        return .{ .buf = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *TlvWriter) void {
        self.buf.deinit(self.alloc);
    }

    /// Append one TLV record. Always succeeds unless OOM.
    pub fn write(self: *TlvWriter, tag: Tag, payload: []const u8) Error!void {
        try self.buf.ensureUnusedCapacity(self.alloc, 6 + payload.len);
        var tag_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &tag_bytes, @intFromEnum(tag), .little);
        self.buf.appendSliceAssumeCapacity(&tag_bytes);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(payload.len), .little);
        self.buf.appendSliceAssumeCapacity(&len_bytes);
        self.buf.appendSliceAssumeCapacity(payload);
    }

    /// Finalize the body and return the owned bytes. The writer is
    /// invalidated afterward; do not reuse.
    pub fn finalize(self: *TlvWriter) ![]u8 {
        return try self.buf.toOwnedSlice(self.alloc);
    }
};

/// Iterate TLV records out of a body byte slice. `next()` returns null on
/// clean end or error.TlvOverflow if a record would read past end. Skipping
/// is the caller's responsibility based on the returned tag value.
pub const TlvReader = struct {
    body: []const u8,
    cursor: usize = 0,

    pub fn init(body: []const u8) TlvReader {
        return .{ .body = body };
    }

    pub const Record = struct {
        tag: Tag,
        payload: []const u8,
    };

    pub fn next(self: *TlvReader) Error!?Record {
        if (self.cursor >= self.body.len) return null;
        if (self.cursor + 6 > self.body.len) return error.TlvOverflow;
        const tag_value = std.mem.readInt(u16, self.body[self.cursor..][0..2], .little);
        self.cursor += 2;
        const len = std.mem.readInt(u32, self.body[self.cursor..][0..4], .little);
        self.cursor += 4;
        if (self.cursor + len > self.body.len) return error.TlvOverflow;
        const payload = self.body[self.cursor .. self.cursor + len];
        self.cursor += len;
        return .{ .tag = @enumFromInt(tag_value), .payload = payload };
    }
};

/// Encode a complete crash artifact (header + body) into a freshly
/// allocated buffer. Caller owns the result. v1 always writes
/// flags=0 (uncompressed body).
pub fn encode(
    alloc: std.mem.Allocator,
    glint_version: []const u8,
    body: []const u8,
) Error![]u8 {
    if (body.len > std.math.maxInt(u32)) return error.OutOfMemory;
    const out = alloc.alloc(u8, HEADER_SIZE + body.len) catch return error.OutOfMemory;
    errdefer alloc.free(out);

    @memcpy(out[0..4], &MAGIC);
    std.mem.writeInt(u16, out[4..6], FORMAT_VER, .little);
    std.mem.writeInt(u16, out[6..8], 0, .little); // flags = 0 in v1
    std.mem.writeInt(u32, out[8..12], @intCast(body.len), .little);
    std.mem.writeInt(u32, out[12..16], std.hash.crc.Crc32.hash(body), .little);

    // glint_ver field: copy up to 12 bytes, zero-pad the remainder.
    var ver_field: [GLINT_VER_FIELD_SIZE]u8 = [_]u8{0} ** GLINT_VER_FIELD_SIZE;
    const copy_len = @min(glint_version.len, GLINT_VER_FIELD_SIZE);
    @memcpy(ver_field[0..copy_len], glint_version[0..copy_len]);
    @memcpy(out[16..28], &ver_field);

    @memset(out[28..32], 0); // reserved

    @memcpy(out[32..], body);
    return out;
}

pub const Decoded = struct {
    header: Header,
    body: []const u8, // borrowed slice into the input bytes
};

/// Parse and validate a crash artifact in-place. Returns header + a
/// borrowed slice into `bytes` for the body.
pub fn decode(bytes: []const u8) Error!Decoded {
    if (bytes.len < HEADER_SIZE) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], &MAGIC)) return error.BadMagic;

    const format_ver = std.mem.readInt(u16, bytes[4..6], .little);
    if (format_ver > FORMAT_VER) return error.UnsupportedFormatVersion;

    const flags = std.mem.readInt(u16, bytes[6..8], .little);
    const body_len = std.mem.readInt(u32, bytes[8..12], .little);
    const recorded_crc = std.mem.readInt(u32, bytes[12..16], .little);

    if (HEADER_SIZE + @as(usize, body_len) != bytes.len) return error.BodyLengthMismatch;

    const body = bytes[HEADER_SIZE..];
    const actual_crc = std.hash.crc.Crc32.hash(body);
    if (actual_crc != recorded_crc) return error.BodyCrcMismatch;

    var ver_field: [GLINT_VER_FIELD_SIZE]u8 = undefined;
    @memcpy(&ver_field, bytes[16..28]);

    return .{
        .header = .{
            .format_ver = format_ver,
            .flags = flags,
            .body_len = body_len,
            .body_crc32 = recorded_crc,
            .glint_ver = ver_field,
        },
        .body = body,
    };
}

// ---------- tests ----------

const testing = std.testing;

test "TlvWriter and TlvReader round-trip records" {
    const alloc = testing.allocator;
    var w = TlvWriter.init(alloc);
    defer w.deinit();

    try w.write(.cart_id, "com.example.tile-pusher");
    try w.write(.cart_version, "1.2.3");
    try w.write(.cause, "lua_error");

    const body = try w.finalize();
    defer alloc.free(body);

    var r = TlvReader.init(body);
    const r0 = (try r.next()).?;
    try testing.expectEqual(Tag.cart_id, r0.tag);
    try testing.expectEqualSlices(u8, "com.example.tile-pusher", r0.payload);

    const r1 = (try r.next()).?;
    try testing.expectEqual(Tag.cart_version, r1.tag);
    try testing.expectEqualSlices(u8, "1.2.3", r1.payload);

    const r2 = (try r.next()).?;
    try testing.expectEqual(Tag.cause, r2.tag);
    try testing.expectEqualSlices(u8, "lua_error", r2.payload);

    try testing.expectEqual(@as(?TlvReader.Record, null), try r.next());
}

test "encode and decode round-trip preserves body" {
    const alloc = testing.allocator;
    var w = TlvWriter.init(alloc);
    defer w.deinit();
    try w.write(.cart_id, "x");
    try w.write(.cause, "instr_overrun");
    const body = try w.finalize();
    defer alloc.free(body);

    const out = try encode(alloc, "0.0.1", body);
    defer alloc.free(out);

    const decoded = try decode(out);
    try testing.expectEqual(FORMAT_VER, decoded.header.format_ver);
    try testing.expectEqual(@as(u16, 0), decoded.header.flags);
    try testing.expectEqualSlices(u8, body, decoded.body);
}

test "decode rejects bad magic" {
    const alloc = testing.allocator;
    const out = try encode(alloc, "0.0.1", "");
    defer alloc.free(out);
    var corrupted = try alloc.dupe(u8, out);
    defer alloc.free(corrupted);
    corrupted[0] = 'X';
    try testing.expectError(error.BadMagic, decode(corrupted));
}

test "decode rejects future format_ver" {
    const alloc = testing.allocator;
    const out = try encode(alloc, "0.0.1", "");
    defer alloc.free(out);
    var corrupted = try alloc.dupe(u8, out);
    defer alloc.free(corrupted);
    std.mem.writeInt(u16, corrupted[4..6], FORMAT_VER + 1, .little);
    try testing.expectError(error.UnsupportedFormatVersion, decode(corrupted));
}

test "decode rejects body length mismatch" {
    const alloc = testing.allocator;
    const out = try encode(alloc, "0.0.1", "abc");
    defer alloc.free(out);
    var corrupted = try alloc.dupe(u8, out);
    defer alloc.free(corrupted);
    std.mem.writeInt(u32, corrupted[8..12], 999, .little); // claim body is 999 bytes
    try testing.expectError(error.BodyLengthMismatch, decode(corrupted));
}

test "decode rejects body crc mismatch" {
    const alloc = testing.allocator;
    const out = try encode(alloc, "0.0.1", "abc");
    defer alloc.free(out);
    var corrupted = try alloc.dupe(u8, out);
    defer alloc.free(corrupted);
    corrupted[HEADER_SIZE] ^= 0xFF; // flip a body byte; crc no longer matches
    try testing.expectError(error.BodyCrcMismatch, decode(corrupted));
}

test "decode rejects truncated input" {
    const tiny: [10]u8 = [_]u8{0} ** 10;
    try testing.expectError(error.Truncated, decode(&tiny));
}

test "TlvReader errors on overflow" {
    // Crafted bad body: declares 100-byte payload but only has 5 bytes
    const bad_body = [_]u8{
        0x01, 0x00, // tag = 1
        100, 0, 0, 0, // len = 100 (way past body end)
        'a', 'b', 'c', 'd', 'e',
    };
    var r = TlvReader.init(&bad_body);
    try testing.expectError(error.TlvOverflow, r.next());
}

test "unknown tag is preserved as raw integer (forward-compat)" {
    const alloc = testing.allocator;
    var w = TlvWriter.init(alloc);
    defer w.deinit();
    // Emit a record using a tag not yet in the enum (0xABCD).
    const future_tag: Tag = @enumFromInt(0xABCD);
    try w.write(future_tag, "future-payload");
    const body = try w.finalize();
    defer alloc.free(body);

    var r = TlvReader.init(body);
    const rec = (try r.next()).?;
    try testing.expectEqual(@as(u16, 0xABCD), @intFromEnum(rec.tag));
    try testing.expectEqualSlices(u8, "future-payload", rec.payload);
}

test "encode handles glint_version longer than 12 chars by truncating" {
    const alloc = testing.allocator;
    const out = try encode(alloc, "0.99.123-pre.long", "");
    defer alloc.free(out);
    const decoded = try decode(out);
    // Field is exactly 12 bytes, ascii content followed by zeros.
    try testing.expectEqualSlices(u8, "0.99.123-pre", decoded.header.glint_ver[0..12]);
}

test "encode pads short glint_version with zeros" {
    const alloc = testing.allocator;
    const out = try encode(alloc, "0.0.1", "");
    defer alloc.free(out);
    const decoded = try decode(out);
    try testing.expectEqualSlices(u8, "0.0.1", decoded.header.glint_ver[0..5]);
    for (decoded.header.glint_ver[5..]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "header constants match dx-spec §B.3.1" {
    try testing.expectEqual(@as(usize, 32), HEADER_SIZE);
    try testing.expectEqual(@as(usize, 12), GLINT_VER_FIELD_SIZE);
    try testing.expectEqualSlices(u8, "GCRH", &MAGIC);
}
