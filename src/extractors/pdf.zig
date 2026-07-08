//! PDF text extractor (PDF-lite, in the yamlish/xml-lite spirit: pragmatic,
//! zero dependencies, not a conforming PDF reader).
//!
//! Strategy: scan the file for `stream ... endstream` objects, inflate
//! FlateDecode streams with std.compress.zlib (uncompressed streams pass
//! through; other filters like DCTDecode images are skipped), then evaluate
//! the text operators in every content stream:
//!   BT/ET  text blocks          Tj  show string
//!   TJ     show array (numbers < -100 become word spaces)
//!   ' "    next-line show       Td/TD/T*/Tm  line movement → flush
//! Strings decode PDF literal escapes (\n, \), \\, \ooo, line continuations)
//! and hex strings. Multi-byte CID text (Type0 fonts) has no embedded
//! character map, so strings that are mostly non-printable are dropped
//! rather than emitted as garbage.
//!
//! Extracted text lines become `line` primitives; `line` is the 1-based
//! text-line index within the extracted text (PDFs have no source lines).
//! A structurally-unreadable file returns error.Unparseable; the dispatcher
//! maps that to zero primitives rather than falling back to raw binary.

const std = @import("std");
const types = @import("../types.zig");

pub const Error = error{Unparseable} || std.mem.Allocator.Error;

/// Per-stream inflate cap: a decompression bomb must not take the run down.
const max_stream_out = 32 * 1024 * 1024;
/// Strings below this printable ratio are dropped as CID/binary garbage.
const min_printable_ratio = 0.7;

pub fn extract(arena: std.mem.Allocator, content: []const u8) Error![]types.Primitive {
    if (!std.mem.startsWith(u8, content, "%PDF-")) return error.Unparseable;

    var sink = LineSink{
        .arena = arena,
        .out = std.ArrayList(types.Primitive).init(arena),
        .pending = std.ArrayList(u8).init(arena),
    };

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, "stream")) |kw| {
        // Must be the keyword, not a substring (e.g. "endstream").
        if (kw > 0 and !isDelimiter(content[kw - 1])) {
            pos = kw + 6;
            continue;
        }
        var data_start = kw + 6;
        if (data_start < content.len and content[data_start] == '\r') data_start += 1;
        if (data_start < content.len and content[data_start] == '\n') data_start += 1;

        const data_end = std.mem.indexOfPos(u8, content, data_start, "endstream") orelse break;
        const raw = std.mem.trimRight(u8, content[data_start..data_end], "\r\n");
        pos = data_end + 9;

        // The stream dictionary sits between the enclosing "obj" and "stream".
        const dict_start = std.mem.lastIndexOf(u8, content[0..kw], "obj") orelse 0;
        const dict = content[dict_start..kw];

        const data: []const u8 = if (std.mem.indexOf(u8, dict, "/FlateDecode") != null)
            inflate(arena, raw) catch continue // corrupt stream: skip, don't fail the file
        else if (std.mem.indexOf(u8, dict, "/Filter") != null)
            continue // unsupported filter (images etc.)
        else
            raw;

        if (std.mem.indexOf(u8, data, "BT") == null) continue;
        try evalContent(arena, data, &sink);
    }

    try sink.flush();
    return sink.out.toOwnedSlice();
}

fn isDelimiter(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '>' or c == ']' or c == ')';
}

fn inflate(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var in_stream = std.io.fixedBufferStream(raw);
    var decomp = std.compress.zlib.decompressor(in_stream.reader());
    return decomp.reader().readAllAlloc(arena, max_stream_out);
}

// -------------------------------------------------- content evaluation ----

const LineSink = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(types.Primitive),
    pending: std.ArrayList(u8),

    fn append(self: *LineSink, bytes: []const u8) !void {
        try self.pending.appendSlice(bytes);
    }

    fn space(self: *LineSink) !void {
        if (self.pending.items.len > 0) try self.pending.append(' ');
    }

    fn flush(self: *LineSink) !void {
        const text = try normalize(self.arena, self.pending.items);
        self.pending.clearRetainingCapacity();
        if (text.len == 0) return;
        try self.out.append(.{
            .kind = .line,
            .canonical = text,
            .line = @intCast(self.out.items.len + 1),
        });
    }
};

