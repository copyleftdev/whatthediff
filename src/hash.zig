//! Deterministic identity for primitives.

const std = @import("std");
const types = @import("types.zig");

/// Identity = BLAKE3(tag-name || 0x00 || canonical). Domain-separating on the
/// kind keeps a `kv` primitive `a=1` distinct from a `line` primitive `a=1`.
pub fn identity(kind: types.PrimitiveKind, canonical: []const u8) types.Identity {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update(@tagName(kind));
    h.update(&[_]u8{0});
    h.update(canonical);
    var out: types.Identity = undefined;
    h.final(&out);
    return out;
}

pub fn hex(id: types.Identity) [64]u8 {
    return std.fmt.bytesToHex(id, .lower);
}

test "identity is deterministic" {
    const a = identity(.kv, "timeout=30");
    const b = identity(.kv, "timeout=30");
    try std.testing.expectEqual(a, b);
}

test "identity is domain-separated by kind" {
    const a = identity(.kv, "timeout=30");
    const b = identity(.line, "timeout=30");
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "identity differs on content" {
    const a = identity(.kv, "timeout=30");
    const b = identity(.kv, "timeout=31");
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}
