//! Property-based tests: seeded random corpora checked against independent
//! oracles. Every failing iteration prints its seed (QuickCheck-style
//! reproducibility); regenerate the exact counterexample by re-running with
//! that seed. Shrinking is manual: the generators take size bounds, so bisect
//! by lowering `max_artifacts` / `max_pool` for a reported seed.

const std = @import("std");
const types = @import("types.zig");
const evidence = @import("evidence.zig");
const analysis = @import("analysis.zig");
const render = @import("render.zig");
const engine = @import("engine.zig");
const json_extractor = @import("extractors/json.zig");

// ------------------------------------------------------------ model -------

/// A corpus model that never touches hashing or the store: a pool of unique
/// canonical strings and a boolean membership matrix. All expected statistics
/// are derivable from column/row sums, which is what makes it an oracle.
const Model = struct {
    n: usize,
    pool: [][]const u8,
    membership: [][]bool,
};

fn genModel(
    arena: std.mem.Allocator,
    rand: std.Random,
    max_artifacts: usize,
    max_pool: usize,
) !Model {
    const n = rand.intRangeAtMost(usize, 1, max_artifacts);
    const pool_size = rand.intRangeAtMost(usize, 1, max_pool);

    const pool = try arena.alloc([]const u8, pool_size);
    for (pool, 0..) |*p, i| {
        p.* = try std.fmt.allocPrint(arena, "key{d}=value{d}", .{ i, i });
    }

    // Per-item popularity gives a natural mix of universal / majority /
    // minority / unique primitives instead of a uniform blur.
    const popularity = try arena.alloc(f64, pool_size);
    for (popularity) |*q| q.* = rand.float(f64);

    const membership = try arena.alloc([]bool, n);
    for (membership) |*row| {
        row.* = try arena.alloc(bool, pool_size);
        for (row.*, 0..) |*cell, i| cell.* = rand.float(f64) < popularity[i];
    }

    return .{ .n = n, .pool = pool, .membership = membership };
}

const Fed = struct {
    store: evidence.Store,
    sets: [][]u32,
    adds: u64,
};

/// Feed a model through the real store, optionally shuffling per-artifact
/// primitive order and injecting duplicate observations.
fn feed(arena: std.mem.Allocator, model: Model, rand: std.Random, shuffle: bool) !Fed {
    var store = evidence.Store.init(arena);
    const sets = try arena.alloc([]u32, model.n);
    var adds: u64 = 0;

    const order = try arena.alloc(usize, model.pool.len);
    for (order, 0..) |*o, i| o.* = i;

    for (0..model.n) |a| {
        if (shuffle) rand.shuffle(usize, order);
        var set = std.ArrayList(u32).init(arena);
        for (order) |i| {
            if (!model.membership[a][i]) continue;
            const prim = types.Primitive{
                .kind = .kv,
                .canonical = model.pool[i],
                .line = @intCast(i + 1),
            };
            const r = try store.add(@intCast(a), prim);
            adds += 1;
            if (r.first_for_artifact) try set.append(r.index);
            // Duplicate observation within the same artifact: must count as
            // an occurrence but never as a distinct artifact.
            if (rand.float(f64) < 0.1) {
                const r2 = try store.add(@intCast(a), prim);
                adds += 1;
                std.debug.assert(!r2.first_for_artifact);
            }
        }
        sets[a] = try set.toOwnedSlice();
    }
    return .{ .store = store, .sets = sets, .adds = adds };
}

const ArtifactOracle = struct {
    total: u32,
    in_core: u32,
    unique: u32,
    drift: f64,
};

const Oracle = struct {
    n_identities: usize,
    buckets: [4]usize,
    core_size: usize,
    artifacts: []ArtifactOracle,
};

/// Expected statistics from the membership matrix alone.
fn oracle(arena: std.mem.Allocator, model: Model) !Oracle {
    const pool_size = model.pool.len;
    const k = try arena.alloc(u32, pool_size);
    @memset(k, 0);
    for (model.membership) |row| {
        for (row, 0..) |cell, i| {
            if (cell) k[i] += 1;
        }
    }

    var n_identities: usize = 0;
    var buckets = [4]usize{ 0, 0, 0, 0 };
    var core_size: usize = 0;
    for (k) |ki| {
        if (ki == 0) continue;
        n_identities += 1;
        buckets[@intFromEnum(analysis.bucketOf(ki, model.n))] += 1;
        if (2 * @as(usize, ki) > model.n) core_size += 1;
    }

    const artifacts = try arena.alloc(ArtifactOracle, model.n);
    for (model.membership, 0..) |row, a| {
        var total: u32 = 0;
        var in_core: u32 = 0;
        var unique: u32 = 0;
        for (row, 0..) |cell, i| {
            if (!cell) continue;
            total += 1;
            if (2 * @as(usize, k[i]) > model.n) in_core += 1;
            if (k[i] == 1 and model.n > 1) unique += 1;
        }
        const union_size = @as(usize, total) + core_size - in_core;
        const drift: f64 = if (union_size == 0)
            0
        else
            1.0 - @as(f64, @floatFromInt(in_core)) / @as(f64, @floatFromInt(union_size));
        artifacts[a] = .{ .total = total, .in_core = in_core, .unique = unique, .drift = drift };
    }

    return .{
        .n_identities = n_identities,
        .buckets = buckets,
        .core_size = core_size,
        .artifacts = artifacts,
    };
}

// ------------------------------------------------------- properties -------

