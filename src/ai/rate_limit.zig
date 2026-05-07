//! Token-bucket rate limiter for AI inference requests.
//!
//! Per dx-spec §A.4 / cart manifest [caps].ai.max_tokens_per_sec, the
//! engine caps how many LLM tokens a cart may consume per real-time
//! second. The cap is per-cart and per-NPC; this module implements one
//! bucket — the AI router (src/ai/router.zig, W9 deliverable) holds an
//! array of buckets keyed by NPC id.
//!
//! Why token-bucket vs. sliding-window vs. leaky-bucket:
//!   - Token-bucket allows brief bursts (refunds the unused budget while
//!     idle), matching how cart authors use AI: short flurries when the
//!     player triggers dialogue, then long pauses.
//!   - Constant trickle (leaky-bucket) is too restrictive for the use case.
//!   - Sliding window has more state and is harder to reason about for
//!     debugging.

const std = @import("std");

pub const TokenBucket = struct {
    /// Maximum tokens the bucket can hold (== max burst size).
    capacity: u64,
    /// Current available tokens. Starts at `capacity` (full bucket).
    tokens: u64,
    /// Refill rate in tokens per millisecond, scaled by REFILL_SCALE so
    /// fractional rates (e.g. 0.5 tok/ms = 500 tok/sec) are representable.
    refill_per_ms_scaled: u64,
    /// Last wall-clock timestamp (ms) we processed in `tryConsume`.
    last_refill_ms: u64,
    /// Sub-millisecond residual carried over between calls so very low
    /// rates (e.g. 1 tok/sec) still refill correctly.
    refill_residual: u64 = 0,

    pub const REFILL_SCALE: u64 = 1000; // 1000 = 1 tok/ms; 1 = 0.001 tok/ms

    /// Construct a bucket with given burst capacity and steady-state
    /// refill rate (tokens per second). The bucket starts full so a cart
    /// can issue a burst on its very first frame.
    pub fn init(capacity: u64, refill_per_sec: u64) TokenBucket {
        return .{
            .capacity = capacity,
            .tokens = capacity,
            // refill_per_ms_scaled = refill_per_sec * REFILL_SCALE / 1000
            //                      = refill_per_sec * (REFILL_SCALE / 1000)
            // With REFILL_SCALE=1000 this simplifies to refill_per_sec * 1.
            .refill_per_ms_scaled = refill_per_sec,
            .last_refill_ms = 0,
        };
    }

    /// Attempt to consume `n` tokens. Updates the bucket's refill state
    /// based on `now_ms` (caller-provided wall clock, milliseconds).
    /// Returns true if the bucket had sufficient tokens (and they were
    /// deducted), false otherwise (bucket unchanged).
    ///
    /// Caller's clock must be monotonic non-decreasing; if `now_ms` ever
    /// goes backwards the bucket clamps to a no-refill snapshot for that
    /// step (defensive, never crashes).
    pub fn tryConsume(self: *TokenBucket, n: u64, now_ms: u64) bool {
        self.refill(now_ms);
        if (self.tokens >= n) {
            self.tokens -= n;
            return true;
        }
        return false;
    }

    /// Update the bucket's `tokens` and `last_refill_ms` based on time
    /// elapsed since the previous call. Public so tests can advance the
    /// clock without consuming, and so dev panel can read live state.
    pub fn refill(self: *TokenBucket, now_ms: u64) void {
        if (now_ms <= self.last_refill_ms) return;
        const elapsed_ms = now_ms - self.last_refill_ms;

        // total_scaled = elapsed_ms * refill_per_ms_scaled + residual
        const total_scaled = elapsed_ms *| self.refill_per_ms_scaled + self.refill_residual;
        const whole_tokens = total_scaled / REFILL_SCALE;
        self.refill_residual = total_scaled % REFILL_SCALE;

        self.tokens = @min(self.capacity, self.tokens +| whole_tokens);
        self.last_refill_ms = now_ms;
    }

    /// Restart the bucket: full tokens, clock-aligned to the given time.
    /// Used when the cart resets or the rate budget is reconfigured.
    pub fn reset(self: *TokenBucket, now_ms: u64) void {
        self.tokens = self.capacity;
        self.last_refill_ms = now_ms;
        self.refill_residual = 0;
    }
};

