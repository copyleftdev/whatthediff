const std = @import("std");
const cli = @import("cli.zig");

pub fn main() !void {
    // Run-once CLI: a single arena for the whole execution, freed on exit.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    const code = try cli.run(arena, args[1..]);
    std.process.exit(code);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("types.zig");
    _ = @import("hash.zig");
    _ = @import("discovery.zig");
    _ = @import("extract.zig");
    _ = @import("extractors/json.zig");
    _ = @import("extractors/yamlish.zig");
    _ = @import("extractors/xml.zig");
    _ = @import("extractors/pdf.zig");
    _ = @import("extractors/binary.zig");
    _ = @import("extractors/cbor.zig");
    _ = @import("extractors/config.zig");
    _ = @import("extractors/markdown.zig");
    _ = @import("extractors/text.zig");
    _ = @import("evidence.zig");
    _ = @import("analysis.zig");
    _ = @import("engine.zig");
    _ = @import("render.zig");
    _ = @import("cli.zig");
    _ = @import("proptest.zig");
    _ = @import("cluster.zig");
    _ = @import("ai.zig");
    _ = @import("ask.zig");
}