/// Evaluate one content stream, feeding shown text into the sink.
fn evalContent(arena: std.mem.Allocator, data: []const u8, sink: *LineSink) Error!void {
    var op_strings = std.ArrayList(u8).init(arena);
    var in_array = false;
    var last_number: f64 = 0;
    var i: usize = 0;

    while (i < data.len) {
        const c = data[i];
        switch (c) {
            '(' => {
                const s = try literalString(arena, data, &i);
                if (in_array and last_number < -100) try op_strings.append(' ');
                last_number = 0;
                if (printableEnough(s)) try op_strings.appendSlice(s);
            },
            '<' => {
                if (i + 1 < data.len and data[i + 1] == '<') {
                    i += 2; // dict delimiters carry no text
                } else {
                    const s = try hexString(arena, data, &i);
                    if (in_array and last_number < -100) try op_strings.append(' ');
                    last_number = 0;
                    if (printableEnough(s)) try op_strings.appendSlice(s);
                }
            },
            '>' => i += 1,
            '[' => {
                in_array = true;
                last_number = 0;
                i += 1;
            },
            ']' => {
                in_array = false;
                i += 1;
            },
            '%' => { // comment to end of line
                while (i < data.len and data[i] != '\n' and data[i] != '\r') i += 1;
            },
            '/' => { // name object
                i += 1;
                while (i < data.len and !std.ascii.isWhitespace(data[i]) and
                    data[i] != '/' and data[i] != '[' and data[i] != ']' and
                    data[i] != '(' and data[i] != '<' and data[i] != '>') i += 1;
            },
            '+', '-', '.', '0'...'9' => {
                const start = i;
                i += 1;
                while (i < data.len and (std.ascii.isDigit(data[i]) or data[i] == '.')) i += 1;
                last_number = std.fmt.parseFloat(f64, data[start..i]) catch 0;
            },
            else => {
                if (std.ascii.isAlphabetic(c) or c == '\'' or c == '"' or c == '*') {
                    const start = i;
                    i += 1;
                    while (i < data.len and (std.ascii.isAlphanumeric(data[i]) or data[i] == '*' or data[i] == '\'')) i += 1;
                    const op = data[start..i];
                    try applyOperator(op, &op_strings, sink);
                    if (std.mem.eql(u8, op, "BI")) {
                        // Inline image: skip binary payload to EI.
                        const ei = std.mem.indexOfPos(u8, data, i, "EI") orelse data.len;
                        i = if (ei == data.len) data.len else ei + 2;
                    }
                } else {
                    i += 1;
                }
            },
        }
    }
}

fn applyOperator(op: []const u8, op_strings: *std.ArrayList(u8), sink: *LineSink) Error!void {
    if (std.mem.eql(u8, op, "Tj") or std.mem.eql(u8, op, "TJ")) {
        try sink.space();
        try sink.append(op_strings.items);
        op_strings.clearRetainingCapacity();
    } else if (std.mem.eql(u8, op, "'") or std.mem.eql(u8, op, "\"")) {
        // Move to next line, then show.
        try sink.flush();
        try sink.append(op_strings.items);
        op_strings.clearRetainingCapacity();
    } else if (std.mem.eql(u8, op, "Td") or std.mem.eql(u8, op, "TD") or
        std.mem.eql(u8, op, "T*") or std.mem.eql(u8, op, "Tm") or
        std.mem.eql(u8, op, "ET") or std.mem.eql(u8, op, "BT"))
    {
        try sink.flush();
        op_strings.clearRetainingCapacity();
    } else {
        // Any other operator consumes pending string operands.
        op_strings.clearRetainingCapacity();
    }
}

// --------------------------------------------------------- strings --------

fn literalString(arena: std.mem.Allocator, data: []const u8, i: *usize) Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    var depth: usize = 1;
    i.* += 1; // '('
    while (i.* < data.len) {
        const c = data[i.*];
        if (c == '\\') {
            i.* += 1;
            if (i.* >= data.len) break;
            const e = data[i.*];
            switch (e) {
                'n' => try out.append('\n'),
                'r' => try out.append('\r'),
                't' => try out.append('\t'),
                'b', 'f' => {},
                '(' => try out.append('('),
                ')' => try out.append(')'),
                '\\' => try out.append('\\'),
                '\r' => { // line continuation
                    if (i.* + 1 < data.len and data[i.* + 1] == '\n') i.* += 1;
                },
                '\n' => {},
                '0'...'7' => { // up to 3 octal digits
                    var v: u16 = 0;
                    var n: usize = 0;
                    while (n < 3 and i.* < data.len and data[i.*] >= '0' and data[i.*] <= '7') {
                        v = v * 8 + (data[i.*] - '0');
                        i.* += 1;
                        n += 1;
                    }
                    i.* -= 1;
                    try out.append(@truncate(v));
                },
                else => try out.append(e),
            }
            i.* += 1;
        } else if (c == '(') {
            depth += 1;
            try out.append(c);
            i.* += 1;
        } else if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                i.* += 1;
                return out.toOwnedSlice();
            }
            try out.append(c);
            i.* += 1;
        } else {
            try out.append(c);
            i.* += 1;
        }
    }
    return error.Unparseable;
}

fn hexString(arena: std.mem.Allocator, data: []const u8, i: *usize) Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    i.* += 1; // '<'
    var hi: ?u8 = null;
    while (i.* < data.len) {
        const c = data[i.*];
        if (c == '>') {
            i.* += 1;
            if (hi) |h| try out.append(h << 4); // odd digit: low nibble is 0
            return out.toOwnedSlice();
        }
        const digit = std.fmt.charToDigit(c, 16) catch {
            i.* += 1;
            continue; // whitespace inside hex strings is legal
        };
        if (hi) |h| {
            try out.append((h << 4) | digit);
            hi = null;
        } else {
            hi = digit;
        }
        i.* += 1;
    }
    return error.Unparseable;
}

