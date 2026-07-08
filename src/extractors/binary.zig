//! Binary / executable extractor: content-defined chunking (the core
//! technique inside SSDeep / CTPH fuzzy hashing), turned into WTD primitives.
//!
//! A binary is cut into variable-length chunks whose boundaries are chosen by
//! the *content* itself (a rolling gear-hash trips a boundary when its low
//! bits hit zero), not by fixed offsets. Each chunk's BLAKE3 becomes a
//! `chunk` primitive. Because boundaries are content-defined, inserting or
//! removing bytes only disturbs the chunks around the edit — the rest re-sync
//! — so two related binaries share most of their chunk set even after shifts.
//! That shared fraction is exactly what the consensus / drift / faction
//! engine already measures, so binary similarity clustering falls out for
//! free, with byte-offset evidence and AI explanation on top.
//!
//! A single `kv` primitive records the executable format and architecture
//! (`binary.format=elf/x86_64`), so binaries of the same platform share it —
//! a lone PE among ELF files is an outlier before chunking even matters.
//!
//! Chunk primitives carry the chunk's byte offset in `.line` (files are
//! capped at 64 MiB, so the offset fits u32).

const std = @import("std");
const types = @import("../types.zig");

/// Chunking parameters. Average chunk ≈ min + 2^mask_bits. Smaller chunks
/// give finer similarity resolution at the cost of more primitives; these
/// values (~1.3 KB average) keep a 64 MiB file under ~50k chunks while
/// resolving similarity on samples as small as a few KB.
const min_chunk = 256;
const max_chunk = 8192;
const mask_bits = 10; // boundary probability 1/1024
const boundary_mask: u64 = (1 << mask_bits) - 1;
const chunk_hash_bytes = 12; // 96-bit chunk identity, hex-encoded

/// Deterministic gear table (splitmix64), computed at compile time.
const gear: [256]u64 = blk: {
    @setEvalBranchQuota(4000);
    var g: [256]u64 = undefined;
    var s: u64 = 0x1234567890abcdef;
    for (&g) |*v| {
        s +%= 0x9e3779b97f4a7c15;
        var z = s;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        z = z ^ (z >> 31);
        v.* = z;
    }
    break :blk g;
};

pub fn extract(arena: std.mem.Allocator, content: []const u8) ![]types.Primitive {
    var out = std.ArrayList(types.Primitive).init(arena);

    // Format/arch primitive: platform consensus without touching bytes.
    try out.append(.{
        .kind = .kv,
        .canonical = try std.mem.concat(arena, u8, &.{ "binary.format=", detectFormat(content) }),
        .line = 0,
    });

    // Content-defined chunk boundaries.
    var start: usize = 0;
    while (start < content.len) {
        const end = nextBoundary(content, start);
        try out.append(.{
            .kind = .chunk,
            .canonical = try chunkHash(arena, content[start..end]),
            .line = @intCast(start),
        });
        start = end;
    }
    return out.toOwnedSlice();
}

/// Find the end of the chunk beginning at `start`: the first content-defined
/// boundary at or after `min_chunk` bytes, else `max_chunk`, else EOF.
fn nextBoundary(content: []const u8, start: usize) usize {
    var fp: u64 = 0;
    var i = start;
    while (i < content.len) {
        fp = (fp << 1) +% gear[content[i]];
        i += 1;
        const len = i - start;
        if (len >= min_chunk and (fp & boundary_mask) == 0) return i;
        if (len >= max_chunk) return i;
    }
    return content.len;
}

fn chunkHash(arena: std.mem.Allocator, chunk: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(chunk, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..chunk_hash_bytes], .lower);
    return arena.dupe(u8, &hex);
}

/// Recognize the common executable/object formats and their architecture.
/// Unknown binaries get a stable generic label so they still cluster by
/// content.
fn detectFormat(c: []const u8) []const u8 {
    if (c.len >= 4 and std.mem.eql(u8, c[0..4], "\x7fELF")) return elfFormat(c);
    if (c.len >= 2 and c[0] == 'M' and c[1] == 'Z') return peFormat(c);
    if (c.len >= 4) {
        const m = std.mem.readInt(u32, c[0..4], .little);
        if (m == 0xfeedface) return "mach-o/32";
        if (m == 0xfeedfacf) return "mach-o/64";
        if (std.mem.readInt(u32, c[0..4], .big) == 0xcafebabe) return "mach-o/universal";
        if (std.mem.eql(u8, c[0..4], "\x00asm")) return "wasm";
        if (std.mem.eql(u8, c[0..4], "\xca\xfe\xba\xbe")) return "jvm-class";
    }
    if (c.len >= 8 and std.mem.eql(u8, c[0..8], "!<arch>\n")) return "ar-archive";
    return "binary";
}

