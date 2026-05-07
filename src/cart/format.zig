//! Cart binary container format.
//!
//! The bytes that PNG steganography hides on disk (or that `glint pack`
//! produces directly) follow this layout:
//!
//!   +---------+----------+----------+----------+----------+
//!   | Magic 8 | Header 56| Sections | CRC32 4  | Foot  8  |
//!   +---------+----------+----------+----------+----------+
//!
//! Magic head : "GLINT" + \x00\x01\x00      (8 bytes; version 1.0)
//! Header     : 56 bytes of cart metadata (see Header struct below)
//! Sections   : 0..255 TLV records: { type u8, len u32 LE, data[len] }
//! CRC32      : crc32 of everything from MAGIC_HEAD..end-of-last-section
//! Magic foot : "ENDGLINT"                   (8 bytes)
//!
//! Total fixed overhead: 76 bytes. Per section overhead: 5 bytes.
//! The full cart payload is bounded by PNG-steg capacity = 32800 bytes,
//! so the cart's section data must total <= 32724 bytes.
//!
//! Forward compatibility:
//!   - The version sub-bytes in the magic head bump on schema-breaking
//!     changes; readers refuse loading unfamiliar majors.
//!   - SectionType is an open enum: unknown sections are skipped, not errored,
//!     so a v1.0 reader can ignore a v1.1-introduced section.

const std = @import("std");

/// Magic bytes at the head of a cart binary. 5 ASCII + 3 version sub-bytes.
pub const MAGIC_HEAD: [8]u8 = "GLINT\x00\x01\x00".*;
/// Magic bytes at the end of a cart binary; doubles as a "we got to the end"
/// sentinel for the validator.
pub const MAGIC_FOOT: [8]u8 = "ENDGLINT".*;

pub const HEADER_SIZE: usize = 56;
pub const FIXED_OVERHEAD: usize = MAGIC_HEAD.len + HEADER_SIZE + @sizeOf(u32) + MAGIC_FOOT.len;
pub const SECTION_OVERHEAD: usize = @sizeOf(u8) + @sizeOf(u32);
/// Hard upper bound on cart binary size. Matches PNG-steg capacity so
/// every well-formed cart binary fits in a single 160x205 carrier image.
pub const MAX_CART_BYTES: usize = 32800;

/// Section type tag. Open enum: unknown values are skipped during parse so
/// future sections do not break older readers (forward-compat policy).
pub const SectionType = enum(u8) {
    code = 0,
    sprite = 1,
    map = 2,
    music = 3,
    sfx = 4,
    ai = 5,
    meta = 6,
    icon = 7,
    _,
};

pub const Header = struct {
    cart_id: u128,
    /// Cart author handle; null-padded ASCII.
    author: [16]u8,
    /// Cart title; null-padded ASCII.
    title: [16]u8,
    /// Bitfield: 0=needs_net, 1=needs_llm, 2=multiplayer, 3..31=reserved.
    flags: u32,
    /// Number of sections that follow. Hard cap = 255 (u8).
    n_sections: u8,

    pub const FLAG_NEEDS_NET: u32 = 1 << 0;
    pub const FLAG_NEEDS_LLM: u32 = 1 << 1;
    pub const FLAG_MULTIPLAYER: u32 = 1 << 2;
};

pub const Section = struct {
    type: SectionType,
    data: []const u8,
};

pub const Cart = struct {
    header: Header,
    sections: []Section,

    /// Free the sections slice and each section's data, both allocated by
    /// `decode`. Header is value-only; no allocation.
    pub fn deinit(self: *Cart, alloc: std.mem.Allocator) void {
        for (self.sections) |s| alloc.free(s.data);
        alloc.free(self.sections);
    }
};

pub const Error = error{
    /// Cart binary too short to even read the magic + header.
    Truncated,
    /// MAGIC_HEAD does not match this engine's known cart format version.
    MagicHeadMismatch,
    /// MAGIC_FOOT not found at the expected end of stream.
    MagicFootMissing,
    /// CRC32 over the cart contents does not match the recorded checksum.
    CrcMismatch,
    /// Cart declared more sections than the binary actually contains.
    SectionCountMismatch,
    /// A section's len field would read past the end of the cart binary.
    SectionOverflow,
    /// Cart binary exceeds MAX_CART_BYTES.
    TooLarge,
    OutOfMemory,
};

