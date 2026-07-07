//! Core contracts shared by every WTD module.
//!
//! Everything downstream of extraction operates on `Primitive` values and
//! their deterministic `Identity` — never on raw file text.

const std = @import("std");

/// BLAKE3 digest of (primitive kind || 0x00 || canonical bytes).
/// The sole join key across the entire pipeline.
pub const Identity = [32]u8;

pub const ArtifactKind = enum {
    json,
    yaml,
    markdown,
    config,
    text,
};

pub const Artifact = struct {
    /// Dense index into the corpus, assigned in sorted-path order.
    id: u32,
    path: []const u8,
    kind: ArtifactKind,
    size: u64,
};

pub const PrimitiveKind = enum {
    /// A JSON leaf: `$.path[0].to.leaf=<canonical scalar>`.
    json_leaf,
    /// A key/value fact from config or YAML-like sources: `section.key=value`.
    kv,
    /// A Markdown heading: `h2:Title`.
    heading,
    /// A normalized (trimmed, non-empty) text line.
    line,
};

/// The unit of comparison. Artifacts are never compared directly; they are
/// decomposed into primitives whose canonical bytes are stable across
/// formatting noise.
pub const Primitive = struct {
    kind: PrimitiveKind,
    canonical: []const u8,
    /// 1-based source line; 0 when the extractor cannot attribute one.
    line: u32,
};

pub const Occurrence = struct {
    artifact: u32,
    line: u32,
};