fn elfFormat(c: []const u8) []const u8 {
    if (c.len < 20) return "elf";
    const little = c[5] != 2;
    const e_machine = if (little)
        (@as(u16, c[18]) | (@as(u16, c[19]) << 8))
    else
        (@as(u16, c[19]) | (@as(u16, c[18]) << 8));
    return switch (e_machine) {
        0x03 => "elf/x86",
        0x3e => "elf/x86_64",
        0x28 => "elf/arm",
        0xb7 => "elf/aarch64",
        0xf3 => "elf/riscv",
        0x08 => "elf/mips",
        else => "elf",
    };
}

fn peFormat(c: []const u8) []const u8 {
    if (c.len < 0x40) return "pe";
    const pe_off = std.mem.readInt(u32, c[0x3c..0x40], .little);
    if (pe_off + 6 > c.len) return "pe";
    if (!std.mem.eql(u8, c[pe_off .. pe_off + 4], "PE\x00\x00")) return "pe";
    const machine = std.mem.readInt(u16, c[pe_off + 4 ..][0..2], .little);
    return switch (machine) {
        0x014c => "pe/x86",
        0x8664 => "pe/x86_64",
        0xaa64 => "pe/aarch64",
        0x01c0, 0x01c4 => "pe/arm",
        else => "pe",
    };
}

// -------------------------------------------------------------- tests -----

fn chunkSet(arena: std.mem.Allocator, prims: []const types.Primitive) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(arena);
    for (prims) |p| {
        if (p.kind == .chunk) try set.put(p.canonical, {});
    }
    return set;
}

fn jaccard(a: std.StringHashMap(void), b: std.StringHashMap(void)) f64 {
    var inter: usize = 0;
    var it = a.keyIterator();
    while (it.next()) |k| {
        if (b.contains(k.*)) inter += 1;
    }
    const uni = a.count() + b.count() - inter;
    if (uni == 0) return 1;
    return @as(f64, @floatFromInt(inter)) / @as(f64, @floatFromInt(uni));
}

test "chunking is deterministic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [8192]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(1);
    prng.random().bytes(&buf);

    const a = try extract(arena, &buf);
    const b = try extract(arena, &buf);
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try std.testing.expectEqual(x.kind, y.kind);
        try std.testing.expectEqualStrings(x.canonical, y.canonical);
        try std.testing.expectEqual(x.line, y.line);
    }
    try std.testing.expect(a.len > 3); // several chunks for 8 KB
}

test "a localized edit disturbs almost nothing (CTPH shift resilience)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var base: [20000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(&base);

    // Insert 200 bytes in the middle — a fixed-block hasher would lose every
    // downstream block; content-defined chunking re-syncs.
    var edited = std.ArrayList(u8).init(arena);
    try edited.appendSlice(base[0..10000]);
    try edited.appendNTimes(0xAB, 200);
    try edited.appendSlice(base[10000..]);

    const sa = try chunkSet(arena, try extract(arena, &base));
    const sb = try chunkSet(arena, try extract(arena, edited.items));
    try std.testing.expect(jaccard(sa, sb) >= 0.7);

    // An unrelated file of the same size shares essentially nothing.
    var other: [20200]u8 = undefined;
    var prng2 = std.Random.DefaultPrng.init(99);
    prng2.random().bytes(&other);
    const sc = try chunkSet(arena, try extract(arena, &other));
    try std.testing.expect(jaccard(sa, sc) < 0.05);
}

test "format detection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Minimal ELF header: magic, class=2(64), data=1(LE), ... e_machine=0x3e.
    var elf = [_]u8{0} ** 24;
    @memcpy(elf[0..4], "\x7fELF");
    elf[4] = 2;
    elf[5] = 1;
    elf[18] = 0x3e;
    const p = try extract(arena, &elf);
    try std.testing.expectEqualStrings("binary.format=elf/x86_64", p[0].canonical);
    try std.testing.expectEqual(types.PrimitiveKind.kv, p[0].kind);

    const wasm = try extract(arena, "\x00asm\x01\x00\x00\x00");
    try std.testing.expectEqualStrings("binary.format=wasm", wasm[0].canonical);
}

test "tiny input yields one chunk plus the format primitive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try extract(arena, "short");
    try std.testing.expectEqual(@as(usize, 2), p.len);
    try std.testing.expectEqualStrings("binary.format=binary", p[0].canonical);
    try std.testing.expectEqual(types.PrimitiveKind.chunk, p[1].kind);
    try std.testing.expectEqual(@as(u32, 0), p[1].line);
}
