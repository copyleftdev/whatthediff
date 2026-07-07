//! Output rendering. Text tells the story; JSON exposes the full evidence
//! graph for machines (and the future AI adapter). Both are deterministic:
//! same corpus in, byte-identical report out.

const std = @import("std");
const types = @import("types.zig");
const hash = @import("hash.zig");
const engine = @import("engine.zig");
const analysis = @import("analysis.zig");

pub const Section = enum { all, consensus, drift };

pub const Options = struct {
    section: Section = .all,
    /// Emit every occurrence in JSON instead of capping per identity.
    full_evidence: bool = false,
};

const occurrence_cap = 16;
const canonical_display_max = 96;

// ---------------------------------------------------------------- text ----

pub fn renderText(writer: anytype, corpus: *const engine.Corpus, opts: Options) !void {
    const a = &corpus.analysis;

    try writer.print("WhatTheDiff — corpus analysis\n", .{});
    try writer.print(
        "Corpus: {d} artifacts · {d} distinct primitives · {d} observations",
        .{ a.n_artifacts, a.n_identities, a.total_observations },
    );
    if (corpus.skipped > 0) try writer.print(" · {d} skipped", .{corpus.skipped});
    try writer.print("\n", .{});

    if (opts.section != .drift) try renderConsensus(writer, a);
    if (opts.section != .consensus) {
        try renderDrift(writer, corpus);
        try renderUniqueEvidence(writer, corpus);
    }
}

fn renderConsensus(writer: anytype, a: *const analysis.Analysis) !void {
    try writer.print("\nConsensus\n", .{});
    const labels = [_][]const u8{ "universal", "majority", "minority", "unique" };
    inline for (0..4) |i| {
        try writer.print("  {s:<10} {d:>6}", .{ labels[i], a.bucket_counts[i] });
        if (i == 0) try writer.print("  (present in all {d} artifacts)", .{a.n_artifacts});
        try writer.print("\n", .{});
    }
    try writer.print("  consensus core: {d} primitives\n", .{a.core_size});
}

fn renderDrift(writer: anytype, corpus: *const engine.Corpus) !void {
    const a = &corpus.analysis;
    if (a.n_artifacts == 0) return;

    try writer.print("\nDrift (distance from consensus core, 0 = pure consensus)\n", .{});

    const order = try sortedByDriftDesc(corpus);
    for (order) |s| {
        try writer.print("  {d:.3}  {s}", .{ s.drift, corpus.artifacts[s.id].path });
        if (s.outlier) try writer.print("   ⚠ OUTLIER", .{});
        try writer.print("\n", .{});
    }
    try writer.print(
        "  mean {d:.3} · stddev {d:.3}\n",
        .{ a.mean_drift, a.std_drift },
    );
}

fn renderUniqueEvidence(writer: anytype, corpus: *const engine.Corpus) !void {
    const a = &corpus.analysis;
    if (a.n_artifacts < 2) return;

    // Show unique primitives for outliers; if none are flagged, for the
    // highest-drift artifacts that have any unique evidence.
    const order = try sortedByDriftDesc(corpus);
    var any_outlier = false;
    for (order) |s| any_outlier = any_outlier or s.outlier;

    var shown_artifacts: usize = 0;
    var header_done = false;
    for (order) |s| {
        if (s.unique == 0) continue;
        if (any_outlier and !s.outlier) continue;
        if (shown_artifacts >= 3) break;
        shown_artifacts += 1;

        if (!header_done) {
            try writer.print("\nEvidence — unique primitives\n", .{});
            header_done = true;
        }
        try writer.print("  {s}  ({d} unique)\n", .{ corpus.artifacts[s.id].path, s.unique });

        var shown: usize = 0;
        for (a.identity_stats) |stat| {
            if (stat.bucket != .unique) continue;
            const obs = corpus.store.get(stat.identity).?;
            const occ = obs.occurrences.items[0];
            if (occ.artifact != s.id) continue;

            try writer.print("    {s:<9} {s}", .{
                @tagName(stat.kind),
                truncateUtf8(stat.canonical, canonical_display_max),
            });
            if (stat.canonical.len > canonical_display_max) try writer.print("…", .{});
            if (occ.line > 0) try writer.print("  (line {d})", .{occ.line});
            try writer.print("\n", .{});

            shown += 1;
            if (shown >= 5) {
                if (s.unique > 5) try writer.print("    … and {d} more\n", .{s.unique - 5});
                break;
            }
        }
    }
    if (header_done) {
        try writer.print("\nRun with --json for the full evidence graph.\n", .{});
    }
}

