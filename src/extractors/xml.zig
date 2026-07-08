//! XML extractor (XML-lite, like the YAML-lite extractor: pragmatic, not a
//! validating parser). Emits `kv` primitives in the cross-format canonical
//! form: `<config><db><port>5432</port></db></config>` → `config.db.port=5432`.
//!
//! Canonicalization decisions:
//! - Attributes unify with child elements: `<server host="db"/>` and
//!   `<server><host>db</host></server>` both emit `server.host=db` —
//!   attribute-vs-element is a syntax choice, not a semantic one.
//! - The root element name is part of the path (it is semantic in XML).
//! - Repeated sibling elements emit repeated paths (`features.feature=m`,
//!   `features.feature=t`); XML has no index-less list form.
//! - Text is entity-decoded and whitespace-normalized (runs collapse to one
//!   space, ends trimmed). CDATA is captured verbatim, then normalized the
//!   same way.
//! - An element with no attributes, no text, and no children emits
//!   `path=` — presence of a marker element is a fact.
//! - Comments, processing instructions, and DOCTYPE are skipped.
//!
//! Malformed input returns error.Unparseable; the dispatcher degrades to
//! line primitives, so nothing is ever dropped silently.

const std = @import("std");
const types = @import("../types.zig");

pub const Error = error{Unparseable} || std.mem.Allocator.Error;

const Frame = struct {
    path_mark: usize,
    name: []const u8,
    has_content: bool,
    line: u32,
};

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    path: std.ArrayList(u8),
    stack: std.ArrayList(Frame),
    out: std.ArrayList(types.Primitive),

    fn advance(self: *Parser, n: usize) void {
        const end = @min(self.pos + n, self.src.len);
        for (self.src[self.pos..end]) |c| {
            if (c == '\n') self.line += 1;
        }
        self.pos = end;
    }

    fn rest(self: *const Parser) []const u8 {
        return self.src[self.pos..];
    }

    fn startsWith(self: *const Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.rest(), prefix);
    }

    /// Advance past `needle`, or fail.
    fn skipPast(self: *Parser, needle: []const u8) Error!void {
        const idx = std.mem.indexOf(u8, self.rest(), needle) orelse return error.Unparseable;
        self.advance(idx + needle.len);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.src.len and std.ascii.isWhitespace(self.src[self.pos])) {
            self.advance(1);
        }
    }

    fn parseName(self: *Parser) Error![]const u8 {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isWhitespace(c) or c == '=' or c == '>' or c == '/' or c == '<') break;
            self.advance(1);
        }
        if (self.pos == start) return error.Unparseable;
        return self.src[start..self.pos];
    }

    fn markParentContent(self: *Parser) void {
        if (self.stack.items.len > 0) {
            self.stack.items[self.stack.items.len - 1].has_content = true;
        }
    }

    fn emit(self: *Parser, value: []const u8, line: u32) Error!void {
        const canonical = try std.mem.concat(self.arena, u8, &.{ self.path.items, "=", value });
        try self.out.append(.{ .kind = .kv, .canonical = canonical, .line = line });
    }

    fn emitAttr(self: *Parser, name: []const u8, value: []const u8, line: u32) Error!void {
        const canonical = try std.mem.concat(self.arena, u8, &.{ self.path.items, ".", name, "=", value });
        try self.out.append(.{ .kind = .kv, .canonical = canonical, .line = line });
    }

    fn openTag(self: *Parser) Error!void {
        self.advance(1); // '<'
        const name = try self.parseName();

        self.markParentContent();
        const mark = self.path.items.len;
        if (mark > 0) try self.path.append('.');
        try self.path.appendSlice(name);
        try self.stack.append(.{
            .path_mark = mark,
            .name = name,
            .has_content = false,
            .line = self.line,
        });

        // Attributes until '>' or '/>'.
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) return error.Unparseable;
            if (self.startsWith("/>")) {
                self.advance(2);
                try self.popElement();
                return;
            }
            if (self.src[self.pos] == '>') {
                self.advance(1);
                return;
            }
            const attr_line = self.line;
            const attr_name = try self.parseName();
            self.skipWhitespace();
            if (self.pos >= self.src.len or self.src[self.pos] != '=') return error.Unparseable;
            self.advance(1);
            self.skipWhitespace();
            if (self.pos >= self.src.len) return error.Unparseable;
            const quote = self.src[self.pos];
            if (quote != '"' and quote != '\'') return error.Unparseable;
            self.advance(1);
            const vstart = self.pos;
            const vend = std.mem.indexOfScalarPos(u8, self.src, self.pos, quote) orelse
                return error.Unparseable;
            const raw = self.src[vstart..vend];
            self.advance(raw.len + 1);
            const decoded = try decodeEntities(self.arena, raw);
            try self.emitAttr(attr_name, decoded, attr_line);
            self.stack.items[self.stack.items.len - 1].has_content = true;
        }
    }

    fn closeTag(self: *Parser) Error!void {
        self.advance(2); // '</'
        const name = try self.parseName();
        self.skipWhitespace();
        if (self.pos >= self.src.len or self.src[self.pos] != '>') return error.Unparseable;
        self.advance(1);

        if (self.stack.items.len == 0) return error.Unparseable;
        const top = self.stack.items[self.stack.items.len - 1];
        if (!std.mem.eql(u8, top.name, name)) return error.Unparseable;
        try self.popElement();
    }

    fn popElement(self: *Parser) Error!void {
        const frame = self.stack.pop() orelse return error.Unparseable;
        if (!frame.has_content) try self.emit("", frame.line);
        self.path.shrinkRetainingCapacity(frame.path_mark);
    }

    fn textRun(self: *Parser) Error!void {
        const line = self.line;
        const start = self.pos;
        const idx = std.mem.indexOfScalarPos(u8, self.src, self.pos, '<') orelse self.src.len;
        const raw = self.src[start..idx];
        self.advance(raw.len);

        const decoded = try decodeEntities(self.arena, raw);
        const text = try normalizeWhitespace(self.arena, decoded);
        if (text.len == 0) return;
        // Non-whitespace text outside any element is not XML.
        if (self.stack.items.len == 0) return error.Unparseable;
        self.markParentContent();
        try self.emit(text, line);
    }

    fn cdata(self: *Parser) Error!void {
        const line = self.line;
        self.advance("<![CDATA[".len);
        const idx = std.mem.indexOf(u8, self.rest(), "]]>") orelse return error.Unparseable;
        const raw = self.rest()[0..idx];
        self.advance(idx + "]]>".len);

        const text = try normalizeWhitespace(self.arena, raw);
        if (text.len == 0) return;
        if (self.stack.items.len == 0) return error.Unparseable;
        self.markParentContent();
        try self.emit(text, line);
    }

    fn doctype(self: *Parser) Error!void {
        // <!DOCTYPE ...> possibly with an internal subset [...].
        self.advance(2); // '<!'
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '[') {
                try self.skipPast("]");
                continue;
            }
            if (c == '>') {
                self.advance(1);
                return;
            }
            self.advance(1);
        }
        return error.Unparseable;
    }
};

