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
const conflicts = @import("conflicts.zig");
const creds = @import("creds.zig");

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
    /// Value conflicts: scalar keys the fleet disagrees on.
    conflicts: conflicts.Conflicts,
    /// Per-page credential-harvest forms (web/phishing triage).
    credential_forms: []creds.CredentialForm,
    /// Files skipped as binary, oversized, or unreadable.
    skipped: u32,
};

pub const RunOptions = struct {
    /// Keys-only mode: for `kv` primitives, drop the value and keep only the
    /// key path (`db.port=5432` → `db.port`). Files are then compared by
    /// structure, not content — ideal for credential/env profiles, where it
    /// is also secret-safe by construction: no value ever enters the store,
    /// report, or JSON output.
    keys_only: bool = false,
};

pub fn run(arena: std.mem.Allocator, paths: []const []const u8) !Corpus {
    return runOpts(arena, paths, .{});
}

/// The key path of a `kv` canonical: everything before the first `=`.
fn keyOf(canonical: []const u8) []const u8 {
    const eq = std.mem.indexOfScalar(u8, canonical, '=') orelse return canonical;
    return canonical[0..eq];
}

/// Keys-only sanitizer. `kv` keeps its key path; `line` (structureless text,
/// e.g. a raw key/token file with no `=`) is replaced by a short hash so
/// identical lines still cluster but the content is never exposed. Other
/// kinds (`heading`, `chunk`) carry no secret value and pass through.
fn sanitizeCanonical(scratch: std.mem.Allocator, prim: types.Primitive) ![]const u8 {
    switch (prim.kind) {
        .kv => return keyOf(prim.canonical),
        .line => {
            var digest: [32]u8 = undefined;
            std.crypto.hash.Blake3.hash(prim.canonical, &digest, .{});
            const hex = std.fmt.bytesToHex(digest[0..6], .lower);
            return std.mem.concat(scratch, u8, &.{ "line#", &hex });
        },
        else => return prim.canonical,
    }
}

/// An artifact whose content is already in memory (e.g. a fetched web page).
pub const Source = struct {
    /// Display name / provenance — a file path or a URL.
    name: []const u8,
    content: []const u8,
    /// Best kind guess; `.text` lets the extractor sniff the payload.
    kind: types.ArtifactKind,
};

/// Accumulates artifacts into the evidence store. Shared by the file path
/// (`runOpts`) and the in-memory path (`runSources`) so both ingest identically.
const Builder = struct {
    arena: std.mem.Allocator,
    store: *evidence.Store,
    artifacts: *std.ArrayList(types.Artifact),
    sets: *std.ArrayList([]u32),
    skipped: *u32,
    opts: RunOptions,

    fn add(self: Builder, scratch: std.mem.Allocator, name: []const u8, kind_in: types.ArtifactKind, content: []const u8) !void {
        // Unknown-extension binaries route to content-defined chunking; a file
        // declared as a text format but actually binary is malformed → skip.
        var kind = kind_in;
        if (kind == .text and isBinary(content)) kind = .binary;
        if (kind != .pdf and kind != .binary and kind != .cbor and isBinary(content)) {
            self.skipped.* += 1;
            return;
        }
        if (content.len == 0) {
            self.skipped.* += 1;
            return;
        }

        const id: u32 = @intCast(self.artifacts.items.len);
        const prims = try extract.extract(scratch, kind, content);

        var set = std.ArrayList(u32).init(self.arena);
        for (prims) |p| {
            var prim = p;
            if (self.opts.keys_only) prim.canonical = try sanitizeCanonical(scratch, prim);
            const r = try self.store.add(id, prim);
            if (r.first_for_artifact) try set.append(r.index);
        }

        try self.artifacts.append(.{ .id = id, .path = name, .kind = kind, .size = content.len });
        try self.sets.append(try set.toOwnedSlice());
    }
};

fn finalize(
    arena: std.mem.Allocator,
    store: *evidence.Store,
    artifacts: *std.ArrayList(types.Artifact),
    sets: *std.ArrayList([]u32),
    skipped: u32,
) !Corpus {
    const result = try analysis.analyze(arena, store, artifacts.items.len, sets.items);
    const clusters = try cluster.detect(arena, store, &result, sets.items);
    const conflict_report = try conflicts.detect(arena, store, artifacts.items.len);
    const cred_forms = try creds.detect(arena, store, artifacts.items, sets.items);
    return .{
        .artifacts = try artifacts.toOwnedSlice(),
        .store = store.*,
        .sets = try sets.toOwnedSlice(),
        .analysis = result,
        .clusters = clusters,
        .conflicts = conflict_report,
        .credential_forms = cred_forms,
        .skipped = skipped,
    };
}

