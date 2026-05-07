//! Cart-author AI API (Phase 1 — Mock backend).
//!
//! Bindings under the global `ai` table (so a cart calls
//! `ai.ask(...)` / `ai.poll(...)` matching the README example):
//!
//!   ai.ask(npc, prompt)    enqueue a prompt for the named NPC; non-
//!                          blocking. Cart can call multiple times per
//!                          frame; the worker thread serialises them
//!                          per-NPC, latest-wins.
//!   ai.poll(npc) -> string queries the latest completed response;
//!                          returns nil if no answer has arrived yet
//!                          (cart should branch on nil and fall back
//!                          to placeholder text or skip rendering).
//!
//! Both bindings are no-ops when the cart's CartContext.ai is null
//! (cart did not declare the `ai` capability or host policy denied it).
//! This way carts written for an AI-enabled host don't crash on a
//! plain headless run; they just see ai.poll always returning nil.
//!
//! NPC name is an arbitrary string — the cart picks. Convention: human
//! names ("baker"), role tags ("guard:north_gate"), or freeform.
//!
//! Determinism caveat: see src/ai/router.zig top-of-file. Phase 1
//! reads the live mailbox under a mutex; cross-frame snapshot
//! semantics for replay are deferred to Phase 2.

const std = @import("std");
const zlua = @import("zlua");
const VM = @import("vm.zig").VM;
const CartContext = @import("cart_ctx.zig").CartContext;

pub fn register(vm: *VM, ctx: *CartContext) void {
    // Build a fresh `ai` table on the stack, attach two closures, then
    // assign it to _G.ai. Using a table (rather than two top-level
    // globals like ai_ask / ai_poll) keeps the cart-author surface
    // hierarchical — future ai.spawn / ai.cancel slot in cleanly.
    vm.lua.newTable();
    bindCtxField(vm, ctx, "ask", c_ai_ask);
    bindCtxField(vm, ctx, "poll", c_ai_poll);
    vm.lua.setGlobal("ai");
}

/// Attach a closure-with-context as a field on the table sitting at
/// stack top (the partly-built `ai` table). Mirrors api_input.bindCtx
/// but writes to a table field instead of a global.
fn bindCtxField(vm: *VM, ctx: *anyopaque, field: [:0]const u8, fnptr: zlua.CFn) void {
    vm.lua.pushLightUserdata(ctx);
    vm.lua.pushClosure(fnptr, 1);
    vm.lua.setField(-2, field);
}

fn ctxFrom(lua: *zlua.Lua) *CartContext {
    const idx = zlua.Lua.upvalueIndex(1);
    return lua.toUserdata(CartContext, idx) catch @panic("ai binding lost CartContext upvalue");
}

/// Read a string argument by index. Strict: numbers are NOT coerced
/// (NPC names "1" and 1 should not collide silently — different keys).
/// Raises a Lua error on type mismatch.
fn requireString(lua: *zlua.Lua, idx: i32, fn_name: []const u8, arg_name: []const u8) []const u8 {
    if (!lua.isString(idx)) {
        // Print the expected shape so cart-authors can self-correct
        // without diving into engine internals.
        lua.raiseErrorStr(
            "%s: %s must be a string",
            .{
                fn_name.ptr,
                arg_name.ptr,
            },
        );
    }
    return lua.toStringEx(idx);
}

fn c_ai_ask(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const npc = requireString(lua, 1, "ai.ask", "npc");
    const prompt = requireString(lua, 2, "ai.ask", "prompt");
    if (ctx.ai) |router| {
        router.ask(npc, prompt) catch |err| {
            lua.raiseErrorStr("ai.ask: enqueue failed (%s)", .{@errorName(err).ptr});
        };
    }
    return 0;
}

fn c_ai_poll(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const ctx = ctxFrom(lua);
    const npc = requireString(lua, 1, "ai.poll", "npc");
    if (ctx.ai) |router| {
        if (router.poll(npc)) |resp| {
            _ = lua.pushString(resp);
            return 1;
        }
    }
    lua.pushNil();
    return 1;
}

// ---------------- tests ----------------

