//! Evidence store: identity → observation, with every occurrence retained so
//! any downstream claim can be traced back to artifact + line.
//!
//! Memory contract (the streaming property): the store owns everything it
//! keeps. Callers may pass primitives whose canonical bytes live in a
//! per-artifact scratch arena — the store copies the canonical exactly once,
//! on first insert. Resident memory therefore scales with distinct facts and
//! observations, never with total corpus bytes.
//!
//! Every identity also has a dense u32 index (its insertion position); all
//! per-artifact bookkeeping downstream uses indexes, which cuts set storage
//! 8x and turns membership checks into bitset probes.

const std = @import("std");
const types = @import("types.zig");
const hash = @import("hash.zig");

pub const Observation = struct {
    kind: types.PrimitiveKind,
    canonical: []const u8,
    /// Number of distinct artifacts containing this primitive.
    distinct_artifacts: u32,
    /// Last artifact id that touched this observation; relies on the engine
    /// feeding one artifact fully before the next.
    last_artifact: u32,
    occurrences: std.ArrayList(types.Occurrence),
};

pub const AddResult = struct {
    /// Dense index of the identity (stable insertion order).
    index: u32,
    /// True the first time this artifact contributes this primitive.
    first_for_artifact: bool,
};

pub const Store = struct {
    map: std.AutoArrayHashMap(types.Identity, Observation),
    total_observations: u64,

    pub fn init(alloc: std.mem.Allocator) Store {
        return .{
            .map = std.AutoArrayHashMap(types.Identity, Observation).init(alloc),
            .total_observations = 0,
        };
    }

    pub fn add(self: *Store, artifact_id: u32, prim: types.Primitive) !AddResult {
        const id = hash.identity(prim.kind, prim.canonical);
        const gop = try self.map.getOrPut(id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .kind = prim.kind,
                // The one copy the store keeps; the caller's buffer may be
                // scratch that is reset after this artifact.
                .canonical = try self.map.allocator.dupe(u8, prim.canonical),
                .distinct_artifacts = 0,
                .last_artifact = std.math.maxInt(u32),
                .occurrences = std.ArrayList(types.Occurrence).init(self.map.allocator),
            };
        }
        try gop.value_ptr.occurrences.append(.{ .artifact = artifact_id, .line = prim.line });
        self.total_observations += 1;

        if (gop.value_ptr.last_artifact != artifact_id) {
            gop.value_ptr.last_artifact = artifact_id;
            gop.value_ptr.distinct_artifacts += 1;
            return .{ .index = @intCast(gop.index), .first_for_artifact = true };
        }
        return .{ .index = @intCast(gop.index), .first_for_artifact = false };
    }

    pub fn get(self: *const Store, id: types.Identity) ?Observation {
        return self.map.get(id);
    }

    pub fn count(self: *const Store) usize {
        return self.map.count();
    }

    pub fn at(self: *const Store, index: usize) *const Observation {
        return &self.map.values()[index];
    }

    pub fn identityAt(self: *const Store, index: usize) types.Identity {
        return self.map.keys()[index];
    }
};

test "store counts distinct artifacts, not raw occurrences" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = Store.init(arena);
    const p = types.Primitive{ .kind = .kv, .canonical = "a=1", .line = 3 };

    const r1 = try store.add(0, p);
    const r2 = try store.add(0, .{ .kind = .kv, .canonical = "a=1", .line = 9 });
    const r3 = try store.add(1, p);

    try std.testing.expect(r1.first_for_artifact);
    try std.testing.expect(!r2.first_for_artifact);
    try std.testing.expect(r3.first_for_artifact);
    try std.testing.expectEqual(r1.index, r3.index);

    const obs = store.at(r1.index);
    try std.testing.expectEqual(@as(u32, 2), obs.distinct_artifacts);
    try std.testing.expectEqual(@as(usize, 3), obs.occurrences.items.len);
    try std.testing.expectEqual(@as(u64, 3), store.total_observations);
}

test "store copies canonicals: caller scratch can be reused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = Store.init(arena);

    var scratch: [16]u8 = undefined;
    @memcpy(scratch[0..7], "port=80");
    _ = try store.add(0, .{ .kind = .kv, .canonical = scratch[0..7], .line = 1 });
    // Clobber the scratch buffer — the store must be unaffected.
    @memset(&scratch, 'X');

    try std.testing.expectEqualStrings("port=80", store.at(0).canonical);
}
