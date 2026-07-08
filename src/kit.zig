//! DOM kit signatures — the web analog of `wtd yara`.
//!
//! wtd clusters web pages into families (factions). This turns a family into a
//! detection descriptor: for each faction it finds the DOM features present in
//! **every member and absent from every other page in the corpus** — the
//! discriminative core — and reports them grouped by what they mean to an
//! analyst: what the page harvests (form fields), where it posts (form action),
//! what infra it loads (resource hosts), its brand markers, and how much of its
//! structural skeleton is exclusive.
//!
//! Soundness is identical to `wtd yara`: an atom is included only when its
//! witness set equals the faction's member set exactly, so every atom matches
//! the whole family and nothing else in the corpus you ran it on. It is a
//! candidate to refine (absent-elsewhere is proven only against your corpus),
//! not a shipped rule.

const std = @import("std");
const evidence = @import("evidence.zig");
const cluster = @import("cluster.zig");
const types = @import("types.zig");

pub const KitSignature = struct {
    members: []const u32,
    member_names: []const []const u8,
    /// Form field names exclusive to this family (what it harvests).
    fields: []const []const u8,
    /// Field-set fingerprints (hash of a form's sorted field names).
    formfields: []const []const u8,
    /// Form action hosts / paths (where it posts).
    actions: []const []const u8,
    /// External resource hosts (the infra it loads).
    resources: []const []const u8,
    /// Landmark element paths.
    paths: []const []const u8,
    /// Brand markers: titles, headings, meta.
    brand: []const []const u8,
    /// Count of exclusive structural skeleton shingles.
    shape_count: usize,

    /// A family with a functional signal (fields/action/resource) is a real
    /// "kit"; one with only shared structure is a weaker structural cluster.
    pub fn functional(self: KitSignature) bool {
        return self.fields.len + self.formfields.len + self.actions.len + self.resources.len > 0;
    }
};

fn ltU32(_: void, a: u32, b: u32) bool {
    return a < b;
}
fn ltStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn setKey(arena: std.mem.Allocator, ids: []const u32) ![]const u8 {
    const copy = try arena.dupe(u32, ids);
    std.mem.sort(u32, copy, {}, ltU32);
    var out = std.ArrayList(u8).init(arena);
    var prev: ?u32 = null;
    for (copy) |v| {
        if (prev != null and prev.? == v) continue;
        if (out.items.len > 0) try out.append(',');
        try out.writer().print("{d}", .{v});
        prev = v;
    }
    return out.toOwnedSlice();
}

fn witnessKey(arena: std.mem.Allocator, obs: *const evidence.Observation) ![]const u8 {
    const ids = try arena.alloc(u32, obs.occurrences.items.len);
    for (obs.occurrences.items, 0..) |occ, i| ids[i] = occ.artifact;
    return setKey(arena, ids);
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| return path[s + 1 ..];
    return path;
}

/// A per-faction accumulator while scanning the store.
const Bucket = struct {
    fields: std.ArrayList([]const u8),
    formfields: std.ArrayList([]const u8),
    actions: std.ArrayList([]const u8),
    resources: std.ArrayList([]const u8),
    paths: std.ArrayList([]const u8),
    brand: std.ArrayList([]const u8),
    shape_count: usize = 0,

    fn init(arena: std.mem.Allocator) Bucket {
        return .{
            .fields = std.ArrayList([]const u8).init(arena),
            .formfields = std.ArrayList([]const u8).init(arena),
            .actions = std.ArrayList([]const u8).init(arena),
            .resources = std.ArrayList([]const u8).init(arena),
            .paths = std.ArrayList([]const u8).init(arena),
            .brand = std.ArrayList([]const u8).init(arena),
        };
    }
};

/// Route a discriminative DOM primitive into its bucket by canonical prefix.
fn route(b: *Bucket, canonical: []const u8) !void {
    const table = .{
        .{ "field[]=", &b.fields },
        .{ "formfields[]=", &b.formfields },
        .{ "formaction[]=", &b.actions },
        .{ "resource[]=", &b.resources },
        .{ "path[]=", &b.paths },
        .{ "title[]=", &b.brand },
        .{ "heading[]=", &b.brand },
        .{ "meta[]=", &b.brand },
    };
    inline for (table) |row| {
        if (std.mem.startsWith(u8, canonical, row[0])) {
            try row[1].append(canonical[row[0].len..]);
            return;
        }
    }
    if (std.mem.startsWith(u8, canonical, "shape[]=")) b.shape_count += 1;
}

