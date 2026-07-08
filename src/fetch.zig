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
pub const default_timeout_ms: u64 = 10_000;

pub const Error = error{
    NotHttp,
    FetchFailed,
    HttpStatus,
    Empty,
    Timeout,
    SpawnFailed,
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

/// GET a URL with a hard wall-clock timeout. Follows redirects, caps the body,
/// and treats any final status outside 200–399 as an error so a 404/500 page is
/// not mistaken for content.
///
/// std.http exposes no timeout hook, and connect + TLS happen inside `fetch`,
/// so a socket-level read timeout can't bound the handshake. Instead the whole
/// fetch runs on a worker thread bounded by `ResetEvent.timedWait`. On timeout
/// the worker is detached — it (and its allocations, made from a thread-safe
/// allocator, never the caller's arena) leak until process exit, which is fine
/// for a run that fetches a bounded set of URLs and then exits. This is what
/// makes wtd web usable on real phishing feeds, where dead/slow hosts abound.
pub fn get(arena: std.mem.Allocator, url: []const u8, timeout_ms: u64) Error!Response {
    if (!isHttpUrl(url)) return error.NotHttp;

    const job = std.heap.page_allocator.create(Job) catch return error.OutOfMemory;
    job.* = .{ .url = url };
    const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
        std.heap.page_allocator.destroy(job);
        return error.SpawnFailed;
    };

    job.ev.timedWait(timeout_ms * std.time.ns_per_ms) catch {
        // Abandon the still-running worker; job (leaked) stays valid for it.
        thread.detach();
        return error.Timeout;
    };
    thread.join();
    defer std.heap.page_allocator.destroy(job);

    if (job.err) |e| return e;
    const src = job.body orelse return error.Empty;
    defer std.heap.page_allocator.free(src);
    return .{ .status = job.status, .body = try arena.dupe(u8, src) };
}

/// Shared state between the caller and the fetch worker. Allocated from
/// page_allocator so it (and the worker's writes) stay valid even if the
/// caller abandons it on timeout.
const Job = struct {
    url: []const u8,
    ev: std.Thread.ResetEvent = .{},
    status: u16 = 0,
    body: ?[]u8 = null, // page_allocator-owned on success
    err: ?Error = null,
};

fn worker(job: *Job) void {
    const raw = fetchRaw(std.heap.page_allocator, job.url) catch |e| {
        job.err = e;
        job.ev.set();
        return;
    };
    job.status = raw.status;
    job.body = raw.body;
    job.ev.set();
}

/// The raw fetch. Body is owned by `alloc` (freed by the caller of `get`).
fn fetchRaw(alloc: std.mem.Allocator, url: []const u8) Error!struct { status: u16, body: []u8 } {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var body = std.ArrayList(u8).init(alloc);
    errdefer body.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "user-agent", .value = "whatthediff/1.x (+https://github.com/copyleftdev/whatthediff)" },
            .{ .name = "accept", .value = "text/html,application/xhtml+xml,text/*" },
        },
        .response_storage = .{ .dynamic = &body },
        .max_append_size = max_page_bytes,
    }) catch {
        body.deinit();
        return error.FetchFailed;
    };

    const status = @intFromEnum(result.status);
    if (status < 200 or status >= 400) {
        body.deinit();
        return error.HttpStatus;
    }
    if (body.items.len == 0) {
        body.deinit();
        return error.Empty;
    }
    return .{ .status = @intCast(status), .body = try body.toOwnedSlice() };
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

test "get() times out on a server that accepts but never responds" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    // Accept one connection and hold it open without ever sending a response.
    const Holder = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            std.time.sleep(2 * std.time.ns_per_s);
            conn.stream.close();
        }
    };
    var th = try std.Thread.spawn(.{}, Holder.run, .{&server});
    defer th.join();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/", .{port});

    const start = std.time.milliTimestamp();
    const result = get(arena.allocator(), url, 400); // 400 ms deadline
    const elapsed = std.time.milliTimestamp() - start;

    try testing.expectError(error.Timeout, result);
    // Returned near the deadline, not after the server's 2 s hold.
    try testing.expect(elapsed < 1500);
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
