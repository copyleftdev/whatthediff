//! JSON extractor: parses the document and emits one `kv` primitive per leaf
//! using the cross-format canonical form shared with the YAML-lite and config
//! extractors — `db.port=5432`, list items as `features[]=x` (index-less: a
//! list is a bag, so reordering is not a semantic difference), scalars
//! unquoted. The same fact in JSON, YAML, or INI therefore hashes to the
//! same identity. Object keys are visited in sorted order so the primitive
//! stream is independent of key order in the source.
//!
//! JSONC tolerant: `tsconfig.json`, VS Code `settings.json`, and
//! `devcontainer.json` are JSON *with comments* and trailing commas. Strict
//! JSON fails on those, so on a parse error the input is sanitized (comments
//! and trailing commas stripped, string literals preserved) and reparsed.
//! Clean JSON never takes that path, so it stays fast at scale.

const std = @import("std");
const types = @import("../types.zig");

pub const Error = error{Unparseable} || std.mem.Allocator.Error;

pub fn extract(arena: std.mem.Allocator, content: []const u8) Error![]types.Primitive {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, content, .{}) catch blk: {
        // Might be JSONC — strip comments/trailing commas and try once more.
        const cleaned = try stripJsonc(arena, content);
        break :blk std.json.parseFromSlice(std.json.Value, arena, cleaned, .{}) catch
            return error.Unparseable;
    };

    var out = std.ArrayList(types.Primitive).init(arena);
    var path = std.ArrayList(u8).init(arena);
    try walk(arena, parsed.value, &path, &out);
    return out.toOwnedSlice();
}

/// Sanitize JSONC to JSON: drop `//` line and `/* */` block comments and
/// trailing commas before `}`/`]`. String literals (and any `//` or `,}`
/// inside them) are copied verbatim; insignificant whitespace is collapsed,
/// which is safe because valid JSON always separates tokens with structural
/// characters.
fn stripJsonc(arena: std.mem.Allocator, src: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    var i: usize = 0;
    var pending_comma = false; // a comma awaiting a decision: keep, or drop if trailing

    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            if (pending_comma) {
                try out.append(',');
                pending_comma = false;
            }
            try out.append(c);
            i += 1;
            while (i < src.len) {
                const d = src[i];
                try out.append(d);
                i += 1;
                if (d == '\\') {
                    if (i < src.len) {
                        try out.append(src[i]);
                        i += 1;
                    }
                } else if (d == '"') break;
            }
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            i += 2;
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            i = @min(i + 2, src.len);
            continue;
        }
        if (c == ',') {
            pending_comma = true;
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        // A significant, non-string character: resolve any pending comma.
        if (pending_comma) {
            if (c != '}' and c != ']') try out.append(',');
            pending_comma = false;
        }
        try out.append(c);
        i += 1;
    }
    return out.toOwnedSlice();
}

fn walk(
    arena: std.mem.Allocator,
    value: std.json.Value,
    path: *std.ArrayList(u8),
    out: *std.ArrayList(types.Primitive),
) Error!void {
    switch (value) {
        .object => |obj| {
            if (obj.count() == 0) return emit(arena, path.items, "{}", out);

            const keys = try arena.alloc([]const u8, obj.count());
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) keys[i] = entry.key_ptr.*;
            std.mem.sort([]const u8, keys, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);

            for (keys) |key| {
                const mark = path.items.len;
                if (path.items.len > 0) try path.append('.');
                try path.appendSlice(key);
                try walk(arena, obj.get(key).?, path, out);
                path.shrinkRetainingCapacity(mark);
            }
        },
        .array => |arr| {
            if (arr.items.len == 0) return emit(arena, path.items, "[]", out);
            const mark = path.items.len;
            try path.appendSlice("[]");
            for (arr.items) |item| {
                try walk(arena, item, path, out);
            }
            path.shrinkRetainingCapacity(mark);
        },
        else => try emit(arena, path.items, try scalarText(arena, value), out),
    }
}

/// Cross-format scalar canonicalization: bare text, no quotes. This means a
/// JSON string "5432" and number 5432 collide deliberately — text formats
/// like YAML and INI cannot tell them apart, so neither should identity.
fn scalarText(arena: std.mem.Allocator, value: std.json.Value) Error![]const u8 {
    return switch (value) {
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        .number_string => |s| s,
        .string => |s| s,
        else => unreachable,
    };
}

