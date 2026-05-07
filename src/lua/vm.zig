//! Luau VM wrapper — sandboxed embedding for cart-author scripts.
//!
//! Carts are written in Luau (Roblox's typed, sandboxed Lua dialect). This
//! file is the engine's narrow boundary onto Luau: every cart sees a fresh
//! VM with a curated standard-library subset, no file IO, no env access,
//! no introspection that could break the sandbox.
//!
//! Threading model: one VM per cart. VMs are not shareable across threads
//! (Luau state is single-threaded). The AI worker thread (W9) talks to the
//! VM via a message queue, never touches `Lua *` directly.
//!
//! Sandbox policy (mirrors dx-spec §A.4 + §C.2):
//!   - opened: base, string, table, math, coroutine, bit32
//!   - NOT opened: io, os, debug, package
//!   - additionally nil'd: dofile, loadfile, load, loadstring, require
//!     (these are part of `base` but escape the sandbox)
//!
//! Determinism note: math.random is non-deterministic and platform-dependent.
//! Cart authors must use the engine's `rnd()` / `srand()` (runtime/rng.zig);
//! a follow-up commit replaces the math.random binding entirely. Until then,
//! cart authors are advised in doc/dx-reliability-spec.md to avoid math.random.

const std = @import("std");
const zlua = @import("zlua");

/// One sandboxed Luau VM. Each cart owns one. Not thread-safe.
pub const VM = struct {
    lua: *zlua.Lua,

    pub const Error = error{
        OutOfMemory,
        InvalidBytecode,
        SyntaxError,
        RuntimeError,
        NoReturnValue,
        ExpectedInteger,
        ExpectedNumber,
        StackOverflow,
    };

    /// Allocate a fresh Luau state and apply the sandbox policy. Caller
    /// owns the returned VM and must call `deinit`.
    pub fn init(alloc: std.mem.Allocator) Error!VM {
        const lua = zlua.Lua.init(alloc) catch return error.OutOfMemory;
        errdefer lua.deinit();
        applySandbox(lua);
        return .{ .lua = lua };
    }

    pub fn deinit(self: *VM) void {
        self.lua.deinit();
        self.* = undefined;
    }

    /// Execute a Luau source snippet. Discards any return values. Use
    /// `evalInt` / `evalNumber` if the snippet ends with `return ...`.
    pub fn exec(self: *VM, src: [:0]const u8) Error!void {
        self.lua.doString(src) catch |err| return mapErr(err);
    }

    /// Evaluate a Luau snippet that ends in `return <int>` and return that
    /// integer. Errors if the snippet leaves nothing on the stack or its
    /// top value is not coercible to an integer.
    pub fn evalInt(self: *VM, src: [:0]const u8) Error!i64 {
        const top_before = self.lua.getTop();
        self.lua.doString(src) catch |err| return mapErr(err);
        const top_after = self.lua.getTop();
        if (top_after <= top_before) return error.NoReturnValue;
        const n = self.lua.toInteger(-1) catch return error.ExpectedInteger;
        self.lua.pop(top_after - top_before);
        return @as(i64, @intCast(n));
    }

    /// Evaluate a Luau snippet that returns a Lua number. Same shape as
    /// `evalInt` but returns the Number (Luau's f64).
    pub fn evalNumber(self: *VM, src: [:0]const u8) Error!f64 {
        const top_before = self.lua.getTop();
        self.lua.doString(src) catch |err| return mapErr(err);
        const top_after = self.lua.getTop();
        if (top_after <= top_before) return error.NoReturnValue;
        const v = self.lua.toNumber(-1) catch return error.ExpectedNumber;
        self.lua.pop(top_after - top_before);
        return @as(f64, v);
    }

    /// Check that a global name is currently bound to nil (sandbox proof).
    /// Used by the dev-panel sandbox auditor and by the unit tests below.
    pub fn globalIsNil(self: *VM, name: [:0]const u8) bool {
        const ty = self.lua.getGlobal(name);
        defer self.lua.pop(1);
        return ty == .nil;
    }
};

