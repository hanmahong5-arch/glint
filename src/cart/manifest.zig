//! Cart manifest TOML parser (dx-spec §A.4).
//!
//! Cart authors describe their cart in a `manifest.toml` text file that the
//! `glint pack` command reads, validates, and folds into the cart binary.
//! The manifest is the public schema between cart authors and the engine,
//! so it is intentionally narrow:
//!
//!   [glint]
//!   schema_version = 1            # required; refuses load on bump
//!   title = "demo"                # required; <=16 ASCII bytes
//!   author = "glint-team"         # required; <=16 ASCII bytes
//!   min_engine = "0.0.1"          # required; semver
//!
//!   [caps]                        # optional section; per-name modes
//!   ai = "required"               # required | optional
//!   save = "optional"
//!
//!   [limits]                      # optional; defaults are sensible
//!   heap_kb = 1024
//!   ai_tokens_per_sec = 60
//!
//!   [palette]                     # reserved for v2 palette overrides
//!
//! WHY a hand-rolled subset parser instead of zig-toml: the manifest grammar
//! is intentionally small (sections + key=value), and pulling a third-party
//! parser adds 1500+ LOC and a dependency just to read 20 lines of text.
//! Subset supported: `[section]` headers, `key = "string"` / `key = 42`,
//! `# line comments` (and inline comments outside of strings), and bare
//! identifier values (treated as strings).
//!
//! Subset NOT supported: nested tables, arrays, multi-line strings, dates,
//! booleans, floats. Bumping schema_version is the upgrade path if any of
//! these become necessary.
//!
//! Forward-compatibility: unknown sections and unknown keys inside known
//! sections are ignored (logged in dev panel, not errored). Unknown
//! capability names ARE an error because they correspond to permission
//! requests; silently ignoring would be a security hazard.

const std = @import("std");
const capability = @import("capability.zig");

/// Cart title and author each fit in a 16-byte ASCII field of the cart
/// binary header (see cart/format.zig). Manifests longer than that are
/// rejected at parse time so the failure happens at `glint pack` rather
/// than at `glint run` after upload.
pub const TITLE_MAX: usize = 16;
pub const AUTHOR_MAX: usize = 16;

/// The only schema_version this engine accepts. Manifest authors pin it
/// explicitly; bumping requires a new engine release that supports both
/// the old and new shape (or refuses old shapes with a clear error).
pub const SCHEMA_VERSION: u32 = 1;

/// Defaults per dx-spec §A.4.4. Mirror values printed by `glint new`.
pub const DEFAULT_HEAP_KB: u32 = 1024;
pub const DEFAULT_AI_TOKENS_PER_SEC: u32 = 60;

/// Parsed cart manifest. Strings and the capabilities slice are owned by
/// the manifest and freed by `deinit`. Caller owns the manifest itself.
pub const Manifest = struct {
    schema_version: u32,
    title: []u8,
    author: []u8,
    min_engine: []u8,
    capabilities: []capability.Declaration,
    heap_kb: u32 = DEFAULT_HEAP_KB,
    ai_tokens_per_sec: u32 = DEFAULT_AI_TOKENS_PER_SEC,

    pub fn deinit(self: *Manifest, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.author);
        alloc.free(self.min_engine);
        alloc.free(self.capabilities);
    }
};

pub const Error = error{
    /// File contains no `[glint]` section. Required for any cart.
    MissingGlintSection,
    /// `[glint].schema_version` not present.
    MissingSchemaVersion,
    /// schema_version is a number this engine does not implement.
    UnsupportedSchemaVersion,
    /// `[glint].title` not present.
    MissingTitle,
    /// `[glint].author` not present.
    MissingAuthor,
    /// `[glint].min_engine` not present.
    MissingMinEngine,
    /// title exceeds 16 ASCII bytes.
    TitleTooLong,
    /// author exceeds 16 ASCII bytes.
    AuthorTooLong,
    /// Capability key under [caps] is not one of the engine's known names
    /// (cart/capability.zig). Hard error: silently dropping a permission
    /// request would be a security hazard.
    UnknownCapability,
    /// Capability value is neither "required" nor "optional".
    InvalidCapabilityMode,
    /// Same capability name listed twice under [caps].
    DuplicateCapability,
    /// Line lacks `=` and is not a section header / blank / comment.
    MalformedLine,
    /// Integer field had non-numeric content.
    InvalidInteger,
    OutOfMemory,
};

