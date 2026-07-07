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
    sets: [][]types.Identity,
    adds: u64,
};

/// Feed a model through the real store, optionally shuffling per-artifact
/// primitive order and injecting duplicate observations.
fn feed(arena: std.mem.Allocator, model: Model, rand: std.Random, shuffle: bool) !Fed {
    var store = evidence.Store.init(arena);
    const sets = try arena.alloc([]types.Identity, model.n);
    var adds: u64 = 0;

    const order = try arena.alloc(usize, model.pool.len);
    for (order, 0..) |*o, i| o.* = i;

    for (0..model.n) |a| {
        if (shuffle) rand.shuffle(usize, order);
        var set = std.ArrayList(types.Identity).init(arena);
        for (order) |i| {
            if (!model.membership[a][i]) continue;
            const prim = types.Primitive{
                .kind = .kv,
                .canonical = model.pool[i],
                .line = @intCast(i + 1),
            };
            const r = try store.add(arena, @intCast(a), prim);
            adds += 1;
            if (r.first_for_artifact) try set.append(r.identity);
            // Duplicate observation within the same artifact: must count as
            // an occurrence but never as a distinct artifact.
            if (rand.float(f64) < 0.1) {
                const r2 = try store.add(arena, @intCast(a), prim);
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
    const sets = try arena.alloc([]types.Identity, n);
    var adds: u64 = 0;

    for (0..n) |a| {
        var set = std.ArrayList(types.Identity).init(arena);
        // ~25 shared primitives, popularity-weighted by pool index.
        for (0..25) |_| {
            const i = rand.uintLessThan(usize, shared_pool);
            const canonical = try std.fmt.allocPrint(arena, "shared{d}=v", .{i});
            const r = try store.add(arena, @intCast(a), .{ .kind = .kv, .canonical = canonical, .line = 1 });
            adds += 1;
            if (r.first_for_artifact) try set.append(r.identity);
        }
        // 5 artifact-unique primitives.
        for (0..5) |j| {
            const canonical = try std.fmt.allocPrint(arena, "own{d}_{d}=v", .{ a, j });
            const r = try store.add(arena, @intCast(a), .{ .kind = .kv, .canonical = canonical, .line = 1 });
            adds += 1;
            if (r.first_for_artifact) try set.append(r.identity);
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