/// Encode `header` + `sections` into a freshly allocated buffer. Caller
/// owns the result and must free it with `alloc.free(...)`.
///
/// `header.n_sections` is overwritten by the actual number of sections
/// passed (so callers cannot accidentally lie about the count).
pub fn encode(
    alloc: std.mem.Allocator,
    header: Header,
    sections: []const Section,
) Error![]u8 {
    var total: usize = FIXED_OVERHEAD;
    for (sections) |s| total += SECTION_OVERHEAD + s.data.len;
    if (total > MAX_CART_BYTES) return error.TooLarge;
    if (sections.len > 255) return error.TooLarge;

    const buf = alloc.alloc(u8, total) catch return error.OutOfMemory;
    errdefer alloc.free(buf);

    var off: usize = 0;

    // 1. magic head
    @memcpy(buf[off .. off + MAGIC_HEAD.len], &MAGIC_HEAD);
    off += MAGIC_HEAD.len;

    // 2. header (manually serialized for cross-platform LE byte layout)
    var fixed_header = header;
    fixed_header.n_sections = @intCast(sections.len);
    writeHeader(buf[off .. off + HEADER_SIZE], fixed_header);
    off += HEADER_SIZE;

    // 3. sections
    for (sections) |s| {
        buf[off] = @intFromEnum(s.type);
        off += 1;
        std.mem.writeInt(u32, buf[off..][0..4], @intCast(s.data.len), .little);
        off += 4;
        @memcpy(buf[off .. off + s.data.len], s.data);
        off += s.data.len;
    }

    // 4. CRC32 over magic + header + sections (everything written so far)
    const crc = std.hash.crc.Crc32.hash(buf[0..off]);
    std.mem.writeInt(u32, buf[off..][0..4], crc, .little);
    off += 4;

    // 5. magic foot
    @memcpy(buf[off .. off + MAGIC_FOOT.len], &MAGIC_FOOT);
    off += MAGIC_FOOT.len;

    std.debug.assert(off == total); // sanity: layout matches plan
    return buf;
}

/// Decode a cart binary into `Cart`. Validates magic + CRC32 + footer.
/// On success, caller owns `Cart` and must call `cart.deinit(alloc)`.
pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) Error!Cart {
    if (bytes.len > MAX_CART_BYTES) return error.TooLarge;
    if (bytes.len < FIXED_OVERHEAD) return error.Truncated;

    if (!std.mem.eql(u8, bytes[0..MAGIC_HEAD.len], &MAGIC_HEAD)) {
        return error.MagicHeadMismatch;
    }

    const foot_at = bytes.len - MAGIC_FOOT.len;
    if (!std.mem.eql(u8, bytes[foot_at..], &MAGIC_FOOT)) {
        return error.MagicFootMissing;
    }

    const crc_at = foot_at - 4;
    const recorded_crc = std.mem.readInt(u32, bytes[crc_at..][0..4], .little);
    const actual_crc = std.hash.crc.Crc32.hash(bytes[0..crc_at]);
    if (recorded_crc != actual_crc) return error.CrcMismatch;

    var off: usize = MAGIC_HEAD.len;
    const header = readHeader(bytes[off .. off + HEADER_SIZE]);
    off += HEADER_SIZE;

    var sections = alloc.alloc(Section, header.n_sections) catch return error.OutOfMemory;
    errdefer alloc.free(sections);
    var freed_sections: usize = 0;
    errdefer for (sections[0..freed_sections]) |s| alloc.free(s.data);

    var i: usize = 0;
    while (i < header.n_sections) : (i += 1) {
        if (off + SECTION_OVERHEAD > crc_at) return error.SectionCountMismatch;
        const t: SectionType = @enumFromInt(bytes[off]);
        off += 1;
        const len = std.mem.readInt(u32, bytes[off..][0..4], .little);
        off += 4;
        if (off + len > crc_at) return error.SectionOverflow;
        const data = alloc.alloc(u8, len) catch return error.OutOfMemory;
        @memcpy(data, bytes[off .. off + len]);
        off += len;
        sections[i] = .{ .type = t, .data = data };
        freed_sections = i + 1;
    }

    if (off != crc_at) return error.SectionCountMismatch;

    return .{ .header = header, .sections = sections };
}

