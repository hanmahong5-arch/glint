//! Cart-author API surface (Luau bindings, Phase 2a — math + helpers).
//!
//! This file installs the deterministic, stateless cart functions as Luau
//! globals. Per dx-spec §A.2 the cart-author surface is bounded at ~80
//! functions; this module ships the math leaf set:
//!
//!   sin / cos / atan2  — turns-based, LUT-backed (runtime/fixed.zig)
//!   sqrt               — Q16.16 isqrt scaled to f64
//!   abs / flr / ceil   — built-in number coercion
//!   min / max          — 2-arg form
//!   mid                — Pico-8 median-of-three clamp (runtime/math.zig)
//!   lerp / saturate    — interpolation primitives (runtime/math.zig)
//!   sgn                — three-way sign (-1, 0, +1)
//!
//! Why these *here* (not in vm.zig): keeping the binding registrations in
//! a separate file makes the cart-API surface auditable. A reviewer can
//! grep `bind\(` to see exactly which functions are exposed; new APIs go
//! through this file or its siblings (api_gfx.zig in Phase 2b, api_input,
//! api_audio, api_ai). Sandbox boundary stays in vm.zig.
//!
//! Argument typing: every function takes `number`. Wrong types raise a
//! Lua error with the function and parameter name, never panic the engine.
//! Out-of-range / NaN inputs are passed through to the underlying math
//! helpers, which silent-clamp per the dx-spec error policy.

const std = @import("std");
const zlua = @import("zlua");
const c = zlua.c;
const fixed = @import("../runtime/fixed.zig");
const math_helpers = @import("../runtime/math.zig");
const VM = @import("vm.zig").VM;

/// Register the math + helper bindings as Lua globals on `vm`. Call once
/// after the VM is initialized (and before any cart code runs).
pub fn registerMath(vm: *VM) void {
    bind(vm, "sin", c_sin);
    bind(vm, "cos", c_cos);
    bind(vm, "atan2", c_atan2);
    bind(vm, "sqrt", c_sqrt);
    bind(vm, "abs", c_abs);
    bind(vm, "flr", c_flr);
    bind(vm, "ceil", c_ceil);
    bind(vm, "min", c_min);
    bind(vm, "max", c_max);
    bind(vm, "mid", c_mid);
    bind(vm, "lerp", c_lerp);
    bind(vm, "saturate", c_saturate);
    bind(vm, "sgn", c_sgn);
}

/// Install one C function under a Lua global name.
fn bind(vm: *VM, name: [:0]const u8, fnptr: zlua.CFn) void {
    vm.lua.pushFunction(fnptr);
    vm.lua.setGlobal(name);
}

/// Pull the i-th argument off the Lua stack as a number. Raises a Lua
/// error (long-jump out of this function) if absent or non-numeric. The
/// caller never returns from this function on failure.
fn numArg(lua: *zlua.Lua, idx: i32, comptime fn_name: []const u8, comptime arg_name: []const u8) f64 {
    return lua.toNumber(idx) catch {
        lua.raiseErrorStr(fn_name ++ ": " ++ arg_name ++ " must be a number", .{});
    };
}

// ---------- trig + sqrt (deterministic LUT) ----------

fn c_sin(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const t = numArg(lua, 1, "sin", "turns");
    lua.pushNumber(fixed.sinTurns(t));
    return 1;
}

fn c_cos(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const t = numArg(lua, 1, "cos", "turns");
    lua.pushNumber(fixed.cosTurns(t));
    return 1;
}

fn c_atan2(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const y = numArg(lua, 1, "atan2", "y");
    const x = numArg(lua, 2, "atan2", "x");
    lua.pushNumber(fixed.atan2Turns(y, x));
    return 1;
}

fn c_sqrt(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const f = numArg(lua, 1, "sqrt", "x");
    lua.pushNumber(fixed.sqrtFloat(f));
    return 1;
}

// ---------- number coercion helpers ----------

fn c_abs(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const x = numArg(lua, 1, "abs", "x");
    lua.pushNumber(@abs(x));
    return 1;
}

fn c_flr(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const x = numArg(lua, 1, "flr", "x");
    lua.pushNumber(@floor(x));
    return 1;
}

fn c_ceil(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const x = numArg(lua, 1, "ceil", "x");
    lua.pushNumber(@ceil(x));
    return 1;
}

fn c_min(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const a = numArg(lua, 1, "min", "a");
    const b = numArg(lua, 2, "min", "b");
    lua.pushNumber(@min(a, b));
    return 1;
}

fn c_max(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const a = numArg(lua, 1, "max", "a");
    const b = numArg(lua, 2, "max", "b");
    lua.pushNumber(@max(a, b));
    return 1;
}

// ---------- Pico-8-style cart helpers ----------

fn c_mid(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const a = numArg(lua, 1, "mid", "a");
    const b = numArg(lua, 2, "mid", "b");
    const z = numArg(lua, 3, "mid", "c");
    lua.pushNumber(math_helpers.mid(a, b, z));
    return 1;
}

fn c_lerp(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const a = numArg(lua, 1, "lerp", "a");
    const b = numArg(lua, 2, "lerp", "b");
    const t = numArg(lua, 3, "lerp", "t");
    lua.pushNumber(math_helpers.lerp(a, b, t));
    return 1;
}

fn c_saturate(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const v = numArg(lua, 1, "saturate", "v");
    lua.pushNumber(math_helpers.saturate(v));
    return 1;
}

