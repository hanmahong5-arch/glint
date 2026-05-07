//! glint — fantasy console engine library (public API surface)
//!
//! This is the "library" face of the engine. The CLI in src/main.zig is one
//! consumer; future embedders (cart marketplace web service, modders, IDE
//! plugins) are others. Keep this module's public surface tight so that
//! consumers do not couple to internals.
//!
//! Internal modules (one per top-level directory under src/):
//!   - engine:  frame loop, dev panel, log, capability resolver
//!   - runtime: pixel framebuffer, sprite atlas, input, time
//!   - lua:     ziglua + Luau VM, sandbox, 80-fn cart API binding
//!   - cart:    PNG steganography, manifest TOML, capability validation
//!   - ai:      dlopen llama.cpp, worker thread, streaming inbox, rate limit
//!   - ecs:     zflecs wrapper + helpers
//!   - gfx:     sokol_gfx init, palette LUT shader, integer-scale upscale
//!   - snd:     sokol_audio + 4-channel PSG + .it tracker via libxmp
//!   - replay:  deterministic harness, .crash artifact format
//!
//! As modules come online they will be re-exported here. For now this file
//! advertises the version and the engine error type so downstream code can
//! depend on a stable surface from day one.

const std = @import("std");

/// Project semver. Bump on every release. Pre-1.0 minor bumps may break the
/// cart format; cart manifests pin `min_engine` to refuse loading on older
/// engines.
pub const VERSION = "0.0.1";

/// Open a black demo window via sokol. Blocks until user closes it (Esc).
/// Used by `glint demo` for early-development sanity check.
pub const runDemo = @import("engine/window.zig").runDemo;

/// Open a windowed cart-playback session driving _update / _draw at 60 Hz.
/// Used by `glint play <cart>`. Blocks until user closes (Esc).
pub const runCart = @import("engine/window.zig").runCart;

/// Per-frame phase budget tracker (dx-spec §B.1, drives graphics-shed §B.7).
pub const frame_budget = @import("engine/frame_budget.zig");

/// Crash artifact (.crash) file format: header + TLV body, replay-able.
pub const crash = @import("replay/crash.zig");

/// 128x128 indexed framebuffer + 16-color palette.
pub const pixel = @import("runtime/pixel.zig");

/// 8-button keyboard input abstraction (cart-author surface).
pub const input = @import("runtime/input.zig");

/// xxh3-64 state hashing for replay determinism + dev panel + desync detection.
pub const state_hash = @import("runtime/state_hash.zig");

/// Fixed-step 60Hz accumulator (Glenn Fiedler's "Fix Your Timestep").
pub const time = @import("runtime/time.zig");

/// PICO-8-style PNG steganography for cart carrier images
/// (160x205 RGBA -> 32800 bytes hidden in low 2 bits of each channel).
pub const png_steg = @import("cart/png_steg.zig");

/// Cart binary container format (magic + header + TLV sections + CRC32).
pub const cart_format = @import("cart/format.zig");

/// Cart capability declaration + host-policy resolution (dx-spec §A.4).
pub const capability = @import("cart/capability.zig");

/// Cart manifest (TOML) parser: text -> Manifest struct used by `glint pack`.
pub const manifest = @import("cart/manifest.zig");

/// Sandboxed Luau VM wrapper. One per cart; exposes a curated stdlib subset.
pub const lua_vm = @import("lua/vm.zig");

/// Cart-author API bindings (math + helpers; gfx/input/audio in later phases).
pub const lua_api = @import("lua/api.zig");

/// Cart-author graphics bindings (cls, pset, ...) — depend on CartContext.
pub const lua_api_gfx = @import("lua/api_gfx.zig");

/// Cart-author input bindings (btn, btnp) — depend on CartContext.
pub const lua_api_input = @import("lua/api_input.zig");

/// Cart-author RNG bindings (rnd, srand) — depend on CartContext.
pub const lua_api_rng = @import("lua/api_rng.zig");

/// Per-cart runtime context: shared engine state pointed to by Lua bindings.
pub const cart_ctx = @import("lua/cart_ctx.zig");

/// Token-bucket rate limiter used by the AI router for tokens-per-sec caps.
pub const ai_rate_limit = @import("ai/rate_limit.zig");

/// Deterministic Q16.16 math + sin/cos/atan2/sqrt LUT (no libm in
/// determinism-critical paths; satisfies dx-spec §B.5 case #14).
pub const fixed = @import("runtime/fixed.zig");

/// Deterministic xorshift32 PRNG (cart-author rnd()/srand() backing).
pub const rng = @import("runtime/rng.zig");

/// Cart-author math helpers (mid / lerp / saturate / approachTo / smoothstep).
pub const math = @import("runtime/math.zig");

/// Top-level engine error union. Per project policy library code does not
/// panic; every fallible function returns an error from this set or a
/// caller-injected superset.
pub const EngineError = error{
    /// Out of cart heap budget (declared in manifest [limits]).
    CartOutOfMemory,
    /// Cart binary fails magic / CRC32 / size validation.
    CartFormatInvalid,
    /// Cart's [glint] schema_version not supported by this engine.
    CartSchemaUnsupported,
    /// Cart declared a capability the engine does not recognize.
    CapabilityUnknown,
    /// Cart declared a required capability that host policy denied.
    CapabilityRequiredButDenied,
    /// `_update` produced state hash mismatching replay tape (rollback gate).
    DeterminismViolation,
    /// llama.cpp dlopen failed or model file missing/corrupt.
    AiBackendUnavailable,
    /// Engine called before init() — caller bug.
    EngineNotInitialized,
};

test "version is non-empty and parseable" {
    try std.testing.expect(VERSION.len > 0);
    // crude semver tokenize: at least two dots
    var dot_count: usize = 0;
    for (VERSION) |c| {
        if (c == '.') dot_count += 1;
    }
    try std.testing.expect(dot_count >= 2);
}

test "EngineError set contains expected variants" {
    // Compile-time presence: each named error must be assignable into the set.
    // If a variant is renamed or removed, this test fails at compile time and
    // the public API change is forced through review.
    const a: EngineError = error.CartOutOfMemory;
    const b: EngineError = error.DeterminismViolation;
    const c: EngineError = error.AiBackendUnavailable;
    try std.testing.expect(a != b);
    try std.testing.expect(b != c);
}
