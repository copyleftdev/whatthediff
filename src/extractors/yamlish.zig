//! YAML-lite extractor. Not a YAML parser: it tracks an indentation stack of
//! mapping keys and emits `kv` primitives as dotted paths — enough to make
//! typical config-style YAML comparable by meaning. Lines that don't fit the
//! key/value shape degrade to `line` primitives instead of being dropped.

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
            const item = std.mem.trim(u8, t[2..], " \t\"'");
            const canonical = try joinPath(arena, stack.items, "[]", item);
            try out.append(.{ .kind = .kv, .canonical = canonical, .line = line_no });
            continue;
        }

        if (std.mem.indexOfScalar(u8, t, ':')) |sep| {
            const key = std.mem.trim(u8, t[0..sep], " \t\"'");
            const value = std.mem.trim(u8, t[sep + 1 ..], " \t\"'");
            if (key.len == 0) continue;
            if (value.len == 0 or std.mem.eql(u8, value, "|") or std.mem.eql(u8, value, ">")) {
                try stack.append(.{ .indent = indent, .key = try arena.dupe(u8, key) });
                continue;
            }
            const canonical = try joinPath(arena, stack.items, key, value);
            try out.append(.{ .kind = .kv, .canonical = canonical, .line = line_no });
            continue;
        }

        try out.append(.{ .kind = .line, .canonical = try arena.dupe(u8, t), .line = line_no });
    }
    return out.toOwnedSlice();
}

fn joinPath(
    arena: std.mem.Allocator,
    frames: []const Frame,
    key: []const u8,
    value: []const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(arena);
    for (frames) |frame| {
        try buf.appendSlice(frame.key);
        try buf.append('.');
    }
    if (std.mem.eql(u8, key, "[]")) {
        // List item: drop the trailing dot, use `path[]=value`.
        if (buf.items.len > 0) buf.shrinkRetainingCapacity(buf.items.len - 1);
        try buf.appendSlice("[]");
    } else {
        try buf.appendSlice(key);
    }
    try buf.append('=');
    try buf.appendSlice(value);
    return buf.toOwnedSlice();
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

test "yamlish document separator resets the stack" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prims = try extract(arena, "a:\n  b: 1\n---\nc: 2\n");
    try std.testing.expectEqual(@as(usize, 2), prims.len);
    try std.testing.expectEqualStrings("a.b=1", prims[0].canonical);
    try std.testing.expectEqualStrings("c=2", prims[1].canonical);
}
