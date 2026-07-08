//! Credential-form flag: a *per-page* signal, independent of clustering.
//!
//! `wtd kit` only surfaces harvested fields when a kit is deployed as a family
//! (≥2 members). Real phishing feeds are full of one-off harvesters — a lone
//! login page on a throwaway domain — that never cluster and so slip past kit
//! signatures. This flags each page that carries a credential-harvesting form
//! on its own, and notes when the form posts **off-domain** (a strong
//! exfiltration signal).
//!
//! A page is flagged when its form fields include a password (any `pass`/`pwd`
//! field) or at least two distinct sensitive fields (username, card, cvv, ssn,
//! otp, seed/mnemonic for wallet phishing, …). Detection runs off the DOM
//! primitives the HTML extractor already emits, so it costs one pass over the
//! per-artifact sets.

const std = @import("std");
const evidence = @import("evidence.zig");
const types = @import("types.zig");

pub const CredentialForm = struct {
    id: u32,
    /// Artifact path or URL.
    name: []const u8,
    /// The credential fields the page collects (sorted, deduplicated).
    fields: []const []const u8,
    /// Absolute host the form posts to, if any.
    action_host: ?[]const u8,
    /// The action host differs from the page's own host (off-domain post).
    off_domain: bool,
};

const FieldKind = enum { none, password, sensitive };

fn classifyField(v: []const u8) FieldKind {
    // Field names are already lowercased by the extractor.
    if (std.mem.indexOf(u8, v, "pass") != null or std.mem.indexOf(u8, v, "pwd") != null) return .password;
    const sensitive = [_][]const u8{
        "user",   "login", "card",     "cvv",      "cvc",     "ssn",
        "pin",    "otp",   "iban",     "routing",  "account", "credit",
        "secret", "seed",  "mnemonic", "recovery", "swift",
    };
    for (sensitive) |k| if (std.mem.indexOf(u8, v, k) != null) return .sensitive;
    return .none;
}

/// Host of a URL artifact name, or null for a non-URL (file) name.
fn hostOf(name: []const u8) ?[]const u8 {
    var s = name;
    if (std.ascii.startsWithIgnoreCase(s, "http://")) {
        s = s[7..];
    } else if (std.ascii.startsWithIgnoreCase(s, "https://")) {
        s = s[8..];
    } else return null;
    const end = std.mem.indexOfAny(u8, s, "/?#:") orelse s.len;
    return if (end == 0) null else s[0..end];
}

fn ltStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn detect(
    arena: std.mem.Allocator,
    store: *const evidence.Store,
    artifacts: []const types.Artifact,
    sets: []const []const u32,
) ![]CredentialForm {
    var out = std.ArrayList(CredentialForm).init(arena);

    for (sets, 0..) |set, id| {
        var fields = std.ArrayList([]const u8).init(arena);
        var seen = std.StringHashMap(void).init(arena);
        var sensitive_distinct = std.StringHashMap(void).init(arena);
        var has_password = false;
        var action_host: ?[]const u8 = null;

        for (set) |idx| {
            const obs = store.at(idx);
            if (obs.kind != .kv) continue;
            const c = obs.canonical;
            if (std.mem.startsWith(u8, c, "field[]=")) {
                const v = c["field[]=".len..];
                const kind = classifyField(v);
                if (kind == .none) continue;
                if (kind == .password) has_password = true;
                if (kind == .sensitive) try sensitive_distinct.put(v, {});
                if (!seen.contains(v)) {
                    try seen.put(v, {});
                    try fields.append(v);
                }
            } else if (action_host == null and std.mem.startsWith(u8, c, "formhost[]=")) {
                action_host = c["formhost[]=".len..];
            }
        }

        if (!has_password and sensitive_distinct.count() < 2) continue;

        std.mem.sort([]const u8, fields.items, {}, ltStr);
        const page_host = hostOf(artifacts[id].path);
        const off = action_host != null and page_host != null and
            !std.ascii.eqlIgnoreCase(action_host.?, page_host.?);

        try out.append(.{
            .id = @intCast(id),
            .name = artifacts[id].path,
            .fields = fields.items,
            .action_host = action_host,
            .off_domain = off,
        });
    }
    return out.toOwnedSlice();
}

// ------------------------------------------------------------- render ------