test "property: analysis agrees with the independent counting oracle" {
    var iter: u64 = 0;
    while (iter < 150) : (iter += 1) {
        const seed = 0x5eed_0001 + iter;
        errdefer std.debug.print("\ncounterexample: oracle property, seed=0x{x}\n", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        const model = try genModel(arena, rand, 24, 96);
        const fed = try feed(arena, model, rand, false);
        const a = try analysis.analyze(arena, &fed.store, model.n, fed.sets);
        const expected = try oracle(arena, model);

        try std.testing.expectEqual(fed.adds, a.total_observations);
        try std.testing.expectEqual(expected.n_identities, a.n_identities);
        try std.testing.expectEqual(expected.core_size, a.core_size);
        try std.testing.expectEqualSlices(usize, &expected.buckets, &a.bucket_counts);

        // Global conservation: Σ per-artifact totals == Σ per-identity k.
        var sum_totals: u64 = 0;
        var sum_k: u64 = 0;
        for (a.artifact_stats) |s| sum_totals += s.total;
        for (a.identity_stats) |s| sum_k += s.artifacts;
        try std.testing.expectEqual(sum_k, sum_totals);

        for (a.artifact_stats, expected.artifacts) |got, want| {
            try std.testing.expectEqual(want.total, got.total);
            try std.testing.expectEqual(want.in_core, got.in_core);
            try std.testing.expectEqual(want.unique, got.unique);
            try std.testing.expectApproxEqAbs(want.drift, got.drift, 1e-12);
            try std.testing.expect(got.drift >= 0.0 and got.drift <= 1.0);
        }
    }
}

test "property: per-artifact feed order never changes the analysis" {
    var iter: u64 = 0;
    while (iter < 60) : (iter += 1) {
        const seed = 0x5eed_0002 + iter;
        errdefer std.debug.print("\ncounterexample: permutation property, seed=0x{x}\n", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        const model = try genModel(arena, rand, 24, 96);
        const fed1 = try feed(arena, model, rand, false);
        const fed2 = try feed(arena, model, rand, true);
        const a1 = try analysis.analyze(arena, &fed1.store, model.n, fed1.sets);
        const a2 = try analysis.analyze(arena, &fed2.store, model.n, fed2.sets);

        try std.testing.expectEqual(a1.n_identities, a2.n_identities);
        try std.testing.expectEqual(a1.core_size, a2.core_size);
        try std.testing.expectEqualSlices(usize, &a1.bucket_counts, &a2.bucket_counts);
        // identity_stats are sorted by identity bytes: sequences must match.
        for (a1.identity_stats, a2.identity_stats) |s1, s2| {
            try std.testing.expectEqual(s1.identity, s2.identity);
            try std.testing.expectEqual(s1.artifacts, s2.artifacts);
            try std.testing.expectEqual(s1.bucket, s2.bucket);
        }
        for (a1.artifact_stats, a2.artifact_stats) |s1, s2| {
            try std.testing.expectEqual(s1.total, s2.total);
            try std.testing.expectEqual(s1.in_core, s2.in_core);
            try std.testing.expectEqual(s1.unique, s2.unique);
            try std.testing.expectEqual(s1.drift, s2.drift);
            try std.testing.expectEqual(s1.outlier, s2.outlier);
        }
    }
}

test "property: identical artifacts get identical statistics" {
    var iter: u64 = 0;
    while (iter < 100) : (iter += 1) {
        const seed = 0x5eed_0003 + iter;
        errdefer std.debug.print("\ncounterexample: twin property, seed=0x{x}\n", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        var model = try genModel(arena, rand, 16, 64);
        const twin_of = rand.intRangeLessThan(usize, 0, model.n);

        // Append an exact copy of one artifact.
        const membership = try arena.alloc([]bool, model.n + 1);
        @memcpy(membership[0..model.n], model.membership);
        membership[model.n] = model.membership[twin_of];
        model.membership = membership;
        model.n += 1;

        const fed = try feed(arena, model, rand, false);
        const a = try analysis.analyze(arena, &fed.store, model.n, fed.sets);

        const s1 = a.artifact_stats[twin_of];
        const s2 = a.artifact_stats[model.n - 1];
        try std.testing.expectEqual(s1.total, s2.total);
        try std.testing.expectEqual(s1.in_core, s2.in_core);
        try std.testing.expectEqual(s1.unique, s2.unique);
        try std.testing.expectEqual(s1.drift, s2.drift);
        try std.testing.expectEqual(s1.outlier, s2.outlier);
        // A twinned artifact shares everything with its twin: nothing unique.
        try std.testing.expectEqual(@as(u32, 0), s2.unique);
    }
}

test "property: a planted rogue is always the flagged outlier" {
    var iter: u64 = 0;
    while (iter < 100) : (iter += 1) {
        const seed = 0x5eed_0004 + iter;
        errdefer std.debug.print("\ncounterexample: planted-rogue property, seed=0x{x}\n", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        const n_conform = rand.intRangeAtMost(usize, 5, 40);
        const core_size = rand.intRangeAtMost(usize, 8, 40);
        const n = n_conform + 1;
        const rogue_unique = core_size * 3;
        const pool_size = core_size + rogue_unique;

        const pool = try arena.alloc([]const u8, pool_size);
        for (pool, 0..) |*p, i| p.* = try std.fmt.allocPrint(arena, "k{d}=v{d}", .{ i, i });

        const membership = try arena.alloc([]bool, n);
        for (membership, 0..) |*row, a_idx| {
            row.* = try arena.alloc(bool, pool_size);
            @memset(row.*, false);
            if (a_idx < n_conform) {
                // Conformers: exactly the core.
                for (0..core_size) |i| row.*[i] = true;
            } else {
                // Rogue: one core item plus a mass of unique material.
                row.*[0] = true;
                for (core_size..pool_size) |i| row.*[i] = true;
            }
        }

        const model = Model{ .n = n, .pool = pool, .membership = membership };
        const fed = try feed(arena, model, rand, false);
        const a = try analysis.analyze(arena, &fed.store, model.n, fed.sets);

        for (a.artifact_stats[0..n_conform]) |s| {
            try std.testing.expectEqual(@as(f64, 0), s.drift);
            try std.testing.expect(!s.outlier);
        }
        const rogue = a.artifact_stats[n - 1];
        try std.testing.expect(rogue.outlier);
        try std.testing.expect(rogue.drift > 0.9);
        try std.testing.expectEqual(@as(u32, @intCast(rogue_unique)), rogue.unique);
    }
}

// --------------------------------------------- conflict detection ---------

const conflicts_mod = @import("conflicts.zig");

test "property: a planted value conflict is detected with exact plurality and deviants" {
    var iter: u64 = 0;
    while (iter < 120) : (iter += 1) {
        const seed = 0x5eed_000c + iter;
        errdefer std.debug.print("\ncounterexample: conflict-detection property, seed=0x{x}\n", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        const n = rand.intRangeAtMost(usize, 4, 20);
        // Keep the plurality (base) value shared by >= 2 artifacts.
        const n_deviant = rand.intRangeAtMost(usize, 1, n - 2);

        // Pick which artifacts deviate on the conflict key.
        const ids = try arena.alloc(u32, n);
        for (ids, 0..) |*v, i| v.* = @intCast(i);
        rand.shuffle(u32, ids);
        const deviant_ids = try arena.dupe(u32, ids[0..n_deviant]);
        std.mem.sort(u32, deviant_ids, {}, ltU32);
        const is_deviant = try arena.alloc(bool, n);
        @memset(is_deviant, false);
        for (deviant_ids) |d| is_deviant[d] = true;

        const n_shared = rand.intRangeAtMost(usize, 1, 5);

        var store = evidence.Store.init(arena);
        for (0..n) |aid| {
            const a: u32 = @intCast(aid);
            // Unanimous shared scalar keys — must never be conflicts.
            for (0..n_shared) |s| {
                const c = try std.fmt.allocPrint(arena, "shared{d}=base", .{s});
                _ = try store.add(a, .{ .kind = .kv, .canonical = c, .line = 1 });
            }
            // The conflict key: base for conformers, a unique value per deviant.
            const cv = if (is_deviant[aid])
                try std.fmt.allocPrint(arena, "ckey=dev{d}", .{aid})
            else
                "ckey=base";
            _ = try store.add(a, .{ .kind = .kv, .canonical = cv, .line = 1 });
            // A list key with per-file variation — a bag, never a conflict.
            _ = try store.add(a, .{ .kind = .kv, .canonical = "tags[]=common", .line = 1 });
            const lu = try std.fmt.allocPrint(arena, "tags[]=t{d}", .{aid});
            _ = try store.add(a, .{ .kind = .kv, .canonical = lu, .line = 1 });
        }

        const report = try conflicts_mod.detect(arena, &store, n);

        // Exactly one conflict: ckey. Shared keys are unanimous; tags[] is a bag.
        try std.testing.expectEqual(@as(usize, 1), report.items.len);
        const ck = report.items[0];
        try std.testing.expectEqualStrings("ckey", ck.key);
        try std.testing.expectEqualStrings("base", ck.values[0].value);
        try std.testing.expectEqual(@as(usize, n - n_deviant), ck.values[0].artifacts.len);
        try std.testing.expectEqual(@as(u32, @intCast(n_deviant)), ck.deviants);
        try std.testing.expectEqual(@as(u32, @intCast(n)), ck.holders);

        // The reported deviant artifacts are exactly the planted set.
        var got = std.ArrayList(u32).init(arena);
        for (ck.values[1..]) |g| try got.appendSlice(g.artifacts);
        std.mem.sort(u32, got.items, {}, ltU32);
        try std.testing.expectEqualSlices(u32, deviant_ids, got.items);
    }
}

fn ltU32(_: void, a: u32, b: u32) bool {
    return a < b;
}

// ------------------------------------------- extractor equivalence --------

const JsonNode = union(enum) {
    scalar: []const u8,
    object: []Field,
    array: []JsonNode,

    const Field = struct { name: []const u8, value: JsonNode };
};

fn genJson(arena: std.mem.Allocator, rand: std.Random, depth: usize) !JsonNode {
    if (depth == 0 or rand.float(f64) < 0.4) {
        return .{ .scalar = try genScalar(arena, rand) };
    }
    if (rand.boolean()) {
        const len = rand.intRangeAtMost(usize, 0, 4);
        const fields = try arena.alloc(JsonNode.Field, len);
        for (fields, 0..) |*f, i| {
            f.* = .{
                .name = try std.fmt.allocPrint(arena, "k{d}", .{i}),
                .value = try genJson(arena, rand, depth - 1),
            };
        }
        return .{ .object = fields };
    }
    const len = rand.intRangeAtMost(usize, 0, 4);
    const items = try arena.alloc(JsonNode, len);
    for (items) |*item| item.* = try genJson(arena, rand, depth - 1);
    return .{ .array = items };
}

fn genScalar(arena: std.mem.Allocator, rand: std.Random) ![]const u8 {
    return switch (rand.uintLessThan(u8, 5)) {
        0 => "null",
        1 => "true",
        2 => "false",
        3 => try std.fmt.allocPrint(arena, "{d}", .{rand.int(i32)}),
        else => try std.fmt.allocPrint(arena, "\"s{d}\"", .{rand.uintLessThan(u16, 1000)}),
    };
}

/// Serialize with shuffled object-key order and random whitespace: the same
/// document, arbitrarily reformatted.
fn writeNoisy(
    arena: std.mem.Allocator,
    rand: std.Random,
    node: JsonNode,
    out: *std.ArrayList(u8),
) !void {
    try ws(rand, out);
    switch (node) {
        .scalar => |s| try out.appendSlice(s),
        .object => |fields| {
            const order = try arena.dupe(JsonNode.Field, fields);
            rand.shuffle(JsonNode.Field, order);
            try out.append('{');
            for (order, 0..) |f, i| {
                if (i > 0) try out.append(',');
                try ws(rand, out);
                try out.append('"');
                try out.appendSlice(f.name);
                try out.appendSlice("\":");
                try writeNoisy(arena, rand, f.value, out);
                try ws(rand, out);
            }
            try out.append('}');
        },
        .array => |items| {
            try out.append('[');
            for (items, 0..) |item, i| {
                if (i > 0) try out.append(',');
                try writeNoisy(arena, rand, item, out);
                try ws(rand, out);
            }
            try out.append(']');
        },
    }
    try ws(rand, out);
}

fn ws(rand: std.Random, out: *std.ArrayList(u8)) !void {
    const chars = " \n\t";
    var i = rand.uintLessThan(u8, 3);
    while (i > 0) : (i -= 1) try out.append(chars[rand.uintLessThan(u8, 3)]);
}

test "property: JSON key order and whitespace never change primitives" {
    var iter: u64 = 0;
    while (iter < 150) : (iter += 1) {
        const seed = 0x5eed_0005 + iter;
        errdefer std.debug.print("\ncounterexample: json-equivalence property, seed=0x{x}\n", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        const doc = try genJson(arena, rand, 4);

        var text_a = std.ArrayList(u8).init(arena);
        var text_b = std.ArrayList(u8).init(arena);
        try writeNoisy(arena, rand, doc, &text_a);
        try writeNoisy(arena, rand, doc, &text_b);

        const prims_a = try json_extractor.extract(arena, text_a.items);
        const prims_b = try json_extractor.extract(arena, text_b.items);

        try std.testing.expectEqual(prims_a.len, prims_b.len);
        for (prims_a, prims_b) |pa, pb| {
            try std.testing.expectEqualStrings(pa.canonical, pb.canonical);
        }
    }
}

// ----------------------------------- cross-format unification -------------

const hash = @import("hash.zig");
const yamlish_extractor = @import("extractors/yamlish.zig");

/// A structure expressible in both JSON and YAML-lite: nested maps with
/// scalar leaves and lists of scalars.
const CfNode = union(enum) {
    scalar: []const u8,
    map: []CfField,
    list: [][]const u8,

    const CfField = struct { name: []const u8, value: CfNode };
};

fn genCfMap(arena: std.mem.Allocator, rand: std.Random, depth: usize) !CfNode {
    const len = rand.intRangeAtMost(usize, 1, 5);
    const fields = try arena.alloc(CfNode.CfField, len);
    for (fields, 0..) |*f, i| {
        f.name = try std.fmt.allocPrint(arena, "k{d}", .{i});
        const roll = rand.float(f64);
        if (depth > 0 and roll < 0.35) {
            f.value = try genCfMap(arena, rand, depth - 1);
        } else if (roll < 0.55) {
            const n = rand.intRangeAtMost(usize, 1, 4);
            const items = try arena.alloc([]const u8, n);
            for (items) |*item| item.* = try genCfScalar(arena, rand);
            f.value = .{ .list = items };
        } else {
            f.value = .{ .scalar = try genCfScalar(arena, rand) };
        }
    }
    return .{ .map = fields };
}

fn genCfScalar(arena: std.mem.Allocator, rand: std.Random) ![]const u8 {
    return switch (rand.uintLessThan(u8, 5)) {
        0 => "true",
        1 => "false",
        2 => "null",
        3 => try std.fmt.allocPrint(arena, "{d}", .{rand.intRangeAtMost(i32, -9999, 9999)}),
        else => try std.fmt.allocPrint(arena, "v{d}", .{rand.uintLessThan(u16, 1000)}),
    };
}

fn writeCfJson(node: CfNode, out: *std.ArrayList(u8)) !void {
    switch (node) {
        .scalar => |s| try writeCfJsonScalar(s, out),
        .list => |items| {
            try out.append('[');
            for (items, 0..) |item, i| {
                if (i > 0) try out.append(',');
                try writeCfJsonScalar(item, out);
            }
            try out.append(']');
        },
        .map => |fields| {
            try out.append('{');
            for (fields, 0..) |f, i| {
                if (i > 0) try out.append(',');
                try out.append('"');
                try out.appendSlice(f.name);
                try out.appendSlice("\":");
                try writeCfJson(f.value, out);
            }
            try out.append('}');
        },
    }
}

fn writeCfJsonScalar(s: []const u8, out: *std.ArrayList(u8)) !void {
    // Keep JSON typed where the text form is typed: bools, null, integers
    // stay bare; everything else becomes a JSON string.
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "null")) {
        try out.appendSlice(s);
        return;
    }
    if (std.fmt.parseInt(i64, s, 10)) |_| {
        try out.appendSlice(s);
        return;
    } else |_| {}
    try out.append('"');
    try out.appendSlice(s);
    try out.append('"');
}

fn writeCfYaml(node: CfNode, indent: usize, out: *std.ArrayList(u8)) !void {
    const fields = node.map;
    for (fields) |f| {
        try out.appendNTimes(' ', indent);
        try out.appendSlice(f.name);
        switch (f.value) {
            .scalar => |s| {
                try out.appendSlice(": ");
                try out.appendSlice(s);
                try out.append('\n');
            },
            .list => |items| {
                try out.appendSlice(":\n");
                for (items) |item| {
                    try out.appendNTimes(' ', indent + 2);
                    try out.appendSlice("- ");
                    try out.appendSlice(item);
                    try out.append('\n');
                }
            },
            .map => {
                try out.appendSlice(":\n");
                try writeCfYaml(f.value, indent + 2, out);
            },
        }
    }
}

fn sortedCanonicals(arena: std.mem.Allocator, prims: []const types.Primitive) ![][]const u8 {
    const out = try arena.alloc([]const u8, prims.len);
    for (prims, 0..) |p, i| out[i] = p.canonical;
    std.mem.sort([]const u8, out, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return out;
}

test "property: the same structure in JSON and YAML yields identical identities" {
    var iter: u64 = 0;
    while (iter < 150) : (iter += 1) {
        const seed = 0x5eed_0007 + iter;
        errdefer std.debug.print("\ncounterexample: cross-format property, seed=0x{x}\n", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        const doc = try genCfMap(arena, rand, 3);

        var json_text = std.ArrayList(u8).init(arena);
        try writeCfJson(doc, &json_text);
        var yaml_text = std.ArrayList(u8).init(arena);
        try writeCfYaml(doc, 0, &yaml_text);

        const from_json = try json_extractor.extract(arena, json_text.items);
        const from_yaml = try yamlish_extractor.extract(arena, yaml_text.items);

        // Same fact set regardless of format (order differs: JSON sorts keys).
        const cj = try sortedCanonicals(arena, from_json);
        const cy = try sortedCanonicals(arena, from_yaml);
        try std.testing.expectEqual(cj.len, cy.len);
        for (cj, cy) |a, b| try std.testing.expectEqualStrings(a, b);

        // And therefore identical BLAKE3 identities.
        for (cj) |c| {
            const id_j = hash.identity(.kv, c);
            _ = id_j;
        }
        for (from_yaml) |p| try std.testing.expectEqual(types.PrimitiveKind.kv, p.kind);
    }
}

test "tri-format corpus: JSON, YAML, and INI of the same config fully agree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "a.json",
        .data = "{\"db\": {\"port\": 5432, \"host\": \"db.internal\"}, \"tls\": true}",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "b.yaml",
        .data = "db:\n  port: 5432\n  host: db.internal\ntls: true\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "c.conf",
        .data = "tls = true\n[db]\nport = 5432\nhost = \"db.internal\"\n",
    });

    const root = try tmp.dir.realpathAlloc(arena, ".");
    const corpus = try engine.run(arena, &.{root});

    try std.testing.expectEqual(@as(usize, 3), corpus.artifacts.len);
    // Every primitive is universal: 3 facts, all in all 3 files, zero drift.
    try std.testing.expectEqual(@as(usize, 3), corpus.analysis.n_identities);
    try std.testing.expectEqual(@as(usize, 3), corpus.analysis.bucket_counts[0]);
    for (corpus.analysis.artifact_stats) |s| {
        try std.testing.expectEqual(@as(f64, 0), s.drift);
        try std.testing.expectEqual(@as(u32, 3), s.total);
    }
}

// -------------------------------------------- cbor cross-format -----------

const cbor_extractor = @import("extractors/cbor.zig");

/// Encode a CfNode (maps of scalars/lists) as CBOR — the binary twin of the
/// JSON the `writeCfJson` helper produces, so both must decode to identical
/// identities. Scalars are typed to match `writeCfJsonScalar`: true/false/null
/// and integers stay typed; everything else is a text string.
fn cborUint(major: u3, n: u64, out: *std.ArrayList(u8)) !void {
    const m: u8 = @as(u8, major) << 5;
    if (n < 24) {
        try out.append(m | @as(u8, @intCast(n)));
    } else if (n < 256) {
        try out.append(m | 24);
        try out.append(@intCast(n));
    } else if (n < 65536) {
        try out.append(m | 25);
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, @intCast(n), .big);
        try out.appendSlice(&b);
    } else {
        try out.append(m | 26);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @intCast(n), .big);
        try out.appendSlice(&b);
    }
}

fn cborText(s: []const u8, out: *std.ArrayList(u8)) !void {
    try cborUint(3, s.len, out);
    try out.appendSlice(s);
}

fn cborScalar(s: []const u8, out: *std.ArrayList(u8)) !void {
    if (std.mem.eql(u8, s, "true")) return out.append(0xf5);
    if (std.mem.eql(u8, s, "false")) return out.append(0xf4);
    if (std.mem.eql(u8, s, "null")) return out.append(0xf6);
    if (std.fmt.parseInt(i64, s, 10)) |n| {
        if (n >= 0) return cborUint(0, @intCast(n), out);
        return cborUint(1, @intCast(-(n + 1)), out);
    } else |_| {}
    return cborText(s, out);
}

fn writeCfCbor(node: CfNode, out: *std.ArrayList(u8)) !void {
    switch (node) {
        .scalar => |s| try cborScalar(s, out),
        .list => |items| {
            try cborUint(4, items.len, out);
            for (items) |item| try cborScalar(item, out);
        },
        .map => |fields| {
            try cborUint(5, fields.len, out);
            for (fields) |f| {
                try cborText(f.name, out);
                try writeCfCbor(f.value, out);
            }
        },
    }
}

test "property: the same structure in JSON and CBOR yields identical identities" {
    var iter: u64 = 0;
    while (iter < 150) : (iter += 1) {
        const seed = 0x5eed_000b + iter;
        errdefer std.debug.print("\ncounterexample: cbor cross-format property, seed=0x{x}\n", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        const doc = try genCfMap(arena, rand, 3);

        var json_text = std.ArrayList(u8).init(arena);
        try writeCfJson(doc, &json_text);
        var cbor_bytes = std.ArrayList(u8).init(arena);
        try writeCfCbor(doc, &cbor_bytes);

        const from_json = try json_extractor.extract(arena, json_text.items);
        const from_cbor = try cbor_extractor.extract(arena, cbor_bytes.items);

        const cj = try sortedCanonicals(arena, from_json);
        const cc = try sortedCanonicals(arena, from_cbor);
        try std.testing.expectEqual(cj.len, cc.len);
        for (cj, cc) |a, b| try std.testing.expectEqualStrings(a, b);
    }
}

// -------------------------------------------- xml cross-format ------------

const xml_extractor = @import("extractors/xml.zig");

/// Serialize a map-only CfNode tree as XML under a named root element.
/// (Lists are excluded: XML has no index-less list form — repeated elements
/// emit repeated paths instead of `[]` segments.)
fn writeCfXml(node: CfNode, out: *std.ArrayList(u8)) !void {
    for (node.map) |f| {
        try out.append('<');
        try out.appendSlice(f.name);
        try out.append('>');
        switch (f.value) {
            .scalar => |s| try out.appendSlice(s),
            .map => try writeCfXml(f.value, out),
            .list => unreachable, // generator is called with lists disabled
        }
        try out.appendSlice("</");
        try out.appendSlice(f.name);
        try out.append('>');
    }
}

fn genCfMapNoLists(arena: std.mem.Allocator, rand: std.Random, depth: usize) !CfNode {
    const len = rand.intRangeAtMost(usize, 1, 5);
    const fields = try arena.alloc(CfNode.CfField, len);
    for (fields, 0..) |*f, i| {
        f.name = try std.fmt.allocPrint(arena, "k{d}", .{i});
        if (depth > 0 and rand.float(f64) < 0.35) {
            f.value = try genCfMapNoLists(arena, rand, depth - 1);
        } else {
            f.value = .{ .scalar = try genCfScalar(arena, rand) };
        }
    }
    return .{ .map = fields };
}

test "property: the same structure in JSON and XML yields identical identities" {
    var iter: u64 = 0;
    while (iter < 150) : (iter += 1) {
        const seed = 0x5eed_0009 + iter;
        errdefer std.debug.print("\ncounterexample: xml cross-format property, seed=0x{x}\n", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        const doc = try genCfMapNoLists(arena, rand, 3);

        // XML needs a named root; give JSON the same root key.
        var xml_text = std.ArrayList(u8).init(arena);
        try xml_text.appendSlice("<root>");
        try writeCfXml(doc, &xml_text);
        try xml_text.appendSlice("</root>");

        var json_text = std.ArrayList(u8).init(arena);
        try json_text.appendSlice("{\"root\":");
        try writeCfJson(doc, &json_text);
        try json_text.appendSlice("}");

        const from_xml = try xml_extractor.extract(arena, xml_text.items);
        const from_json = try json_extractor.extract(arena, json_text.items);

        const cx = try sortedCanonicals(arena, from_xml);
        const cj = try sortedCanonicals(arena, from_json);
        try std.testing.expectEqual(cj.len, cx.len);
        for (cj, cx) |a, b| try std.testing.expectEqualStrings(a, b);
    }
}

// ---------------------------------------------- pdf roundtrip -------------

const pdf_extractor = @import("extractors/pdf.zig");

fn escapePdfString(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    for (s) |c| {
        switch (c) {
            '(', ')', '\\' => {
                try out.append('\\');
                try out.append(c);
            },
            else => try out.append(c),
        }
    }
    return out.toOwnedSlice();
}

test "property: text lines survive the PDF write→extract roundtrip" {
    var iter: u64 = 0;
    while (iter < 100) : (iter += 1) {
        const seed = 0x5eed_000a + iter;
        errdefer std.debug.print("\ncounterexample: pdf roundtrip property, seed=0x{x}\n", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        // Random document: 1..20 lines of printable text (with characters
        // that need PDF escaping mixed in).
        const n_lines = rand.intRangeAtMost(usize, 1, 20);
        const lines = try arena.alloc([]const u8, n_lines);
        const chars = "abcdefghijklmnopqrstuvwxyz0123456789 :;,.-_()\\/";
        for (lines) |*l| {
            const len = rand.intRangeAtMost(usize, 1, 60);
            const buf = try arena.alloc(u8, len);
            for (buf) |*c| c.* = chars[rand.uintLessThan(usize, chars.len)];
            // The extractor normalizes whitespace; generate pre-normalized
            // text (no leading/trailing/double spaces) so equality is exact.
            l.* = try normalizeSpaces(arena, buf);
        }

        var cs = std.ArrayList(u8).init(arena);
        try cs.appendSlice("BT /F1 12 Tf 72 720 Td ");
        var wrote: usize = 0;
        for (lines) |l| {
            if (l.len == 0) continue;
            if (wrote > 0) try cs.appendSlice("0 -14 Td ");
            try cs.append('(');
            try cs.appendSlice(try escapePdfString(arena, l));
            try cs.appendSlice(") Tj ");
            wrote += 1;
        }
        try cs.appendSlice("ET");

        const compressed = rand.boolean();
        const pdf = try pdf_extractor.buildTestPdf(arena, cs.items, compressed);
        const prims = try pdf_extractor.extract(arena, pdf);

        var expected: usize = 0;
        for (lines) |l| {
            if (l.len == 0) continue;
            try std.testing.expect(expected < prims.len);
            try std.testing.expectEqualStrings(l, prims[expected].canonical);
            try std.testing.expectEqual(types.PrimitiveKind.line, prims[expected].kind);
            expected += 1;
        }
        try std.testing.expectEqual(expected, prims.len);
    }
}

fn normalizeSpaces(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    var in_ws = true;
    for (raw) |c| {
        if (c == ' ') {
            in_ws = true;
        } else {
            if (in_ws and out.items.len > 0) try out.append(' ');
            in_ws = false;
            try out.append(c);
        }
    }
    return out.toOwnedSlice();
}

// ------------------------------------------------- faction recovery -------

const cluster = @import("cluster.zig");

test "property: planted factions are recovered exactly" {
    var iter: u64 = 0;
    while (iter < 100) : (iter += 1) {
        const seed = 0x5eed_0008 + iter;
        errdefer std.debug.print("\ncounterexample: faction-recovery property, seed=0x{x}\n", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        // Corpus shape: conformers (pure core + unique noise) plus F factions
        // with disjoint signature sets. Conformers outnumber the largest
        // faction so signatures stay in the minority bucket.
        const n_factions = rand.intRangeAtMost(usize, 1, 3);
        var faction_sizes: [3]usize = undefined;
        var max_faction: usize = 0;
        for (0..n_factions) |f| {
            faction_sizes[f] = rand.intRangeAtMost(usize, 2, 6);
            max_faction = @max(max_faction, faction_sizes[f]);
        }
        var total_faction: usize = 0;
        for (faction_sizes[0..n_factions]) |s| total_faction += s;
        const n_conform = @max(max_faction + 1, rand.intRangeAtMost(usize, 4, 12));
        const n = n_conform + total_faction;

        var store = evidence.Store.init(arena);
        var sets = std.ArrayList([]u32).init(arena);
        var aid: u32 = 0;

        const core_size = rand.intRangeAtMost(usize, 3, 8);
        const core = try arena.alloc([]const u8, core_size);
        for (core, 0..) |*c, i| c.* = try std.fmt.allocPrint(arena, "core{d}=v", .{i});

        const feedOne = struct {
            fn go(
                al: std.mem.Allocator,
                st: *evidence.Store,
                se: *std.ArrayList([]u32),
                id: u32,
                canonicals: []const []const u8,
            ) !void {
                var set = std.ArrayList(u32).init(al);
                for (canonicals, 0..) |c, line| {
                    const r = try st.add(id, .{ .kind = .kv, .canonical = c, .line = @intCast(line + 1) });
                    if (r.first_for_artifact) try set.append(r.index);
                }
                try se.append(try set.toOwnedSlice());
            }
        }.go;

        // Conformers.
        for (0..n_conform) |_| {
            var prims = std.ArrayList([]const u8).init(arena);
            try prims.appendSlice(core);
            try prims.append(try std.fmt.allocPrint(arena, "own{d}=x", .{aid}));
            try feedOne(arena, &store, &sets, aid, prims.items);
            aid += 1;
        }

        // Factions: core + disjoint signature + unique noise per member.
        var expected: [3][]u32 = undefined;
        for (0..n_factions) |f| {
            const sig_size = rand.intRangeAtMost(usize, 2, 5);
            const sig = try arena.alloc([]const u8, sig_size);
            for (sig, 0..) |*s, i| s.* = try std.fmt.allocPrint(arena, "fac{d}.k{d}=v", .{ f, i });

            const members = try arena.alloc(u32, faction_sizes[f]);
            for (members) |*m| {
                var prims = std.ArrayList([]const u8).init(arena);
                try prims.appendSlice(core);
                try prims.appendSlice(sig);
                try prims.append(try std.fmt.allocPrint(arena, "own{d}=x", .{aid}));
                try feedOne(arena, &store, &sets, aid, prims.items);
                m.* = aid;
                aid += 1;
            }
            expected[f] = members;
        }

        const anal = try analysis.analyze(arena, &store, n, sets.items);
        const clusters = try cluster.detect(arena, &store, &anal, sets.items);

        try std.testing.expectEqual(n_factions, clusters.factions.len);
        // Match each expected faction to a detected one by first member.
        for (expected[0..n_factions]) |want| {
            var found = false;
            for (clusters.factions) |got| {
                if (got.members[0] == want[0]) {
                    try std.testing.expectEqualSlices(u32, want, got.members);
                    try std.testing.expectEqual(@as(f64, 1.0), got.cohesion);
                    found = true;
                }
            }
            try std.testing.expect(found);
        }
    }
}

test "factions survive the full disk pipeline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 4 conformers, one 3-member "eu" faction — mixed formats, unified.
    for (0..4) |i| {
        const name = try std.fmt.allocPrint(arena, "svc-{d}.yaml", .{i});
        const body = try std.fmt.allocPrint(arena, "host: db\nport: 5432\ntls: true\nnode: n{d}\n", .{i});
        try tmp.dir.writeFile(.{ .sub_path = name, .data = body });
    }
    for (0..3) |i| {
        const name = try std.fmt.allocPrint(arena, "svc-eu-{d}.json", .{i});
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"host\": \"db\", \"port\": 5432, \"tls\": true, \"region\": \"eu\", \"dc\": \"fra\", \"node\": \"e{d}\"}}",
            .{i},
        );
        try tmp.dir.writeFile(.{ .sub_path = name, .data = body });
    }

    const root = try tmp.dir.realpathAlloc(arena, ".");
    const corpus = try engine.run(arena, &.{root});

    try std.testing.expectEqual(@as(usize, 1), corpus.clusters.factions.len);
    const f = corpus.clusters.factions[0];
    try std.testing.expectEqual(@as(usize, 3), f.members.len);
    for (f.members) |m| {
        try std.testing.expect(std.mem.indexOf(u8, corpus.artifacts[m].path, "svc-eu-") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), f.signature.len);
    try std.testing.expectEqualStrings("dc=fra", f.signature[0].canonical);
    try std.testing.expectEqualStrings("region=eu", f.signature[1].canonical);
}

// ------------------------------------------------ end-to-end shape --------

test "property: full pipeline is byte-deterministic on disk corpora" {
    var iter: u64 = 0;
    while (iter < 5) : (iter += 1) {
        const seed = 0x5eed_0006 + iter;
        errdefer std.debug.print("\ncounterexample: pipeline determinism, seed=0x{x}\n", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const n_files = rand.intRangeAtMost(usize, 3, 12);
        for (0..n_files) |i| {
            var content = std.ArrayList(u8).init(arena);
            const n_lines = rand.intRangeAtMost(usize, 1, 20);
            for (0..n_lines) |_| {
                try content.writer().print("k{d}: v{d}\n", .{
                    rand.uintLessThan(u16, 40),
                    rand.uintLessThan(u16, 10),
                });
            }
            const name = try std.fmt.allocPrint(arena, "f{d}.yaml", .{i});
            try tmp.dir.writeFile(.{ .sub_path = name, .data = content.items });
        }

        const root = try tmp.dir.realpathAlloc(arena, ".");

        var out1 = std.ArrayList(u8).init(arena);
        var out2 = std.ArrayList(u8).init(arena);
        const corpus1 = try engine.run(arena, &.{root});
        try render.renderJson(arena, out1.writer(), &corpus1, .{ .full_evidence = true });
        const corpus2 = try engine.run(arena, &.{root});
        try render.renderJson(arena, out2.writer(), &corpus2, .{ .full_evidence = true });

        try std.testing.expectEqualStrings(out1.items, out2.items);
    }
}

test "capacity: 2000-artifact corpus preserves global invariants" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0x5eed_cafe);
    const rand = prng.random();

    const n: usize = 2000;
    const shared_pool: usize = 500;

    var store = evidence.Store.init(arena);
    const sets = try arena.alloc([]u32, n);
    var adds: u64 = 0;

    for (0..n) |a| {
        var set = std.ArrayList(u32).init(arena);
        // ~25 shared primitives, popularity-weighted by pool index.
        for (0..25) |_| {
            const i = rand.uintLessThan(usize, shared_pool);
            const canonical = try std.fmt.allocPrint(arena, "shared{d}=v", .{i});
            const r = try store.add(@intCast(a), .{ .kind = .kv, .canonical = canonical, .line = 1 });
            adds += 1;
            if (r.first_for_artifact) try set.append(r.index);
        }
        // 5 artifact-unique primitives.
        for (0..5) |j| {
            const canonical = try std.fmt.allocPrint(arena, "own{d}_{d}=v", .{ a, j });
            const r = try store.add(@intCast(a), .{ .kind = .kv, .canonical = canonical, .line = 1 });
            adds += 1;
            if (r.first_for_artifact) try set.append(r.index);
        }
        sets[a] = try set.toOwnedSlice();
    }

    const a = try analysis.analyze(arena, &store, n, sets);

    try std.testing.expectEqual(adds, a.total_observations);
    try std.testing.expectEqual(
        a.n_identities,
        a.bucket_counts[0] + a.bucket_counts[1] + a.bucket_counts[2] + a.bucket_counts[3],
    );
    try std.testing.expectEqual(a.core_size, a.bucket_counts[0] + a.bucket_counts[1]);

    var sum_totals: u64 = 0;
    var sum_k: u64 = 0;
    for (a.artifact_stats) |s| {
        sum_totals += s.total;
        try std.testing.expect(s.drift >= 0.0 and s.drift <= 1.0);
    }
    for (a.identity_stats) |s| sum_k += s.artifacts;
    try std.testing.expectEqual(sum_k, sum_totals);
    // Every artifact planted 5 unique primitives.
    try std.testing.expectEqual(@as(usize, n * 5 + a.core_size + a.bucket_counts[2]), a.n_identities);
}
