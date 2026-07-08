//! Faction detection: groups of artifacts that deviate from the consensus
//! in the same way.
//!
//! Clustering runs over *minority* primitives only (1 < k, 2k <= N). The
//! universal/majority core is shared by everyone and cannot distinguish
//! groups; unique primitives belong to a single artifact. What remains — the
//! shared deviations — is exactly what defines a faction. Artifacts whose
//! minority set is empty are the consensus group and are never listed.
//!
//! Deterministic by construction: pair candidates come from the evidence
//! store's occurrence lists, edges are thresholded Jaccard over minority
//! sets, components use min-root union-find (result independent of edge
//! order), and all output is sorted.

const std = @import("std");
const types = @import("types.zig");
const evidence = @import("evidence.zig");
const analysis = @import("analysis.zig");

/// Minority identities held by more artifacts than this are skipped for
/// pair generation — a "faction" that large is nearly a majority anyway,
/// and this bounds the quadratic pair fan-out.
pub const pair_cap = 1024;
/// Minimum Jaccard similarity (over minority sets) for an edge.
pub const similarity_threshold = 0.5;
pub const max_signature = 8;

pub const SignatureItem = struct {
    kind: types.PrimitiveKind,
    canonical: []const u8,
    /// How many faction members hold this primitive.
    present: u32,
};

pub const Faction = struct {
    /// Artifact ids, sorted ascending.
    members: []u32,
    /// The shared deviations that define the faction, best-supported first.
    signature: []SignatureItem,
    /// Mean Jaccard similarity over the threshold edges inside the faction.
    cohesion: f64,
};

pub const Clusters = struct {
    factions: []Faction,
};

pub const empty = Clusters{ .factions = &.{} };

