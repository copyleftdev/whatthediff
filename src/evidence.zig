//! Evidence store: identity → observation, with every occurrence retained so
//! any downstream claim can be traced back to artifact + line.

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
    identity: types.Identity,
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

    pub fn add(
        self: *Store,
        alloc: std.mem.Allocator,
        artifact_id: u32,
        prim: types.Primitive,
    ) !AddResult {
        const id = hash.identity(prim.kind, prim.canonical);
        const gop = try self.map.getOrPut(id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .kind = prim.kind,
                .canonical = prim.canonical,
                .distinct_artifacts = 0,
                .last_artifact = std.math.maxInt(u32),
                .occurrences = std.ArrayList(types.Occurrence).init(alloc),
            };
        }
        try gop.value_ptr.occurrences.append(.{ .artifact = artifact_id, .line = prim.line });
        self.total_observations += 1;

        if (gop.value_ptr.last_artifact != artifact_id) {
            gop.value_ptr.last_artifact = artifact_id;
            gop.value_ptr.distinct_artifacts += 1;
            return .{ .identity = id, .first_for_artifact = true };
        }
        return .{ .identity = id, .first_for_artifact = false };
    }

    pub fn get(self: *const Store, id: types.Identity) ?Observation {
        return self.map.get(id);
    }
};

test "store counts distinct artifacts, not raw occurrences" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = Store.init(arena);
    const p = types.Primitive{ .kind = .kv, .canonical = "a=1", .line = 3 };

    const r1 = try store.add(arena, 0, p);
    const r2 = try store.add(arena, 0, .{ .kind = .kv, .canonical = "a=1", .line = 9 });
    const r3 = try store.add(arena, 1, p);

    try std.testing.expect(r1.first_for_artifact);
    try std.testing.expect(!r2.first_for_artifact);
    try std.testing.expect(r3.first_for_artifact);
    try std.testing.expectEqual(r1.identity, r3.identity);

    const obs = store.get(r1.identity).?;
    try std.testing.expectEqual(@as(u32, 2), obs.distinct_artifacts);
    try std.testing.expectEqual(@as(usize, 3), obs.occurrences.items.len);
    try std.testing.expectEqual(@as(u64, 3), store.total_observations);
}
