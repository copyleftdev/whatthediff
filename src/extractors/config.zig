//! Config extractor for INI/env/properties/TOML-lite files.
//! Emits `kv` primitives as `section.key=value`; comments and blanks vanish,
//! so formatting churn never registers as difference.

const std = @import("std");
const types = @import("../types.zig");

pub fn extract(arena: std.mem.Allocator, content: []const u8) ![]types.Primitive {
    var out = std.ArrayList(types.Primitive).init(arena);
    var section: []const u8 = "";

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len == 0 or t[0] == '#' or t[0] == ';') continue;

        if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']') {
            section = std.mem.trim(u8, t[1 .. t.len - 1], " \t");
            continue;
        }

        const sep = separatorIndex(t) orelse {
            // Not key/value shaped; keep it as a line so nothing is lost.
            try out.append(.{
                .kind = .line,
                .canonical = try arena.dupe(u8, t),
                .line = line_no,
            });
            continue;
        };

        const key = std.mem.trim(u8, t[0..sep], " \t");
        const value = std.mem.trim(u8, t[sep + 1 ..], " \t\"'");
        if (key.len == 0) continue;

        const canonical = if (section.len > 0)
            try std.mem.concat(arena, u8, &.{ section, ".", key, "=", value })
        else
            try std.mem.concat(arena, u8, &.{ key, "=", value });
        try out.append(.{ .kind = .kv, .canonical = canonical, .line = line_no });
    }
    return out.toOwnedSlice();
}

fn separatorIndex(line: []const u8) ?usize {
    for (line, 0..) |c, i| {
        if (c == '=' or c == ':') return i;
    }
    return null;
}

test "config kv with sections, comments, and quotes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\# comment
        \\timeout = 30
        \\
        \\[db]
        \\host = "localhost"
        \\port: 5432
    ;
    const prims = try extract(arena, src);
    try std.testing.expectEqual(@as(usize, 3), prims.len);
    try std.testing.expectEqualStrings("timeout=30", prims[0].canonical);
    try std.testing.expectEqualStrings("db.host=localhost", prims[1].canonical);
    try std.testing.expectEqualStrings("db.port=5432", prims[2].canonical);
    try std.testing.expectEqual(@as(u32, 2), prims[0].line);
    try std.testing.expectEqual(types.PrimitiveKind.kv, prims[0].kind);
}
