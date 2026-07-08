//! CBOR extractor (RFC 8949). CBOR is JSON's data model in binary — maps,
//! arrays, strings, integers, floats, bool/null — so it decodes to a value
//! tree and is walked with the *same* path and canonical logic as the JSON
//! extractor. The bytes `A2 62 64 62 …` therefore hash to the same identity
//! as the equivalent `{"db":{"port":5432}, …}` JSON: the same fact in JSON,
//! YAML, XML, INI, or CBOR is one identity.
//!
//! Pragmatic, not a validating decoder: it handles the eight major types
//! (incl. indefinite-length strings/arrays/maps and half/single/double
//! floats), skips tag numbers and decodes their content (so a self-describe
//! or datetime tag just yields its inner value), and hashes byte strings
//! (which have no JSON equivalent and may be binary/secret) rather than
//! dumping them. Malformed input returns error.Unparseable.

const std = @import("std");
const types = @import("../types.zig");

pub const Error = error{Unparseable} || std.mem.Allocator.Error;

const max_depth = 64;

/// The self-describe CBOR tag (RFC 8949 §3.4.6) — a reliable magic prefix
/// when present, used by the dispatcher to sniff extensionless CBOR.
pub const self_describe = [_]u8{ 0xd9, 0xd9, 0xf7 };

const Value = union(enum) {
    int: i128, // covers CBOR unsigned (u64) and negative
    float: f64,
    text: []const u8,
    bytes: []const u8,
    boolean: bool,
    nil,
    undef,
    simple: u8,
    array: []Value,
    map: []Pair,

    const Pair = struct { key: Value, val: Value };
};

const Decoder = struct {
    data: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,

    fn byte(self: *Decoder) Error!u8 {
        if (self.pos >= self.data.len) return error.Unparseable;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn take(self: *Decoder, n: usize) Error![]const u8 {
        if (self.pos + n > self.data.len) return error.Unparseable;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn remaining(self: *const Decoder) usize {
        return self.data.len - self.pos;
    }

    /// Read the argument (length/value) encoded by the low 5 bits.
    fn readArg(self: *Decoder, ai: u5) Error!u64 {
        return switch (ai) {
            0...23 => ai,
            24 => try self.byte(),
            25 => std.mem.readInt(u16, (try self.take(2))[0..2], .big),
            26 => std.mem.readInt(u32, (try self.take(4))[0..4], .big),
            27 => std.mem.readInt(u64, (try self.take(8))[0..8], .big),
            else => error.Unparseable, // 28..31 are not valid here
        };
    }

    fn value(self: *Decoder, depth: usize) Error!Value {
        if (depth > max_depth) return error.Unparseable;
        const ib = try self.byte();
        const major: u3 = @intCast(ib >> 5);
        const ai: u5 = @intCast(ib & 0x1f);

        switch (major) {
            0 => return .{ .int = @intCast(try self.readArg(ai)) },
            1 => {
                const n = try self.readArg(ai);
                return .{ .int = -1 - @as(i128, @intCast(n)) };
            },
            2 => return .{ .bytes = try self.readString(ai, 2) },
            3 => return .{ .text = try self.readString(ai, 3) },
            4 => return .{ .array = try self.readArray(ai, depth) },
            5 => return .{ .map = try self.readMap(ai, depth) },
            6 => {
                _ = try self.readArg(ai); // tag number — decode the content
                return self.value(depth + 1);
            },
            7 => return self.readSimple(ai),
        }
    }

    fn readString(self: *Decoder, ai: u5, major: u3) Error![]const u8 {
        if (ai == 31) {
            // Indefinite length: concat definite chunks of the same major type.
            var buf = std.ArrayList(u8).init(self.arena);
            while (true) {
                const ib = try self.byte();
                if (ib == 0xff) break; // break stop code
                if ((ib >> 5) != major) return error.Unparseable;
                const chunk = try self.readString(@intCast(ib & 0x1f), major);
                try buf.appendSlice(chunk);
            }
            return buf.toOwnedSlice();
        }
        const len = try self.readArg(ai);
        if (len > self.remaining()) return error.Unparseable;
        return self.take(@intCast(len));
    }

    fn readArray(self: *Decoder, ai: u5, depth: usize) Error![]Value {
        var items = std.ArrayList(Value).init(self.arena);
        if (ai == 31) {
            while (true) {
                if (self.pos < self.data.len and self.data[self.pos] == 0xff) {
                    self.pos += 1;
                    break;
                }
                try items.append(try self.value(depth + 1));
            }
        } else {
            const count = try self.readArg(ai);
            if (count > self.remaining()) return error.Unparseable; // ≥1 byte/item
            var i: u64 = 0;
            while (i < count) : (i += 1) try items.append(try self.value(depth + 1));
        }
        return items.toOwnedSlice();
    }

    fn readMap(self: *Decoder, ai: u5, depth: usize) Error![]Value.Pair {
        var pairs = std.ArrayList(Value.Pair).init(self.arena);
        if (ai == 31) {
            while (true) {
                if (self.pos < self.data.len and self.data[self.pos] == 0xff) {
                    self.pos += 1;
                    break;
                }
                const k = try self.value(depth + 1);
                const v = try self.value(depth + 1);
                try pairs.append(.{ .key = k, .val = v });
            }
        } else {
            const count = try self.readArg(ai);
            if (count > self.remaining()) return error.Unparseable; // ≥2 bytes/pair
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                const k = try self.value(depth + 1);
                const v = try self.value(depth + 1);
                try pairs.append(.{ .key = k, .val = v });
            }
        }
        return pairs.toOwnedSlice();
    }

    fn readSimple(self: *Decoder, ai: u5) Error!Value {
        return switch (ai) {
            20 => .{ .boolean = false },
            21 => .{ .boolean = true },
            22 => .nil,
            23 => .undef,
            24 => .{ .simple = try self.byte() },
            25 => .{ .float = halfToF64(std.mem.readInt(u16, (try self.take(2))[0..2], .big)) },
            26 => .{ .float = @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, (try self.take(4))[0..4], .big)))) },
            27 => .{ .float = @bitCast(std.mem.readInt(u64, (try self.take(8))[0..8], .big)) },
            else => .{ .simple = ai },
        };
    }
};

