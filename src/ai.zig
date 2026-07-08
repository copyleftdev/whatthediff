//! AI adapter: a thin HTTP client for LLM chat APIs. Supports the Anthropic
//! Messages API natively and OpenAI-compatible endpoints (OpenRouter, local
//! servers). The adapter only transports text — everything it says is
//! constrained by the evidence prompt built in ask.zig. Zero dependencies:
//! std.http + std.json.

const std = @import("std");

pub const Provider = enum { anthropic, openai_compat };

pub const Config = struct {
    provider: Provider,
    url: []const u8,
    model: []const u8,
    key: []const u8,
};

pub const default_anthropic_model = "claude-opus-4-8";
pub const default_openrouter_model = "anthropic/claude-sonnet-4.5";

/// Resolve provider config from the environment. Precedence:
/// WTD_AI_URL (custom/local endpoint, key optional) > ANTHROPIC_API_KEY >
/// OPENROUTER_API_KEY. WTD_AI_MODEL / WTD_AI_KEY override within any branch.
pub fn detect(arena: std.mem.Allocator) !?Config {
    const override_model = getEnv(arena, "WTD_AI_MODEL");

    // Explicit endpoint: OpenAI-compatible unless it looks like Anthropic.
    // Enables keyless local servers (ollama, llama.cpp, vllm).
    if (getEnv(arena, "WTD_AI_URL")) |url| {
        const is_anthropic = if (getEnv(arena, "WTD_AI_PROVIDER")) |p|
            std.mem.eql(u8, p, "anthropic")
        else
            std.mem.indexOf(u8, url, "anthropic") != null;
        const key = getEnv(arena, "WTD_AI_KEY") orelse
            getEnv(arena, "ANTHROPIC_API_KEY") orelse
            getEnv(arena, "OPENROUTER_API_KEY") orelse "none";
        return .{
            .provider = if (is_anthropic) .anthropic else .openai_compat,
            .url = url,
            .model = override_model orelse
                (if (is_anthropic) default_anthropic_model else default_openrouter_model),
            .key = key,
        };
    }
    if (getEnv(arena, "ANTHROPIC_API_KEY")) |key| {
        return .{
            .provider = .anthropic,
            .url = "https://api.anthropic.com/v1/messages",
            .model = override_model orelse default_anthropic_model,
            .key = key,
        };
    }
    if (getEnv(arena, "OPENROUTER_API_KEY")) |key| {
        const base = getEnv(arena, "OPENROUTER_BASE_URL") orelse "https://openrouter.ai/api/v1";
        return .{
            .provider = .openai_compat,
            .url = try std.mem.concat(arena, u8, &.{ std.mem.trimRight(u8, base, "/"), "/chat/completions" }),
            .model = override_model orelse getEnv(arena, "OPENROUTER_MODEL") orelse default_openrouter_model,
            .key = key,
        };
    }
    return null;
}

fn getEnv(arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const v = std.process.getEnvVarOwned(arena, name) catch return null;
    if (v.len == 0) return null;
    return v;
}

pub const Error = error{ HttpFailed, ApiError, EmptyResponse } || std.mem.Allocator.Error;

