//! AI router — gives cart code (`ai.ask("baker", prompt)`) a way to
//! talk to an LLM and read the answer back via `ai.poll("baker")`.
//!
//! Phase 1 (this file) is **synchronous** with a Mock backend: ask()
//! invokes the backend inline and writes the response directly to the
//! mailbox. No worker thread, no mutex, no queue.
//!
//! Phase 2 will swap Mock for llama.cpp via dlopen, AND introduce a
//! worker thread + Io.Mutex / Io.Condition mailbox so a real LLM call
//! (which takes seconds) does NOT block the cart's 60 Hz frame loop.
//! The cart-author surface (`ai.ask` / `ai.poll`) is identical between
//! sync and async — Phase 2 is a backend swap, not an API change.
//!
//! Why sync first: Mock returns in microseconds; making Phase 1 async
//! would require plumbing `std.Io` through the whole engine just to
//! validate threading we don't actually need yet. We get the API,
//! the tests, the integration with cart_ctx, the rate-limit hook
//! (deferred), without the Io rewrite. Phase 2 introduces the worker
//! thread on a single isolated diff once it's the bottleneck.
//!
//! Determinism: in Phase 1, ask() and poll() are deterministic given
//! the backend is deterministic. Mock is `echo: <prompt>` — pure
//! function of input. When llama.cpp lands, determinism becomes a
//! per-frame snapshot problem (replay must record + replay mailbox
//! events) handled in Phase 2's design.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
};

/// Pluggable LLM backend. Submit takes a prompt, returns a freshly
/// allocated response slice owned by the caller.
///
/// Phase 1 ships MockBackend (deterministic echo). Phase 2 will add
/// LlamaCppBackend that dlopens libllama and streams tokens; the same
/// submit() shape works because Phase 2 will accumulate streamed
/// tokens behind the scenes and return the full string per call.
pub const Backend = struct {
    submitFn: *const fn (self: *Backend, alloc: Allocator, prompt: []const u8) anyerror![]u8,

    pub fn submit(self: *Backend, alloc: Allocator, prompt: []const u8) anyerror![]u8 {
        return self.submitFn(self, alloc, prompt);
    }
};

/// Echo backend — returns "echo: <prompt>". Deterministic, never fails,
/// no external dependencies. Used by `glint run` and unit tests.
pub const MockBackend = struct {
    backend: Backend,

    pub fn init() MockBackend {
        return .{ .backend = .{ .submitFn = submit } };
    }

    fn submit(b: *Backend, alloc: Allocator, prompt: []const u8) anyerror![]u8 {
        _ = b;
        return std.fmt.allocPrint(alloc, "echo: {s}", .{prompt});
    }
};

/// Per-NPC latest-response store. In Phase 1 there's no concurrent
/// writer, so no mutex; Phase 2 will add Io.Mutex when the worker
/// thread lands.
pub const Mailbox = struct {
    alloc: Allocator,
    entries: std.StringHashMap([]u8),

    pub fn init(alloc: Allocator) Mailbox {
        return .{ .alloc = alloc, .entries = std.StringHashMap([]u8).init(alloc) };
    }

    pub fn deinit(self: *Mailbox) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.entries.deinit();
    }

    /// Record `value` as the latest message for `npc`. Replaces any
    /// previous entry, freeing the old value's bytes. Both inputs are
    /// duped into the mailbox's allocator so callers can free their
    /// originals immediately.
    pub fn put(self: *Mailbox, npc: []const u8, value: []const u8) !void {
        const value_dup = try self.alloc.dupe(u8, value);
        errdefer self.alloc.free(value_dup);
        const gop = try self.entries.getOrPut(npc);
        if (gop.found_existing) {
            self.alloc.free(gop.value_ptr.*);
            gop.value_ptr.* = value_dup;
        } else {
            // New key: dup the npc bytes so the hashmap owns its keys.
            const npc_dup = try self.alloc.dupe(u8, npc);
            gop.key_ptr.* = npc_dup;
            gop.value_ptr.* = value_dup;
        }
    }

    /// Look up the latest response for `npc`. Returns null if no
    /// message has ever landed. Returned slice is borrowed from
    /// mailbox memory; caller must NOT hold it across any subsequent
    /// put() that could free it. In practice cart code copies into a
    /// Lua string immediately, so this is safe.
    pub fn get(self: *const Mailbox, npc: []const u8) ?[]const u8 {
        return self.entries.get(npc);
    }
};

