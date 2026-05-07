//! Deterministic state hashing.
//!
//! Per dx-spec §B.8, xxh3-64 is the chosen algorithm: ~30 GB/s, strong
//! avalanche, well-spec'd cross-platform. The engine uses one running hash
//! to (a) feed the dev panel's HASH field, (b) gate replay determinism in
//! `glint replay`, and (c) gossip across peers for v1.5 desync detection.
//!
//! This module re-exports Zig's std.hash.XxHash3 with a project-fixed seed
//! and provides one-shot + streaming helpers. The metatable-based
//! incremental hashing (per dx-spec §B.8.2) lives one layer up, in the
//! Luau binding once that arrives.

const std = @import("std");

/// Project-wide seed for state hashing. Fixed at zero so every cart and
/// every engine version computes the same hash for the same state bytes.
pub const SEED: u64 = 0;

/// The streaming hasher type. Same as std.hash.XxHash3.
pub const Hasher = std.hash.XxHash3;

/// One-shot hash of a byte slice. Equivalent to `Hasher.hash(SEED, bytes)`.
pub fn hashBytes(bytes: []const u8) u64 {
    return Hasher.hash(SEED, bytes);
}

/// One-shot hash of any value's underlying bytes (sized exactly as
/// @sizeOf(T)). The caller is responsible for ensuring the type is
/// trivially-bytes-comparable: no padding holes, no pointers, no
/// platform-dependent layouts. Use for fixed-layout structs only.
pub fn hashValue(comptime T: type, value: T) u64 {
    const bytes = std.mem.asBytes(&value);
    return Hasher.hash(SEED, bytes);
}

/// Convenience wrapper for the streaming use case: caller obtains a Hasher,
/// feeds it via `update`, and calls `final` when done. Returned to make the
/// calling pattern self-documenting at the call site.
pub fn streaming() Hasher {
    return Hasher.init(SEED);
}

test "hashBytes is deterministic across calls" {
    const a = hashBytes("hello, glint");
    const b = hashBytes("hello, glint");
    try std.testing.expectEqual(a, b);
}

test "hashBytes differs for different inputs" {
    try std.testing.expect(hashBytes("a") != hashBytes("b"));
    try std.testing.expect(hashBytes("hello") != hashBytes("Hello"));
}

test "hashBytes on empty input is well-defined" {
    // Specific value isn't required for correctness — what matters is that
    // it computes without crashing and returns the same thing twice.
    const a = hashBytes("");
    const b = hashBytes("");
    try std.testing.expectEqual(a, b);
}

test "hashValue on a fixed-layout struct" {
    const Frame = packed struct {
        seed: u32,
        turn: u32,
        leader: u8,
    };
    const f1: Frame = .{ .seed = 42, .turn = 5, .leader = 1 };
    const f2: Frame = .{ .seed = 42, .turn = 5, .leader = 1 };
    try std.testing.expectEqual(hashValue(Frame, f1), hashValue(Frame, f2));

    const f3: Frame = .{ .seed = 42, .turn = 5, .leader = 2 };
    try std.testing.expect(hashValue(Frame, f1) != hashValue(Frame, f3));
}

test "streaming hasher matches one-shot for same bytes" {
    var h = streaming();
    h.update("hello, ");
    h.update("glint");
    try std.testing.expectEqual(hashBytes("hello, glint"), h.final());
}
