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
const z = @import("root.zig");
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
    const alloc = app_ctx.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    res.header("Content-Type", "application/json");

    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error: empty request body\"}}";
        return;
    };

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
    } else if (std.mem.eql(u8, mcp_req.method, "resources/list")) {
        try buildResourcesList(mcp_req.id, &out);
    } else if (std.mem.eql(u8, mcp_req.method, "resources/read")) {
        const params = mcp_req.params orelse .null;
        try handleResourcesRead(mcp_req.id, params, &out);
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
        ",\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}},\"resources\":{{}}}},\"serverInfo\":{{\"name\":\"{s}\",\"version\":\"{s}\"}}}}}}",
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
    \\    "description": "Execute JavaScript in a headless DOM+JS engine (QuickJS, browser-like). Returns plain text/JSON, or a base64 image if the script returns an ArrayBuffer from zxp.encode().\n\nENVIRONMENT: Full DOM (document, querySelector, innerHTML, events), fetch(), URL, setTimeout, TextDecoder/Encoder.\n\nZXP API:\n  zxp.goto(url)                       - fetch URL with browser headers, parse HTML+CSS, run scripts\n  zxp.streamFrom(url)                 - streaming fetch into parser (better for large pages)\n  zxp.fetchAll(urlArray, hdrsArray)   - parallel fetch; returns [{ok,status,data,type}] — use for batch image replacement\n  zxp.loadHTML(html)                  - parse an HTML string into document\n  zxp.paintDOM(node, width)           - render DOM node to RGBA canvas {data,width,height}\n  zxp.paintElement(el, width)         - render a single element (cropped to its bbox)\n  zxp.encode(img, format)             - encode canvas to ArrayBuffer (png/webp/jpeg/pdf) — return this for an image response\n  zxp.arrayBufferToBase64DataUri(buf,mime) - convert ArrayBuffer to data URI string\n  zxp.markdownToHTML(md)              - Markdown to HTML (GFM: tables, strikethrough, tasks)\n  zxp.toMarkdown(element)             - DOM element to Markdown string (compact for LLM input)\n  zxp.llmHTML({model,prompt,...})     - call Ollama, stream HTML response, return as string\n  zxp.llmStream({model,prompt,...})   - stream LLM tokens directly into DOM\n  zxp.csv.parse(str)                  - CSV string to array of objects\n  zxp.csv.stringify(rows)             - array of objects to CSV string\n  zxp.fs.readFileSync(path)           - read file to ArrayBuffer\n  zxp.stdin.read()                    - read stdin as string (CLI only)\n\nSCRAPING:\n  await zxp.goto('https://news.ycombinator.com');\n  return Array.from(document.querySelectorAll('.titleline a')).map(a => a.textContent);\n\nSCRAPE + REPLACE IMAGES (render a live page with real images):\n  await zxp.goto('https://example.com');\n  const imgs = Array.from(document.querySelectorAll('img[src]'));\n  const urls = imgs.map(i => i.getAttribute('src')).filter(s => s.startsWith('http'));\n  const fetched = await zxp.fetchAll(urls, urls.map(() => ({})));\n  fetched.forEach((r,i) => { if (r.ok) imgs[i].setAttribute('src', zxp.arrayBufferToBase64DataUri(r.data, r.type)); });\n  return zxp.encode(zxp.paintDOM(document.body, 1200), 'png');\n\nCall get_zxp_docs before writing scripts to get worked examples and understand CSS rendering constraints.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "script": {"type": "string", "description": "JavaScript code to execute"}
    \\      },
    \\      "required": ["script"]
    \\    }
    \\  },
    \\  {
    \\    "name": "get_zxp_docs",
    \\    "description": "Return API documentation and worked code examples for the zxp JavaScript environment. Call this BEFORE writing a run_script to learn exact function signatures, which CSS properties the compositor supports, and copy-paste patterns for common tasks (scraping, image replacement, LLM rendering, CSV tables).",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "topic": {
    \\          "type": "string",
    \\          "enum": ["all", "examples", "api", "rendering", "scraping"],
    \\          "description": "Doc section to return (default: all). examples=worked code patterns; api=full function signatures; rendering=CSS constraints and layout tips; scraping=goto/fetchAll/toMarkdown patterns."
    \\        }
    \\      }
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

// ── Resources ─────────────────────────────────────────────────────────────────
//
// Resources expose documentation that Claude can read to understand the zxp API
// before writing a run_script call.  URIs follow the scheme zxp://docs/<topic>.

