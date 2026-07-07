//! Fallback extractor: every trimmed, non-empty line is a `line` primitive.

const std = @import("std");
const types = @import("../types.zig");

pub fn extract(arena: std.mem.Allocator, content: []const u8) ![]types.Primitive {
    var out = std.ArrayList(types.Primitive).init(arena);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len == 0) continue;
        try out.append(.{ .kind = .line, .canonical = try arena.dupe(u8, t), .line = line_no });
    }
    return out.toOwnedSlice();
}

test "text lines are trimmed and blank lines dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prims = try extract(arena, "  hello \r\n\n\tworld\n");
    try std.testing.expectEqual(@as(usize, 2), prims.len);
    try std.testing.expectEqualStrings("hello", prims[0].canonical);
    try std.testing.expectEqualStrings("world", prims[1].canonical);
    try std.testing.expectEqual(@as(u32, 1), prims[0].line);
    try std.testing.expectEqual(@as(u32, 3), prims[1].line);
}
