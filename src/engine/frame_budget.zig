//! Per-frame phase budget tracker.
//!
//! Implements the budget enforcement contract from dx-spec §B.1: the
//! engine must complete each phase of frame work within a documented
//! nanosecond budget so that 60Hz pacing is consistent. This module
//! records per-phase nanoseconds, exposes a 6-frame moving-average for
//! the graphics-shed decision (§B.7), and feeds the dev panel HUD.
//!
//! Per dx-spec §B.7, logic frames are sacred: when budgets are blown
//! the engine drops graphics-side work (panel rendering -> _draw skip
//! every other frame -> palette dithering off) before it ever touches
//! `_update`. The tracker here surfaces the data; the policy (when to
//! shed) lives in engine/core.zig once that arrives.

const std = @import("std");

pub const Phase = enum(u4) {
    input_dispatch = 0,
    net_resimulate = 1, // v1.5; 0 budget in v1
    lua_update = 2,
    ai_worker_sync = 3,
    lua_draw = 4,
    audio_mix = 5,
    gpu_present = 6,
    dev_panel = 7,
};

pub const PHASE_COUNT: usize = 8;

/// Hard frame budget per dx-spec §B.1 (1/60 second).
pub const FRAME_BUDGET_NS: u64 = 16_666_667;

/// Per-phase target budget in nanoseconds. Index by @intFromEnum(Phase).
/// Sum equals FRAME_BUDGET_NS minus 3.17ms slack. See dx-spec §B.1 for the
/// rationale behind each number.
pub const PHASE_BUDGET_NS: [PHASE_COUNT]u64 = .{
    100_000, // input_dispatch:  100 us
    2_000_000, // net_resimulate:  2.0 ms (0 in v1; reserved for v1.5)
    6_000_000, // lua_update:      6.0 ms
    300_000, // ai_worker_sync:  300 us
    2_000_000, // lua_draw:        2.0 ms
    800_000, // audio_mix:       800 us
    2_000_000, // gpu_present:    2.0 ms
    300_000, // dev_panel:      300 us
};

pub const HISTORY_FRAMES: usize = 6;

/// Tracks per-phase nanoseconds for the current frame plus the last
/// HISTORY_FRAMES. The caller drives by calling beginPhase / endPhase
/// around each block of work and endFrame once at the end of the render
/// loop.
pub const Tracker = struct {
    /// Nanoseconds spent in each phase this frame. Index by Phase.
    current: [PHASE_COUNT]u64 = [_]u64{0} ** PHASE_COUNT,
    /// Ring buffer of past frames' totals.
    history: [HISTORY_FRAMES][PHASE_COUNT]u64 = .{[_]u64{0} ** PHASE_COUNT} ** HISTORY_FRAMES,
    /// Index into `history` for the next write.
    history_idx: usize = 0,
    /// Set to true once history has wrapped at least once; before that,
    /// historicalAverageTotal divides only by samples_filled.
    samples_filled: usize = 0,

    /// Monotonic ns timestamp captured by the most recent beginPhase().
    /// Caller-supplied so this module stays clock-agnostic; the engine
    /// (engine/window.zig) reads from std.Io.Clock and passes ns in.
    last_begin_ns: u64 = 0,
    active_phase: ?Phase = null,

    /// Begin timing a phase. If a different phase is already active, ends
    /// it first (re-entrancy is treated as a usage bug, not a crash).
    /// `now_ns` is a monotonic timestamp the caller pulled from its
    /// chosen clock (Io.Clock.Timestamp.now(.monotonic) in production;
    /// hand-injected values in tests).
    pub fn beginPhase(self: *Tracker, phase: Phase, now_ns: u64) void {
        if (self.active_phase != null) self.endPhase(now_ns);
        self.active_phase = phase;
        self.last_begin_ns = now_ns;
    }

    /// End the active phase; record (now_ns - last_begin_ns) into
    /// `current`. No-op if no phase is active so callers can be sloppy
    /// about pairing. Saturating subtraction so a non-monotonic clock
    /// glitch (rare; defensive) doesn't underflow into a huge count.
    pub fn endPhase(self: *Tracker, now_ns: u64) void {
        const phase = self.active_phase orelse return;
        const elapsed = now_ns -| self.last_begin_ns;
        const idx = @intFromEnum(phase);
        self.current[idx] +|= elapsed;
        self.active_phase = null;
    }

    /// Roll `current` into history; reset `current` to zero. Call once per
    /// rendered frame, after all phases have been ended.
    pub fn endFrame(self: *Tracker) void {
        self.history[self.history_idx] = self.current;
        self.history_idx = (self.history_idx + 1) % HISTORY_FRAMES;
        if (self.samples_filled < HISTORY_FRAMES) self.samples_filled += 1;
        self.current = [_]u64{0} ** PHASE_COUNT;
    }

    /// Total nanoseconds spent in all phases this frame so far.
    pub fn currentTotal(self: Tracker) u64 {
        var sum: u64 = 0;
        for (self.current) |v| sum +|= v;
        return sum;
    }

    /// Mean total nanoseconds per frame across the (last) HISTORY_FRAMES.
    /// Returns 0 before the first frame closes.
    pub fn historicalAverageTotal(self: Tracker) u64 {
        if (self.samples_filled == 0) return 0;
        var sum: u64 = 0;
        for (self.history[0..self.samples_filled]) |frame| {
            for (frame) |v| sum +|= v;
        }
        return sum / @as(u64, self.samples_filled);
    }

    /// True when the moving average exceeds the hard frame budget.
    /// engine/core.zig consults this to enter graphics-shed mode.
    pub fn isOverBudget(self: Tracker) bool {
        return self.historicalAverageTotal() > FRAME_BUDGET_NS;
    }

    /// Per-phase recent average. Returns 0 if no samples yet.
    pub fn averageForPhase(self: Tracker, phase: Phase) u64 {
        if (self.samples_filled == 0) return 0;
        const idx = @intFromEnum(phase);
        var sum: u64 = 0;
        for (self.history[0..self.samples_filled]) |frame| sum +|= frame[idx];
        return sum / @as(u64, self.samples_filled);
    }
};