pub fn detect(
    arena: std.mem.Allocator,
    store: *const evidence.Store,
    anal: *const analysis.Analysis,
    sets: []const []const types.Identity,
) !Clusters {
    const n = anal.n_artifacts;
    if (n < 3) return empty; // minority bucket requires 1 < k, 2k <= N

    // Distinctive identities: minority-bucket, bounded fan-out.
    var distinctive = std.AutoHashMap(types.Identity, void).init(arena);
    for (anal.identity_stats) |s| {
        if (s.bucket == .minority and s.artifacts <= pair_cap) {
            try distinctive.put(s.identity, {});
        }
    }
    if (distinctive.count() == 0) return empty;

    // |M(a)| — size of each artifact's minority set.
    const msize = try arena.alloc(u32, n);
    @memset(msize, 0);
    for (sets, 0..) |set, aid| {
        for (set) |id| {
            if (distinctive.contains(id)) msize[aid] += 1;
        }
    }

    // Shared-deviation counts per artifact pair, via the store's occurrence
    // lists (grouped by artifact because the engine feeds artifacts whole).
    var shared = std.AutoHashMap(u64, u32).init(arena);
    var holders = std.ArrayList(u32).init(arena);
    var it = store.map.iterator();
    while (it.next()) |entry| {
        if (!distinctive.contains(entry.key_ptr.*)) continue;
        holders.clearRetainingCapacity();
        var last: u32 = std.math.maxInt(u32);
        for (entry.value_ptr.occurrences.items) |occ| {
            if (occ.artifact != last) {
                last = occ.artifact;
                try holders.append(occ.artifact);
            }
        }
        for (holders.items, 0..) |a, i| {
            for (holders.items[i + 1 ..]) |b| {
                const gop = try shared.getOrPut(pairKey(a, b));
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
    }

    // Threshold edges → min-root union-find (edge order cannot matter).
    const parent = try arena.alloc(u32, n);
    for (parent, 0..) |*p, i| p.* = @intCast(i);

    var edge_it = shared.iterator();
    while (edge_it.next()) |e| {
        const a: u32 = @intCast(e.key_ptr.* >> 32);
        const b: u32 = @intCast(e.key_ptr.* & 0xffff_ffff);
        if (pairSimilarity(e.value_ptr.*, msize[a], msize[b]) >= similarity_threshold) {
            join(parent, a, b);
        }
    }

    // Collect components; singletons are filtered below.
    var groups = std.AutoArrayHashMap(u32, std.ArrayList(u32)).init(arena);
    for (0..n) |i| {
        const root = find(parent, @intCast(i));
        const gop = try groups.getOrPut(root);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).init(arena);
        try gop.value_ptr.append(@intCast(i));
    }

    var factions = std.ArrayList(Faction).init(arena);
    var group_it = groups.iterator();
    while (group_it.next()) |g| {
        const members = g.value_ptr.items;
        if (members.len < 2) continue;
        std.mem.sort(u32, members, {}, std.sort.asc(u32));

        try factions.append(.{
            .members = members,
            .signature = try buildSignature(arena, store, sets, members, &distinctive),
            .cohesion = cohesionOf(&shared, msize, members),
        });
    }

    const out = try factions.toOwnedSlice();
    std.mem.sort(Faction, out, {}, struct {
        fn lessThan(_: void, x: Faction, y: Faction) bool {
            if (x.members.len != y.members.len) return x.members.len > y.members.len;
            return x.members[0] < y.members[0];
        }
    }.lessThan);
    return .{ .factions = out };
}

fn pairKey(a: u32, b: u32) u64 {
    const lo = @min(a, b);
    const hi = @max(a, b);
    return (@as(u64, lo) << 32) | hi;
}

fn pairSimilarity(shared_count: u32, ma: u32, mb: u32) f64 {
    const uni = ma + mb - shared_count;
    if (uni == 0) return 0;
    return @as(f64, @floatFromInt(shared_count)) / @as(f64, @floatFromInt(uni));
}

fn find(parent: []u32, x: u32) u32 {
    var cur = x;
    while (parent[cur] != cur) {
        parent[cur] = parent[parent[cur]]; // path halving
        cur = parent[cur];
    }
    return cur;
}

/// Attach the larger root under the smaller: the final component partition
/// is a function of the edge *set*, not the edge order.
fn join(parent: []u32, a: u32, b: u32) void {
    const ra = find(parent, a);
    const rb = find(parent, b);
    if (ra == rb) return;
    if (ra < rb) parent[rb] = ra else parent[ra] = rb;
}

fn buildSignature(
    arena: std.mem.Allocator,
    store: *const evidence.Store,
    sets: []const []const types.Identity,
    members: []const u32,
    distinctive: *const std.AutoHashMap(types.Identity, void),
) ![]SignatureItem {
    var counts = std.AutoArrayHashMap(types.Identity, u32).init(arena);
    for (members) |m| {
        for (sets[m]) |id| {
            if (!distinctive.contains(id)) continue;
            const gop = try counts.getOrPut(id);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }

    var items = std.ArrayList(SignatureItem).init(arena);
    var it = counts.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* < 2) continue;
        const obs = store.get(e.key_ptr.*).?;
        try items.append(.{
            .kind = obs.kind,
            .canonical = obs.canonical,
            .present = e.value_ptr.*,
        });
    }
    const slice = try items.toOwnedSlice();
    std.mem.sort(SignatureItem, slice, {}, struct {
        fn lessThan(_: void, x: SignatureItem, y: SignatureItem) bool {
            if (x.present != y.present) return x.present > y.present;
            return std.mem.lessThan(u8, x.canonical, y.canonical);
        }
    }.lessThan);
    return slice[0..@min(slice.len, max_signature)];
}

fn cohesionOf(
    shared: *const std.AutoHashMap(u64, u32),
    msize: []const u32,
    members: []const u32,
) f64 {
    var sum: f64 = 0;
    var count: usize = 0;
    for (members, 0..) |a, i| {
        for (members[i + 1 ..]) |b| {
            const s = shared.get(pairKey(a, b)) orelse continue;
            const sim = pairSimilarity(s, msize[a], msize[b]);
            if (sim >= similarity_threshold) {
                sum += sim;
                count += 1;
            }
        }
    }
    if (count == 0) return 0;
    return sum / @as(f64, @floatFromInt(count));
}

// -------------------------------------------------------------- tests -----

fn feedArtifact(
    arena: std.mem.Allocator,
    store: *evidence.Store,
    sets: *std.ArrayList([]types.Identity),
    aid: u32,
    canonicals: []const []const u8,
) !void {
    var set = std.ArrayList(types.Identity).init(arena);
    for (canonicals, 0..) |c, line| {
        const r = try store.add(arena, aid, .{ .kind = .kv, .canonical = c, .line = @intCast(line + 1) });
        if (r.first_for_artifact) try set.append(r.identity);
    }
    try sets.append(try set.toOwnedSlice());
}