pub fn extract(arena: std.mem.Allocator, content: []const u8) Error![]types.Primitive {
    var p = Parser{
        .arena = arena,
        .src = content,
        .path = std.ArrayList(u8).init(arena),
        .stack = std.ArrayList(Frame).init(arena),
        .out = std.ArrayList(types.Primitive).init(arena),
    };

    while (p.pos < p.src.len) {
        if (p.src[p.pos] == '<') {
            if (p.startsWith("<!--")) {
                try p.skipPast("-->");
            } else if (p.startsWith("<![CDATA[")) {
                try p.cdata();
            } else if (p.startsWith("<!")) {
                try p.doctype();
            } else if (p.startsWith("<?")) {
                try p.skipPast("?>");
            } else if (p.startsWith("</")) {
                try p.closeTag();
            } else {
                try p.openTag();
            }
        } else {
            try p.textRun();
        }
    }

    if (p.stack.items.len != 0) return error.Unparseable;
    if (p.out.items.len == 0) return error.Unparseable; // no elements at all
    return p.out.toOwnedSlice();
}

/// Decode the predefined entities plus numeric character references.
/// Unknown entities are kept literally.
fn decodeEntities(arena: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;

    var out = std.ArrayList(u8).init(arena);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try out.append(raw[i]);
            i += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse {
            try out.append(raw[i]);
            i += 1;
            continue;
        };
        const entity = raw[i + 1 .. end];
        if (std.mem.eql(u8, entity, "amp")) {
            try out.append('&');
        } else if (std.mem.eql(u8, entity, "lt")) {
            try out.append('<');
        } else if (std.mem.eql(u8, entity, "gt")) {
            try out.append('>');
        } else if (std.mem.eql(u8, entity, "quot")) {
            try out.append('"');
        } else if (std.mem.eql(u8, entity, "apos")) {
            try out.append('\'');
        } else if (entity.len > 1 and entity[0] == '#') {
            const cp = if (entity[1] == 'x' or entity[1] == 'X')
                std.fmt.parseInt(u21, entity[2..], 16) catch return error.Unparseable
            else
                std.fmt.parseInt(u21, entity[1..], 10) catch return error.Unparseable;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch return error.Unparseable;
            try out.appendSlice(buf[0..n]);
        } else {
            // Unknown entity: keep literally.
            try out.appendSlice(raw[i .. end + 1]);
        }
        i = end + 1;
    }
    return out.toOwnedSlice();
}