fn halfToF64(h: u16) f64 {
    const sign: f64 = if ((h >> 15) & 1 == 1) -1 else 1;
    const exp: u32 = (h >> 10) & 0x1f;
    const mant: f64 = @floatFromInt(h & 0x3ff);
    if (exp == 0) return sign * mant * std.math.pow(f64, 2, -24);
    if (exp == 31) return if (h & 0x3ff == 0) sign * std.math.inf(f64) else std.math.nan(f64);
    return sign * (mant / 1024.0 + 1.0) * std.math.pow(f64, 2, @as(f64, @floatFromInt(@as(i32, @intCast(exp)) - 15)));
}

pub fn extract(arena: std.mem.Allocator, content: []const u8) Error![]types.Primitive {
    var dec = Decoder{ .data = content, .arena = arena };
    const root = try dec.value(0);
    // Trailing bytes after a complete top-level item → not a clean CBOR doc.
    if (dec.pos != content.len) return error.Unparseable;

    var out = std.ArrayList(types.Primitive).init(arena);
    var path = std.ArrayList(u8).init(arena);
    try walk(arena, root, &path, &out);
    return out.toOwnedSlice();
}

/// Mirrors the JSON extractor's walk exactly, so identities unify: sorted map
/// keys, dotted paths, index-less `[]` list segments, bare scalars.
fn walk(
    arena: std.mem.Allocator,
    v: Value,
    path: *std.ArrayList(u8),
    out: *std.ArrayList(types.Primitive),
) Error!void {
    switch (v) {
        .map => |pairs| {
            if (pairs.len == 0) return emit(arena, path.items, "{}", out);
            // Precompute key text, then sort by it — order-independence like JSON.
            const Keyed = struct { k: []const u8, v: Value };
            const keyed = try arena.alloc(Keyed, pairs.len);
            for (pairs, 0..) |p, i| keyed[i] = .{ .k = try keyText(arena, p.key), .v = p.val };
            std.mem.sort(Keyed, keyed, {}, struct {
                fn lessThan(_: void, a: Keyed, b: Keyed) bool {
                    return std.mem.lessThan(u8, a.k, b.k);
                }
            }.lessThan);

            for (keyed) |ke| {
                const mark = path.items.len;
                if (path.items.len > 0) try path.append('.');
                try path.appendSlice(ke.k);
                try walk(arena, ke.v, path, out);
                path.shrinkRetainingCapacity(mark);
            }
        },
        .array => |items| {
            if (items.len == 0) return emit(arena, path.items, "[]", out);
            const mark = path.items.len;
            try path.appendSlice("[]");
            for (items) |item| try walk(arena, item, path, out);
            path.shrinkRetainingCapacity(mark);
        },
        else => try emit(arena, path.items, try scalarText(arena, v), out),
    }
}

fn keyText(arena: std.mem.Allocator, key: Value) Error![]const u8 {
    return switch (key) {
        .text => |t| t,
        .int => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .boolean => |b| if (b) "true" else "false",
        .bytes => |b| try hashLabel(arena, "bytes#", b),
        else => "?",
    };
}

