//! CLI: intent in, story out. Flags select sections and output shape; all
//! analysis is done by the deterministic engine.

const std = @import("std");
const engine = @import("engine.zig");
const render = @import("render.zig");
const ask = @import("ask.zig");
const gate = @import("gate.zig");
const yara = @import("yara.zig");
const kit = @import("kit.zig");
const creds = @import("creds.zig");
const binary = @import("extractors/binary.zig");
const fetch = @import("fetch.zig");

pub const version = "1.11.1";

const usage =
    \\wtd — WhatTheDiff: what actually matters across N artifacts
    \\
    \\Usage:
    \\  wtd <path>... [options]
    \\  wtd ask "<question>" [path...] [options]
    \\  wtd yara <path>...   Emit candidate YARA rules for detected binary families
    \\  wtd web <url>...     Fetch pages and cluster them (phishing-kit / clone detection);
    \\                       [--snapshot-dir <dir>] saves what was fetched (reproducible),
    \\                       [--timeout <sec>] per-request deadline (default 10)
    \\  wtd kit <path>...    Emit a kit signature per web family (harvested fields,
    \\                       action host, resources, skeleton) — the wtd yara for web
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
    \\                  conflicts[>N]  outliers[>N]  drift>F  credential-forms[>N]
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
    if (args.len > 0 and std.mem.eql(u8, args[0], "yara")) {
        return runYara(arena, args[1..]);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "web")) {
        return runWeb(arena, args[1..]);
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "kit")) {
        return runKit(arena, args[1..]);
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
            .credential_forms = @intCast(corpus.credential_forms.len),
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

/// Credential forms whose page is not a member of any detected family.
fn ungroupedCredForms(arena: std.mem.Allocator, corpus: *const engine.Corpus) ![]creds.CredentialForm {
    const in_family = try arena.alloc(bool, corpus.artifacts.len);
    @memset(in_family, false);
    for (corpus.clusters.factions) |f| {
        for (f.members) |m| in_family[m] = true;
    }
    var out = std.ArrayList(creds.CredentialForm).init(arena);
    for (corpus.credential_forms) |cf| {
        if (!in_family[cf.id]) try out.append(cf);
    }
    return out.toOwnedSlice();
}

fn runKit(arena: std.mem.Allocator, args: []const []const u8) !u8 {
    var paths = std.ArrayList([]const u8).init(arena);
    var as_json = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.io.getStdOut().writer().writeAll(usage);
            return 0;
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try std.io.getStdErr().writer().print("wtd: unknown kit option '{s}'\n", .{arg});
            return 2;
        } else try paths.append(arg);
    }
    if (paths.items.len == 0) {
        try std.io.getStdErr().writer().writeAll("wtd: kit needs at least one path\n");
        return 2;
    }

    const corpus = engine.run(arena, paths.items) catch |err| {
        try std.io.getStdErr().writer().print("wtd: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    if (corpus.artifacts.len == 0) {
        try std.io.getStdErr().writer().writeAll("wtd: no readable artifacts found\n");
        return 1;
    }

    const sigs = try kit.signatures(arena, &corpus.store, &corpus.clusters, corpus.artifacts);

    var buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
    if (as_json) {
        try kit.renderJson(arena, buffered.writer(), sigs);
    } else {
        try kit.render(buffered.writer(), sigs);
        // Credential harvesters that don't cluster into a family — the one-off
        // pages a kit signature (which needs ≥2 members) structurally misses.
        try creds.render(buffered.writer(), try ungroupedCredForms(arena, &corpus));
    }
    try buffered.flush();
    return 0;
}