fn writeHeader(buf: []u8, h: Header) void {
    std.debug.assert(buf.len == HEADER_SIZE);
    std.mem.writeInt(u128, buf[0..16], h.cart_id, .little);
    @memcpy(buf[16..32], &h.author);
    @memcpy(buf[32..48], &h.title);
    std.mem.writeInt(u32, buf[48..52], h.flags, .little);
    buf[52] = h.n_sections;
    @memset(buf[53..56], 0); // reserved padding
}

fn readHeader(buf: []const u8) Header {
    std.debug.assert(buf.len == HEADER_SIZE);
    var h: Header = .{
        .cart_id = std.mem.readInt(u128, buf[0..16], .little),
        .author = undefined,
        .title = undefined,
        .flags = std.mem.readInt(u32, buf[48..52], .little),
        .n_sections = buf[52],
    };
    @memcpy(&h.author, buf[16..32]);
    @memcpy(&h.title, buf[32..48]);
    return h;
}

// ---------------- tests ----------------

const testing = std.testing;

fn fixedAuthor(comptime s: []const u8) [16]u8 {
    var out: [16]u8 = [_]u8{0} ** 16;
    @memcpy(out[0..s.len], s);
    return out;
}

fn fixedTitle(comptime s: []const u8) [16]u8 {
    var out: [16]u8 = [_]u8{0} ** 16;
    @memcpy(out[0..s.len], s);
    return out;
}

test "round-trip with one code section" {
    const alloc = testing.allocator;
    const code: []const u8 = "function _init() end\nfunction _update() end\n";
    const sections = [_]Section{.{ .type = .code, .data = code }};
    const header: Header = .{
        .cart_id = 0xDEADBEEFCAFEBABE_0123456789ABCDEF,
        .author = fixedAuthor("ada"),
        .title = fixedTitle("hello-cart"),
        .flags = 0,
        .n_sections = 0, // overwritten by encode
    };

    const bin = try encode(alloc, header, &sections);
    defer alloc.free(bin);

    var cart = try decode(alloc, bin);
    defer cart.deinit(alloc);

    try testing.expectEqual(header.cart_id, cart.header.cart_id);
    try testing.expectEqualSlices(u8, &header.author, &cart.header.author);
    try testing.expectEqualSlices(u8, &header.title, &cart.header.title);
    try testing.expectEqual(@as(u8, 1), cart.header.n_sections);
    try testing.expectEqual(@as(usize, 1), cart.sections.len);
    try testing.expectEqual(SectionType.code, cart.sections[0].type);
    try testing.expectEqualSlices(u8, code, cart.sections[0].data);
}

test "round-trip with multiple section types" {
    const alloc = testing.allocator;
    const code = "code";
    const spr = [_]u8{ 1, 2, 3, 4 };
    const ai = "[npc.beef] system = 'cocky'";
    const sections = [_]Section{
        .{ .type = .code, .data = code },
        .{ .type = .sprite, .data = &spr },
        .{ .type = .ai, .data = ai },
    };
    const header: Header = .{
        .cart_id = 1,
        .author = fixedAuthor("zz"),
        .title = fixedTitle("multi"),
        .flags = Header.FLAG_NEEDS_LLM,
        .n_sections = 0,
    };

    const bin = try encode(alloc, header, &sections);
    defer alloc.free(bin);

    var cart = try decode(alloc, bin);
    defer cart.deinit(alloc);

    try testing.expectEqual(@as(usize, 3), cart.sections.len);
    try testing.expectEqual(SectionType.code, cart.sections[0].type);
    try testing.expectEqual(SectionType.sprite, cart.sections[1].type);
    try testing.expectEqual(SectionType.ai, cart.sections[2].type);
    try testing.expectEqualSlices(u8, code, cart.sections[0].data);
    try testing.expectEqualSlices(u8, &spr, cart.sections[1].data);
    try testing.expectEqualSlices(u8, ai, cart.sections[2].data);
    try testing.expectEqual(Header.FLAG_NEEDS_LLM, cart.header.flags);
}