/// Open the safe stdlib subset and remove every dangerous default global.
/// Called exactly once per VM during `init`.
fn applySandbox(lua: *zlua.Lua) void {
    // Open only the libraries cart authors are allowed to use.
    // (Luau already exposes bit32 + buffer via openBase, no separate
    // openBit32 — that helper is gated to Lua 5.2/LuaJIT.)
    lua.openBase();
    lua.openString();
    lua.openTable();
    lua.openMath();
    lua.openCoroutine();

    // The base library re-exposes a handful of dynamic-load functions and
    // file IO entry points. Nil them so the cart cannot escape the sandbox
    // via `dofile` / `load("...")` / `require`. The list is intentionally
    // explicit rather than a "remove everything starting with X" filter so
    // a future Luau bump that adds a new escape vector is a compile-time
    // diff in this slice rather than a silent regression.
    const dangerous = [_][:0]const u8{
        "dofile",
        "loadfile",
        "load",
        "loadstring",
        "require",
        "collectgarbage", // can be DoS'd; cart manifests pin heap_kb instead
        "newproxy", // metatable escape vector in some Lua versions
        "rawequal", // optional: cart-author API does not need this
        "rawget",
        "rawset",
    };
    inline for (dangerous) |name| {
        lua.pushNil();
        lua.setGlobal(name);
    }
}

/// Translate ziglua's verbose error union into our `VM.Error` set. Keeps
/// callers from having to know zlua's internal error names.
fn mapErr(err: anyerror) VM.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBytecode => error.InvalidBytecode,
        error.LuaSyntax => error.SyntaxError,
        error.LuaRuntime, error.LuaMsgHandler => error.RuntimeError,
        else => error.RuntimeError,
    };
}

// ---------------- tests ----------------

const testing = std.testing;

test "init/deinit does not leak" {
    var vm = try VM.init(testing.allocator);
    vm.deinit();
}

test "exec runs a Lua statement and mutates VM state" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    try vm.exec("global_x = 42");
    const v = try vm.evalInt("return global_x");
    try testing.expectEqual(@as(i64, 42), v);
}

test "evalInt returns integer arithmetic result" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    try testing.expectEqual(@as(i64, 5), try vm.evalInt("return 2 + 3"));
    try testing.expectEqual(@as(i64, -7), try vm.evalInt("return -10 + 3"));
    try testing.expectEqual(@as(i64, 144), try vm.evalInt("return 12 * 12"));
}

test "evalNumber returns float result" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const v = try vm.evalNumber("return 3.14 * 2");
    try testing.expectApproxEqAbs(@as(f64, 6.28), v, 1e-9);
}

test "syntax error returns SyntaxError" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    try testing.expectError(error.SyntaxError, vm.exec("this is not lua"));
}

test "runtime error returns RuntimeError" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    // Indexing nil triggers a runtime error in Luau.
    try testing.expectError(error.RuntimeError, vm.exec("local x = nil; return x.y"));
}

test "sandbox: io is nil" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    try testing.expect(vm.globalIsNil("io"));
}

test "sandbox: os is nil" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    try testing.expect(vm.globalIsNil("os"));
}

test "sandbox: debug is nil" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    try testing.expect(vm.globalIsNil("debug"));
}

test "sandbox: dynamic-load functions are nil" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    try testing.expect(vm.globalIsNil("dofile"));
    try testing.expect(vm.globalIsNil("loadfile"));
    try testing.expect(vm.globalIsNil("load"));
    try testing.expect(vm.globalIsNil("loadstring"));
    try testing.expect(vm.globalIsNil("require"));
}

test "sandbox: math is still available" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const v = try vm.evalNumber("return math.floor(3.9)");
    try testing.expectApproxEqAbs(@as(f64, 3.0), v, 1e-12);
}

test "sandbox: string is still available" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const v = try vm.evalInt("return string.len('hello')");
    try testing.expectEqual(@as(i64, 5), v);
}

test "sandbox: table is still available" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    try vm.exec("t = {1, 2, 3, 4}");
    const v = try vm.evalInt("return #t");
    try testing.expectEqual(@as(i64, 4), v);
}

test "VM survives many exec calls (no stack leak)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try vm.exec("local _ = 1");
    }
    // Stack should be back to empty after each protected call.
    try testing.expectEqual(@as(i32, 0), vm.lua.getTop());
}

test "evalInt can be called repeatedly without growing the stack" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const v = try vm.evalInt("return 7");
        try testing.expectEqual(@as(i64, 7), v);
    }
    try testing.expectEqual(@as(i32, 0), vm.lua.getTop());
}