// ---------- tests ----------

const testing = std.testing;

test "PHASE_BUDGET_NS sums fit within FRAME_BUDGET_NS" {
    var sum: u64 = 0;
    for (PHASE_BUDGET_NS) |b| sum += b;
    try testing.expect(sum < FRAME_BUDGET_NS); // slack is positive
    // Per dx-spec §B.1, slack is around 3.17 ms.
    const slack = FRAME_BUDGET_NS - sum;
    try testing.expect(slack > 2_500_000);
    try testing.expect(slack < 4_000_000);
}

test "fresh tracker has zero current and zero history" {
    var t: Tracker = .{};
    try testing.expectEqual(@as(u64, 0), t.currentTotal());
    try testing.expectEqual(@as(u64, 0), t.historicalAverageTotal());
    try testing.expect(!t.isOverBudget());
}

test "begin/end phase records time from injected timestamps" {
    var t: Tracker = .{};
    t.beginPhase(.lua_update, 0);
    t.endPhase(1_000_000); // simulate 1 ms wall time
    try testing.expectEqual(@as(u64, 1_000_000), t.current[@intFromEnum(Phase.lua_update)]);
}

test "non-monotonic clock glitch saturates to zero rather than underflowing" {
    var t: Tracker = .{};
    t.beginPhase(.lua_update, 1_000_000);
    // now_ns went BACKWARDS (rare clock-skew; defensive). Saturating
    // subtraction guarantees we record 0, not 2^64 - delta.
    t.endPhase(500_000);
    try testing.expectEqual(@as(u64, 0), t.current[@intFromEnum(Phase.lua_update)]);
}

test "endFrame rolls current into history and resets" {
    var t: Tracker = .{};
    t.current[@intFromEnum(Phase.lua_update)] = 5_000_000;
    t.endFrame();
    try testing.expectEqual(@as(u64, 0), t.current[@intFromEnum(Phase.lua_update)]);
    try testing.expectEqual(@as(u64, 5_000_000), t.history[0][@intFromEnum(Phase.lua_update)]);
    try testing.expectEqual(@as(usize, 1), t.samples_filled);
}

test "historicalAverageTotal returns mean of HISTORY_FRAMES" {
    var t: Tracker = .{};
    // Fill with 6 frames, each with lua_update = 1ms, gpu_present = 2ms.
    var i: usize = 0;
    while (i < HISTORY_FRAMES) : (i += 1) {
        t.current[@intFromEnum(Phase.lua_update)] = 1_000_000;
        t.current[@intFromEnum(Phase.gpu_present)] = 2_000_000;
        t.endFrame();
    }
    try testing.expectEqual(@as(usize, HISTORY_FRAMES), t.samples_filled);
    try testing.expectEqual(@as(u64, 3_000_000), t.historicalAverageTotal());
    try testing.expectEqual(@as(u64, 1_000_000), t.averageForPhase(.lua_update));
    try testing.expectEqual(@as(u64, 2_000_000), t.averageForPhase(.gpu_present));
}

test "isOverBudget triggers when average exceeds frame budget" {
    var t: Tracker = .{};
    var i: usize = 0;
    while (i < HISTORY_FRAMES) : (i += 1) {
        t.current[@intFromEnum(Phase.lua_update)] = FRAME_BUDGET_NS + 1_000_000;
        t.endFrame();
    }
    try testing.expect(t.isOverBudget());
}

test "ring buffer wraps after HISTORY_FRAMES" {
    var t: Tracker = .{};
    var i: usize = 0;
    while (i < HISTORY_FRAMES * 2 + 3) : (i += 1) {
        t.current[@intFromEnum(Phase.lua_update)] = @as(u64, @intCast(i)) * 100_000;
        t.endFrame();
    }
    // After 2*HISTORY_FRAMES+3 endFrame calls, samples_filled is capped.
    try testing.expectEqual(@as(usize, HISTORY_FRAMES), t.samples_filled);
    // history_idx is at (2*HISTORY_FRAMES+3) mod HISTORY_FRAMES = 3.
    try testing.expectEqual(@as(usize, 3), t.history_idx);
}

test "begin without paired end is auto-ended on next begin" {
    var t: Tracker = .{};
    t.beginPhase(.lua_update, 0);
    // Don't end. Begin another phase; tracker should auto-finalize
    // lua_update at the second beginPhase's `now_ns`.
    t.beginPhase(.lua_draw, 500_000);
    try testing.expectEqual(@as(u64, 500_000), t.current[@intFromEnum(Phase.lua_update)]);
    t.endPhase(700_000);
    try testing.expectEqual(@as(u64, 200_000), t.current[@intFromEnum(Phase.lua_draw)]);
}