test "decode rejects bad magic head" {
    const alloc = testing.allocator;
    const sections = [_]Section{.{ .type = .code, .data = "x" }};
    const header: Header = .{ .cart_id = 0, .author = [_]u8{0} ** 16, .title = [_]u8{0} ** 16, .flags = 0, .n_sections = 0 };
    const bin = try encode(alloc, header, &sections);
    defer alloc.free(bin);

    const tampered = try alloc.dupe(u8, bin);
    defer alloc.free(tampered);
    tampered[0] = 'X'; // corrupt magic
    try testing.expectError(error.MagicHeadMismatch, decode(alloc, tampered));
}

test "decode rejects bad CRC32" {
    const alloc = testing.allocator;
    const sections = [_]Section{.{ .type = .code, .data = "x" }};
    const header: Header = .{ .cart_id = 0, .author = [_]u8{0} ** 16, .title = [_]u8{0} ** 16, .flags = 0, .n_sections = 0 };
    const bin = try encode(alloc, header, &sections);
    defer alloc.free(bin);

    const tampered = try alloc.dupe(u8, bin);
    defer alloc.free(tampered);
    tampered[MAGIC_HEAD.len + HEADER_SIZE + SECTION_OVERHEAD] ^= 0xFF; // flip a section data byte
    try testing.expectError(error.CrcMismatch, decode(alloc, tampered));
}

test "decode rejects missing footer" {
    const alloc = testing.allocator;
    const sections = [_]Section{.{ .type = .code, .data = "x" }};
    const header: Header = .{ .cart_id = 0, .author = [_]u8{0} ** 16, .title = [_]u8{0} ** 16, .flags = 0, .n_sections = 0 };
    const bin = try encode(alloc, header, &sections);
    defer alloc.free(bin);

    const tampered = try alloc.dupe(u8, bin);
    defer alloc.free(tampered);
    tampered[tampered.len - 1] = 'Z';
    try testing.expectError(error.MagicFootMissing, decode(alloc, tampered));
}

test "decode rejects truncated cart" {
    const alloc = testing.allocator;
    const tiny: [10]u8 = [_]u8{0} ** 10;
    try testing.expectError(error.Truncated, decode(alloc, &tiny));
}

test "encode rejects too-many sections" {
    const alloc = testing.allocator;
    var many: [256]Section = undefined;
    for (&many) |*s| s.* = .{ .type = .code, .data = "" };
    const header: Header = .{ .cart_id = 0, .author = [_]u8{0} ** 16, .title = [_]u8{0} ** 16, .flags = 0, .n_sections = 0 };
    try testing.expectError(error.TooLarge, encode(alloc, header, &many));
}

test "encode rejects oversized payload" {
    const alloc = testing.allocator;
    const big = try alloc.alloc(u8, MAX_CART_BYTES);
    defer alloc.free(big);
    const sections = [_]Section{.{ .type = .code, .data = big }};
    const header: Header = .{ .cart_id = 0, .author = [_]u8{0} ** 16, .title = [_]u8{0} ** 16, .flags = 0, .n_sections = 0 };
    try testing.expectError(error.TooLarge, encode(alloc, header, &sections));
}

test "encode overwrites n_sections to actual count" {
    const alloc = testing.allocator;
    const sections = [_]Section{
        .{ .type = .code, .data = "a" },
        .{ .type = .sprite, .data = "b" },
    };
    const header: Header = .{
        .cart_id = 0,
        .author = [_]u8{0} ** 16,
        .title = [_]u8{0} ** 16,
        .flags = 0,
        .n_sections = 99, // lie; encode should fix
    };
    const bin = try encode(alloc, header, &sections);
    defer alloc.free(bin);
    var cart = try decode(alloc, bin);
    defer cart.deinit(alloc);
    try testing.expectEqual(@as(u8, 2), cart.header.n_sections);
}

test "fixed overhead constants match layout" {
    try testing.expectEqual(@as(usize, 76), FIXED_OVERHEAD);
    try testing.expectEqual(@as(usize, 5), SECTION_OVERHEAD);
    try testing.expectEqual(@as(usize, 32800), MAX_CART_BYTES);
}
