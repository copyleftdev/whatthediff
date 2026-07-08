//! YAML-lite extractor. Not a YAML parser: it tracks an indentation stack of
//! mapping keys and emits `kv` primitives in the cross-format canonical form
//! shared with the JSON and config extractors (`db.port=5432`,
//! `features[]=x`) — so the same fact in YAML and JSON hashes to the same
//! identity. Handles nested maps, scalar list items, and list-of-maps
//! (`- key: value` with continuation lines). Lines that don't fit degrade to
//! `line` primitives instead of being dropped.

const std = @import("std");
const types = @import("../types.zig");

const Frame = struct {
    indent: usize,
    key: []const u8,
};

pub fn extract(arena: std.mem.Allocator, content: []const u8) ![]types.Primitive {
    var out = std.ArrayList(types.Primitive).init(arena);
    var stack = std.ArrayList(Frame).init(arena);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const no_cr = std.mem.trimRight(u8, raw, "\r");
        const t = std.mem.trim(u8, no_cr, " \t");
        if (t.len == 0 or t[0] == '#') continue;
        if (std.mem.eql(u8, t, "---") or std.mem.eql(u8, t, "...")) {
            stack.clearRetainingCapacity();
            continue;
        }

        const indent = no_cr.len - std.mem.trimLeft(u8, no_cr, " \t").len;
        while (stack.items.len > 0 and stack.items[stack.items.len - 1].indent >= indent) {
            _ = stack.pop();
        }

        if (std.mem.startsWith(u8, t, "- ")) {
            const rest = std.mem.trimLeft(u8, t[2..], " \t");
            if (std.mem.indexOfScalar(u8, rest, ':')) |sep| {
                // List-of-maps item: `- key: value`. Open a synthetic []
                // frame anchored just past the dash so continuation lines
                // (`  key2: value2` at deeper indent) join the same element,
                // and a following `- ` at the dash's indent closes it.
                try stack.append(.{ .indent = indent + 1, .key = "[]" });
                try handlePair(arena, &stack, &out, rest, sep, indent + 2, line_no);
            } else {
                const item = std.mem.trim(u8, rest, " \t\"'");
                if (item.len == 0) continue;
                const canonical = try joinPath(arena, stack.items, "[]", item);
                try out.append(.{ .kind = .kv, .canonical = canonical, .line = line_no });
            }
            continue;
        }

        if (std.mem.indexOfScalar(u8, t, ':')) |sep| {
            try handlePair(arena, &stack, &out, t, sep, indent, line_no);
            continue;
        }

        try out.append(.{ .kind = .line, .canonical = try arena.dupe(u8, t), .line = line_no });
    }
    return out.toOwnedSlice();
}

/// Process a `key: value` pair at the given effective indent: emit a kv
/// primitive, or push a mapping frame when the value is empty / a block
/// scalar marker.
fn handlePair(
    arena: std.mem.Allocator,
    stack: *std.ArrayList(Frame),
    out: *std.ArrayList(types.Primitive),
    pair: []const u8,
    sep: usize,
    indent: usize,
    line_no: u32,
) !void {
    const key = std.mem.trim(u8, pair[0..sep], " \t\"'");
    const value = std.mem.trim(u8, pair[sep + 1 ..], " \t\"'");
    if (key.len == 0) return;
    if (value.len == 0 or std.mem.eql(u8, value, "|") or std.mem.eql(u8, value, ">")) {
        try stack.append(.{ .indent = indent, .key = try arena.dupe(u8, key) });
        return;
    }
    const canonical = try joinPath(arena, stack.items, key, value);
    try out.append(.{ .kind = .kv, .canonical = canonical, .line = line_no });
}

fn joinPath(
    arena: std.mem.Allocator,
    frames: []const Frame,
    key: []const u8,
    value: []const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(arena);
    for (frames) |frame| try appendSegment(&buf, frame.key);
    try appendSegment(&buf, key);
    try buf.append('=');
    try buf.appendSlice(value);
    return buf.toOwnedSlice();
}

/// `[]` attaches to the previous segment (`servers[]`); named keys are
/// dot-separated (`db.port`) — matching the JSON extractor's form exactly.
fn appendSegment(buf: *std.ArrayList(u8), seg: []const u8) !void {
    if (std.mem.eql(u8, seg, "[]")) {
        try buf.appendSlice("[]");
    } else {
        if (buf.items.len > 0) try buf.append('.');
        try buf.appendSlice(seg);
    }
}

test "yamlish nested paths and lists" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\# comment
        \\service: api
        \\db:
        \\  host: localhost
        \\  port: 5432
        \\features:
        \\  - alpha
        \\  - beta
        \\replicas: 3
    ;
    const prims = try extract(arena, src);
    try std.testing.expectEqual(@as(usize, 6), prims.len);
    try std.testing.expectEqualStrings("service=api", prims[0].canonical);
    try std.testing.expectEqualStrings("db.host=localhost", prims[1].canonical);
    try std.testing.expectEqualStrings("db.port=5432", prims[2].canonical);
    try std.testing.expectEqualStrings("features[]=alpha", prims[3].canonical);
    try std.testing.expectEqualStrings("features[]=beta", prims[4].canonical);
    try std.testing.expectEqualStrings("replicas=3", prims[5].canonical);
}

test "yamlish list-of-maps with continuation lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\servers:
        \\  - host: a
        \\    port: 1
        \\  - host: b
        \\tls: true
    ;
    const prims = try extract(arena, src);
    try std.testing.expectEqual(@as(usize, 4), prims.len);
    try std.testing.expectEqualStrings("servers[].host=a", prims[0].canonical);
    try std.testing.expectEqualStrings("servers[].port=1", prims[1].canonical);
    try std.testing.expectEqualStrings("servers[].host=b", prims[2].canonical);
    try std.testing.expectEqualStrings("tls=true", prims[3].canonical);
}

test "yamlish nested map inside a list item" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\servers:
        \\  - db:
        \\      host: x
        \\    port: 1
    ;
    const prims = try extract(arena, src);
    try std.testing.expectEqual(@as(usize, 2), prims.len);
    try std.testing.expectEqualStrings("servers[].db.host=x", prims[0].canonical);
    try std.testing.expectEqualStrings("servers[].port=1", prims[1].canonical);
}

test "yamlish document separator resets the stack" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prims = try extract(arena, "a:\n  b: 1\n---\nc: 2\n");
    try std.testing.expectEqual(@as(usize, 2), prims.len);
    try std.testing.expectEqualStrings("a.b=1", prims[0].canonical);
    try std.testing.expectEqualStrings("c=2", prims[1].canonical);
}