/// Recognised manifest sections. Unknown sections collapse to `.unknown`
/// (silently skipped) rather than erroring, for forward-compat.
const Section = enum { none, glint, caps, limits, palette, unknown };

/// Parse a manifest from a UTF-8 text buffer. The text is borrowed only
/// for the duration of the call; all retained strings are dup'd into the
/// caller's allocator.
pub fn parse(alloc: std.mem.Allocator, text: []const u8) Error!Manifest {
    var section: Section = .none;
    var saw_glint: bool = false;
    var schema_version: ?u32 = null;
    var title: ?[]u8 = null;
    var author: ?[]u8 = null;
    var min_engine: ?[]u8 = null;
    var heap_kb: u32 = DEFAULT_HEAP_KB;
    var ai_tokens_per_sec: u32 = DEFAULT_AI_TOKENS_PER_SEC;
    var caps_list: std.ArrayList(capability.Declaration) = .empty;
    var caps_seen: capability.Set = 0;

    // Free partial allocations on early-return error paths.
    errdefer {
        if (title) |t| alloc.free(t);
        if (author) |a| alloc.free(a);
        if (min_engine) |m| alloc.free(m);
        caps_list.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;

        // Section header
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            section = sectionFromName(name);
            if (section == .glint) saw_glint = true;
            continue;
        }

        // Key = value
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.MalformedLine;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val_raw = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) return error.MalformedLine;

        switch (section) {
            .none => return error.MissingGlintSection,
            .glint => {
                if (eql(key, "schema_version")) {
                    schema_version = parseUint(val_raw) catch return error.InvalidInteger;
                } else if (eql(key, "title")) {
                    const s = unquote(val_raw);
                    if (s.len > TITLE_MAX) return error.TitleTooLong;
                    if (title) |t| alloc.free(t);
                    title = try alloc.dupe(u8, s);
                } else if (eql(key, "author")) {
                    const s = unquote(val_raw);
                    if (s.len > AUTHOR_MAX) return error.AuthorTooLong;
                    if (author) |a| alloc.free(a);
                    author = try alloc.dupe(u8, s);
                } else if (eql(key, "min_engine")) {
                    const s = unquote(val_raw);
                    if (min_engine) |m| alloc.free(m);
                    min_engine = try alloc.dupe(u8, s);
                }
                // Unknown keys in [glint] silently ignored (forward-compat).
            },
            .caps => {
                const cap_name = capability.nameFromString(key) orelse return error.UnknownCapability;
                const b = capability.bit(cap_name);
                if ((caps_seen & b) != 0) return error.DuplicateCapability;
                caps_seen |= b;
                const mode_str = unquote(val_raw);
                const mode: capability.Mode = if (eql(mode_str, "required")) .required
                else if (eql(mode_str, "optional")) .optional
                else return error.InvalidCapabilityMode;
                caps_list.append(alloc, .{ .name = cap_name, .mode = mode }) catch return error.OutOfMemory;
            },
            .limits => {
                if (eql(key, "heap_kb")) {
                    heap_kb = parseUint(val_raw) catch return error.InvalidInteger;
                } else if (eql(key, "ai_tokens_per_sec")) {
                    ai_tokens_per_sec = parseUint(val_raw) catch return error.InvalidInteger;
                }
                // Unknown limits keys silently ignored.
            },
            .palette, .unknown => {
                // Reserved / forward-compat: silently accept and discard.
            },
        }
    }

    if (!saw_glint) return error.MissingGlintSection;
    const sv = schema_version orelse return error.MissingSchemaVersion;
    if (sv != SCHEMA_VERSION) return error.UnsupportedSchemaVersion;

    return .{
        .schema_version = sv,
        .title = title orelse return error.MissingTitle,
        .author = author orelse return error.MissingAuthor,
        .min_engine = min_engine orelse return error.MissingMinEngine,
        .capabilities = caps_list.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .heap_kb = heap_kb,
        .ai_tokens_per_sec = ai_tokens_per_sec,
    };
}