const field_cap = 12;

pub fn render(writer: anytype, forms: []const CredentialForm) !void {
    if (forms.len == 0) return;
    try writer.print("\nCredential forms ({d} page{s} harvesting credentials)\n", .{
        forms.len, if (forms.len == 1) "" else "s",
    });
    for (forms) |f| try renderOne(writer, f);
}

fn renderOne(writer: anytype, f: CredentialForm) !void {
    try writer.print("  {s}\n    harvests: ", .{f.name});
    const shown = @min(f.fields.len, field_cap);
    for (f.fields[0..shown], 0..) |v, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeAll(v);
    }
    if (f.fields.len > shown) try writer.print(" …+{d}", .{f.fields.len - shown});
    if (f.action_host) |h| {
        try writer.print("   posts to: {s}", .{h});
        if (f.off_domain) try writer.writeAll("  \u{26a0} OFF-DOMAIN");
    }
    try writer.writeAll("\n");
}

pub const JsonForm = struct {
    page: []const u8,
    harvests: []const []const u8,
    posts_to: ?[]const u8,
    off_domain: bool,
};

pub fn toJson(arena: std.mem.Allocator, forms: []const CredentialForm) ![]JsonForm {
    const out = try arena.alloc(JsonForm, forms.len);
    for (forms, 0..) |f, i| {
        out[i] = .{ .page = f.name, .harvests = f.fields, .posts_to = f.action_host, .off_domain = f.off_domain };
    }
    return out;
}

// -------------------------------------------------------------- tests ------

const testing = std.testing;

fn feed(store: *evidence.Store, id: u32, canonicals: []const []const u8) !std.ArrayList(u32) {
    var set = std.ArrayList(u32).init(std.testing.allocator);
    for (canonicals) |c| {
        const r = try store.add(id, .{ .kind = .kv, .canonical = c, .line = 0 });
        if (r.first_for_artifact) try set.append(r.index);
    }
    return set;
}

test "flags a password form and detects off-domain posting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = evidence.Store.init(arena);
    // page 0: login form on evil.example posting to collect.attacker.example
    var s0 = try feed(&store, 0, &.{
        "field[]=username", "field[]=password", "formhost[]=collect.attacker.example", "shape[]=x",
    });
    defer s0.deinit();
    // page 1: a search page — a "search" field, not credentials.
    var s1 = try feed(&store, 1, &.{ "field[]=search-bar", "shape[]=y" });
    defer s1.deinit();
    // page 2: newsletter — a single email field is NOT enough.
    var s2 = try feed(&store, 2, &.{ "field[]=email", "shape[]=z" });
    defer s2.deinit();

    const artifacts = [_]types.Artifact{
        .{ .id = 0, .path = "https://evil.example/login", .kind = .html, .size = 1 },
        .{ .id = 1, .path = "https://ok.example/search", .kind = .html, .size = 1 },
        .{ .id = 2, .path = "https://ok.example/news", .kind = .html, .size = 1 },
    };
    const sets = [_][]const u32{ s0.items, s1.items, s2.items };

    const forms = try detect(arena, &store, &artifacts, &sets);
    try testing.expectEqual(@as(usize, 1), forms.len);
    try testing.expectEqual(@as(u32, 0), forms[0].id);
    try testing.expect(forms[0].off_domain);
    try testing.expectEqualStrings("collect.attacker.example", forms[0].action_host.?);
    try testing.expectEqualStrings("password", forms[0].fields[0]);
    try testing.expectEqualStrings("username", forms[0].fields[1]);
}

test "two sensitive fields flag even without a password field; same-host is not off-domain" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = evidence.Store.init(arena);
    var s0 = try feed(&store, 0, &.{
        "field[]=cardnumber", "field[]=cvv", "formhost[]=pay.shop.example",
    });
    defer s0.deinit();
    const artifacts = [_]types.Artifact{.{ .id = 0, .path = "https://pay.shop.example/checkout", .kind = .html, .size = 1 }};
    const sets = [_][]const u32{s0.items};

    const forms = try detect(arena, &store, &artifacts, &sets);
    try testing.expectEqual(@as(usize, 1), forms.len);
    // action host equals the page host → not off-domain.
    try testing.expect(!forms[0].off_domain);
}
