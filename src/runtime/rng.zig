//! Deterministic xorshift32 PRNG.
//!
//! Cart-author `rnd()` and `srand()` live on top of this. Cart RNG MUST
//! be deterministic and pure: same seed produces same sequence on every
//! supported target (x86_64 / aarch64 / wasm32). std.Random's defaults
//! pull from the host OS and are unsuitable.
//!
//! Algorithm: Marsaglia 2003 xorshift32 with shifts (13, 17, 5). Period
//! is 2^32 - 1, more than enough for fantasy-console game state. Not
//! cryptographic — never use for secrets.

const std = @import("std");

/// xorshift32 PRNG state. Initialize via init(seed) and call next() to
/// pull pseudo-random u32 values.
pub const Xorshift32 = struct {
    state: u32,

    /// Initialize with the given seed. Seed value 0 is degenerate for
    /// xorshift (gets stuck at 0); we salt it with a non-zero constant
    /// so cart authors who srand(0) get a usable sequence.
    pub fn init(seed: u32) Xorshift32 {
        return .{ .state = if (seed == 0) 0xACE1_ACE1 else seed };
    }

    /// Advance and return the next u32. ~1ns / call on modern CPUs.
    pub fn next(self: *Xorshift32) u32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return x;
    }

    /// Next f64 in [0.0, 1.0). Matches Pico-8 `rnd()` semantics.
    pub fn nextFloat(self: *Xorshift32) f64 {
        return @as(f64, @floatFromInt(self.next())) / 4294967296.0; // 2^32
    }

    /// Next i32 in [lo, hi). Returns lo if hi <= lo.
    pub fn nextRange(self: *Xorshift32, lo: i32, hi: i32) i32 {
        if (hi <= lo) return lo;
        const span: u32 = @intCast(hi - lo);
        return lo + @as(i32, @intCast(self.next() % span));
    }

    /// Reseed in place. Engine calls this when the cart issues `srand()`.
    pub fn reseed(self: *Xorshift32, seed: u32) void {
        self.state = if (seed == 0) 0xACE1_ACE1 else seed;
    }
};

// ---------- tests ----------

const testing = std.testing;

test "same seed produces same sequence" {
    var a = Xorshift32.init(42);
    var b = Xorshift32.init(42);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try testing.expectEqual(a.next(), b.next());
    }
}

test "different seeds diverge quickly" {
    var a = Xorshift32.init(1);
    var b = Xorshift32.init(2);
    // After a few iterations the two sequences should differ at every position.
    var divergent: u32 = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (a.next() != b.next()) divergent += 1;
    }
    try testing.expect(divergent > 95); // statistical: should differ ~always
}

test "seed 0 is salted, not stuck" {
    var rng = Xorshift32.init(0);
    const a = rng.next();
    const b = rng.next();
    try testing.expect(a != 0);
    try testing.expect(b != 0);
    try testing.expect(a != b);
}

test "nextFloat returns [0, 1)" {
    var rng = Xorshift32.init(42);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const f = rng.nextFloat();
        try testing.expect(f >= 0.0);
        try testing.expect(f < 1.0);
    }
}

test "nextRange respects bounds" {
    var rng = Xorshift32.init(42);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const v = rng.nextRange(10, 20);
        try testing.expect(v >= 10);
        try testing.expect(v < 20);
    }
}

test "nextRange degenerate hi<=lo returns lo" {
    var rng = Xorshift32.init(42);
    try testing.expectEqual(@as(i32, 5), rng.nextRange(5, 5));
    try testing.expectEqual(@as(i32, 5), rng.nextRange(5, 3));
}

test "reseed restores deterministic sequence" {
    var rng = Xorshift32.init(42);
    _ = rng.next();
    _ = rng.next();
    _ = rng.next();
    rng.reseed(42);
    var fresh = Xorshift32.init(42);
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try testing.expectEqual(fresh.next(), rng.next());
    }
}

test "rough statistical sanity: 1000 samples cover >256 of 1024 buckets" {
    var rng = Xorshift32.init(42);
    var bucket_hit: [1024]bool = [_]bool{false} ** 1024;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        bucket_hit[rng.next() % 1024] = true;
    }
    var hit_count: usize = 0;
    for (bucket_hit) |h| if (h) {
        hit_count += 1;
    };
    try testing.expect(hit_count > 256);
}