/// Collapse whitespace runs to a single space and trim both ends.
fn normalizeWhitespace(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    var in_ws = true; // leading whitespace is dropped
    for (raw) |c| {
        if (std.ascii.isWhitespace(c)) {
            in_ws = true;
        } else {
            if (in_ws and out.items.len > 0) try out.append(' ');
            in_ws = false;
            try out.append(c);
        }
    }
    return out.toOwnedSlice();
}

// -------------------------------------------------------------- tests -----

test "nested elements use dotted paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prims = try extract(arena,
        \\<?xml version="1.0"?>
        \\<config>
        \\  <db><port>5432</port><host>db.internal</host></db>
        \\  <tls>true</tls>
        \\</config>
    );
    try std.testing.expectEqual(@as(usize, 3), prims.len);
    try std.testing.expectEqualStrings("config.db.port=5432", prims[0].canonical);
    try std.testing.expectEqualStrings("config.db.host=db.internal", prims[1].canonical);
    try std.testing.expectEqualStrings("config.tls=true", prims[2].canonical);
    try std.testing.expectEqual(@as(u32, 3), prims[0].line);
    for (prims) |p| try std.testing.expectEqual(types.PrimitiveKind.kv, p.kind);
}

test "attributes unify with child elements" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const as_attrs = try extract(arena, "<server host=\"db\" port=\"5432\"/>");
    const as_children = try extract(arena, "<server><host>db</host><port>5432</port></server>");
    try std.testing.expectEqual(@as(usize, 2), as_attrs.len);
    try std.testing.expectEqual(as_attrs.len, as_children.len);
    for (as_attrs, as_children) |a, c| {
        try std.testing.expectEqualStrings(a.canonical, c.canonical);
    }
    try std.testing.expectEqualStrings("server.host=db", as_attrs[0].canonical);
}

test "repeated elements, markers, entities, cdata, comments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prims = try extract(arena,
        \\<!DOCTYPE cfg>
        \\<cfg>
        \\  <!-- ignored -->
        \\  <f>m</f>
        \\  <f>t</f>
        \\  <flag/>
        \\  <q>a &amp; b &#x41;</q>
        \\  <code><![CDATA[x < y]]></code>
        \\</cfg>
    );
    try std.testing.expectEqual(@as(usize, 5), prims.len);
    try std.testing.expectEqualStrings("cfg.f=m", prims[0].canonical);
    try std.testing.expectEqualStrings("cfg.f=t", prims[1].canonical);
    try std.testing.expectEqualStrings("cfg.flag=", prims[2].canonical);
    try std.testing.expectEqualStrings("cfg.q=a & b A", prims[3].canonical);
    try std.testing.expectEqualStrings("cfg.code=x < y", prims[4].canonical);
}

test "whitespace in text is normalized" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prims = try extract(arena, "<a><b>  hello\n   world  </b></a>");
    try std.testing.expectEqual(@as(usize, 1), prims.len);
    try std.testing.expectEqualStrings("a.b=hello world", prims[0].canonical);
}

test "malformed xml is unparseable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Unparseable, extract(arena, "<a><b></a></b>"));
    try std.testing.expectError(error.Unparseable, extract(arena, "<a>unclosed"));
    try std.testing.expectError(error.Unparseable, extract(arena, "just text, no markup"));
}

test "xml matches json under a shared root key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json = @import("json.zig");

    const from_xml = try extract(arena, "<root><db><port>5432</port></db><tls>true</tls></root>");
    const from_json = try json.extract(arena, "{\"root\": {\"db\": {\"port\": 5432}, \"tls\": true}}");
    try std.testing.expectEqual(from_json.len, from_xml.len);
    // JSON sorts keys; XML preserves document order — compare as sets.
    for (from_xml) |x| {
        var found = false;
        for (from_json) |j| {
            if (std.mem.eql(u8, x.canonical, j.canonical)) found = true;
        }
        try std.testing.expect(found);
    }
}
