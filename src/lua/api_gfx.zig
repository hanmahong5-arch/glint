//! Cart-author graphics API (Phase 2b).
//!
//! Stateful bindings that write into the cart's framebuffer. The engine
//! threads its `*CartContext` to each callback via Lua closure upvalues
//! (`pushLightUserdata` + `pushClosure(.., 1)`), so the bindings never
//! reach for thread-local or module-global state — every cart's drawing
//! ends up in its own framebuffer.
//!
//! Functions registered (so far):
//!   cls([c])          fill framebuffer with palette index c (default 0)
//!   pset(x, y[, c])   set one pixel at (x, y); silent-clamp out of bounds
//!
//! Out-of-bounds + out-of-palette inputs follow dx-spec error policy:
//! silent-clamp, never crash. Cart-author surface treats clamping as a
//! feature — sprite blits don't have to range-check before calling pset.

const std = @import("std");
const zlua = @import("zlua");
const pixel = @import("../runtime/pixel.zig");
const input = @import("../runtime/input.zig");
const rng_mod = @import("../runtime/rng.zig");
const VM = @import("vm.zig").VM;
const CartContext = @import("cart_ctx.zig").CartContext;

/// Register the gfx bindings on `vm` with `ctx` as the shared context.
/// Each binding gets `ctx` as a single light-userdata upvalue.
pub fn register(vm: *VM, ctx: *CartContext) void {
    bindCtx(vm, "cls", ctx, c_cls);
    bindCtx(vm, "pset", ctx, c_pset);
}

/// Push `ctx` as a light-userdata then a 1-upvalue closure over `fnptr`,
/// then bind that as a Lua global. The C-callback retrieves `ctx` via
/// `lua_upvalueindex(1)`.
fn bindCtx(vm: *VM, name: [:0]const u8, ctx: *anyopaque, fnptr: zlua.CFn) void {
    vm.lua.pushLightUserdata(ctx);
    vm.lua.pushClosure(fnptr, 1);
    vm.lua.setGlobal(name);
}

fn ctxFrom(lua: *zlua.Lua) *CartContext {
    // The light userdata sat on the stack at upvalue slot 1 when pushClosure
    // was called; touserdata returns its raw pointer. Light userdata isn't
    // typed at the Lua level — the Zig-side upcast is what gives it shape.
    const idx = zlua.Lua.upvalueIndex(1);
    return lua.toUserdata(CartContext, idx) catch @panic("cart-api binding lost its CartContext upvalue");
}

/// Convert a Lua number to a u4 palette index. Out-of-range values silent-
/// clamp into 0..15 per dx-spec error policy.
fn paletteIdx(v: f64) u4 {
    if (std.math.isNan(v)) return 0;
    const i: i32 = @intFromFloat(@floor(v));
    if (i < 0) return 0;
    if (i > 15) return 15;
    return @as(u4, @intCast(i));
}

/// cls([c]): clear the framebuffer to palette index c (default 0).
fn c_cls(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const argc = lua.getTop();
    const idx: u4 = if (argc >= 1)
        paletteIdx(lua.toNumber(1) catch 0)
    else
        0;
    ctx.fb.clear(idx);
    return 0;
}

/// pset(x, y[, c]): set framebuffer pixel at (x, y) to palette index c
/// (default 0). Coordinates outside [0, 128) are silently dropped.
fn c_pset(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const argc = lua.getTop();
    const x_f = lua.toNumber(1) catch {
        lua.raiseErrorStr("pset: x must be a number", .{});
    };
    const y_f = lua.toNumber(2) catch {
        lua.raiseErrorStr("pset: y must be a number", .{});
    };
    const color: u4 = if (argc >= 3)
        paletteIdx(lua.toNumber(3) catch 0)
    else
        0;

    // Out-of-bounds: silent-clamp via Framebuffer.set's own contract.
    // Cart authors rely on pset never crashing.
    if (std.math.isNan(x_f) or std.math.isNan(y_f)) return 0;
    const x_i: i32 = @intFromFloat(@floor(x_f));
    const y_i: i32 = @intFromFloat(@floor(y_f));
    if (x_i < 0 or y_i < 0) return 0;
    if (x_i >= pixel.Framebuffer.WIDTH or y_i >= pixel.Framebuffer.HEIGHT) return 0;
    ctx.fb.set(@intCast(x_i), @intCast(y_i), color);
    return 0;
}

// ---------------- tests ----------------

const testing = std.testing;

/// Test helper: build a CartContext with a stub input + RNG. Uses a
/// thread-local input.State so each test gets independent button state.
threadlocal var test_inp: input.State = .{};

fn freshContext(fb: *pixel.Framebuffer) CartContext {
    test_inp = .{};
    return .{ .fb = fb, .inp = &test_inp, .rng = rng_mod.Xorshift32.init(1) };
}

test "cls() defaults to color 0" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(15);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("cls()");
    try testing.expectEqual(@as(u4, 0), fb.get(0, 0));
    try testing.expectEqual(@as(u4, 0), fb.get(64, 64));
    try testing.expectEqual(@as(u4, 0), fb.get(127, 127));
}

test "cls(c) fills the framebuffer with the given palette index" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("cls(7)");
    try testing.expectEqual(@as(u4, 7), fb.get(10, 10));
    try testing.expectEqual(@as(u4, 7), fb.get(127, 0));
}

test "cls clamps out-of-range color to 0..15" {
    var fb: pixel.Framebuffer = undefined;
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("cls(99)");
    try testing.expectEqual(@as(u4, 15), fb.get(0, 0));
    try vm.exec("cls(-1)");
    try testing.expectEqual(@as(u4, 0), fb.get(0, 0));
}

test "pset writes a single pixel and leaves neighbors alone" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("pset(10, 20, 11)");
    try testing.expectEqual(@as(u4, 11), fb.get(10, 20));
    try testing.expectEqual(@as(u4, 0), fb.get(11, 20));
    try testing.expectEqual(@as(u4, 0), fb.get(10, 21));
}

test "pset out-of-bounds is silently dropped" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("pset(-5, -5, 11)");
    try vm.exec("pset(200, 200, 11)");
    try vm.exec("pset(127, 127, 11)"); // edge in-bounds
    try testing.expectEqual(@as(u4, 0), fb.get(0, 0));
    try testing.expectEqual(@as(u4, 11), fb.get(127, 127));
}

test "pset float coordinates are floored" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("pset(3.9, 4.1, 11)");
    try testing.expectEqual(@as(u4, 11), fb.get(3, 4));
}

test "pset wrong-type x raises a Lua error, not engine panic" {
    var fb: pixel.Framebuffer = undefined;
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try testing.expectError(error.RuntimeError, vm.exec("pset('not a number', 0, 1)"));
}

test "cart code can compose cls + pset over multiple calls" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    // A "frame": clear to bruise (15), then plot a small horizontal line.
    try vm.exec(
        \\cls(15)
        \\for i = 0, 9 do
        \\  pset(i, 64, 11)
        \\end
    );
    try testing.expectEqual(@as(u4, 15), fb.get(0, 0));
    try testing.expectEqual(@as(u4, 11), fb.get(0, 64));
    try testing.expectEqual(@as(u4, 11), fb.get(9, 64));
    try testing.expectEqual(@as(u4, 15), fb.get(10, 64));
}

test "math + gfx bindings co-exist on the same VM" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    // Use a math binding to compute a coordinate, then pset.
    try vm.exec("pset(flr(1.5 + 2.5), 4, 11)");
    try testing.expectEqual(@as(u4, 11), fb.get(4, 4));
}
