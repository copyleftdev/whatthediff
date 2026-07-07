//! gencorpus — deterministic synthetic corpus generator for scale testing.
//!
//! Writes N config-style files sharing a consensus core, plus K planted
//! rogues (mostly-unique content). Emits a JSON manifest on stdout naming the
//! rogues, so a bench harness can assert WTD flags exactly the planted set.
//! Same (seed, files, rogues, format) → byte-identical corpus.

const std = @import("std");

const usage =
    \\gencorpus <out_dir> [--files N] [--seed S] [--rogues K] [--format yaml|json|conf]
    \\
    \\Defaults: --files 100 --seed 42 --rogues max(1, N/50) --format yaml
    \\
;

const core_kvs = 40;
const noise_per_file = 2;
const rogue_core_kvs = 3;
const rogue_unique_kvs = 30;

const Format = enum { yaml, json, conf };

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);

    var out_dir: ?[]const u8 = null;
    var files: usize = 100;
    var seed: u64 = 42;
    var rogues: ?usize = null;
    var format: Format = .yaml;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--files")) {
            i += 1;
            files = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            seed = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--rogues")) {
            i += 1;
            rogues = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            format = std.meta.stringToEnum(Format, args[i]) orelse {
                try std.io.getStdErr().writer().writeAll(usage);
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try std.io.getStdErr().writer().writeAll(usage);
            std.process.exit(2);
        } else {
            out_dir = arg;
        }
    }

    const dir_path = out_dir orelse {
        try std.io.getStdErr().writer().writeAll(usage);
        std.process.exit(2);
    };
    const n_rogues = @min(rogues orelse @max(files / 50, 1), files);

    try std.fs.cwd().makePath(dir_path);
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    // Rogue positions: deterministically scattered through the corpus.
    var rogue_set = std.AutoHashMap(usize, void).init(arena);
    while (rogue_set.count() < n_rogues) {
        try rogue_set.put(rand.uintLessThan(usize, files), {});
    }

    const ext = switch (format) {
        .yaml => "yaml",
        .json => "json",
        .conf => "conf",
    };

    var rogue_names = std.ArrayList([]const u8).init(arena);
    var content = std.ArrayList(u8).init(arena);

    for (0..files) |idx| {
        const name = try std.fmt.allocPrint(arena, "f{d:0>7}.{s}", .{ idx, ext });
        const is_rogue = rogue_set.contains(idx);
        if (is_rogue) try rogue_names.append(name);

        content.clearRetainingCapacity();
        const w = content.writer();

        if (format == .json) try w.writeAll("{\n");
        if (is_rogue) {
            for (0..rogue_core_kvs) |k| try emit(format, w, k == 0, "core_k{d}", "v{d}", k, k);
            for (0..rogue_unique_kvs) |k| {
                try emitOwn(format, w, false, "rogue_{d}_{d}", idx, k);
            }
        } else {
            for (0..core_kvs) |k| try emit(format, w, k == 0, "core_k{d}", "v{d}", k, k);
            for (0..noise_per_file) |k| {
                try emitOwn(format, w, false, "noise_{d}_{d}", idx, k);
            }
        }
        if (format == .json) try w.writeAll("\n}\n");

        try dir.writeFile(.{ .sub_path = name, .data = content.items });
    }

    // Manifest for harnesses: which files were planted as rogues.
    const Manifest = struct {
        files: usize,
        rogues: usize,
        format: []const u8,
        seed: u64,
        rogue_names: []const []const u8,
    };
    const manifest = Manifest{
        .files = files,
        .rogues = n_rogues,
        .format = ext,
        .seed = seed,
        .rogue_names = rogue_names.items,
    };
    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    try std.json.stringify(manifest, .{}, stdout.writer());
    try stdout.writer().writeByte('\n');
    try stdout.flush();
}

fn emit(
    format: Format,
    w: anytype,
    first: bool,
    comptime key_fmt: []const u8,
    comptime val_fmt: []const u8,
    key_arg: usize,
    val_arg: usize,
) !void {
    switch (format) {
        .yaml => try w.print(key_fmt ++ ": " ++ val_fmt ++ "\n", .{ key_arg, val_arg }),
        .conf => try w.print(key_fmt ++ " = " ++ val_fmt ++ "\n", .{ key_arg, val_arg }),
        .json => {
            if (!first) try w.writeAll(",\n");
            try w.print("  \"" ++ key_fmt ++ "\": \"" ++ val_fmt ++ "\"", .{ key_arg, val_arg });
        },
    }
}

fn emitOwn(
    format: Format,
    w: anytype,
    first: bool,
    comptime key_fmt: []const u8,
    file_idx: usize,
    k: usize,
) !void {
    switch (format) {
        .yaml => try w.print(key_fmt ++ ": x\n", .{ file_idx, k }),
        .conf => try w.print(key_fmt ++ " = x\n", .{ file_idx, k }),
        .json => {
            if (!first) try w.writeAll(",\n");
            try w.print("  \"" ++ key_fmt ++ "\": \"x\"", .{ file_idx, k });
        },
    }
}