fn emit(
    arena: std.mem.Allocator,
    path: []const u8,
    scalar: []const u8,
    out: *std.ArrayList(types.Primitive),
) Error!void {
    // A whole-document scalar has no path; "$" keeps the canonical non-empty.
    const key = if (path.len == 0) "$" else path;
    const canonical = try std.mem.concat(arena, u8, &.{ key, "=", scalar });
    try out.append(.{ .kind = .kv, .canonical = canonical, .line = 0 });
}

test "json leaves use the cross-format canonical form" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prims = try extract(arena, "{\"b\": 1, \"a\": {\"x\": [true, null]}, \"s\": \"v0\"}");
    try std.testing.expectEqual(@as(usize, 4), prims.len);
    try std.testing.expectEqualStrings("a.x[]=true", prims[0].canonical);
    try std.testing.expectEqualStrings("a.x[]=null", prims[1].canonical);
    try std.testing.expectEqualStrings("b=1", prims[2].canonical);
    try std.testing.expectEqualStrings("s=v0", prims[3].canonical);
    for (prims) |p| try std.testing.expectEqual(types.PrimitiveKind.kv, p.kind);
}

test "json key order does not change identities" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try extract(arena, "{\"x\": 1, \"y\": \"s\"}");
    const b = try extract(arena, "{ \"y\":\"s\",\n  \"x\": 1 }");
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |pa, pb| try std.testing.expectEqualStrings(pa.canonical, pb.canonical);
}

test "json array order does not change the identity set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try extract(arena, "{\"f\": [\"m\", \"t\"]}");
    const b = try extract(arena, "{\"f\": [\"t\", \"m\"]}");
    // Index-less lists: same items, any order → same canonicals as a set.
    try std.testing.expectEqual(@as(usize, 2), a.len);
    try std.testing.expectEqualStrings("f[]=m", a[0].canonical);
    try std.testing.expectEqualStrings("f[]=t", a[1].canonical);
    try std.testing.expectEqualStrings("f[]=t", b[0].canonical);
    try std.testing.expectEqualStrings("f[]=m", b[1].canonical);
}

test "whole-document scalar and empty containers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try extract(arena, "42");
    try std.testing.expectEqualStrings("$=42", s[0].canonical);
    const e = try extract(arena, "{\"a\": {}, \"b\": []}");
    try std.testing.expectEqualStrings("a={}", e[0].canonical);
    try std.testing.expectEqualStrings("b=[]", e[1].canonical);
}

test "invalid json is unparseable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.Unparseable, extract(arena_state.allocator(), "{nope"));
}

test "JSONC (tsconfig-style comments + trailing commas) parses to kv" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\{
        \\  // line comment
        \\  "compilerOptions": {
        \\    "strict": true,   /* block comment */
        \\    "target": "ES2020",
        \\  },
        \\  "include": ["src",],
        \\}
    ;
    const prims = try extract(arena, src);
    try std.testing.expectEqual(@as(usize, 3), prims.len);
    try std.testing.expectEqualStrings("compilerOptions.strict=true", prims[0].canonical);
    try std.testing.expectEqualStrings("compilerOptions.target=ES2020", prims[1].canonical);
    try std.testing.expectEqualStrings("include[]=src", prims[2].canonical);
    for (prims) |p| try std.testing.expectEqual(types.PrimitiveKind.kv, p.kind);
}

test "JSONC sanitizer never touches comment-like sequences inside strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A comment forces the JSONC path; the URL string must survive intact.
    const src =
        \\{
        \\  "url": "http://example.com//path",  // trailing comment
        \\  "note": "trailing comma, brace }",
        \\}
    ;
    const prims = try extract(arena, src);
    try std.testing.expectEqual(@as(usize, 2), prims.len);
    try std.testing.expectEqualStrings("note=trailing comma, brace }", prims[0].canonical);
    try std.testing.expectEqualStrings("url=http://example.com//path", prims[1].canonical);
}

test "a JSONC document in a text file is sniffed and unified with pure JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const jsonc = try extract(arena, "{ \"a\": 1, // c\n }");
    const pure = try extract(arena, "{\"a\": 1}");
    try std.testing.expectEqual(pure.len, jsonc.len);
    try std.testing.expectEqualStrings(pure[0].canonical, jsonc[0].canonical);
}
