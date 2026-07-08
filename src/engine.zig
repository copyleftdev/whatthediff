//! Pipeline orchestration: discovery → read → extract → evidence → analysis.
//! One artifact is fed to the store completely before the next, which is the
//! ordering contract `evidence.Store.add` relies on.

const std = @import("std");
const types = @import("types.zig");
const discovery = @import("discovery.zig");
const extract = @import("extract.zig");
const evidence = @import("evidence.zig");
const analysis = @import("analysis.zig");
const cluster = @import("cluster.zig");

pub const max_artifact_bytes: usize = 64 * 1024 * 1024;

pub const Corpus = struct {
    artifacts: []types.Artifact,
    store: evidence.Store,
    /// Per-artifact deduplicated identity-index sets (dense u32 indexes into
    /// the store), indexed by artifact id.
    sets: [][]u32,
    analysis: analysis.Analysis,
    /// Factions: groups deviating from consensus in the same way.
    clusters: cluster.Clusters,
    /// Files skipped as binary, oversized, or unreadable.
    skipped: u32,
};

pub fn run(arena: std.mem.Allocator, paths: []const []const u8) !Corpus {
    const files = try discovery.discover(arena, paths);

    var artifacts = std.ArrayList(types.Artifact).init(arena);
    var sets = std.ArrayList([]u32).init(arena);
    var store = evidence.Store.init(arena);
    var skipped: u32 = 0;

    // Streaming property: file contents, parse trees, and canonical scratch
    // live in a per-artifact arena that is reset after every file. Only the
    // store (one canonical copy per distinct fact), the u32 index sets, and
    // artifact metadata survive — resident memory scales with distinct
    // facts, not corpus bytes.
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_state.deinit();

    for (files) |f| {
        _ = scratch_state.reset(.retain_capacity);
        const scratch = scratch_state.allocator();

        const content = std.fs.cwd().readFileAlloc(scratch, f.path, max_artifact_bytes) catch {
            skipped += 1;
            continue;
        };
        // PDFs are legitimately binary; the extractor handles them.
        if (f.kind != .pdf and isBinary(content)) {
            skipped += 1;
            continue;
        }

        const id: u32 = @intCast(artifacts.items.len);
        const prims = try extract.extract(scratch, f.kind, content);

        var set = std.ArrayList(u32).init(arena);
        for (prims) |p| {
            const r = try store.add(id, p);
            if (r.first_for_artifact) try set.append(r.index);
        }

        try artifacts.append(.{
            .id = id,
            .path = f.path,
            .kind = f.kind,
            .size = content.len,
        });
        try sets.append(try set.toOwnedSlice());
    }

    const result = try analysis.analyze(arena, &store, artifacts.items.len, sets.items);
    const clusters = try cluster.detect(arena, &store, &result, sets.items);

    return .{
        .artifacts = try artifacts.toOwnedSlice(),
        .store = store,
        .sets = try sets.toOwnedSlice(),
        .analysis = result,
        .clusters = clusters,
        .skipped = skipped,
    };
}

fn isBinary(content: []const u8) bool {
    const window = content[0..@min(content.len, 8192)];
    return std.mem.indexOfScalar(u8, window, 0) != null;
}

test "isBinary detects NUL bytes" {
    try std.testing.expect(isBinary("ab\x00cd"));
    try std.testing.expect(!isBinary("plain text\n"));
}

test "end-to-end pipeline over a temp corpus" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "a.json", .data = "{\"port\": 80, \"tls\": true}" });
    try tmp.dir.writeFile(.{ .sub_path = "b.json", .data = "{\"tls\": true, \"port\": 80}" });
    try tmp.dir.writeFile(.{ .sub_path = "c.json", .data = "{\"port\": 9999}" });
    try tmp.dir.writeFile(.{ .sub_path = "junk.bin", .data = "\x00\x01\x02" });

    const root = try tmp.dir.realpathAlloc(arena, ".");
    const corpus = try run(arena, &.{root});

    try std.testing.expectEqual(@as(usize, 3), corpus.artifacts.len);
    try std.testing.expectEqual(@as(u32, 1), corpus.skipped);

    // a.json and b.json differ only in key order → identical identity sets.
    try std.testing.expectEqual(@as(usize, 2), corpus.sets[0].len);
    try std.testing.expectEqualSlices(u32, corpus.sets[0], corpus.sets[1]);

    // port=80 and tls=true are majority (2/3); c.json's port=9999 is unique.
    const a = corpus.analysis;
    try std.testing.expectEqual(@as(usize, 3), a.n_identities);
    try std.testing.expectEqual(@as(usize, 2), a.core_size);
    try std.testing.expectEqual(@as(usize, 1), a.bucket_counts[@intFromEnum(analysis.Bucket.unique)]);
    try std.testing.expect(a.artifact_stats[2].drift > a.artifact_stats[0].drift);
}
