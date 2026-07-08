//! CLI: intent in, story out. Flags select sections and output shape; all
//! analysis is done by the deterministic engine.

const std = @import("std");
const engine = @import("engine.zig");
const render = @import("render.zig");
const ask = @import("ask.zig");
const gate = @import("gate.zig");

pub const version = "1.4.0";

const usage =
    \\wtd — WhatTheDiff: what actually matters across N artifacts
    \\
    \\Usage:
    \\  wtd <path>... [options]
    \\  wtd ask "<question>" [path...] [options]
    \\
    \\Options:
    \\  --json        Machine-readable report (full evidence graph)
    \\  --evidence    With --json: emit every occurrence (no per-primitive cap)
    \\  --consensus   Only the consensus section
    \\  --drift       Only the drift section
    \\  --conflicts   Only the conflicts section (scalar keys the fleet
    \\                disagrees on: majority value + the deviant files)
    \\  --factions    Only the factions section (groups deviating together)
    \\  --keys-only   Compare structure, not values (drops values from key=value
    \\                primitives, hashes raw lines). Secret-safe: point it at
    \\                credential/.env profiles to find schema drift safely.
    \\  --fail-on <s> CI gate: exit 3 if the corpus violates the policy. <s> is a
    \\                comma-separated list of conditions:
    \\                  conflicts[>N]  outliers[>N]  drift>F
    \\                A bare count condition means "> 0". Examples:
    \\                  --fail-on conflicts        --fail-on 'outliers,drift>0.5'
    \\  --version     Print version
    \\  --help        Print this help
    \\
    \\Exit codes: 0 ok · 1 error · 2 usage · 3 gate failed (--fail-on)
    \\
    \\Ask options (AI explains the deterministic evidence — never invents it):
    \\  --dry-run     Print the exact prompt instead of calling the model
    \\  --model <m>   Override the model (also honors WTD_AI_MODEL)
    \\                Auth: ANTHROPIC_API_KEY or OPENROUTER_API_KEY
    \\
    \\Examples:
    \\  wtd configs/
    \\  wtd configs/ --conflicts
    \\  wtd configs/ --fail-on conflicts     # CI gate: nonzero if the fleet disagrees
    \\  wtd contracts/ --drift
    \\  wtd a.json b.json c.json --json
    \\  wtd ask "why is svc-d.yaml different?" configs/
    \\
;

pub fn run(arena: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "ask")) {
        return runAsk(arena, args[1..]);
    }

    var paths = std.ArrayList([]const u8).init(arena);
    var opts = render.Options{};
    var as_json = false;
    var keys_only = false;
    var fail_on: ?[]const u8 = null;

    const fail_on_prefix = "--fail-on=";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.io.getStdOut().writer().writeAll(usage);
            return 0;
        } else if (std.mem.eql(u8, arg, "--version")) {
            try std.io.getStdOut().writer().print("wtd {s}\n", .{version});
            return 0;
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else if (std.mem.eql(u8, arg, "--evidence")) {
            opts.full_evidence = true;
        } else if (std.mem.eql(u8, arg, "--consensus")) {
            opts.section = .consensus;
        } else if (std.mem.eql(u8, arg, "--drift")) {
            opts.section = .drift;
        } else if (std.mem.eql(u8, arg, "--conflicts")) {
            opts.section = .conflicts;
        } else if (std.mem.eql(u8, arg, "--factions")) {
            opts.section = .factions;
        } else if (std.mem.eql(u8, arg, "--keys-only")) {
            keys_only = true;
        } else if (std.mem.eql(u8, arg, "--fail-on")) {
            i += 1;
            if (i >= args.len) {
                try std.io.getStdErr().writer().writeAll("wtd: --fail-on requires a value (e.g. --fail-on conflicts)\n");
                return 2;
            }
            fail_on = args[i];
        } else if (std.mem.startsWith(u8, arg, fail_on_prefix)) {
            fail_on = arg[fail_on_prefix.len..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try std.io.getStdErr().writer().print("wtd: unknown option '{s}'\n\n{s}", .{ arg, usage });
            return 2;
        } else {
            try paths.append(arg);
        }
    }

    if (paths.items.len == 0) {
        try std.io.getStdErr().writer().writeAll(usage);
        return 2;
    }

    // Validate the gate spec before doing any work, so a typo fails fast.
    var conditions: ?[]gate.Condition = null;
    if (fail_on) |spec| {
        conditions = gate.parse(arena, spec) catch |e| {
            try std.io.getStdErr().writer().print(
                "wtd: --fail-on: {s} (in '{s}')\n",
                .{ gate.describeError(e), spec },
            );
            return 2;
        };
    }

    const corpus = engine.runOpts(arena, paths.items, .{ .keys_only = keys_only }) catch |err| {
        try std.io.getStdErr().writer().print("wtd: error: {s}\n", .{@errorName(err)});
        return 1;
    };

    if (corpus.artifacts.len == 0) {
        try std.io.getStdErr().writer().writeAll("wtd: no readable artifacts found\n");
        return 1;
    }

    var gate_report: gate.Report = undefined;
    if (conditions) |conds| {
        var n_outliers: u64 = 0;
        var max_drift: f64 = 0;
        for (corpus.analysis.artifact_stats) |s| {
            if (s.outlier) n_outliers += 1;
            if (s.drift > max_drift) max_drift = s.drift;
        }
        const metrics = gate.Metrics{
            .conflicts = @intCast(corpus.conflicts.items.len),
            .outliers = n_outliers,
            .max_drift = max_drift,
        };
        gate_report = try gate.evaluate(arena, metrics, conds);
        opts.gate = &gate_report;
    }

    var buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
    const writer = buffered.writer();
    if (as_json) {
        try render.renderJson(arena, writer, &corpus, opts);
    } else {
        try render.renderText(writer, &corpus, opts);
    }
    try buffered.flush();

    if (opts.gate) |g| {
        // In JSON mode stdout is pure JSON, so signal humans on stderr too.
        if (as_json and g.failed) {
            try std.io.getStdErr().writer().writeAll("wtd: gate FAILED (see .gate in the JSON report)\n");
        }
        if (g.failed) return gate.exit_code;
    }
    return 0;
}

fn runAsk(arena: std.mem.Allocator, args: []const []const u8) !u8 {
    var question: ?[]const u8 = null;
    var paths = std.ArrayList([]const u8).init(arena);
    var opts = ask.Options{};
    var keys_only = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) {
                try std.io.getStdErr().writer().writeAll("wtd: --model requires a value\n");
                return 2;
            }
            opts.model = args[i];
        } else if (std.mem.eql(u8, arg, "--keys-only")) {
            keys_only = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try std.io.getStdErr().writer().print("wtd: unknown ask option '{s}'\n\n{s}", .{ arg, usage });
            return 2;
        } else if (question == null) {
            question = arg;
        } else {
            try paths.append(arg);
        }
    }

    const q = question orelse {
        try std.io.getStdErr().writer().writeAll(usage);
        return 2;
    };
    if (paths.items.len == 0) try paths.append(".");

    const corpus = engine.runOpts(arena, paths.items, .{ .keys_only = keys_only }) catch |err| {
        try std.io.getStdErr().writer().print("wtd: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    if (corpus.artifacts.len == 0) {
        try std.io.getStdErr().writer().writeAll("wtd: no readable artifacts found\n");
        return 1;
    }

    return ask.run(arena, &corpus, q, opts);
}