/// Phase 1 router: thin glue between Backend and Mailbox. ask() runs
/// the backend synchronously, parks the result in the mailbox, returns.
/// Heap-allocated so it can be referenced via *Router from CartContext
/// and pointer-passed across the binding boundary.
pub const Router = struct {
    alloc: Allocator,
    backend: *Backend,
    mailbox: Mailbox,

    pub fn init(alloc: Allocator, backend: *Backend) !*Router {
        const self = try alloc.create(Router);
        self.* = .{
            .alloc = alloc,
            .backend = backend,
            .mailbox = Mailbox.init(alloc),
        };
        return self;
    }

    pub fn deinit(self: *Router) void {
        self.mailbox.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    /// Submit a prompt for the named NPC. In Phase 1 this is synchronous:
    /// the backend runs inline, the mailbox is updated before returning.
    /// Phase 2 makes this fire-and-forget.
    ///
    /// On backend error, an in-band sentinel `[ERROR: <name>]` is parked
    /// in the mailbox so cart-side code can pattern-match the prefix
    /// without needing a separate error binding.
    pub fn ask(self: *Router, npc: []const u8, prompt: []const u8) !void {
        const response = self.backend.submit(self.alloc, prompt) catch |err| {
            const sentinel = try std.fmt.allocPrint(
                self.alloc,
                "[ERROR: {s}]",
                .{@errorName(err)},
            );
            defer self.alloc.free(sentinel);
            try self.mailbox.put(npc, sentinel);
            return;
        };
        defer self.alloc.free(response);
        try self.mailbox.put(npc, response);
    }

    /// Read the latest response for `npc`, or null if no answer yet.
    /// Slice is borrowed from the mailbox; cart bindings copy it into
    /// a Lua string before returning to userspace.
    pub fn poll(self: *const Router, npc: []const u8) ?[]const u8 {
        return self.mailbox.get(npc);
    }
};

// ---------------- tests ----------------

const testing = std.testing;

test "Mailbox put + get round-trip" {
    var mb = Mailbox.init(testing.allocator);
    defer mb.deinit();
    try mb.put("baker", "hot bread, fresh!");
    const v = mb.get("baker") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("hot bread, fresh!", v);
}

test "Mailbox put replaces previous value (frees old)" {
    var mb = Mailbox.init(testing.allocator);
    defer mb.deinit();
    try mb.put("npc1", "first");
    try mb.put("npc1", "second");
    try testing.expectEqualStrings("second", mb.get("npc1").?);
    // testing.allocator catches a leak if put didn't free "first".
}

test "Mailbox get returns null for unknown npc" {
    var mb = Mailbox.init(testing.allocator);
    defer mb.deinit();
    try testing.expectEqual(@as(?[]const u8, null), mb.get("ghost"));
}

test "Router round-trips ask through mock backend into mailbox" {
    var mock = MockBackend.init();
    const r = try Router.init(testing.allocator, &mock.backend);
    defer r.deinit();

    try r.ask("baker", "hi");
    const resp = r.poll("baker") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("echo: hi", resp);
}

test "Router serves multiple distinct npcs independently" {
    var mock = MockBackend.init();
    const r = try Router.init(testing.allocator, &mock.backend);
    defer r.deinit();

    try r.ask("baker", "bread?");
    try r.ask("smith", "shoe?");
    try r.ask("priest", "blessing?");

    try testing.expectEqualStrings("echo: bread?", r.poll("baker").?);
    try testing.expectEqualStrings("echo: shoe?", r.poll("smith").?);
    try testing.expectEqualStrings("echo: blessing?", r.poll("priest").?);
    try testing.expectEqual(@as(?[]const u8, null), r.poll("unknown"));
}

test "Router latest-wins per npc on repeat ask" {
    var mock = MockBackend.init();
    const r = try Router.init(testing.allocator, &mock.backend);
    defer r.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var buf: [16]u8 = undefined;
        const prompt = try std.fmt.bufPrint(&buf, "p{d}", .{i});
        try r.ask("npc", prompt);
    }

    const resp = r.poll("npc") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("echo: p49", resp);
}

/// Backend that fails every call with a fixed error. Exercises the
/// in-band "[ERROR: ...]" sentinel path so cart authors who pattern-
/// match on the prefix can rely on it.
const FailingBackend = struct {
    backend: Backend,

    fn init() FailingBackend {
        return .{ .backend = .{ .submitFn = submit } };
    }

    fn submit(b: *Backend, alloc: Allocator, prompt: []const u8) anyerror![]u8 {
        _ = b;
        _ = alloc;
        _ = prompt;
        return error.SimulatedBackendOutage;
    }
};

test "Router writes [ERROR:] sentinel into mailbox on backend failure" {
    var failing = FailingBackend.init();
    const r = try Router.init(testing.allocator, &failing.backend);
    defer r.deinit();

    try r.ask("baker", "anything");

    const resp = r.poll("baker") orelse return error.TestUnexpectedNull;
    try testing.expect(std.mem.startsWith(u8, resp, "[ERROR:"));
    try testing.expect(std.mem.indexOf(u8, resp, "SimulatedBackendOutage") != null);
}
