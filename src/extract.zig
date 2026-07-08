//! Extraction dispatcher: artifact kind → primitive stream.
//! Extractors that can fail on malformed input degrade to the text extractor
//! so every readable artifact yields evidence.

const std = @import("std");
const types = @import("types.zig");
const json = @import("extractors/json.zig");
const yamlish = @import("extractors/yamlish.zig");
const xml = @import("extractors/xml.zig");
const pdf = @import("extractors/pdf.zig");
const binary = @import("extractors/binary.zig");
const config = @import("extractors/config.zig");
const markdown = @import("extractors/markdown.zig");
const text = @import("extractors/text.zig");

pub fn extract(
    arena: std.mem.Allocator,
    kind: types.ArtifactKind,
    content: []const u8,
) ![]types.Primitive {
    return switch (kind) {
        .json => json.extract(arena, content) catch |err| switch (err) {
            error.Unparseable => text.extract(arena, content),
            else => |e| e,
        },
        .yaml => yamlish.extract(arena, content),
        .xml => xml.extract(arena, content) catch |err| switch (err) {
            error.Unparseable => text.extract(arena, content),
            else => |e| e,
        },
        .pdf => pdf.extract(arena, content) catch |err| switch (err) {
            // Binary junk in a .pdf: nothing extractable — never fall back to
            // raw bytes as line primitives.
            error.Unparseable => try arena.alloc(types.Primitive, 0),
            else => |e| e,
        },
        .binary => binary.extract(arena, content),
        .config => config.extract(arena, content),
        .markdown => markdown.extract(arena, content),
        .text => blk: {
            // Extension lied? Sniff JSON and XML payloads in .txt/unknown files.
            const lead = std.mem.trimLeft(u8, content, " \t\r\n");
            if (lead.len > 0 and (lead[0] == '{' or lead[0] == '[')) {
                if (json.extract(arena, content)) |prims| {
                    break :blk prims;
                } else |_| {}
            }
            if (lead.len > 0 and lead[0] == '<') {
                if (xml.extract(arena, content)) |prims| {
                    break :blk prims;
                } else |_| {}
            }
            break :blk text.extract(arena, content);
        },
    };
}

test "malformed json degrades to line primitives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prims = try extract(arena, .json, "{not json at all");
    try std.testing.expectEqual(@as(usize, 1), prims.len);
    try std.testing.expectEqual(types.PrimitiveKind.line, prims[0].kind);
}

test "json payload in a text file is sniffed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prims = try extract(arena, .text, "  {\"a\": 1}");
    try std.testing.expectEqual(@as(usize, 1), prims.len);
    try std.testing.expectEqual(types.PrimitiveKind.kv, prims[0].kind);
    try std.testing.expectEqualStrings("a=1", prims[0].canonical);
}