// ---------- tests ----------

const testing = std.testing;

test "fresh bucket starts full and consumes within capacity" {
    var b = TokenBucket.init(60, 60);
    try testing.expectEqual(@as(u64, 60), b.tokens);
    try testing.expect(b.tryConsume(20, 0));
    try testing.expectEqual(@as(u64, 40), b.tokens);
    try testing.expect(b.tryConsume(40, 0));
    try testing.expectEqual(@as(u64, 0), b.tokens);
}

test "tryConsume fails when tokens insufficient" {
    var b = TokenBucket.init(10, 10);
    try testing.expect(!b.tryConsume(11, 0));
    try testing.expectEqual(@as(u64, 10), b.tokens); // unchanged on fail
    try testing.expect(b.tryConsume(10, 0));
}

test "refill replenishes tokens over time" {
    var b = TokenBucket.init(60, 60); // 60 tok/sec
    // Drain the bucket
    _ = b.tryConsume(60, 0);
    try testing.expectEqual(@as(u64, 0), b.tokens);
    // After 500ms, 30 tokens should be back
    b.refill(500);
    try testing.expectEqual(@as(u64, 30), b.tokens);
    // After another 500ms, 60 tokens again (clamped to capacity)
    b.refill(1000);
    try testing.expectEqual(@as(u64, 60), b.tokens);
}

test "refill clamps at capacity (no infinite stockpile)" {
    var b = TokenBucket.init(60, 60);
    // Already full; advance one full second, should still be 60 not 120
    b.refill(1_000_000);
    try testing.expectEqual(@as(u64, 60), b.tokens);
}

test "tryConsume with refill: drain then wait then succeed" {
    var b = TokenBucket.init(100, 100);
    _ = b.tryConsume(100, 0);
    try testing.expect(!b.tryConsume(50, 0)); // no time passed, no tokens
    try testing.expect(b.tryConsume(50, 500)); // 500ms later, 50 tokens replenished
}

test "low-rate refill still accumulates via residual" {
    // 1 tok/sec means 0.001 tok/ms. With REFILL_SCALE=1000, that's 1 unit/ms scaled.
    var b = TokenBucket.init(10, 1);
    _ = b.tryConsume(10, 0);
    // After 999ms we should still have 0 tokens (rounded down).
    b.refill(999);
    try testing.expectEqual(@as(u64, 0), b.tokens);
    // After 1000ms we should have 1 token.
    b.refill(1000);
    try testing.expectEqual(@as(u64, 1), b.tokens);
    // After 2500ms total (additional 1500), should have 2 more = 3 tokens.
    b.refill(2500);
    try testing.expectEqual(@as(u64, 3), b.tokens);
}

test "non-monotonic clock (backwards) does not crash and skips refill" {
    var b = TokenBucket.init(10, 10);
    _ = b.tryConsume(10, 1000);
    b.refill(500); // backwards in time: should be no-op
    try testing.expectEqual(@as(u64, 0), b.tokens);
    b.refill(1500); // forward: 5 tokens added
    try testing.expectEqual(@as(u64, 5), b.tokens);
}

test "reset returns to full at given time" {
    var b = TokenBucket.init(60, 60);
    _ = b.tryConsume(60, 0);
    b.reset(2000);
    try testing.expectEqual(@as(u64, 60), b.tokens);
    try testing.expectEqual(@as(u64, 2000), b.last_refill_ms);
    try testing.expectEqual(@as(u64, 0), b.refill_residual);
}

test "high rate does not overflow the scaled multiplication" {
    // 1 million tok/sec; check that 1 hour worth of refill doesn't bork.
    var b = TokenBucket.init(100, 1_000_000);
    _ = b.tryConsume(100, 0);
    b.refill(3_600_000); // 1 hour later
    try testing.expectEqual(@as(u64, 100), b.tokens); // capped at capacity
}

test "zero refill rate means once-empty stays empty" {
    var b = TokenBucket.init(10, 0);
    _ = b.tryConsume(10, 0);
    b.refill(1_000_000); // any amount of time later
    try testing.expectEqual(@as(u64, 0), b.tokens);
}