/// Compute the discriminative kit signature of every faction. Pure over the
/// store and clusters. Only factions with at least one DOM atom are returned.
pub fn signatures(
    arena: std.mem.Allocator,
    store: *const evidence.Store,
    clusters: *const cluster.Clusters,
    artifacts: []const types.Artifact,
) ![]KitSignature {
    var key_to_faction = std.StringHashMap(usize).init(arena);
    for (clusters.factions, 0..) |f, fi| {
        try key_to_faction.put(try setKey(arena, f.members), fi);
    }

    const buckets = try arena.alloc(Bucket, clusters.factions.len);
    for (buckets) |*b| b.* = Bucket.init(arena);

    const n = store.count();
    for (0..n) |i| {
        const obs = store.at(i);
        if (obs.kind != .kv) continue;
        const fi = key_to_faction.get(try witnessKey(arena, obs)) orelse continue;
        try route(&buckets[fi], obs.canonical);
    }

    var out = std.ArrayList(KitSignature).init(arena);
    for (clusters.factions, 0..) |f, fi| {
        const b = buckets[fi];
        const total = b.fields.items.len + b.formfields.items.len + b.actions.items.len +
            b.resources.items.len + b.paths.items.len + b.brand.items.len + b.shape_count;
        if (total == 0) continue;

        for ([_]*std.ArrayList([]const u8){ &buckets[fi].fields, &buckets[fi].formfields, &buckets[fi].actions, &buckets[fi].resources, &buckets[fi].paths, &buckets[fi].brand }) |list| {
            std.mem.sort([]const u8, list.items, {}, ltStr);
        }

        const members = try arena.dupe(u32, f.members);
        std.mem.sort(u32, members, {}, ltU32);
        const names = try arena.alloc([]const u8, members.len);
        for (members, 0..) |m, j| names[j] = basename(artifacts[m].path);

        try out.append(.{
            .members = members,
            .member_names = names,
            .fields = b.fields.items,
            .formfields = b.formfields.items,
            .actions = b.actions.items,
            .resources = b.resources.items,
            .paths = b.paths.items,
            .brand = b.brand.items,
            .shape_count = b.shape_count,
        });
    }
    // Functional kits first, then by size — most actionable at the top.
    std.mem.sort(KitSignature, out.items, {}, struct {
        fn lessThan(_: void, x: KitSignature, y: KitSignature) bool {
            if (x.functional() != y.functional()) return x.functional();
            return x.members.len > y.members.len;
        }
    }.lessThan);
    return out.items;
}

// ------------------------------------------------------------- render ------

pub fn render(writer: anytype, sigs: []const KitSignature) !void {
    if (sigs.len == 0) {
        try writer.writeAll("No web families detected in this corpus.\n");
        return;
    }
    try writer.writeAll("Kit signatures — features exclusive to each web family\n");
    try writer.writeAll("(present in every member, absent from every other page — review before use)\n");

    var idx: usize = 0;
    for (sigs) |s| {
        try writer.print("\n{s} #{d} — {d} members\n", .{
            if (s.functional()) "Kit signature" else "Structural cluster",
            idx,
            s.members.len,
        });
        try writer.writeAll("  members: ");
        const shown = @min(s.member_names.len, 8);
        for (s.member_names[0..shown], 0..) |m, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(m);
        }
        if (s.member_names.len > shown) try writer.print(" …+{d}", .{s.member_names.len - shown});
        try writer.writeAll("\n");

        try renderList(writer, "harvests (form fields)", s.fields);
        try renderList(writer, "field-set fingerprint", s.formfields);
        try renderList(writer, "posts to (form action)", s.actions);
        try renderList(writer, "loads (resources)", s.resources);
        try renderList(writer, "brand markers", s.brand);
        if (s.shape_count > 0) {
            try writer.print("  {s:<24} {d} exclusive skeleton shingles\n", .{ "structure:", s.shape_count });
        }
    }
    idx += 1;
    _ = &idx;
}

fn renderList(writer: anytype, label: []const u8, items: []const []const u8) !void {
    if (items.len == 0) return;
    var buf: [26]u8 = undefined;
    const padded = std.fmt.bufPrint(&buf, "{s}:", .{label}) catch label;
    try writer.print("  {s:<24}", .{padded});
    const shown = @min(items.len, 10);
    for (items[0..shown], 0..) |v, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeAll(v);
    }
    if (items.len > shown) try writer.print(" …+{d}", .{items.len - shown});
    try writer.writeAll("\n");
}

