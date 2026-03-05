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
const js_store = z.js_store;
const AppContext = z.serve.AppContext;

// ── Crash protection (css_shim.c) ────────────────────────────────────────────
// Install a SIGSEGV handler that catches crashes in native C code (Lexbor /
// QuickJS) and allows the server to return an error instead of dying.

extern "c" fn zexp_crash_protect_install() void;

const ZexpProtectedFn = *const fn (ctx: ?*anyopaque) callconv(.c) void;
extern "c" fn zexp_crash_protect_run(fn_ptr: ZexpProtectedFn, user_ctx: ?*anyopaque) c_int;

const MCP_VERSION = "2025-11-25";
const SERVER_NAME = "zexplorer";
const SERVER_VERSION = "0.1.0";

// Default stylesheet injected into render_html and render_markdown.
// GFM-compatible subset: em→px converted, pseudo-selectors stripped, table→flex shim.
const GFM_CSS =
    \\body{font-family:-apple-system,BlinkMacSystemFont,Helvetica,Arial,sans-serif;font-size:16px;line-height:1.5;color:#24292e;padding:24px;max-width:860px}
    \\h1{font-size:32px;font-weight:600;margin:24px 0 16px}
    \\h2{font-size:24px;font-weight:600;margin:24px 0 16px}
    \\h3{font-size:20px;font-weight:600;margin:24px 0 16px}
    \\h4{font-size:16px;font-weight:600;margin:24px 0 16px}
    \\h5{font-size:14px;font-weight:600;margin:24px 0 16px}
    \\h6{font-size:13px;font-weight:600;color:#6a737d;margin:24px 0 16px}
    \\p{margin:0 0 16px}
    \\ol,ul{padding-left:32px;margin:0 0 16px}
    \\li{margin-top:4px}
    \\blockquote{padding:0 16px;color:#6a737d;border-left:4px solid #dfe2e5;margin:0 0 16px}
    \\code{font-size:13px;background-color:#f0f0f0;padding:3px 6px}
    \\pre{font-size:13px;padding:16px;background-color:#f6f8fa;margin-bottom:16px}
    \\hr{height:4px;margin:24px 0;background-color:#e1e4e8}
    \\table{display:flex;flex-direction:column;width:100%;margin-bottom:16px}
    \\thead,tbody{display:flex;flex-direction:column;width:100%}
    \\tr{display:flex;flex-direction:row;width:100%}
    \\th,td{flex:1;padding:6px 13px;border:1px solid #dfe2e5}
    \\th{font-weight:600;background-color:#f6f8fa}
;

// ── JSON-RPC 2.0 request ──────────────────────────────────────────────────────

const McpRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?std.json.Value = null,
    method: []const u8,
    params: ?std.json.Value = null,
};

// ── Entry point ───────────────────────────────────────────────────────────────

// GET /mcp — mcp-remote (Streamable HTTP 2025-03-26) opens a GET SSE channel
// for server-initiated events. We don't push events; return 405 so the client
// falls back to pure request-response mode without waiting for a stream.
pub fn mcpGetHandler(_: *AppContext, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 405;
    res.header("Allow", "POST, OPTIONS");
    res.header("Content-Type", "application/json");
    res.body = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Server-sent events not supported; use POST\"}}";
}

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
    \\    "description": "Render a high fidelity self-contained HTML string to a PNG image. Use this to visually inspect generated UIs or charts, static HTML with inline styles/SVG only.\n\n STRICT GUIDELINES: The rendering engine supports standard HTML, CSS Flexbox, and inline SVG. It does NOT support CSS Grid 2D, CSS variables, or complex external CSS functions. Keep layouts simple, absolute, or Flexbox-based.\n\n⚠️  EXTERNAL SCRIPTS DON'T WORK: <script src=\"https://...\"> CDN links are NOT fetched — external libraries (ECharts, D3, Chart.js, etc.) will not load, leaving charts blank. For charts/visualisations that require external JS libraries, use run_script with zxp.importScript() instead (see worked examples 7 and 10 in get_zxp_docs).\n\nBEST FOR: static layouts, tables, markdown-rendered HTML, inline SVG, custom cards — anything that doesn't need external JS libraries.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "html":   {"type": "string", "description": "Self-contained HTML (no external <script src> CDN links — those are not fetched). Use inline styles and inline SVG."},
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
    \\    "description": "Execute JavaScript in a headless DOM+JS engine (QuickJS). Returns plain text/JSON, or an inline image if the script returns an ArrayBuffer from zxp.encode().\n\nUSE zxp WHEN: fetching remote resources (avatars, pages) + rendering them as an image in one call; rendering HTML/CSS templates (invoices, cards, OG images); scraping pages; tasks that need no Python dependencies.\nUSE PYTHON INSTEAD FOR: pure data visualisation from known data (bar charts, line charts, pie charts) — matplotlib is simpler and better-tested for that. zxp is not a charting library.\nSTRUCTURED DATA (JSON/CSV → image): use loadHTML + paintDOM, NOT hand-crafted SVG. A <table> or two-column <div style='display:flex'> with inline styles renders correctly and is far easier to write than SVG. See example 5.\n\n⚠️  TOP-LEVEL await/return NOT allowed: never write 'await' or 'return' at the top level of the script. Always wrap async code and return values inside an async function: async function run() { await ...; return ...; } run()\n\nENVIRONMENT: Full DOM (document, querySelector, innerHTML, events), fetch(), URL, setTimeout, TextDecoder/Encoder.\n\n⚠️  SCRAPING PUBLIC SITES (Wikipedia, news portals, etc.): ALWAYS pass { execute_scripts: false, load_stylesheets: false } to goto() — complex JS frameworks (jQuery, MediaWiki) will crash the engine otherwise.\n\nZXP API:\n  zxp.goto(url, opts?)                - fetch URL, parse HTML. opts: { execute_scripts: false, load_stylesheets: false } (REQUIRED for public sites)\n  zxp.waitForSelector(sel, ms?)       - poll until selector appears in DOM (default 5000ms); use after goto() on SPAs to wait for async render\n  zxp.streamFrom(url)                 - streaming fetch into parser (better for large pages)\n  zxp.fetchAll(urlArray, hdrsArray)   - parallel fetch; returns [{ok,status,data,type}]\n  zxp.loadHTML(html)                  - parse an HTML string into document\n  zxp.paintDOM(node, width)           - render DOM node to RGBA canvas {data,width,height}\n  zxp.paintElement(el, width)         - render a single element (cropped to its bbox)\n  zxp.paintSVG(svg, opts?)            - rasterize SVG string via ThorVG → {data,width,height}; opts: {width,height} for exact output size (default: longest side ≥ 800px)\n  zxp.measureText(text, fontSize)     - measure Roboto text in pixels → {width,height}; use for SVG word-wrap before paintSVG\n  zxp.encode(img, format)             - encode canvas to ArrayBuffer (png/webp/jpeg/pdf) — return this for an image response\n  zxp.arrayBufferToBase64DataUri(buf,mime) - convert ArrayBuffer to data URI string\n  zxp.markdownToHTML(md)              - Markdown to HTML (GFM: tables, strikethrough, tasks)\n  zxp.toMarkdown(element)             - DOM element to Markdown string (compact for LLM input)\n  zxp.llmHTML({model,prompt,...})     - call Ollama, stream HTML response, return as string\n  zxp.llmStream({model,prompt,...})   - stream LLM tokens directly into DOM\n  zxp.csv.parse(str)                  - CSV string to array of objects\n  zxp.csv.stringify(rows)             - array of objects to CSV string\n  zxp.fs.readFileSync(path)           - read file to ArrayBuffer\n  zxp.fs.writeFileSync(path, data)    - write string/ArrayBuffer to file. ALWAYS use a RELATIVE path (e.g. 'output.png') — it resolves to the server's working directory. Absolute paths like /mnt/... refer to the SERVER machine's filesystem, NOT the Claude Desktop sandbox, and will fail with FileNotFound.\n  zxp.fs.cwd()                        - return the server's working directory as a string (tell user where saved files landed)\n  zxp.stdin.read()                    - read stdin as string (CLI only)\n  zxp.store.save(name, data, opts?)   - persist text/ArrayBuffer to SQLite; opts: {mime,note}\n  zxp.store.get(name)                 - retrieve entry → {name,mime,note,hash,data:ArrayBuffer}\n  zxp.store.list()                    - list all entries (metadata only)\n  zxp.store.delete(name)              - delete entry by name\n\n⚠️  SAVE TO DISK: zxp is a LOCAL server running on the user's own machine. writeFileSync with a relative path saves directly to the user's local filesystem — this IS the final delivery step. Do NOT attempt any store/base64/Python pipeline after a successful writeFileSync; the file is already on the user's disk. NEVER use /mnt/... absolute paths — those are Claude Desktop's own sandbox, not the user's machine.\n  async function run() {\n    // ... build pngBuf ...\n    zxp.fs.writeFileSync('wiki_consoles.png', pngBuf);  // file is NOW on the user's local disk\n    return { image: pngBuf, path: zxp.fs.cwd() + '/wiki_consoles.png' };  // tell user exact path\n  }\n  run()\n\nSCRAPING PUBLIC SITES (Wikipedia, news, etc.) — scripts/css OFF by default:\n  async function run() {\n    await zxp.goto('https://en.wikipedia.org/wiki/...', { execute_scripts: false, load_stylesheets: false });\n    return Array.from(document.querySelectorAll('table.wikitable tbody tr'))\n      .map(r => Array.from(r.querySelectorAll('th,td')).map(c => c.textContent.trim()));\n  }\n  run()\n\nSCRAPE + REPLACE IMAGES:\n  async function run() {\n    await zxp.goto('https://example.com', { execute_scripts: false, load_stylesheets: false });\n    const imgs = Array.from(document.querySelectorAll('img[src]'));\n    const urls = imgs.map(i => i.getAttribute('src')).filter(s => s.startsWith('http'));\n    const fetched = await zxp.fetchAll(urls, urls.map(() => ({})));\n    fetched.forEach((r,i) => { if (r.ok) imgs[i].setAttribute('src', zxp.arrayBufferToBase64DataUri(r.data, r.type)); });\n    return zxp.encode(zxp.paintDOM(document.body, 1200), 'png');\n  }\n  run()\n\nCall get_zxp_docs before writing scripts to get worked examples and understand CSS rendering constraints.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "script": {"type": "string", "description": "JavaScript code to execute. Do NOT use top-level 'await' or 'return' — wrap async/return code in an async function: async function run() { await ...; return ...; } run()"}
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
    \\  },
    \\  {
    \\    "name": "store_save",
    \\    "description": "Save a binary blob or text string to the persistent store (SQLite). Use this to persist intermediate render results across tool calls so you can reference them later without re-computing. Upserts by name (replaces if name already exists).",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "name":  {"type": "string",  "description": "Unique key to store the value under"},
    \\        "value": {"type": "string",  "description": "Text or base64-encoded binary content to store"},
    \\        "mime":  {"type": "string",  "description": "MIME type hint (e.g. image/png, text/plain)"},
    \\        "note":  {"type": "string",  "description": "Optional human-readable description"}
    \\      },
    \\      "required": ["name", "value"]
    \\    }
    \\  },
    \\  {
    \\    "name": "store_get",
    \\    "description": "Retrieve a previously saved value from the persistent store by name. Returns the value as text or as a base64-encoded image if the mime type is an image type.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "name": {"type": "string", "description": "Key to retrieve"}
    \\      },
    \\      "required": ["name"]
    \\    }
    \\  },
    \\  {
    \\    "name": "store_list",
    \\    "description": "List all entries in the persistent store (name, mime, note, hash, created_at). Does not return data blobs — use store_get to retrieve a specific entry.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {}
    \\    }
    \\  },
    \\  {
    \\    "name": "store_delete",
    \\    "description": "Delete an entry from the persistent store by name. Returns true if the entry existed and was deleted.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "name": {"type": "string", "description": "Key to delete"}
    \\      },
    \\      "required": ["name"]
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
    \\  zxp.encode(zxp.paintDOM(document.body, 600), 'png')
    \\
    \\## 4. Extract page content as Markdown (for LLM input)
    \\
    \\  async function run() {
    \\    await zxp.goto('https://example.com');
    \\    return zxp.toMarkdown(document.body);
    \\  }
    \\  run();
    \\
    \\## 5. Structured data → image (JSON / CSV / two-column layout)
    \\
    \\  // RULE: for tables and structured layouts, use loadHTML + paintDOM, NOT hand-crafted SVG.
    \\  // A plain HTML <table> or flex <div> with inline styles is simpler and more reliable.
    \\
    \\  // 5a. JSON array → table image
    \\  const data = [
    \\    { name: 'Alice', score: 95, grade: 'A' },
    \\    { name: 'Bob',   score: 82, grade: 'B' },
    \\    { name: 'Carol', score: 91, grade: 'A' },
    \\  ];
    \\  const cols = Object.keys(data[0]);
    \\  const thead = '<tr>' + cols.map(c => `<th style="background:#2563eb;color:#fff;padding:8px 16px;text-align:left">${c}</th>`).join('') + '</tr>';
    \\  const tbody = data.map(r => '<tr>' + cols.map(c => `<td style="padding:8px 16px;border-bottom:1px solid #e5e7eb">${r[c]}</td>`).join('') + '</tr>').join('');
    \\  zxp.loadHTML(`<div style="padding:24px;font-family:system-ui;font-size:15px"><table style="border-collapse:collapse">${thead}${tbody}</table></div>`);
    \\  zxp.encode(zxp.paintDOM(document.body, 600), 'png')
    \\
    \\  // 5b. Two-column layout from JSON
    \\  const info = { Name: 'Alice', Role: 'Engineer', Score: 95, Status: 'Active' };
    \\  const left  = Object.keys(info).slice(0, 2);
    \\  const right = Object.keys(info).slice(2);
    \\  const col = (keys) => keys.map(k =>
    \\    `<div style="margin-bottom:12px"><div style="color:#6b7280;font-size:12px">${k}</div>
    \\     <div style="font-size:18px;font-weight:600">${info[k]}</div></div>`).join('');
    \\  zxp.loadHTML(`<div style="display:flex;gap:40px;padding:32px;font-family:system-ui;background:#fff">
    \\    <div style="flex:1">${col(left)}</div>
    \\    <div style="flex:1">${col(right)}</div>
    \\  </div>`);
    \\  zxp.encode(zxp.paintDOM(document.body, 600), 'png')
    \\
    \\  // 5c. CSV → table (same pattern, just parse first)
    \\  const csv = `Name,Score\nAlice,95\nBob,82`;
    \\  const rows = zxp.csv.parse(csv);
    \\  // then build thead/tbody as in 5a
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
    \\
    \\## 7. D3 bar chart from CSV data (via zxp.importScript)
    \\
    \\  async function run() {
    \\    const resp = await fetch('https://raw.githubusercontent.com/datasets/gdp/master/data/gdp.csv');
    \\    const rows = zxp.csv.parse(await resp.text())
    \\      .filter(r => r['Country Code'] === 'FRA' && r['Year'] > 2000)
    \\      .map(r => ({ year: r['Year'], gdp: r['Value'] }));
    \\
    \\    zxp.loadHTML('<html><body><div id="chart" style="width:800px;height:600px"></div></body></html>');
    \\    await zxp.importScript('https://d3js.org/d3.v7.min.js');
    \\
    \\    const margin = { top: 40, right: 40, bottom: 60, left: 100 };
    \\    const W = 800, H = 600;
    \\    const iW = W - margin.left - margin.right, iH = H - margin.top - margin.bottom;
    \\    const svg = d3.select('#chart').append('svg')
    \\      .attr('width', W).attr('height', H).attr('xmlns', 'http://www.w3.org/2000/svg')
    \\      .append('g').attr('transform', `translate(${margin.left},${margin.top})`);
    \\    const xScale = d3.scaleBand().domain(rows.map(d => d.year)).range([0, iW]).padding(0.1);
    \\    const yScale = d3.scaleLinear().domain([0, d3.max(rows, d => d.gdp)]).range([iH, 0]);
    \\    svg.append('g').attr('transform', `translate(0,${iH})`).call(d3.axisBottom(xScale));
    \\    svg.append('g').call(d3.axisLeft(yScale).ticks(10, 's'));
    \\    svg.selectAll('rect').data(rows).join('rect')
    \\      .attr('x', d => xScale(d.year)).attr('y', d => yScale(d.gdp))
    \\      .attr('width', xScale.bandwidth()).attr('height', d => iH - yScale(d.gdp))
    \\      .attr('fill', '#3b82f6');
    \\    svg.append('text').attr('x', iW/2).attr('y', -10).attr('text-anchor', 'middle')
    \\      .attr('font-size', '18px').attr('font-weight', 'bold').text('GDP of FRA Over Time');
    \\
    \\    return zxp.encode(zxp.paintElement(document.querySelector('#chart'), { width: 800 }), 'png');
    \\  }
    \\  run();
    \\
    \\  // D3 GOTCHAS (confirmed in zxp):
    \\  // 1. &amp; entity — ThorVG does NOT decode XML entities. It renders &amp; as the literal
    \\  //    string "&amp;". XMLSerializer always encodes & as &amp;. Fix (MUST use raw &):
    \\  //      svgStr = svgStr.replace(/&amp;/g, '&');   // raw & — ThorVG handles it fine
    \\  //    Or build SVG as a JS template string to avoid XMLSerializer entirely.
    \\  //    NOTE: replacing back to &amp; (valid XML) does NOT help — ThorVG still shows it literally.
    \\  // 2. d3.interpolateRgbBasis (and D3 color interpolators) crash QuickJS with:
    \\  //      "TypeError: cannot read property 'name' of undefined"
    \\  //    Fix: use a plain hex color array and index by position, e.g.:
    \\  //      const COLORS = ['#7b2fff','#a855f7','#ec4899','#f97316','#eab308'];
    \\  //      const fill = COLORS[Math.floor(i / data.length * COLORS.length)];
    \\  //    d3.scaleBand(), d3.scaleLinear(), d3.axisBottom/Left all work fine.
    \\  // 3. goto() then loadHTML() in the same script loses D3 — always importScript AFTER loadHTML.
    \\
    \\## 8. Leaflet map with GeoJSON route overlay (via zxp.importScript)
    \\
    \\  async function run() {
    \\    zxp.loadHTML('<html><body><div id="map" style="width:800px;height:600px"></div></body></html>');
    \\    await zxp.importScript('https://unpkg.com/leaflet@1.9.4/dist/leaflet.js');
    \\
    \\    const map = L.map('map', { zoomControl: false, attributionControl: false })
    \\      .setView([51.505, -0.09], 13);
    \\    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png').addTo(map);
    \\    L.geoJSON({ type: 'LineString', coordinates: [[-0.15,51.505],[-0.12,51.51],[-0.076,51.508]] },
    \\      { style: { color: 'red', weight: 6 } }).addTo(map);
    \\
    \\    // Extract tile positions + SVG overlay, fetch tile buffers, composite to PNG
    \\    const tiles = Array.from(document.querySelectorAll('img.leaflet-tile'))
    \\      .map(img => ({ url: img.src, x: parseInt(img.style.left||0,10), y: parseInt(img.style.top||0,10) }));
    \\    const svgString = document.querySelector('.leaflet-overlay-pane svg')?.outerHTML || '';
    \\    const readyTiles = [];
    \\    for (const t of tiles) {
    \\      try { readyTiles.push({ buffer: await (await fetch(t.url)).arrayBuffer(), x: t.x, y: t.y }); }
    \\      catch(_) {}
    \\    }
    \\    // NOTE: generateRoutePng writes to disk and returns undefined — no image content in MCP response
    \\    zxp.generateRoutePng(readyTiles, svgString, 'london_route.png');
    \\    return 'Wrote london_route.png';
    \\  }
    \\  run();
    \\
    \\## 9. Mermaid.js — NOT SUPPORTED
    \\
    \\  // Mermaid cannot be rendered correctly by zexplorer.
    \\  //
    \\  // Root cause: Mermaid calls getBBox() on the root SVG group to compute the
    \\  // viewBox. zexplorer has no geometry engine at JS runtime, so getBBox() always
    \\  // returns {x:0, y:0, width:0, height:0}. The resulting viewBox is near-zero
    \\  // and ThorVG produces a blank or near-blank image.
    \\  //
    \\  // Post-processing the SVG to fix the viewBox is not viable: node sizes depend
    \\  // on rendered text metrics, and shapes vary by diagram type (flowchart, sequence,
    \\  // ER…). There is no general solution without a full SVG geometry engine during
    \\  // JS execution.
    \\  //
    \\  // Alternative: use ECharts (example 10) or hand-crafted SVG for diagrams.
    \\
    \\## 10. ECharts line chart → PNG (SVG renderer recommended)
    \\
    \\  // ECharts has two renderers: 'svg' and 'canvas'.
    \\  // Use SVG: ThorVG rasterizes the output perfectly (no browser geometry engine needed).
    \\  // Canvas works (querySelector now returns the native Canvas via node_cache fix),
    \\  // but stroke() artifacts appear on open paths (e.g. axis ticks get triangle fills).
    \\
    \\  async function run() {
    \\    window.requestAnimationFrame = cb => setTimeout(cb, 0);
    \\    zxp.loadHTML('<!DOCTYPE html><html><body><div id="chart" style="width:800px;height:600px;"></div></body></html>');
    \\    await zxp.importScript('https://cdn.jsdelivr.net/npm/echarts@5.5.0/dist/echarts.min.js');
    \\
    \\    const chart = echarts.init(document.getElementById('chart'), null, { renderer: 'svg', animation: false });
    \\    chart.setOption({
    \\      animation: false,
    \\      title: { text: 'Monthly Sales' },
    \\      xAxis: { type: 'category', data: ['Jan','Feb','Mar','Apr','May','Jun'] },
    \\      yAxis: { type: 'value' },
    \\      series: [{ type: 'line', data: [820, 932, 901, 934, 1290, 1330] }]
    \\    });
    \\
    \\    const svgStr = new XMLSerializer().serializeToString(document.querySelector('#chart svg'));
    \\    return zxp.encode(zxp.paintSVG(svgStr), 'png');
    \\  }
    \\  run();
    \\
    \\## 11. Persist and retrieve results across tool calls (zxp.store)
    \\
    \\  // Save a rendered PNG for later reference — last expression is the result
    \\  zxp.loadHTML('<h1 style="color:#2563eb;font-size:48px">Report v1</h1>');
    \\  const img = zxp.encode(zxp.paintDOM(document.body, 600), 'png');
    \\  zxp.store.save('report_v1', img, { mime: 'image/png', note: 'first draft' });
    \\  ({ saved: true })
    \\
    \\  // — in a later tool call, retrieve and decode it —
    \\  const entry = zxp.store.get('report_v1');
    \\  // entry.data is an ArrayBuffer — last expression sends it as image in MCP
    \\  zxp.encode(zxp.paintSVG(entry.data), 'png') // or just: entry.data
    \\
    \\  // List what is stored — last expression value is returned
    \\  zxp.store.list()   // [{name, mime, note, hash, created_at}, ...]
    \\
    \\  // Clean up
    \\  zxp.store.delete('report_v1');
    \\
    \\  // Save scraped markdown so the next call can use it without re-fetching
    \\  async function run() {
    \\    await zxp.goto('https://example.com');
    \\    const md = zxp.toMarkdown(document.body);
    \\    zxp.store.save('example_md', md, { mime: 'text/markdown' });
    \\    return md;
    \\  }
    \\  run()
    \\
    \\  // — next call — no async needed, store.get is sync
    \\  const entry = zxp.store.get('example_md');
    \\  new TextDecoder().decode(entry.data)  // last expression = returned string
    \\
    \\## 12. Save a rendered image to disk (writeFileSync)
    \\
    \\  // zxp is a LOCAL server on the user's machine. writeFileSync with a relative path
    \\  // saves the file directly to the user's local disk — this IS the final step.
    \\  // After writeFileSync returns successfully, the task is done. No store/base64/Python needed.
    \\  //
    \\  // DO NOT use /mnt/user-data/outputs/... — that is Claude Desktop's sandbox, not the user's machine.
    \\  // Use a plain filename: it saves to the cwd where 'zxp serve' was launched (the user's project folder).
    \\  async function run() {
    \\    // ... build pngBuf via zxp.encode / zxp.paintSVG / etc. ...
    \\    zxp.fs.writeFileSync('wiki_consoles.png', pngBuf);  // file is on the user's local disk — DONE
    \\    return pngBuf;   // also return so Claude sees the image inline
    \\  }
    \\  run()
    \\
    \\## 13. OG image — fetch remote avatar, embed in SVG template, rasterize to PNG
    \\
    \\  // This is zexplorer's unique strength: fetch a remote image, embed as base64 data URI,
    \\  // composite it into an SVG template (with circular clip), and rasterize — all in one call.
    \\  // Python equivalent needs requests + PIL + cairosvg; cairosvg alone can't do SVG <image> embed + clip.
    \\  async function run() {
    \\    // 1. Fetch avatar from any URL
    \\    const avatarRes = await fetch('https://github.com/torvalds.png');
    \\    const avatarBuf = await avatarRes.arrayBuffer();
    \\    const mime = avatarRes.headers.get('content-type') || 'image/jpeg';
    \\    const avatarUri = zxp.arrayBufferToBase64DataUri(avatarBuf, mime);
    \\
    \\    // 2. Build SVG template inline (or load from file with zxp.fs.readFileSync)
    \\    const title = 'Headless Browser in Zig';
    \\    const author = 'N. Drean';
    \\    const svg = `<svg width="1200" height="630" viewBox="0 0 1200 630" xmlns="http://www.w3.org/2000/svg">
    \\      <defs><clipPath id="av"><circle cx="175" cy="175" r="75"/></clipPath></defs>
    \\      <rect width="1200" height="630" fill="#0f172a"/>
    \\      <image href="${avatarUri}" x="100" y="100" width="150" height="150" clip-path="url(#av)"/>
    \\      <text x="100" y="380" font-family="Arial" font-size="80" fill="#fff" font-weight="bold">${title}</text>
    \\      <text x="100" y="480" font-family="Arial" font-size="40" fill="#94a3b8">by ${author}</text>
    \\    </svg>`;
    \\
    \\    // SVG TEXT WRAPPING: SVG <text> has no auto-wrap.
    \\    // Use zxp.measureText to mathematically calculate line breaks:
    \\    //
    \\    // const maxWidth = 900;
    \\    // const words = title.split(' ');
    \\    // let line = ''; let tspans = ''; let y = 0;
    \\    // for (const word of words) {
    \\    //   const testLine = line + word + ' ';
    \\    //   if (zxp.measureText(testLine, 80).width > maxWidth && line !== '') {
    \\    //     tspans += `<tspan x="100" dy="${y === 0 ? 0 : 90}">${line.trim()}</tspan>`;
    \\    //     line = word + ' ';
    \\    //     y += 90;
    \\    //   } else { line = testLine; }
    \\    // }
    \\    // tspans += `<tspan x="100" dy="${y === 0 ? 0 : 90}">${line.trim()}</tspan>`;
    \\    //
    \\    // Usage: <text font-size="80" ...>${tspans}</text>
    \\
    \\    // 3. Rasterize at exact 1200×630 and save
    \\    const pngBuf = zxp.encode(zxp.paintSVG(svg, { width: 1200, height: 630 }), 'png');
    \\    zxp.fs.writeFileSync('og_image.png', pngBuf);
    \\    return pngBuf;
    \\  }
    \\  run()
    \\
    \\## 14. Test a locally-running SPA (React/Vue/Solid)
    \\
    \\  // Zero-dependency headless tests — no Playwright, no Chrome, no test framework config.
    \\  // Ask Claude: "test my counter component" and give it the URL.
    \\  // Claude writes the script, posts it here, gets back structured pass/fail results.
    \\
    \\  // ⚠️  REQUIRES A BUILT BUNDLE — vite dev (port 5173) does NOT work.
    \\  //   vite dev serves unbundled ESM modules that zxp cannot resolve.
    \\  //   You must run: vite build && vite preview   (serves on port 4173)
    \\  //   Or any other bundled output (webpack, rollup, etc.) served over HTTP.
    \\
    \\  // Rules:
    \\  //   - goto() executes the bundle automatically — no runScripts() needed
    \\  //   - Events MUST use { bubbles: true } — React/Vue use root-level delegation
    \\  //   - After state-changing events: await new Promise(r => setTimeout(r, 0))
    \\  //     to flush the framework's microtask re-render queue before reading state
    \\
    \\  async function run() {
    \\    const results = [];
    \\    await zxp.goto('http://localhost:4173'); // vite preview (built bundle)
    \\
    \\    const btn = await zxp.waitForSelector('button');
    \\    results.push({ test: 'initial render',   pass: btn.textContent === 'count is 0' });
    \\
    \\    btn.dispatchEvent(new Event('click', { bubbles: true }));
    \\    await new Promise(r => setTimeout(r, 0));
    \\    results.push({ test: 'click increments', pass: btn.textContent === 'count is 1' });
    \\
    \\    btn.dispatchEvent(new Event('click', { bubbles: true }));
    \\    btn.dispatchEvent(new Event('click', { bubbles: true }));
    \\    await new Promise(r => setTimeout(r, 0));
    \\    results.push({ test: '3 total clicks',   pass: btn.textContent === 'count is 3' });
    \\
    \\    return results; // [{test, pass}] — Claude reports which passed/failed and why
    \\  }
    \\  run()
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
    \\    For SPAs (React/Vue/Solid): goto() already executes the JS bundle. No need for runScripts().
    \\    goto() returns after the initial synchronous render. Use waitForSelector() if the
    \\    content you need appears asynchronously (data fetches, lazy components).
    \\    Simulating clicks: ALWAYS pass { bubbles: true } — React/Vue use root-level event
    \\    delegation, so non-bubbling events never reach the framework handler:
    \\      el.dispatchEvent(new Event('click', { bubbles: true }));
    \\      await new Promise(r => setTimeout(r, 0)); // flush React re-render microtasks
    \\
    \\  zxp.waitForSelector(selector: string, timeoutMs?: number): Promise<Element>
    \\    Poll until selector appears in the DOM (default timeout 5000ms).
    \\    Uses __native_flush() between polls to let React/Vue microtasks settle.
    \\    Use after goto() on SPAs when content loads asynchronously:
    \\      await zxp.goto('http://localhost:4173');
    \\      const el = await zxp.waitForSelector('.product-list');
    \\      return el.textContent;
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
    \\## Remote libraries (zxp.importScript)
    \\  zxp.importScript(url: string): Promise<void>
    \\    Fetch a JS library, eval it in the current context, then compile to bytecode
    \\    and cache it process-wide (~10x faster on repeat calls — no re-fetch, no re-parse).
    \\    Works with any CDN-hosted UMD/IIFE library. Tested: D3 v7, Leaflet 1.9.
    \\    After awaiting, the library's globals (d3, L, etc.) are available immediately.
    \\
    \\    // D3 bar chart
    \\    await zxp.importScript('https://d3js.org/d3.v7.min.js');
    \\    // Leaflet map
    \\    await zxp.importScript('https://unpkg.com/leaflet@1.9.4/dist/leaflet.js');
    \\
    \\## SVG rendering
    \\  zxp.paintSVG(svg: string | Uint8Array | ArrayBuffer, opts?: { width?: number, height?: number }): { data: ArrayBuffer, width, height }
    \\    Rasterize SVG via ThorVG. Accepts a plain string (most convenient), Uint8Array,
    \\    or ArrayBuffer. Returns { data, width, height } — same shape as paintDOM/paintElement.
    \\    Use zxp.encode(img, 'png') to get a PNG ArrayBuffer.
    \\
    \\    Output size (opts):
    \\      { width: 1200, height: 630 } → exact pixel dimensions (SVG scaled to fit the box)
    \\      { width: 1200 }              → 1200px wide, height derived from SVG aspect ratio
    \\      { height: 630 }              → 630px tall, width derived from SVG aspect ratio
    \\      (no opts)                    → DEFAULT: auto-scale so longest side ≥ 800px
    \\    For OG images and social cards, always pass both: paintSVG(svg, { width: 1200, height: 630 })
    \\
    \\    Note: fill="transparent" is automatically normalised to fill="none" (ThorVG quirk).
    \\    Prefer SVG output over canvas for chart libraries — pixel-perfect with no browser
    \\    geometry engine required. Works great with ECharts, D3, any SVG-generating lib.
    \\
    \\    ThorVG SVG text gotchas:
    \\      - text-anchor="start|middle|end"  ✓ all work correctly
    \\      - dominant-baseline="middle"       ✗ NOT SUPPORTED — silently shifts text upward,
    \\        making it disappear or clip. Use dy="0.35em" instead for vertical centring.
    \\      - clipPath                          ✓ works
    \\      - xml:space="preserve"              Add to <svg> root to prevent whitespace collapse
    \\        in multi-word text or tspan elements. Harmless if text is simple.
    \\
    \\  zxp.measureText(text: string, fontSize: number): { width: number, height: number }
    \\    Measure pixel dimensions of text at a given font size (Roboto, same as paintSVG).
    \\    Use this for exact SVG text wrapping — no guesswork, no heuristic constants needed.
    \\
    \\    // SVG TEXT WRAPPING: SVG <text> has no auto-wrap.
    \\    // Use zxp.measureText to mathematically calculate line breaks:
    \\    //
    \\    // const maxWidth = 900;
    \\    // const words = title.split(' ');
    \\    // let line = ''; let tspans = ''; let y = 0;
    \\    // for (const word of words) {
    \\    //   const testLine = line + word + ' ';
    \\    //   if (zxp.measureText(testLine, 80).width > maxWidth && line !== '') {
    \\    //     tspans += `<tspan x="100" dy="${y === 0 ? 0 : 90}">${line.trim()}</tspan>`;
    \\    //     line = word + ' ';
    \\    //     y += 90;
    \\    //   } else { line = testLine; }
    \\    // }
    \\    // tspans += `<tspan x="100" dy="${y === 0 ? 0 : 90}">${line.trim()}</tspan>`;
    \\    //
    \\    // Usage: <text font-size="80" ...>${tspans}</text>
    \\
    \\## File I/O
    \\  zxp.fs.readFileSync(path: string): ArrayBuffer
    \\  zxp.fs.writeFileSync(path: string, buf: ArrayBuffer): void
    \\  zxp.stdin.read(): string    — piped stdin as UTF-8 text (CLI only)
    \\  zxp.stdin.readBytes(): ArrayBuffer
    \\
    \\## Persistent Store (SQLite, sandbox-local)
    \\  zxp.store.save(name: string, data: string | ArrayBuffer | Uint8Array, opts?): { id, hash }
    \\    Upsert by name. opts: { mime?: string, note?: string }
    \\    Use to persist render outputs, scraped content, or intermediate data across tool calls.
    \\
    \\  zxp.store.get(name: string): { id, name, mime, note, hash, data: ArrayBuffer, created_at } | null
    \\    Retrieve a stored entry. data is always an ArrayBuffer — use TextDecoder for text.
    \\
    \\  zxp.store.list(): { id, name, mime, note, hash, created_at }[]
    \\    List all entries (metadata only, no blobs).
    \\
    \\  zxp.store.delete(name: string): boolean
    \\    Delete an entry by name. Returns true if it existed.
    \\
    \\  // Pattern: save a rendered image, retrieve it in the next tool call
    \\  zxp.store.save('my_chart', zxp.encode(zxp.paintDOM(el, 800), 'png'), { mime: 'image/png' });
    \\  // later:
    \\  const { data } = zxp.store.get('my_chart');
    \\  return data;  // returns the PNG as an image in MCP
;

const DOC_SCRAPING =
    \\# Scraping guide
    \\
    \\## IMPORTANT: Use execute_scripts: false for public sites (Wikipedia, news sites, etc.)
    \\
    \\Complex public websites (Wikipedia, news portals) load heavy JS frameworks (jQuery,
    \\MediaWiki, etc.) that use browser APIs not fully implemented in zexplorer. Running
    \\these scripts will crash the engine (segfault). Always disable script execution when
    \\scraping public websites for data extraction — you only need the HTML/DOM anyway.
    \\
    \\  // CORRECT — disable scripts for public site scraping
    \\  await zxp.goto('https://en.wikipedia.org/wiki/...', { execute_scripts: false });
    \\  const rows = Array.from(document.querySelectorAll('table.wikitable tbody tr'));
    \\  return rows.map(r => Array.from(r.querySelectorAll('td')).map(c => c.textContent.trim()));
    \\
    \\  // WRONG — will crash with jQuery/MediaWiki/complex frameworks
    \\  await zxp.goto('https://en.wikipedia.org/wiki/...');  // no options = scripts ON
    \\
    \\## When to enable scripts (execute_scripts: true, the default)
    \\
    \\Only enable scripts for:
    \\  - Pages where content is rendered by JS (SPAs: React, Vue, etc.)
    \\  - Sites you control or know have compatible JS
    \\  - Simple pages without heavy third-party frameworks
    \\
    \\## Link extraction
    \\
    \\  await zxp.goto('https://example.com', { execute_scripts: false });
    \\  const links = Array.from(document.querySelectorAll('a[href]'))
    \\    .map(a => ({ text: a.textContent.trim(), href: a.getAttribute('href') }));
    \\  return links;
    \\
    \\## Text as Markdown (compact for LLMs)
    \\
    \\  await zxp.goto('https://example.com', { execute_scripts: false });
    \\  return zxp.toMarkdown(document.body);
    \\
    \\## Replace images then render
    \\
    \\  await zxp.goto('https://example.com', { execute_scripts: false });
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
    \\## Two golden rules
    \\
    \\  RULE 1 — structured data / layouts → loadHTML + paintDOM:
    \\    Load HTML with inline styles. paintDOM renders it via the CSS compositor.
    \\    Best for: invoices, email templates, OG images, cards, tables, multi-column layouts.
    \\    For JSON/CSV data: build a <table> or flex <div> — do NOT hand-craft SVG for tables.
    \\    Keep CSS simple — no external fonts, no animation, no complex media queries.
    \\    Use flex/block. <table> with border-collapse and inline padding works perfectly.
    \\    Avoid percentage widths in nested flex.
    \\
    \\  RULE 2 — hand-craft SVG, use paintSVG:
    \\    Build the SVG as a JS template string. paintSVG rasterizes via ThorVG.
    \\    Best for: charts, diagrams, data visualisations.
    \\    More reliable than D3/ECharts because it avoids the browser measurement
    \\    feedback loop that those libraries depend on.
    \\    Pass { width, height } for exact output size: paintSVG(svg, { width: 1200, height: 630 })
    \\    Default (no opts): auto-scale so longest side ≥ 800px.
    \\    Add xml:space="preserve" on the <svg> root to prevent whitespace collapse in text.
    \\    text-anchor works. dominant-baseline="middle" does NOT — use dy="0.35em".
    \\    &amp; in text: use raw & (ThorVG doesn't decode XML entities).
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
    } else if (std.mem.eql(u8, name, "store_save")) {
        try toolStoreSave(app_ctx, id, args, out, aa);
    } else if (std.mem.eql(u8, name, "store_get")) {
        try toolStoreGet(app_ctx, id, args, out, aa);
    } else if (std.mem.eql(u8, name, "store_list")) {
        try toolStoreList(app_ctx, id, out, aa);
    } else if (std.mem.eql(u8, name, "store_delete")) {
        try toolStoreDelete(app_ctx, id, args, out, aa);
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

    const styled_html = try std.fmt.allocPrint(aa, "<style>{s}</style>{s}", .{ GFM_CSS, html });
    engine.loadHTML(styled_html) catch |err| {
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
    const esc_gfm = try jsonEscape(aa, GFM_CSS);
    const load_js = try std.fmt.allocPrint(
        aa,
        "(function(){{" ++
            "var h=zxp.markdownToHTML({s});" ++
            "zxp.loadHTML('<html><head><style>'+{s}+{s}+'</style></head><body>'+h+'</body></html>');" ++
            "}})()",
        .{ esc_md, esc_gfm, esc_css },
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

/// Context passed through the C callback boundary into runScriptCb.
const ScriptRunCtx = struct {
    engine: *z.ScriptEngine,
    /// User script: last-expression value is the MCP result.
    script: []const u8,
    /// Set to true once evalAsync + engine.run() both complete (no SIGSEGV).
    finished: bool = false,
    /// Non-null if evalAsync returned a Zig error.
    eval_error: ?[:0]const u8 = null,
    /// The JS result value.  Valid only when finished=true and eval_error=null.
    val: z.qjs.JSValue = undefined,
};

/// C-callable callback that runs the script inside zexp_crash_protect_run().
fn runScriptCb(ptr: ?*anyopaque) callconv(.c) void {
    const ctx: *ScriptRunCtx = @ptrCast(@alignCast(ptr.?));
    const val = ctx.engine.evalAsync(ctx.script, "<mcp-script>") catch |err| {
        ctx.eval_error = @errorName(err);
        ctx.finished = true;
        return;
    };
    ctx.val = val;
    if (!ctx.engine.ctx.isException(val)) {
        ctx.engine.run() catch {};
    }
    ctx.finished = true;
}

/// C-callable callback that calls engine.deinit() — wrapped so SIGSEGV during
/// CSS cleanup (lxb_html_document_stylesheet_destroy_all bug) is caught.
fn engineDeinitCb(ptr: ?*anyopaque) callconv(.c) void {
    const engine: *z.ScriptEngine = @ptrCast(@alignCast(ptr.?));
    engine.deinit();
}

fn toolRunScript(
    app_ctx: *AppContext,
    id: ?std.json.Value,
    args: std.json.Value,
    out: *std.Io.Writer.Allocating,
    aa: std.mem.Allocator,
    alloc: std.mem.Allocator,
) !void {
    // Install SIGSEGV handler once (idempotent).
    zexp_crash_protect_install();

    const script = getStrArg(args, "script") orelse {
        try buildError(id, -32602, "run_script: missing required argument 'script'", out);
        return;
    };

    // Per-request arena for the engine.  On SIGSEGV recovery we skip
    // cleanup entirely (leaking this arena) rather than risk re-crashing
    // on corrupted allocator state.  The global `alloc` is never touched
    // by QuickJS/Lexbor directly, so it stays clean.
    var engine_arena = std.heap.ArenaAllocator.init(alloc);
    const engine_alloc = engine_arena.allocator();

    const zxp_rt = zxp_runtime.getOrCreate(alloc, app_ctx.sandbox_root) catch |err| {
        engine_arena.deinit();
        return err;
    };
    const engine = z.ScriptEngine.init(engine_alloc, zxp_rt) catch |err| {
        engine_arena.deinit();
        return err;
    };
    engine.loadHTML("<html><head></head><body></body></html>") catch |err| {
        engine.deinit();
        engine_arena.deinit();
        return err;
    };

    // ── Execute with SIGSEGV crash protection ──────────────────────────────
    var run_ctx = ScriptRunCtx{ .engine = engine, .script = script };
    const script_crashed = zexp_crash_protect_run(runScriptCb, &run_ctx);

    if (script_crashed != 0) {
        // SIGSEGV caught during script execution.  The engine and its arena
        // may be corrupted — intentionally leak them and invalidate the
        // thread-local ZxpRuntime so the next request starts fresh.
        zxp_runtime.invalidateThreadLocal();
        std.debug.print("💥 [MCP run_script] SIGSEGV caught during eval — runtime invalidated, arena leaked\n", .{});
        const content = try textContent(
            "Script execution crashed (segfault). " ++
                "For public websites always pass { execute_scripts: false, load_stylesheets: false } to goto().",
            aa,
        );
        try buildToolResult(id, content, out);
        return;
    }

    // ── Handle JS-level errors ─────────────────────────────────────────────
    if (run_ctx.eval_error) |ename| {
        // Zig error from evalAsync.  For JSPromiseRejected, include the reason.
        const msg = if (std.mem.eql(u8, ename, "JSPromiseRejected"))
            if (engine.last_rejection_msg) |reason|
                try std.fmt.allocPrint(aa, "run_script: Promise rejected: {s}", .{reason})
            else
                try std.fmt.allocPrint(aa, "run_script: Promise rejected (see server log)", .{})
        else
            try std.fmt.allocPrint(aa, "run_script: eval failed: {s}", .{ename});
        cleanupEngine(engine, &engine_arena);
        try buildError(id, -32603, msg, out);
        return;
    }

    // val is a JSValue owned by the context — must be freed before engine.deinit().
    // We do NOT use defer here to ensure freeValue comes before engineDeinitCb.
    const val = run_ctx.val;

    if (engine.ctx.isException(val)) {
        const ex = engine.ctx.getException();
        const result_content = blk: {
            if (engine.ctx.toZString(ex)) |err_str| {
                defer engine.ctx.freeZString(err_str);
                const msg = try std.fmt.allocPrint(aa, "JavaScript Error:\n{s}", .{err_str});
                break :blk try textContent(msg, aa);
            } else |_| {
                break :blk try textContent("run_script: Unknown JavaScript exception", aa);
            }
        };
        engine.ctx.freeValue(ex);
        engine.ctx.freeValue(val);
        cleanupEngine(engine, &engine_arena);
        try buildToolResult(id, result_content, out);
        return;
    }

    // ── Extract result (all paths: freeValue(val) before engine cleanup) ──

    // ArrayBuffer → base64 image
    if (engine.ctx.isArrayBuffer(val)) {
        const bytes_result = engine.ctx.getArrayBuffer(val);
        if (bytes_result) |bytes| {
            const bytes_copy = try aa.dupe(u8, bytes); // copy before engine goes away
            const content = try imageContent(bytes_copy, sniffMime(bytes_copy), aa);
            engine.ctx.freeValue(val);
            cleanupEngine(engine, &engine_arena);
            try buildToolResult(id, content, out);
        } else |_| {
            engine.ctx.freeValue(val);
            cleanupEngine(engine, &engine_arena);
            try buildError(id, -32603, "run_script: failed to read ArrayBuffer", out);
        }
        return;
    }

    // String, object/array → text content (copy into aa before engine cleanup)
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

    engine.ctx.freeValue(val);
    cleanupEngine(engine, &engine_arena);

    const content = try textContent(text, aa);
    try buildToolResult(id, content, out);
}

/// Protected engine cleanup: runs engine.deinit() inside SIGSEGV protection
/// (guards against the Lexbor lxb_html_document_stylesheet_destroy_all bug),
/// then frees the arena.  On crash: invalidates runtime and leaks the arena.
fn cleanupEngine(engine: *z.ScriptEngine, engine_arena: *std.heap.ArenaAllocator) void {
    const deinit_crashed = zexp_crash_protect_run(engineDeinitCb, engine);
    if (deinit_crashed != 0) {
        std.debug.print("💥 [MCP] SIGSEGV in engine.deinit() — runtime invalidated, arena leaked\n", .{});
        zxp_runtime.invalidateThreadLocal();
        // Do NOT call engine_arena.deinit() — it may also be corrupted.
    } else {
        engine_arena.deinit();
    }
}

// ── store_save ─────────────────────────────────────────────────────────────────

fn toolStoreSave(app_ctx: *AppContext, id: ?std.json.Value, args: std.json.Value, out: *std.Io.Writer.Allocating, aa: std.mem.Allocator) !void {
    const name = getStrArg(args, "name") orelse {
        try buildError(id, -32602, "store_save: missing required argument 'name'", out);
        return;
    };
    const value = getStrArg(args, "value") orelse {
        try buildError(id, -32602, "store_save: missing required argument 'value'", out);
        return;
    };
    const mime = getStrArg(args, "mime");
    const note = getStrArg(args, "note");

    const store = js_store.getOrOpen(aa, app_ctx.sandbox_root) catch |err| {
        const msg = try std.fmt.allocPrint(aa, "store_save: failed to open DB: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };

    const result = store.save(name, value, mime, note) catch |err| {
        const msg = try std.fmt.allocPrint(aa, "store_save: DB error: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };

    const text = try std.fmt.allocPrint(aa, "Saved '{s}' (id={d}, hash={s})", .{ name, result.id, result.hash });
    const cnt = try textContent(text, aa);
    try buildToolResult(id, cnt, out);
}

// ── store_get ──────────────────────────────────────────────────────────────────

fn toolStoreGet(app_ctx: *AppContext, id: ?std.json.Value, args: std.json.Value, out: *std.Io.Writer.Allocating, aa: std.mem.Allocator) !void {
    const name = getStrArg(args, "name") orelse {
        try buildError(id, -32602, "store_get: missing required argument 'name'", out);
        return;
    };

    const store = js_store.getOrOpen(aa, app_ctx.sandbox_root) catch |err| {
        const msg = try std.fmt.allocPrint(aa, "store_get: failed to open DB: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };

    var row = store.get(name) catch |err| {
        const msg = try std.fmt.allocPrint(aa, "store_get: DB error: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };

    if (row == null) {
        const msg = try std.fmt.allocPrint(aa, "store_get: '{s}' not found", .{name});
        const cnt = try textContent(msg, aa);
        try buildToolResult(id, cnt, out);
        return;
    }
    defer row.?.deinit();
    const r = row.?;

    // If mime is an image type, return as MCP image content
    const is_image = if (r.mime) |m| std.mem.startsWith(u8, m, "image/") else false;
    if (is_image) {
        const cnt = try imageContent(r.data, r.mime.?, aa);
        try buildToolResult(id, cnt, out);
    } else {
        const cnt = try textContent(r.data, aa);
        try buildToolResult(id, cnt, out);
    }
}

// ── store_list ─────────────────────────────────────────────────────────────────

fn toolStoreList(app_ctx: *AppContext, id: ?std.json.Value, out: *std.Io.Writer.Allocating, aa: std.mem.Allocator) !void {
    const store = js_store.getOrOpen(aa, app_ctx.sandbox_root) catch |err| {
        const msg = try std.fmt.allocPrint(aa, "store_list: failed to open DB: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };

    const entries = store.list(aa) catch |err| {
        const msg = try std.fmt.allocPrint(aa, "store_list: DB error: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };

    var buf: std.Io.Writer.Allocating = .init(aa);
    const w = &buf.writer;
    try w.writeAll("[");
    for (entries, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"id\":{d},\"name\":", .{e.id});
        try std.json.Stringify.value(e.name, .{}, w);
        try w.writeAll(",\"mime\":");
        if (e.mime) |m| try std.json.Stringify.value(m, .{}, w) else try w.writeAll("null");
        try w.writeAll(",\"note\":");
        if (e.note) |n| try std.json.Stringify.value(n, .{}, w) else try w.writeAll("null");
        try w.writeAll(",\"hash\":");
        if (e.hash) |h| try std.json.Stringify.value(h, .{}, w) else try w.writeAll("null");
        try w.print(",\"created_at\":{d}}}", .{e.created_at});
    }
    try w.writeAll("]");
    const json = try buf.toOwnedSlice();

    const cnt = try textContent(json, aa);
    try buildToolResult(id, cnt, out);
}

// ── store_delete ───────────────────────────────────────────────────────────────

fn toolStoreDelete(app_ctx: *AppContext, id: ?std.json.Value, args: std.json.Value, out: *std.Io.Writer.Allocating, aa: std.mem.Allocator) !void {
    const name = getStrArg(args, "name") orelse {
        try buildError(id, -32602, "store_delete: missing required argument 'name'", out);
        return;
    };

    const store = js_store.getOrOpen(aa, app_ctx.sandbox_root) catch |err| {
        const msg = try std.fmt.allocPrint(aa, "store_delete: failed to open DB: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };

    const deleted = store.delete(name) catch |err| {
        const msg = try std.fmt.allocPrint(aa, "store_delete: DB error: {s}", .{@errorName(err)});
        try buildError(id, -32603, msg, out);
        return;
    };

    const text = if (deleted)
        try std.fmt.allocPrint(aa, "Deleted '{s}'", .{name})
    else
        try std.fmt.allocPrint(aa, "'{s}' not found", .{name});
    const cnt = try textContent(text, aa);
    try buildToolResult(id, cnt, out);
}
