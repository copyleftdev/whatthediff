//! CI gate: turn a report into a pass/fail decision and an exit code.
//!
//! `--fail-on <spec>` makes wtd exit non-zero when the corpus violates a
//! policy — so a pipeline can *block* a config that disagrees with the fleet,
//! drifts too far, or introduces an outlier. This module is deliberately pure:
//! it evaluates over a small `Metrics` struct, never the corpus, so the policy
//! logic is unit-testable without touching the engine, the store, or disk.
//!
//! Spec grammar (comma-separated conditions):
//!   spec   := cond ("," cond)*
//!   cond   := metric [">" number]
//!   metric := "conflicts" | "outliers" | "drift"
//! A count metric (conflicts, outliers) with no threshold means "> 0" — fail
//! if any exist. `drift` requires an explicit threshold (there is no natural
//! default distance). A condition trips when observed > threshold.
//!
//! Exit code: the CLI returns 3 when the gate fails — distinct from 1
//! (internal error) and 2 (usage), so CI can tell "policy violated" from
//! "wtd crashed".

const std = @import("std");

pub const exit_code: u8 = 3;

pub const Metric = enum { conflicts, outliers, drift };

/// The corpus facts a gate can assert against.
pub const Metrics = struct {
    conflicts: u64,
    outliers: u64,
    max_drift: f64,
};

pub const Condition = struct {
    metric: Metric,
    threshold: f64,
    /// The original condition text, for messages.
    spec: []const u8,
};

pub const Result = struct {
    condition: Condition,
    observed: f64,
    tripped: bool,
};

pub const Report = struct {
    conditions: []Result,
    failed: bool,
};

pub const ParseError = error{
    EmptySpec,
    UnknownMetric,
    MissingThreshold,
    BadThreshold,
} || std.mem.Allocator.Error;

/// Human-readable reason for a parse failure, for the CLI to print.
pub fn describeError(e: ParseError) []const u8 {
    return switch (e) {
        error.EmptySpec => "empty condition",
        error.UnknownMetric => "unknown metric (expected conflicts, outliers, or drift)",
        error.MissingThreshold => "drift requires a threshold, e.g. drift>0.5",
        error.BadThreshold => "threshold must be a number >= 0",
        error.OutOfMemory => "out of memory",
    };
}

pub fn parse(arena: std.mem.Allocator, spec: []const u8) ParseError![]Condition {
    var list = std.ArrayList(Condition).init(arena);
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, " \t");
        if (tok.len == 0) return error.EmptySpec;

        var metric_str = tok;
        var threshold: ?f64 = null;
        if (std.mem.indexOfScalar(u8, tok, '>')) |gi| {
            metric_str = std.mem.trim(u8, tok[0..gi], " \t");
            const num = std.mem.trim(u8, tok[gi + 1 ..], " \t");
            const v = std.fmt.parseFloat(f64, num) catch return error.BadThreshold;
            if (!(v >= 0) or std.math.isNan(v)) return error.BadThreshold;
            threshold = v;
        }

        const metric: Metric = if (std.mem.eql(u8, metric_str, "conflicts"))
            .conflicts
        else if (std.mem.eql(u8, metric_str, "outliers"))
            .outliers
        else if (std.mem.eql(u8, metric_str, "drift"))
            .drift
        else
            return error.UnknownMetric;

        const th = threshold orelse switch (metric) {
            .conflicts, .outliers => @as(f64, 0),
            .drift => return error.MissingThreshold,
        };

        try list.append(.{ .metric = metric, .threshold = th, .spec = try arena.dupe(u8, tok) });
    }
    if (list.items.len == 0) return error.EmptySpec;
    return list.toOwnedSlice();
}

fn observed(metric: Metric, m: Metrics) f64 {
    return switch (metric) {
        .conflicts => @floatFromInt(m.conflicts),
        .outliers => @floatFromInt(m.outliers),
        .drift => m.max_drift,
    };
}

pub fn evaluate(arena: std.mem.Allocator, m: Metrics, conditions: []const Condition) !Report {
    const results = try arena.alloc(Result, conditions.len);
    var failed = false;
    for (conditions, 0..) |c, i| {
        const obs = observed(c.metric, m);
        const tripped = obs > c.threshold;
        if (tripped) failed = true;
        results[i] = .{ .condition = c, .observed = obs, .tripped = tripped };
    }
    return .{ .conditions = results, .failed = failed };
}

pub fn metricName(metric: Metric) []const u8 {
    return switch (metric) {
        .conflicts => "conflicts",
        .outliers => "outliers",
        .drift => "drift",
    };
}

// ------------------------------------------------------------- tests ------

const testing = std.testing;

fn parseOne(arena: std.mem.Allocator, spec: []const u8) !Condition {
    const cs = try parse(arena, spec);
    try testing.expectEqual(@as(usize, 1), cs.len);
    return cs[0];
}

test "bare count metric means > 0" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const c = try parseOne(a.allocator(), "conflicts");
    try testing.expectEqual(Metric.conflicts, c.metric);
    try testing.expectEqual(@as(f64, 0), c.threshold);
}

test "explicit thresholds parse for each metric" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqual(@as(f64, 3), (try parseOne(arena, "conflicts>3")).threshold);
    try testing.expectEqual(@as(f64, 2), (try parseOne(arena, "outliers>2")).threshold);
    const d = try parseOne(arena, "drift>0.5");
    try testing.expectEqual(Metric.drift, d.metric);
    try testing.expectEqual(@as(f64, 0.5), d.threshold);
}

test "spaces around tokens and operator are tolerated" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const cs = try parse(a.allocator(), " conflicts , drift > 0.25 ");
    try testing.expectEqual(@as(usize, 2), cs.len);
    try testing.expectEqual(Metric.conflicts, cs[0].metric);
    try testing.expectEqual(Metric.drift, cs[1].metric);
    try testing.expectEqual(@as(f64, 0.25), cs[1].threshold);
}

test "parse rejects bad specs" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectError(error.UnknownMetric, parse(arena, "bogus"));
    try testing.expectError(error.MissingThreshold, parse(arena, "drift"));
    try testing.expectError(error.BadThreshold, parse(arena, "conflicts>abc"));
    try testing.expectError(error.BadThreshold, parse(arena, "drift>-1"));
    try testing.expectError(error.EmptySpec, parse(arena, ""));
    try testing.expectError(error.EmptySpec, parse(arena, "conflicts,,outliers"));
}

test "evaluate trips strictly above threshold" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const m = Metrics{ .conflicts = 3, .outliers = 0, .max_drift = 0.42 };

    // conflicts present → trip.
    {
        const r = try evaluate(arena, m, try parse(arena, "conflicts"));
        try testing.expect(r.failed);
        try testing.expect(r.conditions[0].tripped);
        try testing.expectEqual(@as(f64, 3), r.conditions[0].observed);
    }
    // conflicts>3 with exactly 3 → does NOT trip (strict >).
    {
        const r = try evaluate(arena, m, try parse(arena, "conflicts>3"));
        try testing.expect(!r.failed);
    }
    // outliers none → pass; drift>0.5 with 0.42 → pass; combined → pass.
    {
        const r = try evaluate(arena, m, try parse(arena, "outliers,drift>0.5"));
        try testing.expect(!r.failed);
    }
    // Any one tripping fails the whole gate.
    {
        const r = try evaluate(arena, m, try parse(arena, "outliers,drift>0.3"));
        try testing.expect(r.failed);
        try testing.expect(!r.conditions[0].tripped); // outliers ok
        try testing.expect(r.conditions[1].tripped); // drift 0.42 > 0.3
    }
}
