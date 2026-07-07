//! Consensus and drift analysis over the evidence store.
//!
//! Definitions (N = artifact count, k = distinct artifacts holding a primitive):
//!   universal  k == N            everyone agrees
//!   majority   2k > N, k < N     consensus with dissent
//!   minority   1 < k, 2k <= N    a faction
//!   unique     k == 1            one artifact only
//! The consensus core is every primitive with 2k > N. An artifact's drift is
//! 1 - Jaccard(its primitive set, core): 0 = pure consensus, 1 = alien.

const std = @import("std");
const types = @import("types.zig");
const evidence = @import("evidence.zig");

pub const Bucket = enum { universal, majority, minority, unique };

pub const IdentityStat = struct {
    identity: types.Identity,
    kind: types.PrimitiveKind,
    canonical: []const u8,
    artifacts: u32,
    occurrences: u32,
    bucket: Bucket,
};

pub const ArtifactStat = struct {
    id: u32,
    total: u32,
    in_core: u32,
    unique: u32,
    drift: f64,
    outlier: bool,
};

pub const Analysis = struct {
    n_artifacts: usize,
    n_identities: usize,
    total_observations: u64,
    bucket_counts: [4]usize,
    core_size: usize,
    /// Sorted by identity bytes for reproducible output.
    identity_stats: []IdentityStat,
    /// Indexed by artifact id.
    artifact_stats: []ArtifactStat,
    mean_drift: f64,
    std_drift: f64,
};

pub fn bucketOf(k: u32, n: usize) Bucket {
    if (k == n) return .universal;
    if (k == 1) return .unique;
    if (2 * @as(usize, k) > n) return .majority;
    return .minority;
}

pub fn analyze(
    arena: std.mem.Allocator,
    store: *const evidence.Store,
    n_artifacts: usize,
    artifact_sets: []const []const types.Identity,
) !Analysis {
    std.debug.assert(artifact_sets.len == n_artifacts);

    var core = std.AutoHashMap(types.Identity, void).init(arena);
    var uniques = std.AutoHashMap(types.Identity, void).init(arena);
    var bucket_counts = [4]usize{ 0, 0, 0, 0 };

    const stats = try arena.alloc(IdentityStat, store.map.count());
    var it = store.map.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        const obs = entry.value_ptr;
        const k = obs.distinct_artifacts;
        const bucket = bucketOf(k, n_artifacts);
        bucket_counts[@intFromEnum(bucket)] += 1;
        if (2 * @as(usize, k) > n_artifacts) try core.put(entry.key_ptr.*, {});
        if (k == 1 and n_artifacts > 1) try uniques.put(entry.key_ptr.*, {});
        stats[i] = .{
            .identity = entry.key_ptr.*,
            .kind = obs.kind,
            .canonical = obs.canonical,
            .artifacts = k,
            .occurrences = @intCast(obs.occurrences.items.len),
            .bucket = bucket,
        };
    }

    std.mem.sort(IdentityStat, stats, {}, struct {
        fn lessThan(_: void, a: IdentityStat, b: IdentityStat) bool {
            return std.mem.order(u8, &a.identity, &b.identity) == .lt;
        }
    }.lessThan);

    const core_size = core.count();
    const artifact_stats = try arena.alloc(ArtifactStat, n_artifacts);
    var drift_sum: f64 = 0;
    for (artifact_sets, 0..) |set, aid| {
        var in_core: u32 = 0;
        var unique: u32 = 0;
        for (set) |id| {
            if (core.contains(id)) in_core += 1;
            if (uniques.contains(id)) unique += 1;
        }
        const union_size = set.len + core_size - in_core;
        const drift: f64 = if (union_size == 0)
            0
        else
            1.0 - @as(f64, @floatFromInt(in_core)) / @as(f64, @floatFromInt(union_size));
        drift_sum += drift;
        artifact_stats[aid] = .{
            .id = @intCast(aid),
            .total = @intCast(set.len),
            .in_core = in_core,
            .unique = unique,
            .drift = drift,
            .outlier = false,
        };
    }

    const nf: f64 = @floatFromInt(@max(n_artifacts, 1));
    const mean = drift_sum / nf;
    var var_sum: f64 = 0;
    for (artifact_stats) |s| var_sum += (s.drift - mean) * (s.drift - mean);
    const stddev = std.math.sqrt(var_sum / nf);

    // Outlier rule: with enough artifacts and real spread, flag drift beyond
    // mean + 1.5σ. Thresholds are deliberate constants — deterministic, and
    // conservative for tiny corpora where "outlier" has no statistical footing.
    if (n_artifacts >= 4 and stddev > 0.005) {
        const threshold = mean + 1.5 * stddev;
        for (artifact_stats) |*s| {
            if (s.drift > threshold) s.outlier = true;
        }
    }

    return .{
        .n_artifacts = n_artifacts,
        .n_identities = store.map.count(),
        .total_observations = store.total_observations,
        .bucket_counts = bucket_counts,
        .core_size = core_size,
        .identity_stats = stats,
        .artifact_stats = artifact_stats,
        .mean_drift = mean,
        .std_drift = stddev,
    };
}

