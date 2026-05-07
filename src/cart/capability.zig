//! Cart capability declaration + resolution.
//!
//! Per dx-spec §A.4, the cart manifest's [caps] block declares which
//! permissions the cart wants from the host. This module is the engine's
//! permission decision boundary: declarations come in (parsed by the
//! manifest reader, not yet implemented), the host policy is consulted,
//! and a Resolution emerges with granted / denied bitfields.
//!
//! Edge-case behavior matches dx-spec §B.5 case matrix:
//!   - cart declares cap = required, host denies   -> error.RequiredButDenied
//!   - cart declares cap = optional, host denies   -> in `denied` mask, no error
//!   - cart calls cap-protected API without granted cap -> caller's responsibility
//!     (api binding layer scolds + returns nil-on-fail)
//!
//! TOML parsing of [caps] lives in `cart/manifest.zig` (TODO). This module
//! works on already-parsed Declaration slices so it can be unit tested
//! without dragging in a parser.

const std = @import("std");

/// Permission mode declared by the cart for a given capability.
pub const Mode = enum { required, optional };

/// Well-known capability names. Match the cap_name production in dx-spec
/// §A.4.1 grammar. New names go here AND in `nameFromString`. Adding a
/// new name is a backwards-compatible change for older carts; removing a
/// name is breaking.
pub const Name = enum(u4) {
    ai = 0,
    save = 1,
    net = 2,
    raw = 3,
    fs_read = 4,
    fs_write = 5,
    clipboard = 6,
};
pub const NAME_COUNT: usize = 7;

/// Bitset over Name; bit i = 1 means name i is in the set.
pub const Set = u8;

pub fn bit(name: Name) Set {
    // Shift amount must be u3 (Log2(u8) = 3); enum tag is u4. Values are
    // bounded by NAME_COUNT <= 8, so the @intCast cannot trap.
    const shift: u3 = @intCast(@intFromEnum(name));
    return @as(Set, 1) << shift;
}

pub fn contains(set: Set, name: Name) bool {
    return (set & bit(name)) != 0;
}

/// One declaration line from the cart's [caps] block.
pub const Declaration = struct {
    name: Name,
    mode: Mode,
    /// Optional human-readable justification shown to the player when
    /// requesting the capability. Borrowed from manifest text; lifetime
    /// matches the parsed manifest.
    reason: ?[]const u8 = null,
};

/// Host-side policy: which capability names the host is willing to grant
/// for this cart load. Selected by user prompt, config file, or CLI flag
/// in higher layers.
pub const Policy = struct {
    allowed: Set = 0,

    pub fn allowAll() Policy {
        const all: Set = (@as(Set, 1) << @as(u3, NAME_COUNT)) - 1;
        return .{ .allowed = all };
    }

    pub fn denyAll() Policy {
        return .{ .allowed = 0 };
    }

    pub fn with(self: Policy, name: Name) Policy {
        return .{ .allowed = self.allowed | bit(name) };
    }
};

/// Outcome of resolving a list of Declarations against a Policy.
pub const Resolution = struct {
    /// Names actually granted. Cart's `cap.has(name)` reads this.
    granted: Set,
    /// Names declared optional that the host denied. Cart's
    /// `cap.denied()` reads this.
    denied: Set,
};

pub const Error = error{
    /// A required capability was denied by the host policy. Cart load
    /// must abort. dx-spec §B.5 case 1 / 5 / etc.
    RequiredButDenied,
    /// Same name declared more than once in the manifest.
    DuplicateDeclaration,
};

/// Resolve a slice of declarations against the policy. Order of
/// declarations does not matter. Duplicate names are an error (caller
/// presumably wrote a malformed manifest).
pub fn resolve(declarations: []const Declaration, policy: Policy) Error!Resolution {
    var granted: Set = 0;
    var denied: Set = 0;
    var seen: Set = 0;

    for (declarations) |d| {
        const b = bit(d.name);
        if ((seen & b) != 0) return error.DuplicateDeclaration;
        seen |= b;

        if ((policy.allowed & b) != 0) {
            granted |= b;
        } else {
            if (d.mode == .required) return error.RequiredButDenied;
            denied |= b;
        }
    }

    return .{ .granted = granted, .denied = denied };
}

