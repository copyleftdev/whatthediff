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
    xml,
    pdf,
    binary,
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
    /// A key/value fact in the cross-format canonical form `db.port=5432`
    /// (list items `features[]=x`, scalars unquoted). JSON, YAML-lite, and
    /// config extractors all emit this kind, so the same fact in any of
    /// those formats hashes to the same identity.
    kv,
    /// A Markdown heading: `h2:Title`.
    heading,
    /// A normalized (trimmed, non-empty) text line.
    line,
    /// A content-defined chunk of a binary (SSDeep/CTPH-style); canonical is
    /// the chunk's BLAKE3 hex, `.line` is its byte offset.
    chunk,
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
