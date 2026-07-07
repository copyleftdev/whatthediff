//! CLI: intent in, story out. Flags select sections and output shape; all
//! analysis is done by the deterministic engine.

const std = @import("std");
const engine = @import("engine.zig");
const render = @import("render.zig");

pub const version = "0.1.0";

const usage =
    \\wtd — WhatTheDiff: what actually matters across N artifacts
    \\
    \\Usage:
    \\  wtd <path>... [options]
    \\
    \\Options:
    \\  --json        Machine-readable report (full evidence graph)
    \\  --evidence    With --json: emit every occurrence (no per-primitive cap)
    \\  --consensus   Only the consensus section
    \\  --drift       Only the drift section
    \\  --version     Print version
    \\  --help        Print this help
    \\
    \\Examples:
    \\  wtd configs/
    \\  wtd contracts/ --drift
    \\  wtd a.json b.json c.json --json
    \\
;

pub fn run(arena: std.mem.Allocator, args: []const []const u8) !u8 {
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
