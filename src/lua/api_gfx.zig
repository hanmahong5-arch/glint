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
const draw = @import("../runtime/draw.zig");
const VM = @import("vm.zig").VM;
const CartContext = @import("cart_ctx.zig").CartContext;

/// Register the gfx bindings on `vm` with `ctx` as the shared context.
/// Each binding gets `ctx` as a single light-userdata upvalue.
pub fn register(vm: *VM, ctx: *CartContext) void {
    bindCtx(vm, "cls", ctx, c_cls);
    bindCtx(vm, "pset", ctx, c_pset);
    bindCtx(vm, "pget", ctx, c_pget);
    bindCtx(vm, "line", ctx, c_line);
    bindCtx(vm, "rect", ctx, c_rect);
    bindCtx(vm, "rectfill", ctx, c_rectfill);
    bindCtx(vm, "circ", ctx, c_circ);
    bindCtx(vm, "circfill", ctx, c_circfill);
    bindCtx(vm, "camera", ctx, c_camera);
}

/// Translate a world-space x to screen-space by subtracting the camera
/// offset. Camera offset is 0 by default so this is a no-op until the
/// cart calls camera(x, y).
inline fn screenX(ctx: *const CartContext, world: i32) i32 {
    return world - ctx.cam_x;
}

inline fn screenY(ctx: *const CartContext, world: i32) i32 {
    return world - ctx.cam_y;
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

/// Pull a number from the Lua stack and floor-truncate to i32. Used
/// uniformly for coordinate args across line/rect/circ.
fn intArg(lua: *zlua.Lua, idx: i32, comptime fn_name: []const u8, comptime arg_name: []const u8) i32 {
    const v = lua.toNumber(idx) catch {
        lua.raiseErrorStr(fn_name ++ ": " ++ arg_name ++ " must be a number", .{});
    };
    if (std.math.isNan(v)) return 0;
    return @intFromFloat(@floor(v));
}

/// Read the optional "color" argument at slot `idx`. Returns 0 when the
/// slot is empty. Out-of-range numbers clamp into [0, 15] like cls/pset.
fn optColor(lua: *zlua.Lua, idx: i32, argc: i32) u4 {
    if (argc < idx) return 0;
    return paletteIdx(lua.toNumber(idx) catch 0);
}

/// line(x0, y0, x1, y1[, c]): Bresenham line, OOB silent-clamped.
/// Coordinates are world-space; the camera offset is subtracted here.
fn c_line(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const argc = lua.getTop();
    const x0 = screenX(ctx, intArg(lua, 1, "line", "x0"));
    const y0 = screenY(ctx, intArg(lua, 2, "line", "y0"));
    const x1 = screenX(ctx, intArg(lua, 3, "line", "x1"));
    const y1 = screenY(ctx, intArg(lua, 4, "line", "y1"));
    const color = optColor(lua, 5, argc);
    draw.line(ctx.fb, x0, y0, x1, y1, color);
    return 0;
}

/// rect(x0, y0, x1, y1[, c]): rectangle outline. World-space coords.
fn c_rect(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const argc = lua.getTop();
    const x0 = screenX(ctx, intArg(lua, 1, "rect", "x0"));
    const y0 = screenY(ctx, intArg(lua, 2, "rect", "y0"));
    const x1 = screenX(ctx, intArg(lua, 3, "rect", "x1"));
    const y1 = screenY(ctx, intArg(lua, 4, "rect", "y1"));
    const color = optColor(lua, 5, argc);
    draw.rect(ctx.fb, x0, y0, x1, y1, color);
    return 0;
}

/// rectfill(x0, y0, x1, y1[, c]): filled rectangle. World-space coords.
fn c_rectfill(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const argc = lua.getTop();
    const x0 = screenX(ctx, intArg(lua, 1, "rectfill", "x0"));
    const y0 = screenY(ctx, intArg(lua, 2, "rectfill", "y0"));
    const x1 = screenX(ctx, intArg(lua, 3, "rectfill", "x1"));
    const y1 = screenY(ctx, intArg(lua, 4, "rectfill", "y1"));
    const color = optColor(lua, 5, argc);
    draw.rectFill(ctx.fb, x0, y0, x1, y1, color);
    return 0;
}

/// circ(x, y, r[, c]): circle outline (Pico-8 spelling). World-space
/// center coords; radius is a length so it's NOT camera-translated.
fn c_circ(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const argc = lua.getTop();
    const x = screenX(ctx, intArg(lua, 1, "circ", "x"));
    const y = screenY(ctx, intArg(lua, 2, "circ", "y"));
    const r = intArg(lua, 3, "circ", "r");
    const color = optColor(lua, 4, argc);
    draw.circle(ctx.fb, x, y, r, color);
    return 0;
}

/// circfill(x, y, r[, c]): filled circle. World-space center, length r.
fn c_circfill(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const argc = lua.getTop();
    const x = screenX(ctx, intArg(lua, 1, "circfill", "x"));
    const y = screenY(ctx, intArg(lua, 2, "circfill", "y"));
    const r = intArg(lua, 3, "circfill", "r");
    const color = optColor(lua, 4, argc);
    draw.circleFill(ctx.fb, x, y, r, color);
    return 0;
}

/// pset(x, y[, c]): set framebuffer pixel at world-space (x, y) to
/// palette index c (default 0). Camera offset subtracted to land in
/// the framebuffer's [0, 128) screen space; OOB pixels silently drop.
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

    if (std.math.isNan(x_f) or std.math.isNan(y_f)) return 0;
    const x_w: i32 = @intFromFloat(@floor(x_f));
    const y_w: i32 = @intFromFloat(@floor(y_f));
    const x_s = screenX(ctx, x_w);
    const y_s = screenY(ctx, y_w);
    if (x_s < 0 or y_s < 0) return 0;
    if (x_s >= pixel.Framebuffer.WIDTH or y_s >= pixel.Framebuffer.HEIGHT) return 0;
    ctx.fb.set(@intCast(x_s), @intCast(y_s), color);
    return 0;
}

