//! Discriminative family signatures → candidate YARA rules.
//!
//! wtd already clusters binaries into families (factions). This turns a family
//! into a *detection artifact*: for each faction it finds the features that are
//! present in **every member and absent from every other sample in the corpus**
//! — the discriminative core — and writes a candidate YARA rule from them.
//!
//! The soundness property that makes the output trustworthy: an atom is emitted
//! only when its witness set equals the faction's member set exactly. So every
//! atom is, by construction, shared across the whole family and matches nothing
//! else in the corpus you ran it on. It is the anti-yarGen: deterministic, and
//! every atom traces back to evidence rather than a heuristic.
//!
//! Atoms come from the structured RE features (imports/exports/sections/needs/
//! strings) and from discriminative code chunks (emitted as YARA hex). It is a
//! *candidate* rule — a starting point an analyst refines, not a shipped
//! signature — because "absent elsewhere" is only proven against this corpus.

const std = @import("std");
const evidence = @import("evidence.zig");
const cluster = @import("cluster.zig");
const types = @import("types.zig");

pub const AtomKind = enum { import, needs, @"export", section, string, chunk };

pub const Atom = struct {
    kind: AtomKind,
    /// Feature value, or the chunk's hash when kind == .chunk.
    text: []const u8,
    /// Raw chunk bytes for hex emission; resolved separately, null otherwise.
    bytes: ?[]const u8 = null,
};

pub const Family = struct {
    /// Sorted member artifact ids.
    members: []const u32,
    member_names: []const []const u8,
    atoms: []Atom,
};

/// Cap atoms per rule so a huge shared surface doesn't produce an unwieldy rule.
const max_atoms = 24;

fn ltU32(_: void, a: u32, b: u32) bool {
    return a < b;
}

/// Comma-joined sorted-deduplicated id list — a stable set key.
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

fn witnessIds(arena: std.mem.Allocator, obs: *const evidence.Observation) ![]u32 {
    const ids = try arena.alloc(u32, obs.occurrences.items.len);
    for (obs.occurrences.items, 0..) |occ, i| ids[i] = occ.artifact;
    return ids;
}

/// Classify a store observation into a signature atom, or null if it is not a
/// YARA-usable binary feature (config kv, etc. are skipped).
fn classify(obs: *const evidence.Observation) ?Atom {
    if (obs.kind == .chunk) return .{ .kind = .chunk, .text = obs.canonical };
    if (obs.kind != .kv) return null;
    const c = obs.canonical;
    const map = .{
        .{ "imports[]=", AtomKind.import },
        .{ "needs[]=", AtomKind.needs },
        .{ "exports[]=", AtomKind.@"export" },
        .{ "sections[]=", AtomKind.section },
        .{ "strings[]=", AtomKind.string },
    };
    inline for (map) |m| {
        if (std.mem.startsWith(u8, c, m[0])) return .{ .kind = m[1], .text = c[m[0].len..] };
    }
    return null;
}

/// Rank atoms most-useful first. Symbolic, human-readable atoms (imports,
/// strings, sections) are preferred; raw code chunks rank LAST — they are the
/// least portable (arch-specific) and least readable, a fallback for when a
/// family shares no symbolic surface. This ordering also decides what survives
/// the per-rule atom cap.
fn atomRank(k: AtomKind) u8 {
    return switch (k) {
        .import => 0,
        .needs => 1,
        .@"export" => 2,
        .string => 3,
        .section => 4,
        .chunk => 5,
    };
}