/// Reject multi-byte CID text and binary junk: without a character map it
/// cannot be decoded, only mangled.
fn printableEnough(s: []const u8) bool {
    if (s.len == 0) return false;
    var printable: usize = 0;
    for (s) |c| {
        if (c == 0) return false;
        if (c >= 0x20 or c == '\n' or c == '\r' or c == '\t') printable += 1;
    }
    return @as(f64, @floatFromInt(printable)) / @as(f64, @floatFromInt(s.len)) >= min_printable_ratio;
}

fn normalize(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    var in_ws = true;
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

/// Build a small but structurally real PDF around the given content stream,
/// optionally FlateDecode-compressed — so tests exercise the same paths as
/// PDFs from real generators.
pub fn buildTestPdf(
    arena: std.mem.Allocator,
    content_stream: []const u8,
    compressed: bool,
) ![]const u8 {
    var body = std.ArrayList(u8).init(arena);
    const w = body.writer();

    var stream_data = content_stream;
    var filter: []const u8 = "";
    if (compressed) {
        var out = std.ArrayList(u8).init(arena);
        var comp = try std.compress.zlib.compressor(out.writer(), .{});
        _ = try comp.write(content_stream);
        try comp.finish();
        stream_data = out.items;
        filter = " /Filter /FlateDecode";
    }

    try w.writeAll("%PDF-1.4\n");
    try w.writeAll("1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n");
    try w.writeAll("2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n");
    try w.writeAll("3 0 obj << /Type /Page /Parent 2 0 R /Contents 4 0 R >> endobj\n");
    try w.print("4 0 obj << /Length {d}{s} >> stream\n", .{ stream_data.len, filter });
    try w.writeAll(stream_data);
    try w.writeAll("\nendstream endobj\n");
    try w.writeAll("trailer << /Root 1 0 R >>\n%%EOF\n");
    return body.toOwnedSlice();
}

test "uncompressed content stream text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cs =
        "BT /F1 12 Tf 72 720 Td (Section 1: Coverage) Tj " ++
        "0 -14 Td (Deductible: 500 USD) Tj ET";
    const pdf = try buildTestPdf(arena, cs, false);
    const prims = try extract(arena, pdf);

    try std.testing.expectEqual(@as(usize, 2), prims.len);
    try std.testing.expectEqualStrings("Section 1: Coverage", prims[0].canonical);
    try std.testing.expectEqualStrings("Deductible: 500 USD", prims[1].canonical);
    try std.testing.expectEqual(types.PrimitiveKind.line, prims[0].kind);
    try std.testing.expectEqual(@as(u32, 1), prims[0].line);
    try std.testing.expectEqual(@as(u32, 2), prims[1].line);
}

test "flate-compressed stream is inflated and read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cs = "BT (compressed hello) Tj ET";
    const pdf = try buildTestPdf(arena, cs, true);
    const prims = try extract(arena, pdf);

    try std.testing.expectEqual(@as(usize, 1), prims.len);
    try std.testing.expectEqualStrings("compressed hello", prims[0].canonical);
}

test "TJ arrays, kerning spaces, escapes, and hex strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cs =
        "BT [(Hel) 5 (lo) -250 (world)] TJ " ++
        "0 -14 Td (par\\(en\\) \\\\slash \\101) Tj " ++
        "0 -14 Td <48692074 68657265> Tj ET";
    const pdf = try buildTestPdf(arena, cs, false);
    const prims = try extract(arena, pdf);

    try std.testing.expectEqual(@as(usize, 3), prims.len);
    try std.testing.expectEqualStrings("Hello world", prims[0].canonical);
    try std.testing.expectEqualStrings("par(en) \\slash A", prims[1].canonical);
    try std.testing.expectEqualStrings("Hi there", prims[2].canonical);
}

test "quote operators start new lines; CID garbage is dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cs =
        "BT (first) Tj (second) ' " ++
        "(\\000\\001\\002\\003\\004\\005) Tj (kept) Tj ET";
    const pdf = try buildTestPdf(arena, cs, false);
    const prims = try extract(arena, pdf);

    try std.testing.expectEqual(@as(usize, 2), prims.len);
    try std.testing.expectEqualStrings("first", prims[0].canonical);
    try std.testing.expectEqualStrings("second kept", prims[1].canonical);
}

test "non-pdf input is unparseable; textless pdf yields nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Unparseable, extract(arena, "not a pdf"));

    const pdf = try buildTestPdf(arena, "q 1 0 0 1 0 0 cm Q", false);
    const prims = try extract(arena, pdf);
    try std.testing.expectEqual(@as(usize, 0), prims.len);
}