test "detect finds two planted factions and excludes conformers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = evidence.Store.init(arena);
    var sets = std.ArrayList([]types.Identity).init(arena);

    // 6 conformers: pure core. Faction A (2 files): core + eu deviations.
    // Faction B (3 files): core + debug deviations. Everyone gets unique noise.
    const core = [_][]const u8{ "host=db", "port=5432", "tls=true" };
    var aid: u32 = 0;
    for (0..6) |_| {
        const noise = try std.fmt.allocPrint(arena, "noise{d}=x", .{aid});
        try feedArtifact(arena, &store, &sets, aid, &.{ core[0], core[1], core[2], noise });
        aid += 1;
    }
    for (0..2) |_| {
        const noise = try std.fmt.allocPrint(arena, "noise{d}=x", .{aid});
        try feedArtifact(arena, &store, &sets, aid, &.{ core[0], core[1], core[2], "region=eu", "dc=fra", noise });
        aid += 1;
    }
    for (0..3) |_| {
        const noise = try std.fmt.allocPrint(arena, "noise{d}=x", .{aid});
        try feedArtifact(arena, &store, &sets, aid, &.{ core[0], core[1], core[2], "debug=true", "log=trace", noise });
        aid += 1;
    }

    const anal = try analysis.analyze(arena, &store, aid, sets.items);
    const clusters = try detect(arena, &store, &anal, sets.items);

    try std.testing.expectEqual(@as(usize, 2), clusters.factions.len);
    // Sorted by size desc: debug faction (3) first, then eu faction (2).
    const f0 = clusters.factions[0];
    try std.testing.expectEqualSlices(u32, &.{ 8, 9, 10 }, f0.members);
    try std.testing.expectEqual(@as(usize, 2), f0.signature.len);
    try std.testing.expectEqualStrings("debug=true", f0.signature[0].canonical);
    try std.testing.expectEqual(@as(u32, 3), f0.signature[0].present);
    try std.testing.expectEqual(@as(f64, 1.0), f0.cohesion);

    const f1 = clusters.factions[1];
    try std.testing.expectEqualSlices(u32, &.{ 6, 7 }, f1.members);
    try std.testing.expectEqualStrings("dc=fra", f1.signature[0].canonical); // ties sort by canonical
}

test "detect returns nothing without minority primitives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = evidence.Store.init(arena);
    var sets = std.ArrayList([]types.Identity).init(arena);
    for (0..4) |aid| {
        const noise = try std.fmt.allocPrint(arena, "own{d}=x", .{aid});
        try feedArtifact(arena, &store, &sets, @intCast(aid), &.{ "a=1", noise });
    }
    const anal = try analysis.analyze(arena, &store, 4, sets.items);
    const clusters = try detect(arena, &store, &anal, sets.items);
    try std.testing.expectEqual(@as(usize, 0), clusters.factions.len);
}

test "three equal factions with no consensus core are all found" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = evidence.Store.init(arena);
    var sets = std.ArrayList([]types.Identity).init(arena);

    // 3 groups of 3, disjoint signatures, nothing shared corpus-wide:
    // core is empty, every file drifts 1.0 — but factions are found.
    var aid: u32 = 0;
    for (0..3) |g| {
        const s1 = try std.fmt.allocPrint(arena, "group{d}.k1=v", .{g});
        const s2 = try std.fmt.allocPrint(arena, "group{d}.k2=v", .{g});
        for (0..3) |_| {
            try feedArtifact(arena, &store, &sets, aid, &.{ s1, s2 });
            aid += 1;
        }
    }

    const anal = try analysis.analyze(arena, &store, 9, sets.items);
    try std.testing.expectEqual(@as(usize, 0), anal.core_size);
    const clusters = try detect(arena, &store, &anal, sets.items);
    try std.testing.expectEqual(@as(usize, 3), clusters.factions.len);
    for (clusters.factions) |f| {
        try std.testing.expectEqual(@as(usize, 3), f.members.len);
        try std.testing.expectEqual(@as(f64, 1.0), f.cohesion);
    }
}
