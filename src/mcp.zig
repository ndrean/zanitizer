//! MCP (Model Context Protocol) HTTP handler for zexplorer.
//!
//! Transport: HTTP POST /mcp  (JSON-RPC 2.0)
//!
//! Claude Desktop or Gemini config (via mcp-remote):
//!   {
//!     "mcpServers": {
//!       "zexplorer": {
//!         "command": "npx",
//!         "args": ["-y", "mcp-remote", "http://localhost:9984/mcp"]
//!       }
//!     }
//!   }
//!
//! Or with native HTTP MCP support (newer Claude Desktop):
//!   { "mcpServers": { "zexplorer": { "url": "http://localhost:9984/mcp" } } }

const std = @import("std");
const z = @import("zxp");
const httpz = @import("httpz");
const zxp_runtime = z.zxp_runtime;
const js_streamfrom = z.js_streamfrom;
const AppContext = z.serve.AppContext;

const MCP_VERSION = "2024-11-05";
const SERVER_NAME = "zexplorer";
const SERVER_VERSION = "0.1.0";

// ── JSON-RPC 2.0 request ──────────────────────────────────────────────────────

const McpRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?std.json.Value = null,
    method: []const u8,
    params: ?std.json.Value = null,
};

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn mcpHandler(app_ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        return;
    };

    const alloc = app_ctx.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    res.header("Content-Type", "application/json");

    const parsed = std.json.parseFromSlice(McpRequest, aa, body, .{
        .ignore_unknown_fields = true,
    }) catch {
        res.body = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}";
        return;
    };

    const mcp_req = parsed.value;
    var out: std.Io.Writer.Allocating = .init(aa);

    if (std.mem.eql(u8, mcp_req.method, "initialize")) {
        try buildInitialize(mcp_req.id, &out);
    } else if (std.mem.eql(u8, mcp_req.method, "initialized")) {
        try out.writer.writeAll("{}");
    } else if (std.mem.eql(u8, mcp_req.method, "tools/list")) {
        try buildToolsList(mcp_req.id, &out);
    } else if (std.mem.eql(u8, mcp_req.method, "tools/call")) {
        const params = mcp_req.params orelse {
            try buildError(mcp_req.id, -32602, "Invalid params: missing params", &out);
            res.body = try res.arena.dupe(u8, try out.toOwnedSlice());
            return;
        };
        try handleToolsCall(app_ctx, mcp_req.id, params, &out, aa, alloc);
    } else {
        try buildError(mcp_req.id, -32601, "Method not found", &out);
    }

    res.body = try res.arena.dupe(u8, try out.toOwnedSlice());
}

// ── Response builders ─────────────────────────────────────────────────────────

fn writeId(id: ?std.json.Value, w: anytype) !void {
    if (id) |v| {
        try std.json.Stringify.value(v, .{}, w);
    } else {
        try w.writeAll("null");
    }
}

fn buildInitialize(id: ?std.json.Value, out: *std.Io.Writer.Allocating) !void {
    const w = &out.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(id, w);
    try w.print(
        ",\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"{s}\",\"version\":\"{s}\"}}}}}}",
        .{ MCP_VERSION, SERVER_NAME, SERVER_VERSION },
    );
}

