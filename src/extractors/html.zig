//! HTML / DOM extractor: turns a captured web page into the facts that
//! identify it *structurally*, so the consensus / drift / faction engine can
//! cluster pages the way it clusters configs and binaries. The target use case
//! is clone / phishing-kit detection — pages that are the "same" page even
//! across different domains, branding, and injected noise.
//!
//! The whole problem is DOM noise (session tokens, hashed class names, ads,
//! localized copy). The fix is choosing what to keep so two instances of one
//! page overlap. Every feature is an index-less list primitive (a bag), so it
//! flows through the engine unchanged, exactly like a binary's imports[]:
//!
//!   shape[]=a1b2c3        w-shingles of the tag stream (fuzzy structure)
//!   field[]=password      form field names — the strongest kit signal
//!   formfields[]=9f2e…    hash of one form's sorted field-name set
//!   formaction[]=evil.co  form action host (absolute) or path (relative)
//!   resource[]=cdn.evil.co  script/link/img/iframe hosts (external infra)
//!   path[]=form>input:password   root path to landmark elements
//!   title[]=… heading[]=h1:… meta[]=og:site_name=… comment[]=…
//!
//! The parser is tolerant and bounds-checked: malformed markup yields fewer
//! primitives, never a crash. Given identical bytes it is byte-deterministic.

const std = @import("std");
const types = @import("../types.zig");

pub const Error = std.mem.Allocator.Error;

/// A structural shingle spans this many tag tokens. Smaller = more sensitive
/// to local structure; an inserted element only disturbs `shingle_k` windows.
const shingle_k = 5;
const max_tokens = 200_000;
const max_shingles = 4096;
const max_features = 4096;
const text_max = 120;

const Attr = struct { name: []const u8, value: []const u8 };

const void_tags = [_][]const u8{
    "area",  "base", "br",   "col",   "embed",  "hr",    "img",
    "input", "link", "meta", "param", "source", "track", "wbr",
};

pub fn extract(arena: std.mem.Allocator, content: []const u8) Error![]types.Primitive {
    var p = Parser{
        .arena = arena,
        .out = std.ArrayList(types.Primitive).init(arena),
        .tokens = std.ArrayList([]const u8).init(arena),
        .path = std.ArrayList([]const u8).init(arena),
        .forms = std.ArrayList(std.ArrayList([]const u8)).init(arena),
        .shingles = std.StringHashMap(void).init(arena),
        .counts = .{},
    };
    try p.run(content);
    try p.emitShingles();
    return p.out.toOwnedSlice();
}

const Counts = struct {
    field: usize = 0,
    formfields: usize = 0,
    formaction: usize = 0,
    formhost: usize = 0,
    resource: usize = 0,
    path: usize = 0,
    meta: usize = 0,
    heading: usize = 0,
    title: usize = 0,
    comment: usize = 0,
};