const RESOURCES_LIST_JSON =
    \\[
    \\  {"uri":"zxp://docs/examples","name":"zxp worked examples","description":"Concrete, copy-paste JS examples for common tasks: scraping, image replacement, rendering, CSV, LLM.","mimeType":"text/plain"},
    \\  {"uri":"zxp://docs/api","name":"zxp full API reference","description":"Complete zxp.* function signatures with parameter types and return values.","mimeType":"text/plain"},
    \\  {"uri":"zxp://docs/scraping","name":"Scraping guide","description":"How to use zxp.goto, zxp.fetchAll, and zxp.toMarkdown to extract content from live web pages.","mimeType":"text/plain"},
    \\  {"uri":"zxp://docs/rendering","name":"Rendering guide","description":"How to load HTML/Markdown, paint the DOM, and return images via zxp.encode.","mimeType":"text/plain"}
    \\]
;

const DOC_EXAMPLES =
    \\# zxp run_script — worked examples
    \\
    \\## 1. Scrape Hacker News top stories
    \\
    \\  async function run() {
    \\    await zxp.goto('https://news.ycombinator.com');
    \\    return Array.from(document.querySelectorAll('.titleline a'))
    \\      .slice(0, 10)
    \\      .map(a => ({ title: a.textContent, href: a.href }));
    \\  }
    \\  run();
    \\
    \\## 2. Scrape and render a live page with real images
    \\
    \\  async function run() {
    \\    await zxp.goto('https://demo.vercel.store');
    \\    // Replace all img src with data URIs so the compositor can paint them
    \\    const imgs = Array.from(document.querySelectorAll('img[src]'));
    \\    const urls = imgs.map(i => i.getAttribute('src')).filter(s => s.startsWith('http'));
    \\    const fetched = await zxp.fetchAll(urls, urls.map(() => ({})));
    \\    fetched.forEach((r, i) => {
    \\      if (r.ok) imgs[i].setAttribute('src', zxp.arrayBufferToBase64DataUri(r.data, r.type));
    \\    });
    \\    return zxp.encode(zxp.paintDOM(document.body, 1200), 'png');
    \\  }
    \\  run();
    \\
    \\## 3. Render custom HTML to PNG
    \\
    \\  zxp.loadHTML(`
    \\    <div style="padding:24px;font-family:system-ui;background:#f5f5f5">
    \\      <h1 style="color:#2563eb">Hello from zxp</h1>
    \\      <p>Rendered headlessly in Zig.</p>
    \\    </div>
    \\  `);
    \\  return zxp.encode(zxp.paintDOM(document.body, 600), 'png');
    \\
    \\## 4. Extract page content as Markdown (for LLM input)
    \\
    \\  async function run() {
    \\    await zxp.goto('https://example.com');
    \\    return zxp.toMarkdown(document.body);
    \\  }
    \\  run();
    \\
    \\## 5. Parse a CSV and render it as a table image
    \\
    \\  const csv = `Name,Score\nAlice,95\nBob,82\nCarol,91`;
    \\  const rows = zxp.csv.parse(csv);
    \\  const thead = rows[0] ? '<tr>' + Object.keys(rows[0]).map(k => `<th style="background:#2563eb;color:#fff;padding:8px 12px">${k}</th>`).join('') + '</tr>' : '';
    \\  const tbody = rows.map(r => '<tr>' + Object.values(r).map(v => `<td style="padding:8px 12px;border-bottom:1px solid #e5e7eb">${v}</td>`).join('') + '</tr>').join('');
    \\  zxp.loadHTML(`<table style="border-collapse:collapse;font-family:system-ui">${thead}${tbody}</table>`);
    \\  return zxp.encode(zxp.paintDOM(document.body, 600), 'png');
    \\
    \\## 6. Generate UI with a local LLM (Ollama)
    \\
    \\  async function run() {
    \\    const html = await zxp.llmHTML({
    \\      model: 'qwen2.5-coder:3b',
    \\      prompt: '3 KPI cards: Revenue $42k, Users 3.4k, MRR $8.2k. Clean white cards, blue accents.',
    \\      base_url: 'http://localhost:11434',
    \\    });
    \\    zxp.loadHTML(html);
    \\    return zxp.encode(zxp.paintDOM(document.body, 900), 'png');
    \\  }
    \\  run();
;