const TOOLS_JSON =
    \\[
    \\  {
    \\    "name": "render_html",
    \\    "description": "Render an HTML string to a PNG image. Fast headless DOM render — returns a base64-encoded image.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "html":   {"type": "string", "description": "HTML content to render"},
    \\        "width":  {"type": "integer", "description": "Viewport width in pixels (default 800)"},
    \\        "format": {"type": "string", "enum": ["png","webp","jpeg"], "description": "Output image format (default png)"}
    \\      },
    \\      "required": ["html"]
    \\    }
    \\  },
    \\  {
    \\    "name": "render_markdown",
    \\    "description": "Render Markdown (GFM: tables, task lists, strikethrough) to a styled PNG image.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "markdown": {"type": "string", "description": "Markdown content to render"},
    \\        "width":    {"type": "integer", "description": "Viewport width in pixels (default 800)"},
    \\        "css":      {"type": "string", "description": "Optional additional CSS to inject"},
    \\        "format":   {"type": "string", "enum": ["png","webp","jpeg"], "description": "Output image format (default png)"}
    \\      },
    \\      "required": ["markdown"]
    \\    }
    \\  },
    \\  {
    \\    "name": "render_url",
    \\    "description": "Fetch a URL, execute its scripts, and render the page to a PNG image.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "url":    {"type": "string", "description": "HTTP or HTTPS URL to fetch and render"},
    \\        "width":  {"type": "integer", "description": "Viewport width in pixels (default 800)"},
    \\        "format": {"type": "string", "enum": ["png","webp","jpeg"], "description": "Output image format (default png)"}
    \\      },
    \\      "required": ["url"]
    \\    }
    \\  },
    \\  {
    \\    "name": "run_script",
    \\    "description": "Execute JavaScript in the headless DOM. Returns text/JSON, or a base64 image if the script returns an ArrayBuffer (e.g. from zxp.encode()). Has full access to the zxp API: zxp.paintDOM, zxp.encode, zxp.markdownToHTML, zxp.loadHTML, etc.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "script": {"type": "string", "description": "JavaScript code to execute"}
    \\      },
    \\      "required": ["script"]
    \\    }
    \\  }
    \\]
;

fn buildToolsList(id: ?std.json.Value, out: *std.Io.Writer.Allocating) !void {
    const w = &out.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(id, w);
    try w.writeAll(",\"result\":{\"tools\":");
    try w.writeAll(TOOLS_JSON);
    try w.writeAll("}}");
}

fn buildError(id: ?std.json.Value, code: i64, message: []const u8, out: *std.Io.Writer.Allocating) !void {
    const w = &out.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(id, w);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try std.json.Stringify.value(message, .{}, w);
    try w.writeAll("}}");
}

fn buildToolResult(id: ?std.json.Value, content_json: []const u8, out: *std.Io.Writer.Allocating) !void {
    const w = &out.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(id, w);
    try w.writeAll(",\"result\":{\"content\":");
    try w.writeAll(content_json);
    try w.writeAll("}}");
}

// ── Tool dispatch ─────────────────────────────────────────────────────────────

fn handleToolsCall(
    app_ctx: *AppContext,
    id: ?std.json.Value,
    params: std.json.Value,
    out: *std.Io.Writer.Allocating,
    aa: std.mem.Allocator,
    alloc: std.mem.Allocator,
) !void {
    const obj = switch (params) {
        .object => |o| o,
        else => {
            try buildError(id, -32602, "Invalid params: expected object", out);
            return;
        },
    };

    const name = switch (obj.get("name") orelse {
        try buildError(id, -32602, "Invalid params: missing name", out);
        return;
    }) {
        .string => |s| s,
        else => {
            try buildError(id, -32602, "Invalid params: name must be a string", out);
            return;
        },
    };

    const args: std.json.Value = obj.get("arguments") orelse .null;

    if (std.mem.eql(u8, name, "render_html")) {
        try toolRenderHtml(app_ctx, id, args, out, aa, alloc);
    } else if (std.mem.eql(u8, name, "render_markdown")) {
        try toolRenderMarkdown(app_ctx, id, args, out, aa, alloc);
    } else if (std.mem.eql(u8, name, "render_url")) {
        try toolRenderUrl(app_ctx, id, args, out, aa, alloc);
    } else if (std.mem.eql(u8, name, "run_script")) {
        try toolRunScript(app_ctx, id, args, out, aa, alloc);
    } else {
        try buildError(id, -32602, "Unknown tool", out);
    }
}

// ── Argument helpers ──────────────────────────────────────────────────────────

fn getStrArg(args: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = switch (args) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn getIntArg(args: std.json.Value, key: []const u8, default: u32) u32 {
    const obj = switch (args) {
        .object => |o| o,
        else => return default,
    };
    return switch (obj.get(key) orelse return default) {
        .integer => |i| @intCast(@max(0, i)),
        .float => |f| @intFromFloat(@max(0.0, f)),
        else => default,
    };
}

// ── Content JSON builders ─────────────────────────────────────────────────────

fn imageContent(bytes: []const u8, mime: []const u8, aa: std.mem.Allocator) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const b64_buf = try aa.alloc(u8, encoder.calcSize(bytes.len));
    const b64 = encoder.encode(b64_buf, bytes);

    var buf: std.Io.Writer.Allocating = .init(aa);
    const w = &buf.writer;
    try w.writeAll("[{\"type\":\"image\",\"data\":");
    try std.json.Stringify.value(b64, .{}, w);
    try w.print(",\"mimeType\":\"{s}\"}}]", .{mime});
    return buf.toOwnedSlice();
}

