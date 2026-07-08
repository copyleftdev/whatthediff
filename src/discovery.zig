//! Artifact discovery: expand CLI paths into a deterministic, sorted list of
//! candidate files with a kind guess. Reading and binary-sniffing happen in
//! the engine so discovery stays cheap and side-effect free.

const std = @import("std");
const types = @import("types.zig");

pub const Discovered = struct {
    path: []const u8,
    kind: types.ArtifactKind,
};

const skip_names = [_][]const u8{
    ".git",         ".svn",       ".hg",
    "zig-out",      ".zig-cache", "zig-cache",
    "node_modules", "target",     ".venv",
    "__pycache__",
};

pub fn discover(arena: std.mem.Allocator, paths: []const []const u8) ![]Discovered {
    var out = std.ArrayList(Discovered).init(arena);

    for (paths) |p| {
        if (std.fs.cwd().openDir(p, .{ .iterate = true })) |dir_const| {
            var dir = dir_const;
            defer dir.close();
            var walker = try dir.walk(arena);
            defer walker.deinit();
            while (try walker.next()) |entry| {
                if (entry.kind != .file) continue;
                if (shouldSkip(entry.path)) continue;
                const full = try std.fs.path.join(arena, &.{ p, entry.path });
                try out.append(.{ .path = full, .kind = kindFromPath(full) });
            }
        } else |err| switch (err) {
            error.NotDir => try out.append(.{
                .path = try arena.dupe(u8, p),
                .kind = kindFromPath(p),
            }),
            else => return err,
        }
    }

    // Walker order is filesystem-dependent; sorted paths make artifact ids —
    // and therefore every downstream report — reproducible.
    std.mem.sort(Discovered, out.items, {}, struct {
        fn lessThan(_: void, a: Discovered, b: Discovered) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);

    return out.toOwnedSlice();
}

fn shouldSkip(rel_path: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, rel_path, std.fs.path.sep);
    while (it.next()) |component| {
        for (skip_names) |name| {
            if (std.mem.eql(u8, component, name)) return true;
        }
        // Dot-entries are noise except .env, which is a config artifact.
        if (component.len > 1 and component[0] == '.' and
            !std.mem.eql(u8, component, ".env")) return true;
    }
    return false;
}

pub fn kindFromPath(path: []const u8) types.ArtifactKind {
    const basename = std.fs.path.basename(path);
    if (std.ascii.eqlIgnoreCase(basename, ".env")) return .config;

    const ext = std.fs.path.extension(basename);
    const table = .{
        .{ ".json", types.ArtifactKind.json },
        .{ ".yaml", types.ArtifactKind.yaml },
        .{ ".yml", types.ArtifactKind.yaml },
        .{ ".xml", types.ArtifactKind.xml },
        .{ ".pdf", types.ArtifactKind.pdf },
        .{ ".svg", types.ArtifactKind.xml },
        .{ ".xsd", types.ArtifactKind.xml },
        .{ ".xsl", types.ArtifactKind.xml },
        .{ ".plist", types.ArtifactKind.xml },
        .{ ".md", types.ArtifactKind.markdown },
        .{ ".markdown", types.ArtifactKind.markdown },
        .{ ".ini", types.ArtifactKind.config },
        .{ ".conf", types.ArtifactKind.config },
        .{ ".cfg", types.ArtifactKind.config },
        .{ ".toml", types.ArtifactKind.config },
        .{ ".properties", types.ArtifactKind.config },
        .{ ".env", types.ArtifactKind.config },
    };
    inline for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    }
    return .text;
}

test "kindFromPath maps extensions" {
    try std.testing.expectEqual(types.ArtifactKind.json, kindFromPath("a/b.json"));
    try std.testing.expectEqual(types.ArtifactKind.yaml, kindFromPath("x.yml"));
    try std.testing.expectEqual(types.ArtifactKind.config, kindFromPath("app.toml"));
    try std.testing.expectEqual(types.ArtifactKind.config, kindFromPath("dir/.env"));
    try std.testing.expectEqual(types.ArtifactKind.markdown, kindFromPath("README.md"));
    try std.testing.expectEqual(types.ArtifactKind.text, kindFromPath("main.zig"));
}

test "shouldSkip filters vcs and hidden entries" {
    try std.testing.expect(shouldSkip(".git/config"));
    try std.testing.expect(shouldSkip("a/node_modules/b.json"));
    try std.testing.expect(shouldSkip("a/.hidden/file.txt"));
    try std.testing.expect(!shouldSkip("a/.env"));
    try std.testing.expect(!shouldSkip("configs/app.yaml"));
}