inline fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn sectionFromName(name: []const u8) Section {
    if (eql(name, "glint")) return .glint;
    if (eql(name, "caps")) return .caps;
    if (eql(name, "limits")) return .limits;
    if (eql(name, "palette")) return .palette;
    return .unknown;
}

/// Strip an inline `# ...` comment from a line. `#` inside a double-quoted
/// string does not start a comment. Single-quoted strings are also handled
/// (TOML literal-string syntax).
fn stripComment(line: []const u8) []const u8 {
    var in_dq: bool = false;
    var in_sq: bool = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '"' and !in_sq) in_dq = !in_dq;
        if (c == '\'' and !in_dq) in_sq = !in_sq;
        if (c == '#' and !in_dq and !in_sq) return line[0..i];
    }
    return line;
}

/// Strip outer matching quotes. Bare values pass through unchanged so the
/// manifest can write `mode = required` without needing quotes.
fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

fn parseUint(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, s, 10);
}

// ---------------- tests ----------------

const testing = std.testing;

test "minimal valid manifest parses" {
    const src =
        \\[glint]
        \\schema_version = 1
        \\title = "demo"
        \\author = "ada"
        \\min_engine = "0.0.1"
        \\
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), m.schema_version);
    try testing.expectEqualSlices(u8, "demo", m.title);
    try testing.expectEqualSlices(u8, "ada", m.author);
    try testing.expectEqualSlices(u8, "0.0.1", m.min_engine);
    try testing.expectEqual(@as(usize, 0), m.capabilities.len);
    try testing.expectEqual(DEFAULT_HEAP_KB, m.heap_kb);
}

test "comments and blank lines are skipped" {
    const src =
        \\# top comment
        \\
        \\[glint]   # trailing comment
        \\schema_version = 1
        \\# inside section
        \\title = "x"  # trailing
        \\author = "y"
        \\min_engine = "0.0.1"
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "x", m.title);
}

test "caps section parses required + optional" {
    const src =
        \\[glint]
        \\schema_version = 1
        \\title = "g"
        \\author = "a"
        \\min_engine = "0.0.1"
        \\
        \\[caps]
        \\ai = "required"
        \\save = "optional"
        \\net = "optional"
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), m.capabilities.len);

    var have_ai_required: bool = false;
    var have_save_optional: bool = false;
    var have_net_optional: bool = false;
    for (m.capabilities) |c| {
        if (c.name == .ai and c.mode == .required) have_ai_required = true;
        if (c.name == .save and c.mode == .optional) have_save_optional = true;
        if (c.name == .net and c.mode == .optional) have_net_optional = true;
    }
    try testing.expect(have_ai_required);
    try testing.expect(have_save_optional);
    try testing.expect(have_net_optional);
}

test "bare values work for cap modes" {
    const src =
        \\[glint]
        \\schema_version = 1
        \\title = "g"
        \\author = "a"
        \\min_engine = "0.0.1"
        \\[caps]
        \\ai = required
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(capability.Mode.required, m.capabilities[0].mode);
}

test "limits override defaults" {
    const src =
        \\[glint]
        \\schema_version = 1
        \\title = "g"
        \\author = "a"
        \\min_engine = "0.0.1"
        \\[limits]
        \\heap_kb = 256
        \\ai_tokens_per_sec = 30
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 256), m.heap_kb);
    try testing.expectEqual(@as(u32, 30), m.ai_tokens_per_sec);
}

test "missing schema_version is an error" {
    const src =
        \\[glint]
        \\title = "g"
        \\author = "a"
        \\min_engine = "0.0.1"
    ;
    try testing.expectError(error.MissingSchemaVersion, parse(testing.allocator, src));
}

test "wrong schema_version is rejected" {
    const src =
        \\[glint]
        \\schema_version = 99
        \\title = "g"
        \\author = "a"
        \\min_engine = "0.0.1"
    ;
    try testing.expectError(error.UnsupportedSchemaVersion, parse(testing.allocator, src));
}