const JsonSignature = struct {
    members: []const []const u8,
    functional: bool,
    harvests: []const []const u8,
    field_set: []const []const u8,
    posts_to: []const []const u8,
    loads: []const []const u8,
    brand: []const []const u8,
    skeleton_shingles: usize,
};

pub fn renderJson(arena: std.mem.Allocator, writer: anytype, sigs: []const KitSignature) !void {
    const out = try arena.alloc(JsonSignature, sigs.len);
    for (sigs, 0..) |s, i| {
        out[i] = .{
            .members = s.member_names,
            .functional = s.functional(),
            .harvests = s.fields,
            .field_set = s.formfields,
            .posts_to = s.actions,
            .loads = s.resources,
            .brand = s.brand,
            .skeleton_shingles = s.shape_count,
        };
    }
    try std.json.stringify(.{ .schema = "wtd.kit.v1", .signatures = out }, .{ .whitespace = .indent_2 }, writer);
    try writer.writeAll("\n");
}

// -------------------------------------------------------------- tests ------

const testing = std.testing;
const analysis = @import("analysis.zig");

test "kit signature captures the family's exclusive DOM features" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = evidence.Store.init(arena);
    var sets = std.ArrayList([]const u32).init(arena);
    var artifacts = std.ArrayList(types.Artifact).init(arena);

    const feed = struct {
        fn go(al: std.mem.Allocator, st: *evidence.Store, se: *std.ArrayList([]const u32), ar: *std.ArrayList(types.Artifact), id: u32, name: []const u8, cs: []const []const u8) !void {
            var set = std.ArrayList(u32).init(al);
            for (cs) |c| {
                const r = try st.add(id, .{ .kind = .kv, .canonical = c, .line = 0 });
                if (r.first_for_artifact) try set.append(r.index);
            }
            try ar.append(.{ .id = id, .path = name, .kind = .html, .size = 1 });
            try se.append(try set.toOwnedSlice());
        }
    }.go;

    var id: u32 = 0;
    // 5 diverse conformers sharing a universal shingle + own noise.
    while (id < 5) : (id += 1) {
        try feed(arena, &store, &sets, &artifacts, id, try std.fmt.allocPrint(arena, "page{d}.html", .{id}), &.{
            "shape[]=universal",
            try std.fmt.allocPrint(arena, "shape[]=own{d}", .{id}),
        });
    }
    // 3-member kit: exclusive fields + action + resource + one shingle.
    const fam_lo = id;
    while (id < fam_lo + 3) : (id += 1) {
        try feed(arena, &store, &sets, &artifacts, id, try std.fmt.allocPrint(arena, "kit{d}.html", .{id}), &.{
            "shape[]=universal",
            "shape[]=kitskeleton",
            "field[]=email",
            "field[]=password",
            "formaction[]=collect.evil.example",
            "resource[]=cdn.evil.example",
            try std.fmt.allocPrint(arena, "shape[]=own{d}", .{id}),
        });
    }

    const anal = try analysis.analyze(arena, &store, artifacts.items.len, sets.items);
    const clusters = try cluster.detect(arena, &store, &anal, sets.items);
    const sigs = try signatures(arena, &store, &clusters, artifacts.items);

    try testing.expectEqual(@as(usize, 1), sigs.len);
    const s = sigs[0];
    try testing.expect(s.functional());
    try testing.expectEqual(@as(usize, 3), s.member_names.len);
    try testing.expectEqual(@as(usize, 2), s.fields.len); // email, password
    try testing.expectEqualStrings("email", s.fields[0]);
    try testing.expectEqualStrings("password", s.fields[1]);
    try testing.expectEqual(@as(usize, 1), s.actions.len);
    try testing.expectEqualStrings("collect.evil.example", s.actions[0]);
    try testing.expectEqualStrings("cdn.evil.example", s.resources[0]);
    // "kitskeleton" is exclusive; "universal" is shared with everyone → excluded.
    try testing.expectEqual(@as(usize, 1), s.shape_count);
}

test "render escapes nothing weird and marks functional vs structural" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const names = try arena.alloc([]const u8, 2);
    names[0] = "a.html";
    names[1] = "b.html";
    const sigs = try arena.alloc(KitSignature, 1);
    sigs[0] = .{
        .members = &.{ 0, 1 },
        .member_names = names,
        .fields = &.{ "email", "password" },
        .formfields = &.{},
        .actions = &.{"evil.example"},
        .resources = &.{},
        .paths = &.{},
        .brand = &.{},
        .shape_count = 5,
    };
    var buf = std.ArrayList(u8).init(arena);
    try render(buf.writer(), sigs);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Kit signature #0") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "email, password") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "evil.example") != null);
}
