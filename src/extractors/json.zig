//! JSON extractor: parses the document and emits one primitive per leaf as
//! `$.path[i].to.leaf=<canonical scalar>`. Object keys are visited in sorted
//! order so the primitive stream is independent of key order in the source.

const std = @import("std");
const types = @import("../types.zig");

pub const Error = error{Unparseable} || std.mem.Allocator.Error;

pub fn extract(arena: std.mem.Allocator, content: []const u8) Error![]types.Primitive {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, content, .{}) catch
        return error.Unparseable;

    var out = std.ArrayList(types.Primitive).init(arena);
    var path = std.ArrayList(u8).init(arena);
    try path.appendSlice("$");
    try walk(arena, parsed.value, &path, &out);
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
                try path.append('.');
                try path.appendSlice(key);
                try walk(arena, obj.get(key).?, path, out);
                path.shrinkRetainingCapacity(mark);
            }
        },
        .array => |arr| {
            if (arr.items.len == 0) return emit(arena, path.items, "[]", out);
            for (arr.items, 0..) |item, idx| {
                const mark = path.items.len;
                try path.writer().print("[{d}]", .{idx});
                try walk(arena, item, path, out);
                path.shrinkRetainingCapacity(mark);
            }
        },
        else => {
            var buf = std.ArrayList(u8).init(arena);
            std.json.stringify(value, .{}, buf.writer()) catch return error.Unparseable;
            try emit(arena, path.items, buf.items, out);
        },
    }
}

fn emit(
    arena: std.mem.Allocator,
    path: []const u8,
    scalar: []const u8,
    out: *std.ArrayList(types.Primitive),
) Error!void {
    const canonical = try std.mem.concat(arena, u8, &.{ path, "=", scalar });
    try out.append(.{ .kind = .json_leaf, .canonical = canonical, .line = 0 });
}

test "json leaves are emitted in sorted key order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prims = try extract(arena, "{\"b\": 1, \"a\": {\"x\": [true, null]}}");
    try std.testing.expectEqual(@as(usize, 3), prims.len);
    try std.testing.expectEqualStrings("$.a.x[0]=true", prims[0].canonical);
    try std.testing.expectEqualStrings("$.a.x[1]=null", prims[1].canonical);
    try std.testing.expectEqualStrings("$.b=1", prims[2].canonical);
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

test "invalid json is unparseable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.Unparseable, extract(arena_state.allocator(), "{nope"));
}