const testing = std.testing;
const pixel = @import("../runtime/pixel.zig");
const input = @import("../runtime/input.zig");
const rng_mod = @import("../runtime/rng.zig");
const ai_router = @import("../ai/router.zig");

// Note: tests below set up their rig inline rather than returning
// a struct from a helper. The router holds `&mock.backend`, and a
// returned-by-value setup struct would move `mock` to a new address —
// router's stored pointer would dangle. Inline ownership keeps the
// addresses stable for the test's lifetime.

test "ai.ask + ai.poll round-trips through Mock backend" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var mock = ai_router.MockBackend.init();
    const router = try ai_router.Router.init(testing.allocator, &mock.backend);
    defer router.deinit();
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    var ctx: CartContext = .{
        .fb = &fb,
        .inp = &inp,
        .rng = rng_mod.Xorshift32.init(1),
        .ai = router,
    };
    ctx.registerApi(&vm);

    // Phase 1 is synchronous — ask() returns with the mailbox already
    // written, so a poll on the very next line sees the response.
    try vm.exec("ai.ask('baker', 'hi')");
    const len = try vm.evalInt("return #ai.poll('baker')");
    try testing.expectEqual(@as(i64, "echo: hi".len), len);
}

test "ai.poll returns nil before any ask" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var mock = ai_router.MockBackend.init();
    const router = try ai_router.Router.init(testing.allocator, &mock.backend);
    defer router.deinit();
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    var ctx: CartContext = .{
        .fb = &fb,
        .inp = &inp,
        .rng = rng_mod.Xorshift32.init(1),
        .ai = router,
    };
    ctx.registerApi(&vm);

    const v = try vm.evalInt("return ai.poll('baker') == nil and 1 or 0");
    try testing.expectEqual(@as(i64, 1), v);
}

test "ai.poll returns nil for unknown npc after asking a different one" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var mock = ai_router.MockBackend.init();
    const router = try ai_router.Router.init(testing.allocator, &mock.backend);
    defer router.deinit();
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    var ctx: CartContext = .{
        .fb = &fb,
        .inp = &inp,
        .rng = rng_mod.Xorshift32.init(1),
        .ai = router,
    };
    ctx.registerApi(&vm);

    try vm.exec("ai.ask('baker', 'hi')");
    const v = try vm.evalInt("return ai.poll('priest') == nil and 1 or 0");
    try testing.expectEqual(@as(i64, 1), v);
}

test "ai.ask raises Lua error on non-string npc" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var mock = ai_router.MockBackend.init();
    const router = try ai_router.Router.init(testing.allocator, &mock.backend);
    defer router.deinit();
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    var ctx: CartContext = .{
        .fb = &fb,
        .inp = &inp,
        .rng = rng_mod.Xorshift32.init(1),
        .ai = router,
    };
    ctx.registerApi(&vm);

    try testing.expectError(error.RuntimeError, vm.exec("ai.ask({}, 'hi')"));
}

test "ai.ask raises Lua error on missing prompt" {
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var mock = ai_router.MockBackend.init();
    const router = try ai_router.Router.init(testing.allocator, &mock.backend);
    defer router.deinit();
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    var ctx: CartContext = .{
        .fb = &fb,
        .inp = &inp,
        .rng = rng_mod.Xorshift32.init(1),
        .ai = router,
    };
    ctx.registerApi(&vm);

    try testing.expectError(error.RuntimeError, vm.exec("ai.ask('baker', nil)"));
}

test "ai bindings are no-op when CartContext.ai is null" {
    // Build a context WITHOUT a router; both bindings should be safe.
    var fb: pixel.Framebuffer = undefined;
    var inp: input.State = .{};
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    var ctx: CartContext = .{
        .fb = &fb,
        .inp = &inp,
        .rng = rng_mod.Xorshift32.init(1),
        .ai = null,
    };
    ctx.registerApi(&vm);

    // ask() must not raise (it just silently drops).
    try vm.exec("ai.ask('baker', 'hi')");
    // poll() returns nil (no router to query).
    const v = try vm.evalInt("return ai.poll('baker') == nil and 1 or 0");
    try testing.expectEqual(@as(i64, 1), v);
}