test "bucketOf boundaries" {
    try std.testing.expectEqual(Bucket.universal, bucketOf(5, 5));
    try std.testing.expectEqual(Bucket.majority, bucketOf(4, 5));
    try std.testing.expectEqual(Bucket.majority, bucketOf(3, 5));
    try std.testing.expectEqual(Bucket.minority, bucketOf(2, 5));
    try std.testing.expectEqual(Bucket.unique, bucketOf(1, 5));
    // Single-artifact corpus: its primitives are universal, not unique.
    try std.testing.expectEqual(Bucket.universal, bucketOf(1, 1));
}

test "analyze finds consensus and ranks drift" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 4 artifacts: 0-2 share a core; 3 is a rogue sharing one key.
    var store = evidence.Store.init(arena);
    var sets = std.ArrayList([]const types.Identity).init(arena);

    const shared = [_][]const u8{ "host=db", "port=5432", "tls=true" };
    const rogue = [_][]const u8{ "host=db", "backdoor=on", "debug=1", "xxx=1", "yyy=2" };

    for (0..3) |aid| {
        var set = std.ArrayList(types.Identity).init(arena);
        for (shared) |c| {
            const r = try store.add(arena, @intCast(aid), .{ .kind = .kv, .canonical = c, .line = 1 });
            if (r.first_for_artifact) try set.append(r.identity);
        }
        try sets.append(try set.toOwnedSlice());
    }
    {
        var set = std.ArrayList(types.Identity).init(arena);
        for (rogue) |c| {
            const r = try store.add(arena, 3, .{ .kind = .kv, .canonical = c, .line = 1 });
            if (r.first_for_artifact) try set.append(r.identity);
        }
        try sets.append(try set.toOwnedSlice());
    }

    const a = try analyze(arena, &store, 4, sets.items);

    try std.testing.expectEqual(@as(usize, 7), a.n_identities);
    // host=db in all 4 → universal; port/tls in 3 of 4 → majority (core);
    // 4 rogue-only keys → unique.
    try std.testing.expectEqual(@as(usize, 1), a.bucket_counts[@intFromEnum(Bucket.universal)]);
    try std.testing.expectEqual(@as(usize, 2), a.bucket_counts[@intFromEnum(Bucket.majority)]);
    try std.testing.expectEqual(@as(usize, 0), a.bucket_counts[@intFromEnum(Bucket.minority)]);
    try std.testing.expectEqual(@as(usize, 4), a.bucket_counts[@intFromEnum(Bucket.unique)]);
    try std.testing.expectEqual(@as(usize, 3), a.core_size);

    // Conforming artifacts have zero drift; the rogue drifts hard and is flagged.
    for (a.artifact_stats[0..3]) |s| {
        try std.testing.expectEqual(@as(f64, 0), s.drift);
        try std.testing.expect(!s.outlier);
    }
    const rogue_stat = a.artifact_stats[3];
    try std.testing.expect(rogue_stat.drift > 0.8);
    try std.testing.expect(rogue_stat.outlier);
    try std.testing.expectEqual(@as(u32, 4), rogue_stat.unique);
    try std.testing.expectEqual(@as(u32, 1), rogue_stat.in_core);
}