pub fn runOpts(arena: std.mem.Allocator, paths: []const []const u8, opts: RunOptions) !Corpus {
    const files = try discovery.discover(arena, paths);

    var artifacts = std.ArrayList(types.Artifact).init(arena);
    var sets = std.ArrayList([]u32).init(arena);
    var store = evidence.Store.init(arena);
    var skipped: u32 = 0;
    const builder = Builder{ .arena = arena, .store = &store, .artifacts = &artifacts, .sets = &sets, .skipped = &skipped, .opts = opts };

    // Streaming: file contents and parse trees live in a per-artifact arena
    // reset after every file; only the store, index sets, and metadata survive,
    // so resident memory scales with distinct facts, not corpus bytes.
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_state.deinit();

    for (files) |f| {
        _ = scratch_state.reset(.retain_capacity);
        const scratch = scratch_state.allocator();
        const content = std.fs.cwd().readFileAlloc(scratch, f.path, max_artifact_bytes) catch {
            skipped += 1;
            continue;
        };
        try builder.add(scratch, f.path, f.kind, content);
    }

    return finalize(arena, &store, &artifacts, &sets, skipped);
}

/// Analyze artifacts already in memory (fetched web pages, piped content).
/// Same ingestion and analysis as `runOpts`; only the source of bytes differs.
pub fn runSources(arena: std.mem.Allocator, sources: []const Source, opts: RunOptions) !Corpus {
    var artifacts = std.ArrayList(types.Artifact).init(arena);
    var sets = std.ArrayList([]u32).init(arena);
    var store = evidence.Store.init(arena);
    var skipped: u32 = 0;
    const builder = Builder{ .arena = arena, .store = &store, .artifacts = &artifacts, .sets = &sets, .skipped = &skipped, .opts = opts };

    var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_state.deinit();

    for (sources) |s| {
        _ = scratch_state.reset(.retain_capacity);
        try builder.add(scratch_state.allocator(), s.name, s.kind, s.content);
    }

    return finalize(arena, &store, &artifacts, &sets, skipped);
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
    // Declared JSON but actually binary → malformed, skipped (a .bin file
    // would now be chunk-analyzed as a binary instead).
    try tmp.dir.writeFile(.{ .sub_path = "junk.json", .data = "\x00\x01\x02" });

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

test "keys-only mode compares structure, not values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Same key schema, different secret values.
    try tmp.dir.writeFile(.{ .sub_path = "a.env", .data = "HOST=alpha\nPORT=1\nTOKEN=aaa\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.env", .data = "HOST=beta\nPORT=2\nTOKEN=bbb\n" });
    // A third profile missing one key and adding another.
    try tmp.dir.writeFile(.{ .sub_path = "c.env", .data = "HOST=gamma\nPORT=3\nEXTRA=zzz\n" });

    const root = try tmp.dir.realpathAlloc(arena, ".");

    // Value mode: every key=value differs (except none) → no consensus core.
    const cv = try run(arena, &.{root});
    try std.testing.expectEqual(@as(usize, 0), cv.analysis.core_size);

    // Keys-only: HOST and PORT are in all three (universal); TOKEN in 2 of 3
    // (majority); EXTRA in 1 (unique). No values anywhere.
    const ck = try runOpts(arena, &.{root}, .{ .keys_only = true });
    try std.testing.expectEqual(@as(usize, 4), ck.analysis.n_identities);
    try std.testing.expectEqual(@as(usize, 2), ck.analysis.bucket_counts[0]); // universal: HOST, PORT
    try std.testing.expectEqual(@as(usize, 1), ck.analysis.bucket_counts[1]); // majority: TOKEN
    try std.testing.expectEqual(@as(usize, 1), ck.analysis.bucket_counts[3]); // unique: EXTRA
    // No canonical contains a value character sequence like "alpha".
    for (ck.analysis.identity_stats) |s| {
        try std.testing.expect(std.mem.indexOf(u8, s.canonical, "=") == null);
        try std.testing.expect(std.mem.indexOf(u8, s.canonical, "alpha") == null);
    }
}

test "keys-only hashes structureless secret lines instead of exposing them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Raw key material with no key=value structure (would be a `line`).
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "SUPERSECRETKEYMATERIAL_abc123\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "SUPERSECRETKEYMATERIAL_abc123\n" });
    const root = try tmp.dir.realpathAlloc(arena, ".");

    const ck = try runOpts(arena, &.{root}, .{ .keys_only = true });
    // Identical secret lines still cluster (one universal identity)...
    try std.testing.expectEqual(@as(usize, 1), ck.analysis.n_identities);
    // ...but the secret content never appears in any canonical.
    for (ck.analysis.identity_stats) |s| {
        try std.testing.expect(std.mem.indexOf(u8, s.canonical, "SUPERSECRET") == null);
        try std.testing.expect(std.mem.startsWith(u8, s.canonical, "line#"));
    }
}