const Parser = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(types.Primitive),
    tokens: std.ArrayList([]const u8),
    path: std.ArrayList([]const u8),
    forms: std.ArrayList(std.ArrayList([]const u8)),
    shingles: std.StringHashMap(void),
    counts: Counts,
    capture_tag: ?[]const u8 = null,
    capture: std.ArrayList(u8) = undefined,

    fn run(self: *Parser, content: []const u8) Error!void {
        self.capture = std.ArrayList(u8).init(self.arena);
        var i: usize = 0;
        while (i < content.len) {
            if (content[i] != '<') {
                const start = i;
                while (i < content.len and content[i] != '<') i += 1;
                if (self.capture_tag != null) try self.capture.appendSlice(content[start..i]);
                continue;
            }
            // A '<' begins markup.
            if (std.mem.startsWith(u8, content[i..], "<!--")) {
                const rel = std.mem.indexOf(u8, content[i + 4 ..], "-->") orelse (content.len - i - 4);
                try self.emitText("comment", content[i + 4 .. i + 4 + rel]);
                i = @min(i + 4 + rel + 3, content.len);
                continue;
            }
            if (i + 1 < content.len and content[i + 1] == '!') { // doctype / declaration
                const rel = std.mem.indexOfScalar(u8, content[i..], '>') orelse (content.len - i - 1);
                i += rel + 1;
                continue;
            }
            if (i + 1 < content.len and content[i + 1] == '/') { // close tag
                var j = i + 2;
                const ns = j;
                while (j < content.len and isNameChar(content[j])) j += 1;
                const name = content[ns..j];
                const rel = std.mem.indexOfScalar(u8, content[j..], '>') orelse (content.len - j);
                i = @min(j + rel + 1, content.len);
                try self.handleClose(name);
                continue;
            }
            if (i + 1 >= content.len or !isNameStart(content[i + 1])) { // stray '<'
                i += 1;
                continue;
            }
            const tag = try self.parseTag(content, i);
            i = tag.end;
            const lname = try lower(self.arena, tag.name);
            try self.handleOpen(lname, tag.attrs, tag.selfclose);
            // <script>/<style> hold raw text: skip to the matching close.
            if ((std.mem.eql(u8, lname, "script") or std.mem.eql(u8, lname, "style")) and !tag.selfclose) {
                const close = try std.fmt.allocPrint(self.arena, "</{s}", .{lname});
                const rel = indexOfIgnoreCase(content[i..], close) orelse (content.len - i);
                i += rel;
                // Advance past the close tag's '>'.
                if (std.mem.indexOfScalar(u8, content[i..], '>')) |g| i += g + 1 else i = content.len;
                try self.handleClose(lname);
            }
        }
    }

    fn handleOpen(self: *Parser, lname: []const u8, attrs: []const Attr, selfclose: bool) Error!void {
        const is_void = isVoid(lname) or selfclose;

        // Tag token for the structural stream (inputs carry their type).
        var token: []const u8 = undefined;
        if (std.mem.eql(u8, lname, "input")) {
            const t = getAttr(attrs, "type") orelse "text";
            token = try std.fmt.allocPrint(self.arena, "+input:{s}", .{try lower(self.arena, t)});
        } else {
            token = try std.mem.concat(self.arena, u8, &.{ "+", lname });
        }
        try self.pushToken(token);

        try self.landmarkPath(lname, attrs);
        try self.formField(lname, attrs);
        try self.resources(lname, attrs);
        try self.metaTag(lname, attrs);

        if (std.mem.eql(u8, lname, "form")) {
            try self.forms.append(std.ArrayList([]const u8).init(self.arena));
        }
        if (isTextCapture(lname)) {
            self.capture_tag = lname;
            self.capture.clearRetainingCapacity();
        }

        if (is_void) {
            try self.pushToken(try std.mem.concat(self.arena, u8, &.{ "-", lname }));
        } else {
            try self.path.append(lname);
        }
    }

    fn handleClose(self: *Parser, name: []const u8) Error!void {
        const lname = try lower(self.arena, name);

        if (self.capture_tag) |ct| {
            if (std.mem.eql(u8, ct, lname)) {
                try self.emitCapture(ct);
                self.capture_tag = null;
            }
        }

        if (std.mem.eql(u8, lname, "form") and self.forms.items.len > 0) {
            try self.emitFormFields();
            _ = self.forms.pop();
        }

        // Tolerant close: pop down to the nearest matching open tag.
        var k: usize = self.path.items.len;
        while (k > 0) : (k -= 1) {
            if (std.mem.eql(u8, self.path.items[k - 1], lname)) {
                self.path.shrinkRetainingCapacity(k - 1);
                break;
            }
        }
        try self.pushToken(try std.mem.concat(self.arena, u8, &.{ "-", lname }));
    }

    fn pushToken(self: *Parser, t: []const u8) Error!void {
        if (self.tokens.items.len < max_tokens) try self.tokens.append(t);
    }

    fn landmarkPath(self: *Parser, lname: []const u8, attrs: []const Attr) Error!void {
        if (!isLandmark(lname)) return;
        var buf = std.ArrayList(u8).init(self.arena);
        // Last few ancestors keep the path discriminative without being huge.
        const depth = self.path.items.len;
        const from = if (depth > 5) depth - 5 else 0;
        for (self.path.items[from..]) |anc| {
            try buf.appendSlice(anc);
            try buf.append('>');
        }
        try buf.appendSlice(lname);
        if (std.mem.eql(u8, lname, "input")) {
            const t = getAttr(attrs, "type") orelse "text";
            try buf.append(':');
            try buf.appendSlice(try lower(self.arena, t));
        }
        try self.emit("path", buf.items, &self.counts.path);
    }

    fn formField(self: *Parser, lname: []const u8, attrs: []const Attr) Error!void {
        const is_field = std.mem.eql(u8, lname, "input") or std.mem.eql(u8, lname, "select") or
            std.mem.eql(u8, lname, "textarea");
        if (!is_field or self.forms.items.len == 0) return;
        const raw = getAttr(attrs, "name") orelse getAttr(attrs, "id") orelse
            getAttr(attrs, "type") orelse lname;
        const fname = try lower(self.arena, raw);
        try self.emit("field", fname, &self.counts.field);
        try self.forms.items[self.forms.items.len - 1].append(fname);
    }

    fn emitFormFields(self: *Parser) Error!void {
        const fields = &self.forms.items[self.forms.items.len - 1];
        if (fields.items.len == 0) return;
        std.mem.sort([]const u8, fields.items, {}, lessStr);
        var h = std.crypto.hash.Blake3.init(.{});
        for (fields.items) |f| {
            h.update(f);
            h.update(&[_]u8{0});
        }
        var digest: [32]u8 = undefined;
        h.final(&digest);
        const hex = std.fmt.bytesToHex(digest[0..12], .lower);
        try self.emit("formfields", &hex, &self.counts.formfields);
    }

    fn resources(self: *Parser, lname: []const u8, attrs: []const Attr) Error!void {
        if (std.mem.eql(u8, lname, "form")) {
            if (getAttr(attrs, "action")) |a| {
                if (try actionValue(self.arena, a)) |v| try self.emit("formaction", v, &self.counts.formaction);
                // An absolute action posts to an explicit host — record it so a
                // credential form's off-domain exfiltration can be detected.
                if (urlHost(self.arena, a)) |h| try self.emit("formhost", h, &self.counts.formhost);
            }
            return;
        }
        const url_attr: ?[]const u8 = if (std.mem.eql(u8, lname, "script") or std.mem.eql(u8, lname, "img") or
            std.mem.eql(u8, lname, "iframe"))
            getAttr(attrs, "src")
        else if (std.mem.eql(u8, lname, "link"))
            getAttr(attrs, "href")
        else
            null;
        if (url_attr) |u| {
            if (urlHost(self.arena, u)) |host| try self.emit("resource", host, &self.counts.resource);
        }
    }

    fn metaTag(self: *Parser, lname: []const u8, attrs: []const Attr) Error!void {
        if (!std.mem.eql(u8, lname, "meta")) return;
        const content_v = getAttr(attrs, "content") orelse return;
        const key = getAttr(attrs, "property") orelse getAttr(attrs, "name") orelse return;
        const lk = try lower(self.arena, key);
        const keep = std.mem.startsWith(u8, lk, "og:") or std.mem.eql(u8, lk, "generator") or
            std.mem.eql(u8, lk, "application-name") or std.mem.eql(u8, lk, "author");
        if (!keep) return;
        const norm = normalizeText(self.arena, content_v) orelse return;
        const kv = try std.mem.concat(self.arena, u8, &.{ lk, "=", norm });
        try self.emit("meta", kv, &self.counts.meta);
    }

    fn emitCapture(self: *Parser, tag: []const u8) Error!void {
        const norm = normalizeText(self.arena, self.capture.items) orelse return;
        if (std.mem.eql(u8, tag, "title")) {
            try self.emit("title", norm, &self.counts.title);
        } else {
            const v = try std.mem.concat(self.arena, u8, &.{ tag, ":", norm });
            try self.emit("heading", v, &self.counts.heading);
        }
    }

    fn emitShingles(self: *Parser) Error!void {
        const toks = self.tokens.items;
        if (toks.len < shingle_k) return;
        var i: usize = 0;
        while (i + shingle_k <= toks.len) : (i += 1) {
            var h = std.crypto.hash.Blake3.init(.{});
            for (toks[i .. i + shingle_k]) |t| {
                h.update(t);
                h.update(&[_]u8{0x1f});
            }
            var digest: [32]u8 = undefined;
            h.final(&digest);
            const hex = std.fmt.bytesToHex(digest[0..9], .lower);
            const owned = try self.arena.dupe(u8, &hex);
            if (self.shingles.contains(owned)) continue;
            if (self.shingles.count() >= max_shingles) break;
            try self.shingles.put(owned, {});
            const canonical = try std.mem.concat(self.arena, u8, &.{ "shape[]=", owned });
            try self.out.append(.{ .kind = .kv, .canonical = canonical, .line = 0 });
        }
    }

    fn emit(self: *Parser, key: []const u8, value: []const u8, counter: *usize) Error!void {
        if (counter.* >= max_features) return;
        counter.* += 1;
        const canonical = try std.mem.concat(self.arena, u8, &.{ key, "[]=", value });
        try self.out.append(.{ .kind = .kv, .canonical = canonical, .line = 0 });
    }

    fn emitText(self: *Parser, key: []const u8, raw: []const u8) Error!void {
        const norm = normalizeText(self.arena, raw) orelse return;
        try self.emit(key, norm, &self.counts.comment);
    }

    fn parseTag(self: *Parser, c: []const u8, start: usize) Error!struct {
        name: []const u8,
        attrs: []Attr,
        selfclose: bool,
        end: usize,
    } {
        var i = start + 1;
        const ns = i;
        while (i < c.len and isNameChar(c[i])) i += 1;
        const name = c[ns..i];
        var attrs = std.ArrayList(Attr).init(self.arena);
        var selfclose = false;
        while (i < c.len) {
            while (i < c.len and isSpace(c[i])) i += 1;
            if (i >= c.len) break;
            if (c[i] == '>') {
                i += 1;
                break;
            }
            if (c[i] == '/') {
                selfclose = true;
                i += 1;
                continue;
            }
            const an_s = i;
            while (i < c.len and !isSpace(c[i]) and c[i] != '=' and c[i] != '>' and c[i] != '/') i += 1;
            const aname = c[an_s..i];
            var aval: []const u8 = "";
            while (i < c.len and isSpace(c[i])) i += 1;
            if (i < c.len and c[i] == '=') {
                i += 1;
                while (i < c.len and isSpace(c[i])) i += 1;
                if (i < c.len and (c[i] == '"' or c[i] == '\'')) {
                    const q = c[i];
                    i += 1;
                    const vs = i;
                    while (i < c.len and c[i] != q) i += 1;
                    aval = c[vs..i];
                    if (i < c.len) i += 1;
                } else {
                    const vs = i;
                    while (i < c.len and !isSpace(c[i]) and c[i] != '>') i += 1;
                    aval = c[vs..i];
                }
            }
            if (aname.len > 0) try attrs.append(.{ .name = aname, .value = aval });
        }
        return .{ .name = name, .attrs = try attrs.toOwnedSlice(), .selfclose = selfclose, .end = i };
    }
};