/// Compute the discriminative families. Pure over the store and clusters — no
/// file I/O — so chunk atoms carry only their hash; the caller resolves bytes.
pub fn families(
    arena: std.mem.Allocator,
    store: *const evidence.Store,
    clusters: *const cluster.Clusters,
    artifacts: []const types.Artifact,
) ![]Family {
    // Map each faction's exact member set to its index.
    var key_to_faction = std.StringHashMap(usize).init(arena);
    for (clusters.factions, 0..) |f, fi| {
        try key_to_faction.put(try setKey(arena, f.members), fi);
    }

    var atom_lists = try arena.alloc(std.ArrayList(Atom), clusters.factions.len);
    for (atom_lists) |*l| l.* = std.ArrayList(Atom).init(arena);

    // An atom is discriminative for faction F iff its witness set == F's members.
    const n = store.count();
    for (0..n) |i| {
        const obs = store.at(i);
        const wkey = try setKey(arena, try witnessIds(arena, obs));
        const fi = key_to_faction.get(wkey) orelse continue;
        if (classify(obs)) |atom| try atom_lists[fi].append(atom);
    }

    var out = std.ArrayList(Family).init(arena);
    for (clusters.factions, 0..) |f, fi| {
        var atoms = atom_lists[fi].items;
        if (atoms.len == 0) continue; // no binary-feature signature → skip

        std.mem.sort(Atom, atoms, {}, struct {
            fn lessThan(_: void, a: Atom, b: Atom) bool {
                if (a.kind != b.kind) return atomRank(a.kind) < atomRank(b.kind);
                return std.mem.lessThan(u8, a.text, b.text);
            }
        }.lessThan);
        if (atoms.len > max_atoms) atoms = atoms[0..max_atoms];

        const members = try arena.dupe(u32, f.members);
        std.mem.sort(u32, members, {}, ltU32);
        const names = try arena.alloc([]const u8, members.len);
        for (members, 0..) |m, j| names[j] = basename(artifacts[m].path);

        try out.append(.{ .members = members, .member_names = names, .atoms = atoms });
    }
    return out.toOwnedSlice();
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| return path[s + 1 ..];
    return path;
}

// ------------------------------------------------------------- render ------

/// Write candidate YARA rules for every family. `resolved` maps a chunk hash to
/// its raw bytes (for hex atoms); chunk atoms whose bytes are unavailable are
/// omitted. Deterministic: same corpus in, byte-identical rules out.
pub fn render(
    writer: anytype,
    fams: []const Family,
    resolved: *const std.StringHashMap([]const u8),
) !void {
    if (fams.len == 0) {
        try writer.writeAll("// wtd: no discriminative binary families found in this corpus.\n");
        return;
    }
    try writer.writeAll("// Candidate YARA rules generated by wtd (deterministic).\n");
    try writer.writeAll("// Every atom is present in all family members and absent from every\n");
    try writer.writeAll("// other sample in the analyzed corpus. Review before shipping.\n\n");

    for (fams, 0..) |fam, idx| {
        try renderRule(writer, fam, idx, resolved);
    }
}

fn renderRule(
    writer: anytype,
    fam: Family,
    idx: usize,
    resolved: *const std.StringHashMap([]const u8),
) !void {
    // Pre-render atom bodies so the condition can count only the ones emitted.
    var lines = std.BoundedArray([]const u8, max_atoms){};
    _ = &lines;

    try writer.print("rule wtd_family_{d}\n{{\n", .{idx});
    try writer.writeAll("    meta:\n");
    try writer.print("        description = \"wtd discriminative signature for a {d}-member family\"\n", .{fam.members.len});
    try writer.writeAll("        author = \"whatthediff\"\n");
    try writer.writeAll("        members = \"");
    for (fam.member_names, 0..) |m, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeEscaped(writer, m);
    }
    try writer.writeAll("\"\n");

    try writer.writeAll("    strings:\n");
    var emitted: usize = 0;
    for (fam.atoms, 0..) |atom, i| {
        if (atom.kind == .chunk) {
            const bytes = resolved.get(atom.text) orelse continue;
            try writer.print("        $c{d} = {{ ", .{i});
            try writeHex(writer, bytes);
            try writer.writeAll(" }\n");
        } else {
            try writer.print("        ${s}{d} = \"", .{ atomTag(atom.kind), i });
            try writeEscaped(writer, atom.text);
            try writer.writeAll("\" ascii wide\n");
        }
        emitted += 1;
    }
    if (emitted == 0) {
        // All atoms were chunk-only and unresolved; degrade to a comment rule.
        try writer.writeAll("        $none = \"wtd_placeholder_no_resolvable_atoms\"\n");
        emitted = 1;
    }

    // Require a subset so the rule tolerates minor sample variation, but enough
    // exact atoms that a false positive is unlikely.
    const need = if (emitted <= 6) emitted else 6;
    if (need == emitted) {
        try writer.writeAll("    condition:\n        all of them\n}\n\n");
    } else {
        try writer.print("    condition:\n        {d} of them\n}}\n\n", .{need});
    }
}