fn c_sgn(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *zlua.Lua = @ptrCast(state.?);
    const x = numArg(lua, 1, "sgn", "x");
    lua.pushInteger(@as(zlua.Integer, math_helpers.signI(x)));
    return 1;
}

// ---------------- tests ----------------

const testing = std.testing;

fn freshVM() !VM {
    var vm = try VM.init(testing.allocator);
    errdefer vm.deinit();
    registerMath(&vm);
    return vm;
}

test "sin and cos at standard turns" {
    var vm = try freshVM();
    defer vm.deinit();
    try testing.expectApproxEqAbs(@as(f64, 0.0), try vm.evalNumber("return sin(0)"), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 1.0), try vm.evalNumber("return sin(0.25)"), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 1.0), try vm.evalNumber("return cos(0)"), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0.0), try vm.evalNumber("return cos(0.25)"), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, -1.0), try vm.evalNumber("return cos(0.5)"), 1e-3);
}

test "atan2 returns turns in (-0.5, 0.5]" {
    var vm = try freshVM();
    defer vm.deinit();
    // atan2(1, 0) should give a quarter turn (0.25)
    try testing.expectApproxEqAbs(@as(f64, 0.25), try vm.evalNumber("return atan2(1, 0)"), 1e-2);
    // atan2(0, 1) should give 0 turns
    try testing.expectApproxEqAbs(@as(f64, 0.0), try vm.evalNumber("return atan2(0, 1)"), 1e-2);
}

test "sqrt of perfect squares" {
    var vm = try freshVM();
    defer vm.deinit();
    try testing.expectApproxEqAbs(@as(f64, 4.0), try vm.evalNumber("return sqrt(16)"), 0.05);
    try testing.expectApproxEqAbs(@as(f64, 0.0), try vm.evalNumber("return sqrt(0)"), 1e-9);
    // Negative input is silent-clamped to 0.
    try testing.expectApproxEqAbs(@as(f64, 0.0), try vm.evalNumber("return sqrt(-9)"), 1e-9);
}

test "abs handles negatives + positives" {
    var vm = try freshVM();
    defer vm.deinit();
    try testing.expectApproxEqAbs(@as(f64, 5.0), try vm.evalNumber("return abs(-5)"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5.0), try vm.evalNumber("return abs(5)"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), try vm.evalNumber("return abs(0)"), 1e-9);
}

test "flr/ceil edge cases" {
    var vm = try freshVM();
    defer vm.deinit();
    try testing.expectApproxEqAbs(@as(f64, 3.0), try vm.evalNumber("return flr(3.9)"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -2.0), try vm.evalNumber("return flr(-1.5)"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4.0), try vm.evalNumber("return ceil(3.1)"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -1.0), try vm.evalNumber("return ceil(-1.5)"), 1e-9);
}

test "min/max of two args" {
    var vm = try freshVM();
    defer vm.deinit();
    try testing.expectApproxEqAbs(@as(f64, 3.0), try vm.evalNumber("return min(3, 5)"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5.0), try vm.evalNumber("return max(3, 5)"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -2.0), try vm.evalNumber("return min(-2, 1)"), 1e-9);
}

test "mid clamps regardless of argument order" {
    var vm = try freshVM();
    defer vm.deinit();
    try testing.expectApproxEqAbs(@as(f64, 50.0), try vm.evalNumber("return mid(0, 50, 100)"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 100.0), try vm.evalNumber("return mid(0, 200, 100)"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), try vm.evalNumber("return mid(0, -50, 100)"), 1e-9);
    // Any permutation
    try testing.expectApproxEqAbs(@as(f64, 50.0), try vm.evalNumber("return mid(50, 100, 0)"), 1e-9);
}

test "lerp endpoints + midpoint" {
    var vm = try freshVM();
    defer vm.deinit();
    try testing.expectApproxEqAbs(@as(f64, 10.0), try vm.evalNumber("return lerp(10, 20, 0)"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20.0), try vm.evalNumber("return lerp(10, 20, 1)"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 15.0), try vm.evalNumber("return lerp(10, 20, 0.5)"), 1e-9);
}

test "saturate clamps to [0, 1]" {
    var vm = try freshVM();
    defer vm.deinit();
    try testing.expectApproxEqAbs(@as(f64, 0.0), try vm.evalNumber("return saturate(-0.5)"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), try vm.evalNumber("return saturate(2)"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), try vm.evalNumber("return saturate(0.5)"), 1e-9);
}

test "sgn returns -1, 0, or +1" {
    var vm = try freshVM();
    defer vm.deinit();
    try testing.expectEqual(@as(i64, 1), try vm.evalInt("return sgn(7)"));
    try testing.expectEqual(@as(i64, -1), try vm.evalInt("return sgn(-3)"));
    try testing.expectEqual(@as(i64, 0), try vm.evalInt("return sgn(0)"));
}

test "wrong-type arg raises Lua error not engine panic" {
    var vm = try freshVM();
    defer vm.deinit();
    try testing.expectError(error.RuntimeError, vm.exec("sin('not a number')"));
}

test "all 13 bindings reachable from cart code" {
    var vm = try freshVM();
    defer vm.deinit();
    // One round-trip per name; checks that registerMath set every global.
    inline for (.{
        "sin",  "cos", "atan2", "sqrt", "abs",     "flr", "ceil",
        "min",  "max", "mid",   "lerp", "saturate", "sgn",
    }) |name| {
        try testing.expect(!vm.globalIsNil(name));
    }
}