// --------------------------------------------------------------- helpers ---

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c);
}
fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == ':' or c == '_';
}
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c';
}

fn isVoid(lname: []const u8) bool {
    for (void_tags) |v| if (std.mem.eql(u8, v, lname)) return true;
    return false;
}
fn isLandmark(lname: []const u8) bool {
    const set = [_][]const u8{ "form", "input", "script", "iframe", "select", "textarea", "button" };
    for (set) |s| if (std.mem.eql(u8, s, lname)) return true;
    return false;
}
fn isTextCapture(lname: []const u8) bool {
    const set = [_][]const u8{ "title", "h1", "h2", "h3" };
    for (set) |s| if (std.mem.eql(u8, s, lname)) return true;
    return false;
}

fn lower(arena: std.mem.Allocator, s: []const u8) Error![]const u8 {
    const out = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn getAttr(attrs: []const Attr, name: []const u8) ?[]const u8 {
    for (attrs) |a| if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value;
    return null;
}

/// Host of an absolute URL, lowercased; null for a relative URL.
fn urlHost(arena: std.mem.Allocator, u: []const u8) ?[]const u8 {
    var s = u;
    if (std.ascii.startsWithIgnoreCase(s, "http://")) {
        s = s[7..];
    } else if (std.ascii.startsWithIgnoreCase(s, "https://")) {
        s = s[8..];
    } else if (std.mem.startsWith(u8, s, "//")) {
        s = s[2..];
    } else return null;
    const end = std.mem.indexOfAny(u8, s, "/?#:") orelse s.len;
    const host = s[0..end];
    if (host.len == 0) return null;
    return lower(arena, host) catch null;
}

/// A form action reduced to a stable token: host if absolute, else the last
/// path segment (a kit posting to `next.php` shares that across domains).
fn actionValue(arena: std.mem.Allocator, u: []const u8) Error!?[]const u8 {
    if (urlHost(arena, u)) |h| return h;
    const end = std.mem.indexOfAny(u8, u, "?#") orelse u.len;
    const path = u[0..end];
    const base = std.fs.path.basename(path);
    if (base.len == 0) return null;
    return try lower(arena, base);
}

/// Collapse whitespace, trim, cap length; null if nothing printable remains.
fn normalizeText(arena: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    var out = std.ArrayList(u8).init(arena);
    var in_ws = true;
    for (raw) |c| {
        if (isSpace(c)) {
            in_ws = true;
        } else if (c < 0x20 or c == 0x7f) {
            // Drop ASCII control characters; keep printable ASCII and all
            // high bytes so UTF-8 brand text (accents, em-dashes) survives.
        } else {
            if (in_ws and out.items.len > 0) out.append(' ') catch return null;
            in_ws = false;
            out.append(c) catch return null;
            if (out.items.len >= text_max) break;
        }
    }
    if (out.items.len == 0) return null;
    return out.items;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ------------------------------------------------------------------ tests ---

const testing = std.testing;

fn values(arena: std.mem.Allocator, prims: []const types.Primitive, key: []const u8) ![][]const u8 {
    const prefix = try std.mem.concat(arena, u8, &.{ key, "[]=" });
    var vals = std.ArrayList([]const u8).init(arena);
    for (prims) |p| {
        if (std.mem.startsWith(u8, p.canonical, prefix)) try vals.append(p.canonical[prefix.len..]);
    }
    return vals.toOwnedSlice();
}

fn has(vals: []const []const u8, target: []const u8) bool {
    for (vals) |v| if (std.mem.eql(u8, v, target)) return true;
    return false;
}

test "extracts form fields, action host, and resource hosts" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const html =
        \\<html><head><title>Sign in — Acme</title>
        \\<script src="https://cdn.evil.co/kit.js"></script></head>
        \\<body><h1>Log in to Acme</h1>
        \\<form action="https://harvest.evil.co/next.php" method="post">
        \\  <input type="text" name="username">
        \\  <input type="password" name="password">
        \\  <input type="text" name="otp">
        \\</form></body></html>
    ;
    const prims = try extract(arena, html);

    const fields = try values(arena, prims, "field");
    try testing.expect(has(fields, "username"));
    try testing.expect(has(fields, "password"));
    try testing.expect(has(fields, "otp"));

    const action = try values(arena, prims, "formaction");
    try testing.expect(has(action, "harvest.evil.co"));

    const res = try values(arena, prims, "resource");
    try testing.expect(has(res, "cdn.evil.co"));

    const titles = try values(arena, prims, "title");
    try testing.expect(has(titles, "Sign in — Acme"));
    const heads = try values(arena, prims, "heading");
    try testing.expect(has(heads, "h1:Log in to Acme"));

    // Structural shingles are present.
    const shapes = try values(arena, prims, "shape");
    try testing.expect(shapes.len > 3);
}

test "relative form action keeps the path segment" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const prims = try extract(arena, "<form action=\"/panel/login.php\"><input name=\"u\"></form>");
    const action = try values(arena, prims, "formaction");
    try testing.expect(has(action, "login.php"));
}