fn atomTag(k: AtomKind) []const u8 {
    return switch (k) {
        .import => "imp",
        .needs => "lib",
        .@"export" => "exp",
        .section => "sec",
        .string => "str",
        .chunk => "c",
    };
}

/// Chunks can be large; a 48-byte prefix is a strong, compact YARA atom.
const chunk_hex_prefix = 48;

fn writeHex(writer: anytype, bytes: []const u8) !void {
    const n = @min(bytes.len, chunk_hex_prefix);
    for (bytes[0..n], 0..) |b, i| {
        if (i > 0) try writer.writeAll(" ");
        try writer.print("{x:0>2}", .{b});
    }
}

fn writeEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            else => try writer.writeByte(c),
        }
    }
}

// -------------------------------------------------------------- tests ------

const testing = std.testing;
const analysis = @import("analysis.zig");

test "families finds atoms exclusive to a faction, skips shared ones" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 4 conformers + a 3-member family. The family exclusively shares two
    // imports and a string; a libc import is universal (must NOT be an atom).
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
            try ar.append(.{ .id = id, .path = name, .kind = .binary, .size = 1 });
            try se.append(try set.toOwnedSlice());
        }
    }.go;

    var id: u32 = 0;
    // Conformers: only the universal libc import + own noise.
    while (id < 4) : (id += 1) {
        const own = try std.fmt.allocPrint(arena, "imports[]=own{d}", .{id});
        try feed(arena, &store, &sets, &artifacts, id, try std.fmt.allocPrint(arena, "conf{d}.bin", .{id}), &.{ "imports[]=malloc", own });
    }
    // Family: libc import + two exclusive imports + one exclusive string.
    const fam_start = id;
    while (id < fam_start + 3) : (id += 1) {
        try feed(arena, &store, &sets, &artifacts, id, try std.fmt.allocPrint(arena, "evil{d}.bin", .{id}), &.{
            "imports[]=malloc",
            "imports[]=CreateRemoteThread",
            "imports[]=WSAStartup",
            "strings[]=%s\\svchost.exe",
        });
    }

    const anal = try analysis.analyze(arena, &store, artifacts.items.len, sets.items);
    const clusters = try cluster.detect(arena, &store, &anal, sets.items);
    try testing.expectEqual(@as(usize, 1), clusters.factions.len);

    const fams = try families(arena, &store, &clusters, artifacts.items);
    try testing.expectEqual(@as(usize, 1), fams.len);

    var has_crt = false;
    var has_wsa = false;
    var has_str = false;
    var has_malloc = false;
    for (fams[0].atoms) |a| {
        if (std.mem.eql(u8, a.text, "CreateRemoteThread")) has_crt = true;
        if (std.mem.eql(u8, a.text, "WSAStartup")) has_wsa = true;
        if (std.mem.eql(u8, a.text, "%s\\svchost.exe")) has_str = true;
        if (std.mem.eql(u8, a.text, "malloc")) has_malloc = true;
    }
    try testing.expect(has_crt and has_wsa and has_str);
    try testing.expect(!has_malloc); // universal → not discriminative
    try testing.expectEqual(@as(usize, 3), fams[0].member_names.len);
}

test "render escapes strings and emits a valid-looking rule" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const atoms = try arena.alloc(Atom, 2);
    atoms[0] = .{ .kind = .import, .text = "CreateRemoteThread" };
    atoms[1] = .{ .kind = .string, .text = "path\\with\"quote" };
    const names = try arena.alloc([]const u8, 1);
    names[0] = "evil.bin";
    const fams = try arena.alloc(Family, 1);
    fams[0] = .{ .members = &.{0}, .member_names = names, .atoms = atoms };

    var buf = std.ArrayList(u8).init(arena);
    var resolved = std.StringHashMap([]const u8).init(arena);
    try render(buf.writer(), fams, &resolved);

    const out = buf.items;
    try testing.expect(std.mem.indexOf(u8, out, "rule wtd_family_0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"CreateRemoteThread\"") != null);
    // Backslash and quote are escaped.
    try testing.expect(std.mem.indexOf(u8, out, "path\\\\with\\\"quote") != null);
    try testing.expect(std.mem.indexOf(u8, out, "all of them") != null);
}