const DOC_API =
    \\# zxp API reference
    \\
    \\All functions are on the global `zxp` object.
    \\
    \\## Navigation / Loading
    \\  zxp.goto(url: string, opts?): Promise<void>
    \\    Fetch url with browser headers, parse HTML+CSS, execute inline scripts.
    \\    opts: { sanitize?: bool, execute_scripts?: bool }
    \\
    \\  zxp.streamFrom(url: string): void
    \\    Streaming fetch into lexbor parser. Better for large pages. Executes scripts.
    \\
    \\  zxp.loadHTML(html: string): void
    \\    Parse an HTML string into document (no network, no scripts).
    \\
    \\## Fetch
    \\  zxp.fetchAll(urls: string[], headers: object[]): Promise<{ok,status,data,type}[]>
    \\    Parallel fetch of multiple URLs. headers array must have same length as urls
    \\    (use urls.map(()=>({})) for no custom headers). data is ArrayBuffer.
    \\
    \\  zxp.arrayBufferToBase64DataUri(buf: ArrayBuffer, mime: string): string
    \\    Convert ArrayBuffer to "data:<mime>;base64,<b64>" string.
    \\
    \\## Rendering
    \\  zxp.paintDOM(node: Element, width: number): {data: ArrayBuffer, width, height}
    \\    Render DOM node with Yoga layout + ThorVG. Returns RGBA canvas object.
    \\
    \\  zxp.paintElement(el: Element, width: number): {data: ArrayBuffer, width, height}
    \\    Render a single element (crops to its bounding box).
    \\
    \\  zxp.encode(img: {data,width,height}, format: string): ArrayBuffer
    \\    Encode RGBA canvas to compressed bytes. format: "png" | "webp" | "jpeg" | "pdf"
    \\    Returning this ArrayBuffer from run_script sends it as a base64 image in MCP.
    \\
    \\  zxp.save(img, path: string): void
    \\    Encode and write to disk. Extension determines format (.png .jpg .webp .pdf).
    \\
    \\## Text / Markdown
    \\  zxp.markdownToHTML(md: string): string   — Markdown → HTML (md4c, GFM)
    \\  zxp.toMarkdown(element: Element): string — DOM element → Markdown (compact)
    \\
    \\## LLM (requires local Ollama)
    \\  zxp.llmHTML(config): Promise<string>
    \\    config: { model, prompt, system?, base_url?, provider? }
    \\    Calls Ollama /api/chat, streams HTML tokens, returns full HTML string.
    \\
    \\  zxp.llmStream(config): void
    \\    Like llmHTML but streams tokens directly into the lexbor DOM parser.
    \\    Lower memory, single parse pass. DOM is ready after this returns.
    \\
    \\## CSV
    \\  zxp.csv.parse(csv: string): object[]     — CSV string → array of objects (headers = keys)
    \\  zxp.csv.stringify(rows: object[]): string — array of objects → CSV string
    \\
    \\## File I/O
    \\  zxp.fs.readFileSync(path: string): ArrayBuffer
    \\  zxp.fs.writeFileSync(path: string, buf: ArrayBuffer): void
    \\  zxp.stdin.read(): string    — piped stdin as UTF-8 text (CLI only)
    \\  zxp.stdin.readBytes(): ArrayBuffer
;

const DOC_SCRAPING =
    \\# Scraping guide
    \\
    \\Use zxp.goto() for single-page scraping:
    \\
    \\  await zxp.goto('https://example.com');
    \\  const links = Array.from(document.querySelectorAll('a[href]'))
    \\    .map(a => ({ text: a.textContent.trim(), href: a.getAttribute('href') }));
    \\  return links;
    \\
    \\For just the text content (compact for LLMs):
    \\
    \\  await zxp.goto('https://example.com');
    \\  return zxp.toMarkdown(document.body);
    \\
    \\To replace images so the compositor can paint them:
    \\
    \\  await zxp.goto('https://example.com');
    \\  const imgs = Array.from(document.querySelectorAll('img[src]'));
    \\  const srcs = imgs.map(i => i.getAttribute('src')).filter(s => s.startsWith('http'));
    \\  const fetched = await zxp.fetchAll(srcs, srcs.map(() => ({})));
    \\  fetched.forEach((r, i) => {
    \\    if (r.ok) imgs[i].setAttribute('src', zxp.arrayBufferToBase64DataUri(r.data, r.type));
    \\  });
    \\  return zxp.encode(zxp.paintDOM(document.body, 1200), 'png');
    \\
    \\ThorVG (the compositor) only supports PNG and JPEG images — WebP and SVG via data URIs work too.
    \\Never leave img[src] pointing at http:// URLs; the compositor cannot fetch them.
    \\Always replace with data URIs before calling paintDOM.
;