/// One-shot completion: system + user prompt in, answer text out.
pub fn complete(
    arena: std.mem.Allocator,
    cfg: Config,
    system: []const u8,
    user: []const u8,
    max_tokens: u32,
) ![]const u8 {
    const body = switch (cfg.provider) {
        .anthropic => try buildAnthropicBody(arena, cfg.model, system, user, max_tokens),
        .openai_compat => try buildOpenAiBody(arena, cfg.model, system, user, max_tokens),
    };

    var client = std.http.Client{ .allocator = arena };
    defer client.deinit();

    var response = std.ArrayList(u8).init(arena);

    const extra_headers: []const std.http.Header = switch (cfg.provider) {
        .anthropic => &.{
            .{ .name = "x-api-key", .value = cfg.key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        },
        .openai_compat => &.{
            .{ .name = "authorization", .value = try std.mem.concat(arena, u8, &.{ "Bearer ", cfg.key }) },
        },
    };

    const result = client.fetch(.{
        .location = .{ .url = cfg.url },
        .method = .POST,
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = extra_headers,
        .response_storage = .{ .dynamic = &response },
        .max_append_size = 4 * 1024 * 1024,
    }) catch |err| {
        std.debug.print("wtd: ai request failed: {s}\n", .{@errorName(err)});
        return error.HttpFailed;
    };

    if (result.status != .ok) {
        printApiError(response.items, @intFromEnum(result.status));
        return error.ApiError;
    }

    return switch (cfg.provider) {
        .anthropic => parseAnthropic(arena, response.items),
        .openai_compat => parseOpenAi(arena, response.items),
    };
}

// ------------------------------------------------------------ bodies ------

const ChatMessage = struct { role: []const u8, content: []const u8 };

fn buildAnthropicBody(
    arena: std.mem.Allocator,
    model: []const u8,
    system: []const u8,
    user: []const u8,
    max_tokens: u32,
) ![]const u8 {
    const Body = struct {
        model: []const u8,
        max_tokens: u32,
        system: []const u8,
        thinking: struct { type: []const u8 = "adaptive" } = .{},
        messages: []const ChatMessage,
    };
    const payload = Body{
        .model = model,
        .max_tokens = max_tokens,
        .system = system,
        .messages = &.{.{ .role = "user", .content = user }},
    };
    var out = std.ArrayList(u8).init(arena);
    try std.json.stringify(payload, .{}, out.writer());
    return out.items;
}

fn buildOpenAiBody(
    arena: std.mem.Allocator,
    model: []const u8,
    system: []const u8,
    user: []const u8,
    max_tokens: u32,
) ![]const u8 {
    const Body = struct {
        model: []const u8,
        max_tokens: u32,
        messages: []const ChatMessage,
    };
    const payload = Body{
        .model = model,
        .max_tokens = max_tokens,
        .messages = &.{
            .{ .role = "system", .content = system },
            .{ .role = "user", .content = user },
        },
    };
    var out = std.ArrayList(u8).init(arena);
    try std.json.stringify(payload, .{}, out.writer());
    return out.items;
}

// ----------------------------------------------------------- parsing ------

/// Anthropic Messages API: concatenate all content blocks of type "text".
/// (Adaptive thinking may prepend thinking blocks; those are skipped.)
fn parseAnthropic(arena: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw, .{}) catch
        return error.EmptyResponse;
    const root = parsed.value.object;

    if (root.get("stop_reason")) |sr| {
        if (sr == .string and std.mem.eql(u8, sr.string, "refusal")) {
            std.debug.print("wtd: the model declined this request (stop_reason: refusal)\n", .{});
            return error.EmptyResponse;
        }
    }

    const content = root.get("content") orelse return error.EmptyResponse;
    if (content != .array) return error.EmptyResponse;

    var out = std.ArrayList(u8).init(arena);
    for (content.array.items) |block| {
        if (block != .object) continue;
        const t = block.object.get("type") orelse continue;
        if (t != .string or !std.mem.eql(u8, t.string, "text")) continue;
        const text = block.object.get("text") orelse continue;
        if (text == .string) try out.appendSlice(text.string);
    }
    if (out.items.len == 0) return error.EmptyResponse;
    return out.items;
}

/// OpenAI-compatible: choices[0].message.content.
fn parseOpenAi(arena: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw, .{}) catch
        return error.EmptyResponse;
    const root = parsed.value.object;

    const choices = root.get("choices") orelse return error.EmptyResponse;
    if (choices != .array or choices.array.items.len == 0) return error.EmptyResponse;
    const first = choices.array.items[0];
    if (first != .object) return error.EmptyResponse;
    const message = first.object.get("message") orelse return error.EmptyResponse;
    if (message != .object) return error.EmptyResponse;
    const content = message.object.get("content") orelse return error.EmptyResponse;
    if (content != .string or content.string.len == 0) return error.EmptyResponse;
    return content.string;
}

fn printApiError(raw: []const u8, status: u32) void {
    // Best effort: surface the API's error message; fall back to the status.
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), raw, .{}) catch {
        std.debug.print("wtd: ai api returned HTTP {d}\n", .{status});
        return;
    };
    const root = parsed.value;
    if (root == .object) {
        if (root.object.get("error")) |e| {
            if (e == .object) {
                if (e.object.get("message")) |m| {
                    if (m == .string) {
                        std.debug.print("wtd: ai api error (HTTP {d}): {s}\n", .{ status, m.string });
                        return;
                    }
                }
            }
        }
    }
    std.debug.print("wtd: ai api returned HTTP {d}\n", .{status});
}

test "anthropic response parsing skips thinking blocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Hello "},{"type":"text","text":"world"}],"stop_reason":"end_turn"}
    ;
    const text = try parseAnthropic(arena, raw);
    try std.testing.expectEqualStrings("Hello world", text);
}

test "openai response parsing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{"choices":[{"message":{"role":"assistant","content":"The answer."}}]}
    ;
    const text = try parseOpenAi(arena, raw);
    try std.testing.expectEqualStrings("The answer.", text);
}

test "request bodies are well-formed json" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try buildAnthropicBody(arena, "claude-opus-4-8", "sys", "user \"quoted\"", 1024);
    const parsed_a = try std.json.parseFromSlice(std.json.Value, arena, a, .{});
    try std.testing.expectEqualStrings("adaptive", parsed_a.value.object.get("thinking").?.object.get("type").?.string);

    const o = try buildOpenAiBody(arena, "anthropic/claude-sonnet-4.5", "sys", "user", 1024);
    const parsed_o = try std.json.parseFromSlice(std.json.Value, arena, o, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed_o.value.object.get("messages").?.array.items.len);
}
