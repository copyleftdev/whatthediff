//! Value reconciliation: the odd-one-out report.
//!
//! Drift and factions answer "which artifacts differ?". Conflicts answers the
//! sharper operational question: for a given key, what value does the fleet
//! agree on, and exactly which artifacts disagree? It groups `kv` primitives
//! by their key path (the bytes before `=`) and reports every *scalar* key
//! that carries more than one value across the corpus.
//!
//! Two deliberate exclusions keep the signal clean:
//!   - List keys (canonical key ending in `[]`) are bags, not scalars: several
//!     values in one artifact is a list, not a disagreement. They are skipped.
//!   - A key is only a conflict when its plurality value is shared by at least
//!     two artifacts. That drops identifier fields (hostnames, node ids) where
//!     every artifact holds a distinct value — those are not disagreements,
//!     they are just unique data.
//!
//! Secret-safe by construction under `--keys-only`: that mode strips the value
//! from every `kv` canonical, leaving no `=`, so no key ever has a comparable
//! value and this analysis reports nothing. Values never reach the report.

const std = @import("std");
const types = @import("types.zig");
const evidence = @import("evidence.zig");

/// One value observed for a conflicted key, with the sorted, deduplicated set
/// of artifact ids that hold it.
pub const ValueGroup = struct {
    value: []const u8,
    artifacts: []const u32,
};

pub const Conflict = struct {
    /// The key path, e.g. `db.port`.
    key: []const u8,
    /// Value groups, plurality first: sorted by (artifact count desc, value
    /// bytes asc). `values[0]` is the consensus value; the rest are dissent.
    values: []ValueGroup,
    /// Distinct artifacts holding this key with any value.
    holders: u32,
    /// Distinct artifacts holding a non-plurality value (the deviants).
    deviants: u32,
};

pub const Conflicts = struct {
    /// Sorted by key bytes for reproducible output.
    items: []Conflict,
};

/// The key path of a `kv` canonical: everything before the first `=`.
/// Returns null when there is no `=` (e.g. a keys-only sanitized canonical).
fn splitKv(canonical: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const eq = std.mem.indexOfScalar(u8, canonical, '=') orelse return null;
    return .{ .key = canonical[0..eq], .value = canonical[eq + 1 ..] };
}

fn lessThanU32(_: void, a: u32, b: u32) bool {
    return a < b;
}

/// Sorted, deduplicated artifact ids witnessing an observation.
fn witnessSet(arena: std.mem.Allocator, obs: *const evidence.Observation) ![]u32 {
    const ids = try arena.alloc(u32, obs.occurrences.items.len);
    for (obs.occurrences.items, 0..) |occ, i| ids[i] = occ.artifact;
    std.mem.sort(u32, ids, {}, lessThanU32);
    var w: usize = 0;
    for (ids) |v| {
        if (w == 0 or ids[w - 1] != v) {
            ids[w] = v;
            w += 1;
        }
    }
    return ids[0..w];
}

/// Size of the sorted-deduplicated union of several already-sorted id sets.
fn unionCount(arena: std.mem.Allocator, sets: []const []const u32) !u32 {
    var total: usize = 0;
    for (sets) |s| total += s.len;
    const all = try arena.alloc(u32, total);
    var n: usize = 0;
    for (sets) |s| {
        @memcpy(all[n .. n + s.len], s);
        n += s.len;
    }
    std.mem.sort(u32, all, {}, lessThanU32);
    var count: u32 = 0;
    for (all, 0..) |v, i| {
        if (i == 0 or all[i - 1] != v) count += 1;
    }
    return count;
}

/// Detect value conflicts over the evidence store. Cheap in the common case:
/// witness sets are only materialized for keys that actually conflict.
pub fn detect(
    arena: std.mem.Allocator,
    store: *const evidence.Store,
    n_artifacts: usize,
) !Conflicts {
    if (n_artifacts < 2) return .{ .items = &[_]Conflict{} };

    // Pass 1: group the store index of every scalar `kv` identity by key path.
    // The key slice is borrowed from the store canonical (stable for the run).
    var by_key = std.StringHashMap(std.ArrayList(u32)).init(arena);
    const n_ids = store.count();
    for (0..n_ids) |i| {
        const obs = store.at(i);
        if (obs.kind != .kv) continue;
        const kv = splitKv(obs.canonical) orelse continue;
        if (std.mem.endsWith(u8, kv.key, "[]")) continue; // list bag, not a scalar
        const gop = try by_key.getOrPut(kv.key);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).init(arena);
        try gop.value_ptr.append(@intCast(i));
    }

    // Pass 2: a key conflicts when it has >=2 distinct values (>=2 identities)
    // and the plurality value is shared by >=2 artifacts.
    var out = std.ArrayList(Conflict).init(arena);
    var it = by_key.iterator();
    while (it.next()) |entry| {
        const idxs = entry.value_ptr.items;
        if (idxs.len < 2) continue;

        const groups = try arena.alloc(ValueGroup, idxs.len);
        for (idxs, 0..) |store_idx, g| {
            const obs = store.at(store_idx);
            const kv = splitKv(obs.canonical).?;
            groups[g] = .{ .value = kv.value, .artifacts = try witnessSet(arena, obs) };
        }
        std.mem.sort(ValueGroup, groups, {}, struct {
            fn lessThan(_: void, a: ValueGroup, b: ValueGroup) bool {
                if (a.artifacts.len != b.artifacts.len) return a.artifacts.len > b.artifacts.len;
                return std.mem.lessThan(u8, a.value, b.value);
            }
        }.lessThan);

        if (groups[0].artifacts.len < 2) continue; // identifier field, not a conflict

        const dissent = try arena.alloc([]const u32, groups.len - 1);
        for (groups[1..], 0..) |grp, j| dissent[j] = grp.artifacts;
        const all_sets = try arena.alloc([]const u32, groups.len);
        for (groups, 0..) |grp, j| all_sets[j] = grp.artifacts;

        try out.append(.{
            .key = entry.key_ptr.*,
            .values = groups,
            .holders = try unionCount(arena, all_sets),
            .deviants = try unionCount(arena, dissent),
        });
    }

    const items = try out.toOwnedSlice();
    std.mem.sort(Conflict, items, {}, struct {
        fn lessThan(_: void, a: Conflict, b: Conflict) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lessThan);
    return .{ .items = items };
}