/// Map a manifest token to a Name. Returns null if the token is not a
/// known capability — the caller (manifest parser) decides whether to
/// scold or hard-fail.
pub fn nameFromString(s: []const u8) ?Name {
    if (std.mem.eql(u8, s, "ai")) return .ai;
    if (std.mem.eql(u8, s, "save")) return .save;
    if (std.mem.eql(u8, s, "net")) return .net;
    if (std.mem.eql(u8, s, "raw")) return .raw;
    if (std.mem.eql(u8, s, "fs_read")) return .fs_read;
    if (std.mem.eql(u8, s, "fs_write")) return .fs_write;
    if (std.mem.eql(u8, s, "clipboard")) return .clipboard;
    return null;
}

/// Reverse of nameFromString.
pub fn nameToString(n: Name) []const u8 {
    return switch (n) {
        .ai => "ai",
        .save => "save",
        .net => "net",
        .raw => "raw",
        .fs_read => "fs_read",
        .fs_write => "fs_write",
        .clipboard => "clipboard",
    };
}

// ---------- tests ----------

const testing = std.testing;

test "all caps + required granted yields full granted set" {
    const decls = [_]Declaration{
        .{ .name = .ai, .mode = .required },
        .{ .name = .save, .mode = .required },
    };
    const r = try resolve(&decls, Policy.allowAll());
    try testing.expect(contains(r.granted, .ai));
    try testing.expect(contains(r.granted, .save));
    try testing.expectEqual(@as(Set, 0), r.denied);
}

test "optional cap denied lands in denied set, no error" {
    const decls = [_]Declaration{
        .{ .name = .net, .mode = .optional },
    };
    const r = try resolve(&decls, Policy.denyAll());
    try testing.expectEqual(@as(Set, 0), r.granted);
    try testing.expect(contains(r.denied, .net));
}

test "required cap denied returns error" {
    const decls = [_]Declaration{
        .{ .name = .ai, .mode = .required, .reason = "speak" },
    };
    try testing.expectError(error.RequiredButDenied, resolve(&decls, Policy.denyAll()));
}

test "duplicate declaration is an error" {
    const decls = [_]Declaration{
        .{ .name = .ai, .mode = .required },
        .{ .name = .ai, .mode = .optional },
    };
    try testing.expectError(error.DuplicateDeclaration, resolve(&decls, Policy.allowAll()));
}

test "policy.with adds names cumulatively" {
    const p = Policy.denyAll().with(.ai).with(.save);
    try testing.expect(contains(p.allowed, .ai));
    try testing.expect(contains(p.allowed, .save));
    try testing.expect(!contains(p.allowed, .net));
}

test "mixed required-granted + optional-denied + optional-granted" {
    const decls = [_]Declaration{
        .{ .name = .ai, .mode = .required },
        .{ .name = .save, .mode = .optional },
        .{ .name = .net, .mode = .optional },
    };
    // Host allows ai + save, denies net.
    const policy = Policy.denyAll().with(.ai).with(.save);
    const r = try resolve(&decls, policy);
    try testing.expect(contains(r.granted, .ai));
    try testing.expect(contains(r.granted, .save));
    try testing.expect(!contains(r.granted, .net));
    try testing.expect(contains(r.denied, .net));
}

test "nameFromString round-trips for all known names" {
    inline for (.{ "ai", "save", "net", "raw", "fs_read", "fs_write", "clipboard" }) |s| {
        const n = nameFromString(s).?;
        try testing.expectEqualSlices(u8, s, nameToString(n));
    }
    try testing.expectEqual(@as(?Name, null), nameFromString("camera"));
    try testing.expectEqual(@as(?Name, null), nameFromString(""));
}

test "empty declaration list yields empty resolution" {
    const r = try resolve(&.{}, Policy.allowAll());
    try testing.expectEqual(@as(Set, 0), r.granted);
    try testing.expectEqual(@as(Set, 0), r.denied);
}