fn runWeb(arena: std.mem.Allocator, args: []const []const u8) !u8 {
    const stderr = std.io.getStdErr().writer();
    var urls = std.ArrayList([]const u8).init(arena);
    var opts = render.Options{};
    var as_json = false;
    var snapshot_dir: ?[]const u8 = null;
    var timeout_ms: u64 = fetch.default_timeout_ms;
    const sd_prefix = "--snapshot-dir=";
    const to_prefix = "--timeout=";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.io.getStdOut().writer().writeAll(usage);
            return 0;
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else if (std.mem.eql(u8, arg, "--consensus")) {
            opts.section = .consensus;
        } else if (std.mem.eql(u8, arg, "--drift")) {
            opts.section = .drift;
        } else if (std.mem.eql(u8, arg, "--conflicts")) {
            opts.section = .conflicts;
        } else if (std.mem.eql(u8, arg, "--factions")) {
            opts.section = .factions;
        } else if (std.mem.eql(u8, arg, "--snapshot-dir")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("wtd: --snapshot-dir requires a directory\n");
                return 2;
            }
            snapshot_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, sd_prefix)) {
            snapshot_dir = arg[sd_prefix.len..];
        } else if (std.mem.eql(u8, arg, "--timeout") or std.mem.startsWith(u8, arg, to_prefix)) {
            var val: []const u8 = undefined;
            if (std.mem.startsWith(u8, arg, to_prefix)) {
                val = arg[to_prefix.len..];
            } else {
                i += 1;
                if (i >= args.len) {
                    try stderr.writeAll("wtd: --timeout requires seconds (e.g. --timeout 8)\n");
                    return 2;
                }
                val = args[i];
            }
            const secs = std.fmt.parseFloat(f64, val) catch {
                try stderr.print("wtd: --timeout: not a number: '{s}'\n", .{val});
                return 2;
            };
            if (!(secs > 0)) {
                try stderr.writeAll("wtd: --timeout must be greater than 0\n");
                return 2;
            }
            timeout_ms = @intFromFloat(secs * 1000.0);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("wtd: unknown web option '{s}'\n", .{arg});
            return 2;
        } else {
            try urls.append(arg);
        }
    }

    if (urls.items.len == 0) {
        try stderr.writeAll("wtd web needs at least one URL (http:// or https://)\n");
        return 2;
    }
    if (snapshot_dir) |d| std.fs.cwd().makePath(d) catch {};

    // Fetch is nondeterministic I/O; a per-URL failure is skipped, never fatal.
    var sources = std.ArrayList(engine.Source).init(arena);
    for (urls.items) |url| {
        if (!fetch.isHttpUrl(url)) {
            try stderr.print("wtd: skipping non-http url '{s}'\n", .{url});
            continue;
        }
        const resp = fetch.get(arena, url, timeout_ms) catch |err| {
            try stderr.print("wtd: fetch failed for {s}: {s}\n", .{ url, @errorName(err) });
            continue;
        };
        if (snapshot_dir) |d| {
            const name = try fetch.snapshotName(arena, url);
            const path = try std.fs.path.join(arena, &.{ d, name });
            std.fs.cwd().writeFile(.{ .sub_path = path, .data = resp.body }) catch |err| {
                try stderr.print("wtd: could not save snapshot {s}: {s}\n", .{ path, @errorName(err) });
            };
        }
        // .text lets the extractor sniff — HTML routes to the DOM extractor.
        try sources.append(.{ .name = url, .content = resp.body, .kind = .text });
    }

    if (sources.items.len == 0) {
        try stderr.writeAll("wtd: no pages fetched\n");
        return 1;
    }
    try stderr.print("wtd: fetched {d}/{d} URLs\n", .{ sources.items.len, urls.items.len });

    const corpus = try engine.runSources(arena, sources.items, .{});

    var buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
    const writer = buffered.writer();
    if (as_json) {
        try render.renderJson(arena, writer, &corpus, opts);
    } else {
        try render.renderText(writer, &corpus, opts);
    }
    try buffered.flush();
    return 0;
}

fn runYara(arena: std.mem.Allocator, args: []const []const u8) !u8 {
    var paths = std.ArrayList([]const u8).init(arena);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.io.getStdOut().writer().writeAll(usage);
            return 0;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try std.io.getStdErr().writer().print("wtd: unknown yara option '{s}'\n", .{arg});
            return 2;
        } else try paths.append(arg);
    }
    if (paths.items.len == 0) {
        try std.io.getStdErr().writer().writeAll("wtd: yara needs at least one path\n");
        return 2;
    }

    const corpus = engine.run(arena, paths.items) catch |err| {
        try std.io.getStdErr().writer().print("wtd: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    if (corpus.artifacts.len == 0) {
        try std.io.getStdErr().writer().writeAll("wtd: no readable artifacts found\n");
        return 1;
    }

    const fams = try yara.families(arena, &corpus.store, &corpus.clusters, corpus.artifacts);

    // Resolve raw bytes for the discriminative chunk atoms by re-chunking each
    // member file once (chunk boundaries are deterministic, so hashes match).
    var resolved = std.StringHashMap([]const u8).init(arena);
    var needed = std.StringHashMap(void).init(arena);
    for (fams) |f| for (f.atoms) |a| {
        if (a.kind == .chunk) try needed.put(a.text, {});
    };
    if (needed.count() > 0) {
        var seen = std.AutoHashMap(u32, void).init(arena);
        outer: for (fams) |f| {
            for (f.members) |m| {
                if (seen.contains(m)) continue;
                try seen.put(m, {});
                const content = std.fs.cwd().readFileAlloc(arena, corpus.artifacts[m].path, engine.max_artifact_bytes) catch continue;
                const chs = binary.chunks(arena, content) catch continue;
                for (chs) |c| {
                    if (needed.contains(c.hash) and !resolved.contains(c.hash)) {
                        try resolved.put(c.hash, c.bytes);
                        if (resolved.count() == needed.count()) break :outer;
                    }
                }
            }
        }
    }

    var buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
    try yara.render(buffered.writer(), fams, &resolved);
    try buffered.flush();
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