// ------------------------------------------------------------- tests ------

const testing = std.testing;

/// Feed canonicals for one artifact into a store, mirroring the engine.
fn feedArtifact(store: *evidence.Store, id: u32, canonicals: []const []const u8) !void {
    for (canonicals) |c| _ = try store.add(id, .{ .kind = .kv, .canonical = c, .line = 1 });
}

test "detects the odd-one-out and names the deviant" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = evidence.Store.init(arena);
    // 3 artifacts agree port=5432, host=db; artifact 2 disagrees on port.
    try feedArtifact(&store, 0, &.{ "port=5432", "host=db" });
    try feedArtifact(&store, 1, &.{ "port=5432", "host=db" });
    try feedArtifact(&store, 2, &.{ "port=5433", "host=db" });

    const c = try detect(arena, &store, 3);
    try testing.expectEqual(@as(usize, 1), c.items.len);
    const port = c.items[0];
    try testing.expectEqualStrings("port", port.key);
    try testing.expectEqual(@as(usize, 2), port.values.len);
    // Plurality first.
    try testing.expectEqualStrings("5432", port.values[0].value);
    try testing.expectEqual(@as(usize, 2), port.values[0].artifacts.len);
    try testing.expectEqualStrings("5433", port.values[1].value);
    try testing.expectEqualSlices(u32, &.{2}, port.values[1].artifacts);
    try testing.expectEqual(@as(u32, 3), port.holders);
    try testing.expectEqual(@as(u32, 1), port.deviants);
}

test "unanimous keys are never conflicts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = evidence.Store.init(arena);
    try feedArtifact(&store, 0, &.{ "a=1", "b=2" });
    try feedArtifact(&store, 1, &.{ "a=1", "b=2" });

    const c = try detect(arena, &store, 2);
    try testing.expectEqual(@as(usize, 0), c.items.len);
}

test "identifier fields (all-distinct values) are not conflicts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = evidence.Store.init(arena);
    // Every artifact holds a distinct value for `node`: plurality is 1 → skip.
    // But they agree on `env`, and one disagrees → that IS a conflict.
    try feedArtifact(&store, 0, &.{ "node=n0", "env=prod" });
    try feedArtifact(&store, 1, &.{ "node=n1", "env=prod" });
    try feedArtifact(&store, 2, &.{ "node=n2", "env=stage" });

    const c = try detect(arena, &store, 3);
    try testing.expectEqual(@as(usize, 1), c.items.len);
    try testing.expectEqualStrings("env", c.items[0].key);
}

test "list keys are bags, never conflicts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = evidence.Store.init(arena);
    // Different list contents across files must not be flagged as a conflict.
    try feedArtifact(&store, 0, &.{ "features[]=a", "features[]=b" });
    try feedArtifact(&store, 1, &.{ "features[]=a", "features[]=c" });

    const c = try detect(arena, &store, 2);
    try testing.expectEqual(@as(usize, 0), c.items.len);
}

test "keys-only canonicals (no value) yield no conflicts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = evidence.Store.init(arena);
    // Keys-only mode drops values: canonical is the bare key path, no `=`.
    try feedArtifact(&store, 0, &.{ "db.port", "db.host" });
    try feedArtifact(&store, 1, &.{ "db.port", "db.host" });

    const c = try detect(arena, &store, 2);
    try testing.expectEqual(@as(usize, 0), c.items.len);
}

test "three-way split ranks values by popularity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = evidence.Store.init(arena);
    // level: 3× info, 2× warn, 1× debug.
    try feedArtifact(&store, 0, &.{"level=info"});
    try feedArtifact(&store, 1, &.{"level=info"});
    try feedArtifact(&store, 2, &.{"level=info"});
    try feedArtifact(&store, 3, &.{"level=warn"});
    try feedArtifact(&store, 4, &.{"level=warn"});
    try feedArtifact(&store, 5, &.{"level=debug"});

    const c = try detect(arena, &store, 6);
    try testing.expectEqual(@as(usize, 1), c.items.len);
    const lv = c.items[0];
    try testing.expectEqual(@as(usize, 3), lv.values.len);
    try testing.expectEqualStrings("info", lv.values[0].value);
    try testing.expectEqualStrings("warn", lv.values[1].value);
    try testing.expectEqualStrings("debug", lv.values[2].value);
    try testing.expectEqual(@as(u32, 6), lv.holders);
    try testing.expectEqual(@as(u32, 3), lv.deviants);
}