fn scalarText(arena: std.mem.Allocator, v: Value) Error![]const u8 {
    return switch (v) {
        .nil => "null",
        .undef => "undefined",
        .boolean => |b| if (b) "true" else "false",
        .int => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        .text => |t| t,
        .bytes => |b| try hashLabel(arena, "bytes#", b),
        .simple => |s| try std.fmt.allocPrint(arena, "simple({d})", .{s}),
        else => unreachable, // map/array handled in walk
    };
}

fn hashLabel(arena: std.mem.Allocator, prefix: []const u8, data: []const u8) Error![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..6], .lower);
    return std.mem.concat(arena, u8, &.{ prefix, &hex });
}

fn emit(
    arena: std.mem.Allocator,
    path: []const u8,
    scalar: []const u8,
    out: *std.ArrayList(types.Primitive),
) Error!void {
    const key = if (path.len == 0) "$" else path;
    const canonical = try std.mem.concat(arena, u8, &.{ key, "=", scalar });
    try out.append(.{ .kind = .kv, .canonical = canonical, .line = 0 });
}

// -------------------------------------------------------------- tests -----

const json = @import("json.zig");

test "canonical CBOR decodes to the JSON canonical form (literal bytes)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // {"db": {"port": 5432}, "tls": true}
    const bytes = [_]u8{
        0xa2, // map(2)
        0x62, 'd', 'b', // "db"
        0xa1, // map(1)
        0x64, 'p', 'o', 'r', 't', // "port"
        0x19, 0x15, 0x38, // 5432
        0x63, 't', 'l', 's', // "tls"
        0xf5, // true
    };
    const prims = try extract(arena, &bytes);
    try std.testing.expectEqual(@as(usize, 2), prims.len);
    try std.testing.expectEqualStrings("db.port=5432", prims[0].canonical);
    try std.testing.expectEqualStrings("tls=true", prims[1].canonical);
    for (prims) |p| try std.testing.expectEqual(types.PrimitiveKind.kv, p.kind);
}

test "CBOR unifies with the equivalent JSON, byte-for-byte identity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = [_]u8{
        0xa2, 0x62, 'd', 'b', 0xa1, 0x64, 'p', 'o', 'r', 't', 0x19, 0x15, 0x38, 0x63, 't', 'l', 's', 0xf5,
    };
    const from_cbor = try extract(arena, &bytes);
    const from_json = try json.extract(arena, "{\"db\":{\"port\":5432},\"tls\":true}");
    try std.testing.expectEqual(from_json.len, from_cbor.len);
    for (from_cbor, from_json) |c, j| try std.testing.expectEqualStrings(j.canonical, c.canonical);
}

test "arrays are index-less; null/false; self-describe tag is transparent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // self-describe tag (0xd9d9f7) wrapping {"f": ["m","t"], "n": null}
    const bytes = [_]u8{
        0xd9, 0xd9, 0xf7, // tag 55799 (self-describe)
        0xa2, // map(2)
        0x61, 'f', // "f"
        0x82, 0x61, 'm', 0x61, 't', // ["m","t"]
        0x61, 'n', // "n"
        0xf6, // null
    };
    const prims = try extract(arena, &bytes);
    try std.testing.expectEqual(@as(usize, 3), prims.len);
    try std.testing.expectEqualStrings("f[]=m", prims[0].canonical);
    try std.testing.expectEqualStrings("f[]=t", prims[1].canonical);
    try std.testing.expectEqualStrings("n=null", prims[2].canonical);
}

test "byte strings are hashed, not dumped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // {"secret": h'DEADBEEF'}
    const bytes = [_]u8{ 0xa1, 0x66, 's', 'e', 'c', 'r', 'e', 't', 0x44, 0xde, 0xad, 0xbe, 0xef };
    const prims = try extract(arena, &bytes);
    try std.testing.expectEqual(@as(usize, 1), prims.len);
    try std.testing.expect(std.mem.startsWith(u8, prims[0].canonical, "secret=bytes#"));
    try std.testing.expect(std.mem.indexOf(u8, prims[0].canonical, "\xde") == null);
}

test "malformed / truncated CBOR is unparseable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Unparseable, extract(arena, &[_]u8{ 0xa1, 0x62, 'd' })); // truncated
    try std.testing.expectError(error.Unparseable, extract(arena, &[_]u8{ 0x64, 'a', 'b' })); // len 4, 2 bytes
    try std.testing.expectError(error.Unparseable, extract(arena, &[_]u8{ 0x01, 0x02 })); // trailing byte
}