fn textContent(text: []const u8, aa: std.mem.Allocator) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(aa);
    const w = &buf.writer;
    try w.writeAll("[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, w);
    try w.writeAll("}]");
    return buf.toOwnedSlice();
}

fn sniffMime(bytes: []const u8) []const u8 {
    if (bytes.len >= 4) {
        if (std.mem.startsWith(u8, bytes, "\x89PNG")) return "image/png";
        if (std.mem.startsWith(u8, bytes, "\xFF\xD8")) return "image/jpeg";
        if (std.mem.startsWith(u8, bytes, "RIFF") and bytes.len >= 12 and
            std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    }
    return "application/octet-stream";
}

/// Paint document.body and encode as image bytes (allocated with `alloc`, caller frees).
fn evalPaint(engine: *z.ScriptEngine, width: u32, format: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    const js = try std.fmt.allocPrint(
        alloc,
        "zxp.encode(zxp.paintDOM(document.body, {d}), \"{s}\")",
        .{ width, format },
    );
    defer alloc.free(js);
    return engine.evalAsyncAs(alloc, []const u8, js, "<mcp>");
}

/// JSON-encode a Zig string as a JS string literal (adds quotes + escaping).
fn jsonEscape(aa: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(aa);
    try std.json.Stringify.value(s, .{}, &buf.writer);
    return buf.toOwnedSlice();
}

// ── render_html ───────────────────────────────────────────────────────────────

fn toolRenderHtml(
    app_ctx: *AppContext,
    id: ?std.json.Value,
    args: std.json.Value,
    out: *std.Io.Writer.Allocating,
    aa: std.mem.Allocator,
    alloc: std.mem.Allocator,
) !void {
    const html = getStrArg(args, "html") orelse {
        try buildError(id, -32602, "render_html: missing required argument 'html'", out);
        return;
    };
    const width = getIntArg(args, "width", 800);
    const format = getStrArg(args, "format") orelse "png";

    const zxp_rt = try zxp_runtime.getOrCreate(alloc, app_ctx.sandbox_root);
    var engine = try z.ScriptEngine.init(alloc, zxp_rt);
    defer engine.deinit();

    engine.loadHTML(html) catch |err| {
        const msg = try std.fmt.allocPrint(aa, "render_html: loadHTML failed: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };

    const bytes = evalPaint(engine, width, format, alloc) catch |err| {
        const msg = try std.fmt.allocPrint(aa, "render_html: paint failed: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };
    defer alloc.free(bytes);

    const content = try imageContent(bytes, sniffMime(bytes), aa);
    try buildToolResult(id, content, out);
}

// ── render_markdown ───────────────────────────────────────────────────────────

fn toolRenderMarkdown(
    app_ctx: *AppContext,
    id: ?std.json.Value,
    args: std.json.Value,
    out: *std.Io.Writer.Allocating,
    aa: std.mem.Allocator,
    alloc: std.mem.Allocator,
) !void {
    const markdown = getStrArg(args, "markdown") orelse {
        try buildError(id, -32602, "render_markdown: missing required argument 'markdown'", out);
        return;
    };
    const width = getIntArg(args, "width", 800);
    const format = getStrArg(args, "format") orelse "png";
    const css = getStrArg(args, "css") orelse "";

    const zxp_rt = try zxp_runtime.getOrCreate(alloc, app_ctx.sandbox_root);
    var engine = try z.ScriptEngine.init(alloc, zxp_rt);
    defer engine.deinit();

    // Convert MD → HTML via JS API, then wrap with styling and load into DOM.
    // jsonEscape produces a quoted JS string literal: "# Hello" → `"# Hello"`
    const esc_md = try jsonEscape(aa, markdown);
    const esc_css = try jsonEscape(aa, css);
    const load_js = try std.fmt.allocPrint(
        aa,
        "(function(){{" ++
            "var h=zxp.markdownToHTML({s});" ++
            "zxp.loadHTML('<html><head><style>" ++
            "body{{font-family:system-ui,sans-serif;padding:24px;max-width:860px;line-height:1.6;color:#1a1a1a}}' +{s}+" ++
            "'</style></head><body>'+h+'</body></html>');" ++
            "}})()",
        .{ esc_md, esc_css },
    );

    const setup_val = engine.evalAsync(load_js, "<mcp-md>") catch |err| {
        const msg = try std.fmt.allocPrint(aa, "render_markdown: setup failed: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };
    engine.ctx.freeValue(setup_val);

    const bytes = evalPaint(engine, width, format, alloc) catch |err| {
        const msg = try std.fmt.allocPrint(aa, "render_markdown: paint failed: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };
    defer alloc.free(bytes);

    const content = try imageContent(bytes, sniffMime(bytes), aa);
    try buildToolResult(id, content, out);
}

// ── render_url ────────────────────────────────────────────────────────────────

fn toolRenderUrl(
    app_ctx: *AppContext,
    id: ?std.json.Value,
    args: std.json.Value,
    out: *std.Io.Writer.Allocating,
    aa: std.mem.Allocator,
    alloc: std.mem.Allocator,
) !void {
    const url = getStrArg(args, "url") orelse {
        try buildError(id, -32602, "render_url: missing required argument 'url'", out);
        return;
    };
    const width = getIntArg(args, "width", 800);
    const format = getStrArg(args, "format") orelse "png";

    const zxp_rt = try zxp_runtime.getOrCreate(alloc, app_ctx.sandbox_root);
    var engine = try z.ScriptEngine.init(alloc, zxp_rt);
    defer engine.deinit();

    js_streamfrom.streamFromUrl(engine, url) catch |err| {
        const msg = try std.fmt.allocPrint(aa, "render_url: fetch failed: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };

    const bytes = evalPaint(engine, width, format, alloc) catch |err| {
        const msg = try std.fmt.allocPrint(aa, "render_url: paint failed: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };
    defer alloc.free(bytes);

    const content = try imageContent(bytes, sniffMime(bytes), aa);
    try buildToolResult(id, content, out);
}

// ── run_script ────────────────────────────────────────────────────────────────

fn toolRunScript(
    app_ctx: *AppContext,
    id: ?std.json.Value,
    args: std.json.Value,
    out: *std.Io.Writer.Allocating,
    aa: std.mem.Allocator,
    alloc: std.mem.Allocator,
) !void {
    const script = getStrArg(args, "script") orelse {
        try buildError(id, -32602, "run_script: missing required argument 'script'", out);
        return;
    };

    const zxp_rt = try zxp_runtime.getOrCreate(alloc, app_ctx.sandbox_root);
    var engine = try z.ScriptEngine.init(alloc, zxp_rt);
    defer engine.deinit();

    try engine.loadHTML("<html><head></head><body></body></html>");

    const val = engine.evalAsync(script, "<mcp-script>") catch |err| {
        const msg = try std.fmt.allocPrint(aa, "run_script: eval failed: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };
    defer engine.ctx.freeValue(val);

    engine.run() catch {};

    // ArrayBuffer → base64 image
    if (engine.ctx.isArrayBuffer(val)) {
        const bytes = engine.ctx.getArrayBuffer(val) catch {
            try buildError(id, -32603, "run_script: failed to read ArrayBuffer", out);
            return;
        };
        const content = try imageContent(bytes, sniffMime(bytes), aa);
        try buildToolResult(id, content, out);
        return;
    }

    // String, object/array → text content
    const text: []const u8 = blk: {
        if (engine.ctx.isUndefined(val) or engine.ctx.isNull(val)) break :blk "null";

        if (engine.ctx.isString(val)) {
            const s = engine.ctx.toZString(val) catch break :blk "(error reading string)";
            defer engine.ctx.freeZString(s);
            break :blk try aa.dupe(u8, s);
        }

        const json_val = engine.ctx.jsonStringifySimple(val) catch break :blk "{}";
        defer engine.ctx.freeValue(json_val);
        const json_str = engine.ctx.toZString(json_val) catch break :blk "{}";
        defer engine.ctx.freeZString(json_str);
        break :blk try aa.dupe(u8, json_str);
    };

    const content = try textContent(text, aa);
    try buildToolResult(id, content, out);
}