test "an injected element barely changes the shingle set (structural stability)" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // A realistically-sized page: many structural rows. One injected node then
    // perturbs only a small fraction of the shingle windows.
    var base_b = std.ArrayList(u8).init(arena);
    try base_b.appendSlice("<html><body><main><form>");
    for (0..30) |i| try base_b.writer().print("<div class=row><label>f{d}</label><input name=f{d}></div>", .{ i, i });
    try base_b.appendSlice("<button>go</button></form></main></body></html>");
    const base = base_b.items;

    // Inject one <span> in the middle.
    const mid = std.mem.indexOf(u8, base, "f15").?;
    const inj = try std.mem.concat(arena, u8, &.{ base[0..mid], "<span>ad</span>", base[mid..] });

    const pa = try extract(arena, base);
    const pb = try extract(arena, inj);
    const sa = try values(arena, pa, "shape");
    const sb = try values(arena, pb, "shape");

    var inter: usize = 0;
    for (sa) |x| if (has(sb, x)) {
        inter += 1;
    };
    const uni = sa.len + sb.len - inter;
    const jaccard = @as(f64, @floatFromInt(inter)) / @as(f64, @floatFromInt(uni));
    // One inserted node perturbs only the local windows.
    try testing.expect(jaccard >= 0.5);
}

test "malformed / unclosed markup does not crash" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const prims = try extract(arena, "<html><body><p><div><form><input name=x</form></body");
    try testing.expect(prims.len >= 1);
}
