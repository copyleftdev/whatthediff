//! Zero-dependency URL fetcher for `wtd web`: a raw HTTP(S) GET over
//! std.http, returning the response bytes. Redirects are followed by the
//! client; the body is size-capped. This is deliberately *not* a browser — it
//! retrieves server-rendered HTML, which is what most static phishing kits
//! serve. JS-rendered SPAs need an external headless capture fed as snapshot
//! files instead.
//!
//! Fetching is nondeterministic I/O; the deterministic analysis runs over the
//! bytes it returns, exactly like reading a file. Pair with `--snapshot-dir`
//! to persist what was fetched so a run is reproducible.

const std = @import("std");

pub const max_page_bytes = 8 * 1024 * 1024;

pub const Error = error{
    NotHttp,
    FetchFailed,
    HttpStatus,
    Empty,
} || std.mem.Allocator.Error;

pub const Response = struct {
    status: u16,
    body: []const u8,
};

/// True for an `http://` or `https://` URL.
pub fn isHttpUrl(u: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(u, "http://") or
        std.ascii.startsWithIgnoreCase(u, "https://");
}

/// GET a URL. Follows redirects (client default), caps the body, and treats
/// any final status outside 200–399 as an error so a 404/500 page is not
/// mistaken for content.
pub fn get(arena: std.mem.Allocator, url: []const u8) Error!Response {
    if (!isHttpUrl(url)) return error.NotHttp;

    var client = std.http.Client{ .allocator = arena };
    defer client.deinit();

    var body = std.ArrayList(u8).init(arena);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "user-agent", .value = "whatthediff/1.x (+https://github.com/copyleftdev/whatthediff)" },
            .{ .name = "accept", .value = "text/html,application/xhtml+xml,text/*" },
        },
        .response_storage = .{ .dynamic = &body },
        .max_append_size = max_page_bytes,
    }) catch return error.FetchFailed;

    const status = @intFromEnum(result.status);
    if (status < 200 or status >= 400) return error.HttpStatus;
    if (body.items.len == 0) return error.Empty;
    return .{ .status = @intCast(status), .body = body.items };
}

/// A filesystem-safe snapshot filename derived from a URL: non-alphanumeric
/// runs collapse to `_`, capped, with a `.html` suffix. Deterministic so the
/// same URL always maps to the same snapshot name.
pub fn snapshotName(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    var s = url;
    if (std.ascii.startsWithIgnoreCase(s, "http://")) s = s[7..];
    if (std.ascii.startsWithIgnoreCase(s, "https://")) s = s[8..];
    var out = std.ArrayList(u8).init(arena);
    var last_us = false;
    for (s) |c| {
        if (out.items.len >= 96) break;
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-') {
            try out.append(c);
            last_us = false;
        } else if (!last_us) {
            try out.append('_');
            last_us = true;
        }
    }
    while (out.items.len > 0 and (out.items[out.items.len - 1] == '_' or out.items[out.items.len - 1] == '.')) {
        _ = out.pop();
    }
    if (out.items.len == 0) try out.appendSlice("page");
    // Avoid doubling the extension when the URL already ends in .html/.htm.
    if (!std.mem.endsWith(u8, out.items, ".html") and !std.mem.endsWith(u8, out.items, ".htm")) {
        try out.appendSlice(".html");
    }
    return out.items;
}

// ------------------------------------------------------------------ tests ---

const testing = std.testing;

test "isHttpUrl" {
    try testing.expect(isHttpUrl("http://a.com"));
    try testing.expect(isHttpUrl("HTTPS://a.com/x"));
    try testing.expect(!isHttpUrl("ftp://a.com"));
    try testing.expect(!isHttpUrl("/local/path.html"));
}

test "snapshotName is filesystem-safe and deterministic" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const n1 = try snapshotName(arena, "https://evil.example/panel/login.php?id=9");
    try testing.expectEqualStrings("evil.example_panel_login.php_id_9.html", n1);
    const n2 = try snapshotName(arena, "https://evil.example/panel/login.php?id=9");
    try testing.expectEqualStrings(n1, n2); // deterministic

    // No path → host only.
    try testing.expectEqualStrings("a.com.html", try snapshotName(arena, "http://a.com/"));
    // A URL already ending in .html does not double the extension.
    try testing.expectEqualStrings("x.example_p.html", try snapshotName(arena, "https://x.example/p.html"));
}
