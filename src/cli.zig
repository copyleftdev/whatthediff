//! CLI: intent in, story out. Flags select sections and output shape; all
//! analysis is done by the deterministic engine.

const std = @import("std");
const engine = @import("engine.zig");
const render = @import("render.zig");
const ask = @import("ask.zig");

pub const version = "0.5.0";

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
    \\  --factions    Only the factions section (groups deviating together)
    \\  --version     Print version
    \\  --help        Print this help
    \\
    \\Ask options (AI explains the deterministic evidence — never invents it):
    \\  --dry-run     Print the exact prompt instead of calling the model
    \\  --model <m>   Override the model (also honors WTD_AI_MODEL)
    \\                Auth: ANTHROPIC_API_KEY or OPENROUTER_API_KEY
    \\
    \\Examples:
    \\  wtd configs/
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

    for (args) |arg| {
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
        } else if (std.mem.eql(u8, arg, "--factions")) {
            opts.section = .factions;
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

    const corpus = engine.run(arena, paths.items) catch |err| {
        try std.io.getStdErr().writer().print("wtd: error: {s}\n", .{@errorName(err)});
        return 1;
    };

    if (corpus.artifacts.len == 0) {
        try std.io.getStdErr().writer().writeAll("wtd: no readable artifacts found\n");
        return 1;
    }

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

fn runAsk(arena: std.mem.Allocator, args: []const []const u8) !u8 {
    var question: ?[]const u8 = null;
    var paths = std.ArrayList([]const u8).init(arena);
    var opts = ask.Options{};

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

    const corpus = engine.run(arena, paths.items) catch |err| {
        try std.io.getStdErr().writer().print("wtd: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    if (corpus.artifacts.len == 0) {
        try std.io.getStdErr().writer().writeAll("wtd: no readable artifacts found\n");
        return 1;
    }

    return ask.run(arena, &corpus, q, opts);
}
