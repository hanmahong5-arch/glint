//! Per-cart runtime context.
//!
//! A `CartContext` holds every piece of engine state that the cart-author
//! API needs to manipulate during a frame: the framebuffer, the input
//! state, the per-cart RNG, etc. (Currently just the framebuffer; input
//! and RNG land in Phase 2c.)
//!
//! WHY a single struct: every Lua C-callback needs to pull engine state
//! out of the Lua VM. Using one well-defined context pointer (passed via
//! `lua_pushcclosurek`'s upvalue slot) keeps the binding code uniform —
//! every `c_*` function fetches its `*CartContext` the same way and then
//! reads/writes the named fields. Adding a new piece of cart state (e.g.,
//! the AI inbox) is a one-line change here, not a rewrite of every
//! binding.
//!
//! Lifetime: the engine owns the framebuffer + input state and passes
//! pointers in. The CartContext borrows for the duration of a cart run.

const std = @import("std");
const pixel = @import("../runtime/pixel.zig");
const input = @import("../runtime/input.zig");
const rng_mod = @import("../runtime/rng.zig");
const VM = @import("vm.zig").VM;
const api = @import("api.zig");
const api_gfx = @import("api_gfx.zig");
const api_input = @import("api_input.zig");
const api_rng = @import("api_rng.zig");

pub const CartContext = struct {
    /// 128x128 indexed framebuffer. Cart's `cls` / `pset` write here; the
    /// engine reads this every frame, palette-translates to RGBA8, and
    /// uploads to the GPU (engine/window.zig).
    fb: *pixel.Framebuffer,

    /// Per-frame keyboard state. Engine refreshes via input.beginFrame()
    /// before calling _update; cart reads via btn() / btnp().
    inp: *input.State,

    /// Per-cart deterministic xorshift32 PRNG (rnd / srand bindings).
    /// Stored by value so each cart gets an isolated, savable RNG state.
    rng: rng_mod.Xorshift32,

    /// Install every cart-author binding on `vm` with `self` as the
    /// shared context. Math bindings are stateless and registered first;
    /// the rest reach engine state through this context via Lua closure
    /// upvalues.
    pub fn registerApi(self: *CartContext, vm: *VM) void {
        api.registerMath(vm);
        api_gfx.register(vm, self);
        api_input.register(vm, self);
        api_rng.register(vm, self);
    }
};
