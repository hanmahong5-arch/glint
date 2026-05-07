//! Cart-author RNG API (Phase 2c — randomness).
//!
//! Two bindings:
//!   rnd([n])   float in [0, n) (default n=1; matches Pico-8 semantics)
//!   srand(s)   reseed the per-cart RNG; s is coerced to u32
//!
//! State plumbing: each CartContext owns one `Xorshift32` (runtime/rng.zig).
//! It's deterministic, host-independent, single-threaded — the contract
//! the replay harness relies on. Cart authors that want integer values
//! in [0, n) write `flr(rnd(n))`, the Pico-8 idiom, rather than us
//! adding a separate integer-rnd binding.
//!
//! Why a per-cart RNG instead of a global state: rollback netcode (v1.5)
//! needs to be able to re-seed mid-frame to replay deterministically; a
//! global PRNG would couple unrelated carts. Per-cart isolation matches
//! the Engine kernel's "one cart, one VM, one budget" mental model.

const std = @import("std");
const zlua = @import("zlua");
const rng_mod = @import("../runtime/rng.zig");
const VM = @import("vm.zig").VM;
const CartContext = @import("cart_ctx.zig").CartContext;

pub fn register(vm: *VM, ctx: *CartContext) void {
    bindCtx(vm, "rnd", ctx, c_rnd);
    bindCtx(vm, "srand", ctx, c_srand);
}

fn bindCtx(vm: *VM, name: [:0]const u8, ctx: *anyopaque, fnptr: zlua.CFn) void {
    vm.lua.pushLightUserdata(ctx);
    vm.lua.pushClosure(fnptr, 1);
    vm.lua.setGlobal(name);
}

fn ctxFrom(lua: *zlua.Lua) *CartContext {
    const idx = zlua.Lua.upvalueIndex(1);
    return lua.toUserdata(CartContext, idx) catch @panic("rng binding lost CartContext upvalue");
}

/// Coerce a Lua-supplied value to the u32 seed input the xorshift expects.
/// Negative or non-integer floats wrap via two's-complement to the same
/// bit pattern Lua/Luau already uses for integer-of-float coercion.
fn coerceSeed(v: f64) u32 {
    if (std.math.isNan(v)) return 0;
    const trunc = @as(i64, @intFromFloat(@trunc(v)));
    const low: i32 = @truncate(trunc);
    return @bitCast(low);
}

fn c_rnd(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const argc = lua.getTop();
    const u = ctx.rng.nextFloat(); // [0, 1)
    if (argc >= 1) {
        const n = lua.toNumber(1) catch {
            lua.raiseErrorStr("rnd: limit must be a number", .{});
        };
        lua.pushNumber(u * n);
    } else {
        lua.pushNumber(u);
    }
    return 1;
}

fn c_srand(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const seed_f = lua.toNumber(1) catch {
        lua.raiseErrorStr("srand: seed must be a number", .{});
    };
    ctx.rng.reseed(coerceSeed(seed_f));
    return 0;
}

// ---------------- tests ----------------

const testing = std.testing;
const pixel = @import("../runtime/pixel.zig");
const input = @import("../runtime/input.zig");

fn freshSetup(fb: *pixel.Framebuffer, inp: *input.State, seed: u32) struct { vm: VM, ctx: CartContext } {
    const vm = VM.init(testing.allocator) catch unreachable;
    const ctx: CartContext = .{
        .fb = fb,
        .inp = inp,
        .rng = rng_mod.Xorshift32.init(seed),
    };
    return .{ .vm = vm, .ctx = ctx };
}

test "rnd() returns a number in [0, 1)" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var s = freshSetup(&fb, &inp, 42);
    defer s.vm.deinit();
    s.ctx.registerApi(&s.vm);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const v = try s.vm.evalNumber("return rnd()");
        try testing.expect(v >= 0.0);
        try testing.expect(v < 1.0);
    }
}

test "rnd(n) scales the result to [0, n)" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var s = freshSetup(&fb, &inp, 42);
    defer s.vm.deinit();
    s.ctx.registerApi(&s.vm);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const v = try s.vm.evalNumber("return rnd(128)");
        try testing.expect(v >= 0.0);
        try testing.expect(v < 128.0);
    }
}

test "same seed produces same sequence" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};

    var s1 = freshSetup(&fb, &inp, 42);
    defer s1.vm.deinit();
    s1.ctx.registerApi(&s1.vm);
    const a1 = try s1.vm.evalNumber("return rnd()");
    const b1 = try s1.vm.evalNumber("return rnd()");

    var s2 = freshSetup(&fb, &inp, 42);
    defer s2.vm.deinit();
    s2.ctx.registerApi(&s2.vm);
    const a2 = try s2.vm.evalNumber("return rnd()");
    const b2 = try s2.vm.evalNumber("return rnd()");

    try testing.expectEqual(a1, a2);
    try testing.expectEqual(b1, b2);
}

test "srand resets the sequence" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var s = freshSetup(&fb, &inp, 1);
    defer s.vm.deinit();
    s.ctx.registerApi(&s.vm);

    try s.vm.exec("srand(99)");
    const a = try s.vm.evalNumber("return rnd()");
    try s.vm.exec("srand(99)");
    const b = try s.vm.evalNumber("return rnd()");
    try testing.expectEqual(a, b);
}

test "rnd wrong-type limit raises Lua error" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var s = freshSetup(&fb, &inp, 1);
    defer s.vm.deinit();
    s.ctx.registerApi(&s.vm);
    try testing.expectError(error.RuntimeError, s.vm.exec("rnd('not a number')"));
}

test "srand 0 is salted (xorshift never gets stuck on zero)" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var s = freshSetup(&fb, &inp, 1);
    defer s.vm.deinit();
    s.ctx.registerApi(&s.vm);
    try s.vm.exec("srand(0)");
    const v1 = try s.vm.evalNumber("return rnd()");
    const v2 = try s.vm.evalNumber("return rnd()");
    try testing.expect(v1 != 0.0 or v2 != 0.0); // at least one must be non-zero
    try testing.expect(v1 != v2);
}