const DOC_RENDERING =
    \\# Rendering guide
    \\
    \\## HTML string → PNG
    \\  zxp.loadHTML('<h1 style="color:blue">Hello</h1>');
    \\  return zxp.encode(zxp.paintDOM(document.body, 800), 'png');
    \\
    \\## Markdown → PNG
    \\  const html = zxp.markdownToHTML('# Hello\n\n- item 1\n- item 2');
    \\  zxp.loadHTML('<html><body style="padding:24px;font-family:system-ui">' + html + '</body></html>');
    \\  return zxp.encode(zxp.paintDOM(document.body, 800), 'png');
    \\
    \\## Supported CSS (inline styles only for best results)
    \\  display: flex, block, inline, none
    \\  flex-direction, justify-content, align-items, flex-wrap, gap
    \\  padding, margin (shorthand ok: "8px 16px")
    \\  width, height (px or %)
    \\  color, background, background-color
    \\  font-size, font-weight, font-family
    \\  border-radius, border
    \\  box-shadow (simple values)
    \\  text-align, white-space, overflow
    \\  grid-template-columns: repeat(N, 1fr) — supported via flex shim
    \\
    \\## Tips
    \\  - Use width in pixels for reliable layout (not 100% at top level)
    \\  - External fonts are not loaded — system-ui, monospace, serif, sans-serif work
    \\  - <link rel=stylesheet> from http:// URLs are not fetched; embed <style> tags instead
    \\  - Return zxp.encode(..., 'png') from the script for an image MCP response
;

fn buildResourcesList(id: ?std.json.Value, out: *std.Io.Writer.Allocating) !void {
    const w = &out.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(id, w);
    try w.writeAll(",\"result\":{\"resources\":");
    try w.writeAll(RESOURCES_LIST_JSON);
    try w.writeAll("}}");
}

fn handleResourcesRead(id: ?std.json.Value, params: std.json.Value, out: *std.Io.Writer.Allocating) !void {
    const uri: []const u8 = switch (params) {
        .object => |o| switch (o.get("uri") orelse return buildError(id, -32602, "resources/read: missing uri", out)) {
            .string => |s| s,
            else => return buildError(id, -32602, "resources/read: uri must be a string", out),
        },
        else => return buildError(id, -32602, "resources/read: params must be an object", out),
    };

    const text: []const u8 =
        if (std.mem.eql(u8, uri, "zxp://docs/examples")) DOC_EXAMPLES else if (std.mem.eql(u8, uri, "zxp://docs/api")) DOC_API else if (std.mem.eql(u8, uri, "zxp://docs/scraping")) DOC_SCRAPING else if (std.mem.eql(u8, uri, "zxp://docs/rendering")) DOC_RENDERING else return buildError(id, -32002, "Resource not found", out);

    const w = &out.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(id, w);
    try w.writeAll(",\"result\":{\"contents\":[{\"uri\":");
    try std.json.Stringify.value(uri, .{}, w);
    try w.writeAll(",\"mimeType\":\"text/plain\",\"text\":");
    try std.json.Stringify.value(text, .{}, w);
    try w.writeAll("}]}}");
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
    } else if (std.mem.eql(u8, name, "get_zxp_docs")) {
        try toolGetZxpDocs(id, args, out, aa);
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

// ── get_zxp_docs ──────────────────────────────────────────────────────────────

fn toolGetZxpDocs(
    id: ?std.json.Value,
    args: std.json.Value,
    out: *std.Io.Writer.Allocating,
    aa: std.mem.Allocator,
) !void {
    const topic = getStrArg(args, "topic") orelse "all";

    const text: []const u8 = if (std.mem.eql(u8, topic, "examples"))
        DOC_EXAMPLES
    else if (std.mem.eql(u8, topic, "api"))
        DOC_API
    else if (std.mem.eql(u8, topic, "rendering"))
        DOC_RENDERING
    else if (std.mem.eql(u8, topic, "scraping"))
        DOC_SCRAPING
    else blk: {
        // "all" — concatenate every section
        break :blk try std.fmt.allocPrint(aa, "{s}\n\n{s}\n\n{s}\n\n{s}", .{
            DOC_EXAMPLES, DOC_API, DOC_RENDERING, DOC_SCRAPING,
        });
    };

    const content = try textContent(text, aa);
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

    if (engine.ctx.isException(val)) {
        const ex = engine.ctx.getException();
        defer engine.ctx.freeValue(ex);

        if (engine.ctx.toZString(ex)) |err_str| {
            defer engine.ctx.freeZString(err_str);
            const msg = try std.fmt.allocPrint(aa, "JavaScript Error:\n{s}", .{err_str});
            const content = try textContent(msg, aa);
            try buildToolResult(id, content, out);
        } else |_| {
            try buildError(id, -32603, "run_script: Unknown JavaScript exception", out);
        }
        return;
    }

    engine.run() catch |err| {
        std.debug.print("❌ [MCP run_script event loop error]: {}\n", .{err});
    };

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
