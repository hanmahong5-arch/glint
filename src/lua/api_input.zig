//! Cart-author input API (Phase 2c — keyboard).
//!
//! Two bindings:
//!   btn(b)   true if logical button `b` is held this frame
//!   btnp(b)  true if logical button `b` was pressed this frame (rising edge)
//!
//! Button index follows runtime/input.zig:
//!   0 left, 1 right, 2 up, 3 down, 4 a, 5 b, 6 x, 7 y
//!
//! Out-of-range button indices return false (silent — cart authors hit
//! this when typoing button numbers; don't crash, don't error).
//!
//! State plumbing: bindings reach into `*CartContext.inp`, which the
//! engine's window loop refreshes via input.beginFrame() before calling
//! the cart's _update each frame. Headless runs (`glint run`) leave the
//! State zero — btn / btnp always return false there, which is correct.

const std = @import("std");
const zlua = @import("zlua");
const input = @import("../runtime/input.zig");
const VM = @import("vm.zig").VM;
const CartContext = @import("cart_ctx.zig").CartContext;

pub fn register(vm: *VM, ctx: *CartContext) void {
    bindCtx(vm, "btn", ctx, c_btn);
    bindCtx(vm, "btnp", ctx, c_btnp);
}

fn bindCtx(vm: *VM, name: [:0]const u8, ctx: *anyopaque, fnptr: zlua.CFn) void {
    vm.lua.pushLightUserdata(ctx);
    vm.lua.pushClosure(fnptr, 1);
    vm.lua.setGlobal(name);
}

fn ctxFrom(lua: *zlua.Lua) *CartContext {
    const idx = zlua.Lua.upvalueIndex(1);
    return lua.toUserdata(CartContext, idx) catch @panic("input binding lost CartContext upvalue");
}

/// Decode a Lua-supplied button number into the engine's Button enum.
/// Out-of-range values return null so the caller can short-circuit
/// without raising a Lua error (cart authors expect btn(99) to just
/// return false rather than crash their game).
fn parseButton(v: f64) ?input.Button {
    if (std.math.isNan(v)) return null;
    const i: i32 = @intFromFloat(@floor(v));
    if (i < 0 or i > 7) return null;
    return @enumFromInt(@as(u3, @intCast(i)));
}

fn c_btn(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const b_f = lua.toNumber(1) catch {
        lua.raiseErrorStr("btn: button index must be a number", .{});
    };
    const button = parseButton(b_f) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    lua.pushBoolean(ctx.inp.isHeld(button));
    return 1;
}

fn c_btnp(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const b_f = lua.toNumber(1) catch {
        lua.raiseErrorStr("btnp: button index must be a number", .{});
    };
    const button = parseButton(b_f) orelse {
        lua.pushBoolean(false);
        return 1;
    };
    lua.pushBoolean(ctx.inp.wasPressed(button));
    return 1;
}

// ---------------- tests ----------------

const testing = std.testing;
const pixel = @import("../runtime/pixel.zig");
const rng_mod = @import("../runtime/rng.zig");

fn freshSetup(fb: *pixel.Framebuffer, inp: *input.State) struct { vm: VM, ctx: CartContext } {
    const vm = VM.init(testing.allocator) catch unreachable;
    const ctx: CartContext = .{
        .fb = fb,
        .inp = inp,
        .rng = rng_mod.Xorshift32.init(1),
    };
    return .{ .vm = vm, .ctx = ctx };
}

test "btn returns false when no button held" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var s = freshSetup(&fb, &inp);
    defer s.vm.deinit();
    s.ctx.registerApi(&s.vm);
    inline for (.{ 0, 1, 2, 3, 4, 5, 6, 7 }) |i| {
        const src = std.fmt.comptimePrint("return btn({d})", .{i});
        try testing.expectEqual(@as(i64, 0), try s.vm.evalInt(src ++ " and 1 or 0"));
    }
}

test "btn returns true for held buttons" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    // Simulate Z (button 'a' = 4) held.
    inp.held = (@as(u8, 1) << 4);
    var s = freshSetup(&fb, &inp);
    defer s.vm.deinit();
    s.ctx.registerApi(&s.vm);
    try testing.expectEqual(@as(i64, 1), try s.vm.evalInt("return btn(4) and 1 or 0"));
    try testing.expectEqual(@as(i64, 0), try s.vm.evalInt("return btn(0) and 1 or 0"));
}

test "btnp fires only on rising edge" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var s = freshSetup(&fb, &inp);
    defer s.vm.deinit();
    s.ctx.registerApi(&s.vm);

    // Frame 1: Z down for the first time.
    input.updateOnKeyDown(&inp, .Z);
    input.beginFrame(&inp);
    try testing.expectEqual(@as(i64, 1), try s.vm.evalInt("return btnp(4) and 1 or 0"));

    // Frame 2: Z still held; rising-edge mask must clear.
    input.beginFrame(&inp);
    try testing.expectEqual(@as(i64, 0), try s.vm.evalInt("return btnp(4) and 1 or 0"));
    try testing.expectEqual(@as(i64, 1), try s.vm.evalInt("return btn(4) and 1 or 0"));
}

test "btn out-of-range index returns false (silent)" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    inp.held = 0xFF; // every button held
    var s = freshSetup(&fb, &inp);
    defer s.vm.deinit();
    s.ctx.registerApi(&s.vm);
    try testing.expectEqual(@as(i64, 0), try s.vm.evalInt("return btn(99) and 1 or 0"));
    try testing.expectEqual(@as(i64, 0), try s.vm.evalInt("return btn(-1) and 1 or 0"));
}

test "btn wrong-type arg raises Lua error" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var s = freshSetup(&fb, &inp);
    defer s.vm.deinit();
    s.ctx.registerApi(&s.vm);
    try testing.expectError(error.RuntimeError, s.vm.exec("btn('left')"));
}