/// pget(x, y) -> color: read the palette index at world-space (x, y).
/// Returns 0 for out-of-bounds reads (Pico-8 convention) so cart code
/// can blindly query without bounds-checking.
fn c_pget(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const x_w = intArg(lua, 1, "pget", "x");
    const y_w = intArg(lua, 2, "pget", "y");
    const x_s = screenX(ctx, x_w);
    const y_s = screenY(ctx, y_w);
    if (x_s < 0 or y_s < 0 or x_s >= pixel.Framebuffer.WIDTH or y_s >= pixel.Framebuffer.HEIGHT) {
        lua.pushInteger(0);
        return 1;
    }
    const c = ctx.fb.get(@intCast(x_s), @intCast(y_s));
    lua.pushInteger(@intCast(c));
    return 1;
}

/// camera([x][, y]): set world->screen translation. With no args, both
/// reset to 0. Subsequent draw calls subtract this offset, so drawing
/// at world coords (cam_x, cam_y) lands at screen origin (0, 0).
fn c_camera(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const argc = lua.getTop();
    if (argc == 0) {
        ctx.cam_x = 0;
        ctx.cam_y = 0;
        return 0;
    }
    ctx.cam_x = intArg(lua, 1, "camera", "x");
    ctx.cam_y = if (argc >= 2) intArg(lua, 2, "camera", "y") else 0;
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

test "line() from Lua draws between endpoints" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("line(10, 20, 30, 20, 7)");
    try testing.expectEqual(@as(u4, 7), fb.get(10, 20));
    try testing.expectEqual(@as(u4, 7), fb.get(20, 20));
    try testing.expectEqual(@as(u4, 7), fb.get(30, 20));
    try testing.expectEqual(@as(u4, 0), fb.get(31, 20));
}

test "rect() outline + rectfill() interior" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("rect(5, 5, 15, 15, 9)");
    try testing.expectEqual(@as(u4, 9), fb.get(5, 5));
    try testing.expectEqual(@as(u4, 9), fb.get(15, 15));
    try testing.expectEqual(@as(u4, 0), fb.get(10, 10)); // hole

    try vm.exec("rectfill(20, 20, 30, 30, 11)");
    try testing.expectEqual(@as(u4, 11), fb.get(25, 25));
}

test "circ() and circfill() respect radius" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("circfill(64, 64, 5, 11)");
    try testing.expectEqual(@as(u4, 11), fb.get(64, 64));
    try testing.expectEqual(@as(u4, 11), fb.get(64, 60));
    try testing.expectEqual(@as(u4, 0), fb.get(64, 70));
}

test "default color (omitted argument) is 0" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(7); // pre-fill non-zero
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("rectfill(0, 0, 10, 10)"); // no color arg -> default 0
    try testing.expectEqual(@as(u4, 0), fb.get(5, 5));
    try testing.expectEqual(@as(u4, 7), fb.get(50, 50)); // outside rect untouched
}

test "pget reads what pset wrote" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("pset(40, 50, 9)");
    const c = try vm.evalInt("return pget(40, 50)");
    try testing.expectEqual(@as(i64, 9), c);
}

test "pget out-of-bounds returns 0" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(11);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    // Fully OOB negative + past-edge: must return 0, not crash.
    try testing.expectEqual(@as(i64, 0), try vm.evalInt("return pget(-1, 0)"));
    try testing.expectEqual(@as(i64, 0), try vm.evalInt("return pget(0, -1)"));
    try testing.expectEqual(@as(i64, 0), try vm.evalInt("return pget(128, 0)"));
    try testing.expectEqual(@as(i64, 0), try vm.evalInt("return pget(0, 128)"));
}

test "camera shifts world coords; pset(cam_x, cam_y) lands at screen origin" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    // After camera(10, 20), world (10, 20) -> screen (0, 0).
    try vm.exec("camera(10, 20); pset(10, 20, 11)");
    try testing.expectEqual(@as(u4, 11), fb.get(0, 0));
    // World (15, 25) -> screen (5, 5).
    try vm.exec("pset(15, 25, 7)");
    try testing.expectEqual(@as(u4, 7), fb.get(5, 5));
}

test "camera() with no args resets the offset" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("camera(50, 50); camera(); pset(0, 0, 11)");
    // After reset, world (0, 0) -> screen (0, 0).
    try testing.expectEqual(@as(u4, 11), fb.get(0, 0));
}

test "camera also affects line/rect/circ" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("camera(20, 30); rectfill(20, 30, 24, 34, 11)");
    // Rect at world (20, 30)..(24, 34) -> screen (0, 0)..(4, 4).
    try testing.expectEqual(@as(u4, 11), fb.get(0, 0));
    try testing.expectEqual(@as(u4, 11), fb.get(4, 4));
    try testing.expectEqual(@as(u4, 0), fb.get(5, 5));
}

test "circ radius is unaffected by camera (length, not position)" {
    var fb: pixel.Framebuffer = undefined;
    fb.clear(0);
    var ctx = freshContext(&fb);
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    ctx.registerApi(&vm);
    try vm.exec("camera(60, 60); circfill(64, 64, 3, 11)");
    // Center world (64, 64) -> screen (4, 4); pixels within radius 3.
    try testing.expectEqual(@as(u4, 11), fb.get(4, 4));
    try testing.expectEqual(@as(u4, 11), fb.get(4, 7));
    try testing.expectEqual(@as(u4, 0), fb.get(4, 8));
}
