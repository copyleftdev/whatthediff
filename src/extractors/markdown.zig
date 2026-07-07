//! Markdown extractor: headings become structural `heading` primitives
//! (`h2:Title`), everything else non-empty becomes normalized `line`
//! primitives.

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

        if (t[0] == '#') {
            var level: usize = 0;
            while (level < t.len and t[level] == '#') level += 1;
            const text = std.mem.trim(u8, t[level..], " \t");
            if (level <= 6 and text.len > 0) {
                const canonical = try std.fmt.allocPrint(arena, "h{d}:{s}", .{ level, text });
                try out.append(.{ .kind = .heading, .canonical = canonical, .line = line_no });
                continue;
            }
        }

        try out.append(.{ .kind = .line, .canonical = try arena.dupe(u8, t), .line = line_no });
    }
    return out.toOwnedSlice();
}

test "markdown headings and lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prims = try extract(arena, "# Title\n\nBody text.\n## Sub\n");
    try std.testing.expectEqual(@as(usize, 3), prims.len);
    try std.testing.expectEqualStrings("h1:Title", prims[0].canonical);
    try std.testing.expectEqual(types.PrimitiveKind.heading, prims[0].kind);
    try std.testing.expectEqualStrings("Body text.", prims[1].canonical);
    try std.testing.expectEqualStrings("h2:Sub", prims[2].canonical);
}