fn sortedByDriftDesc(corpus: *const engine.Corpus) ![]analysis.ArtifactStat {
    // The analysis slice lives in the arena; sort a copy so the canonical
    // id-indexed order is preserved for JSON rendering.
    const alloc = corpus.store.map.allocator;
    const copy = try alloc.dupe(analysis.ArtifactStat, corpus.analysis.artifact_stats);
    std.mem.sort(analysis.ArtifactStat, copy, {}, struct {
        fn lessThan(_: void, x: analysis.ArtifactStat, y: analysis.ArtifactStat) bool {
            if (x.drift != y.drift) return x.drift > y.drift;
            return x.id < y.id;
        }
    }.lessThan);
    return copy;
}

/// Cut at a byte budget without splitting a UTF-8 sequence.
fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

// ---------------------------------------------------------------- json ----

const JsonOccurrence = struct { artifact: u32, line: u32 };

const JsonEvidence = struct {
    identity: []const u8,
    kind: []const u8,
    canonical: []const u8,
    artifacts: u32,
    occurrences_total: u32,
    bucket: []const u8,
    occurrences: []JsonOccurrence,
};

const JsonArtifact = struct {
    id: u32,
    path: []const u8,
    kind: []const u8,
    size: u64,
    primitives: u32,
    in_core: u32,
    unique: u32,
    drift: f64,
    outlier: bool,
};

const JsonReport = struct {
    schema: []const u8,
    corpus: struct {
        artifacts: usize,
        distinct_primitives: usize,
        observations: u64,
        skipped: u32,
    },
    consensus: struct {
        universal: usize,
        majority: usize,
        minority: usize,
        unique: usize,
        core_size: usize,
    },
    drift: struct { mean: f64, stddev: f64 },
    artifacts: []JsonArtifact,
    evidence: []JsonEvidence,
};

pub fn renderJson(
    arena: std.mem.Allocator,
    writer: anytype,
    corpus: *const engine.Corpus,
    opts: Options,
) !void {
    const a = &corpus.analysis;

    const artifacts = try arena.alloc(JsonArtifact, corpus.artifacts.len);
    for (corpus.artifacts, a.artifact_stats, 0..) |art, stat, i| {
        artifacts[i] = .{
            .id = art.id,
            .path = art.path,
            .kind = @tagName(art.kind),
            .size = art.size,
            .primitives = stat.total,
            .in_core = stat.in_core,
            .unique = stat.unique,
            .drift = stat.drift,
            .outlier = stat.outlier,
        };
    }

    const evidence_out = try arena.alloc(JsonEvidence, a.identity_stats.len);
    for (a.identity_stats, 0..) |stat, i| {
        const obs = corpus.store.get(stat.identity).?;
        const total = obs.occurrences.items.len;
        const cap = if (opts.full_evidence) total else @min(total, occurrence_cap);
        const occs = try arena.alloc(JsonOccurrence, cap);
        for (obs.occurrences.items[0..cap], 0..) |occ, j| {
            occs[j] = .{ .artifact = occ.artifact, .line = occ.line };
        }
        evidence_out[i] = .{
            .identity = try arena.dupe(u8, &hash.hex(stat.identity)),
            .kind = @tagName(stat.kind),
            .canonical = stat.canonical,
            .artifacts = stat.artifacts,
            .occurrences_total = @intCast(total),
            .bucket = @tagName(stat.bucket),
            .occurrences = occs,
        };
    }

    const report = JsonReport{
        .schema = "wtd.report.v0",
        .corpus = .{
            .artifacts = a.n_artifacts,
            .distinct_primitives = a.n_identities,
            .observations = a.total_observations,
            .skipped = corpus.skipped,
        },
        .consensus = .{
            .universal = a.bucket_counts[0],
            .majority = a.bucket_counts[1],
            .minority = a.bucket_counts[2],
            .unique = a.bucket_counts[3],
            .core_size = a.core_size,
        },
        .drift = .{ .mean = a.mean_drift, .stddev = a.std_drift },
        .artifacts = artifacts,
        .evidence = evidence_out,
    };

    try std.json.stringify(report, .{ .whitespace = .indent_2 }, writer);
    try writer.print("\n", .{});
}

test "truncateUtf8 never splits a codepoint" {
    try std.testing.expectEqualStrings("abc", truncateUtf8("abc", 10));
    try std.testing.expectEqualStrings("ab", truncateUtf8("abcd", 2));
    // "é" is 2 bytes; cutting at 1 must back off to 0.
    try std.testing.expectEqualStrings("", truncateUtf8("é", 1));
    try std.testing.expectEqualStrings("aé", truncateUtf8("aéz", 3));
}