test "missing title / author / min_engine are errors" {
    const m1 = parse(testing.allocator, "[glint]\nschema_version = 1\nauthor=\"a\"\nmin_engine=\"0.0.1\"");
    try testing.expectError(error.MissingTitle, m1);
    const m2 = parse(testing.allocator, "[glint]\nschema_version = 1\ntitle=\"x\"\nmin_engine=\"0.0.1\"");
    try testing.expectError(error.MissingAuthor, m2);
    const m3 = parse(testing.allocator, "[glint]\nschema_version = 1\ntitle=\"x\"\nauthor=\"a\"");
    try testing.expectError(error.MissingMinEngine, m3);
}

test "title or author over 16 bytes is rejected" {
    const too_long_title =
        \\[glint]
        \\schema_version = 1
        \\title = "abcdefghijklmnopq"
        \\author = "a"
        \\min_engine = "0.0.1"
    ;
    try testing.expectError(error.TitleTooLong, parse(testing.allocator, too_long_title));

    const too_long_author =
        \\[glint]
        \\schema_version = 1
        \\title = "ok"
        \\author = "abcdefghijklmnopq"
        \\min_engine = "0.0.1"
    ;
    try testing.expectError(error.AuthorTooLong, parse(testing.allocator, too_long_author));
}

test "unknown capability name is an error" {
    const src =
        \\[glint]
        \\schema_version = 1
        \\title = "g"
        \\author = "a"
        \\min_engine = "0.0.1"
        \\[caps]
        \\camera = "required"
    ;
    try testing.expectError(error.UnknownCapability, parse(testing.allocator, src));
}

test "duplicate capability entries are rejected" {
    const src =
        \\[glint]
        \\schema_version = 1
        \\title = "g"
        \\author = "a"
        \\min_engine = "0.0.1"
        \\[caps]
        \\ai = "required"
        \\ai = "optional"
    ;
    try testing.expectError(error.DuplicateCapability, parse(testing.allocator, src));
}

test "invalid cap mode is rejected" {
    const src =
        \\[glint]
        \\schema_version = 1
        \\title = "g"
        \\author = "a"
        \\min_engine = "0.0.1"
        \\[caps]
        \\ai = "maybe"
    ;
    try testing.expectError(error.InvalidCapabilityMode, parse(testing.allocator, src));
}

test "missing [glint] section is an error" {
    const src =
        \\[caps]
        \\ai = "required"
    ;
    try testing.expectError(error.MissingGlintSection, parse(testing.allocator, src));
}

test "key without = is malformed" {
    const src =
        \\[glint]
        \\schema_version 1
    ;
    try testing.expectError(error.MalformedLine, parse(testing.allocator, src));
}

test "unknown sections are silently accepted (forward-compat)" {
    const src =
        \\[glint]
        \\schema_version = 1
        \\title = "g"
        \\author = "a"
        \\min_engine = "0.0.1"
        \\[future_section]
        \\anything = "goes"
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "g", m.title);
}

test "# inside double-quoted string is not a comment" {
    const src =
        \\[glint]
        \\schema_version = 1
        \\title = "a#b"
        \\author = "x"
        \\min_engine = "0.0.1"
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "a#b", m.title);
}

test "single-quoted (literal) strings work" {
    const src =
        \\[glint]
        \\schema_version = 1
        \\title = 'demo'
        \\author = "x"
        \\min_engine = "0.0.1"
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "demo", m.title);
}

test "non-numeric integer field is rejected" {
    const src =
        \\[glint]
        \\schema_version = "one"
        \\title = "x"
        \\author = "y"
        \\min_engine = "0.0.1"
    ;
    try testing.expectError(error.InvalidInteger, parse(testing.allocator, src));
}

test "title exactly at 16 bytes is accepted" {
    const src =
        \\[glint]
        \\schema_version = 1
        \\title = "abcdefghijklmnop"
        \\author = "x"
        \\min_engine = "0.0.1"
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 16), m.title.len);
}
