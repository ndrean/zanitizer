const std = @import("std");
const builtin = @import("builtin");
const z = @import("root.zig");
const zqjs = z.wrapper;
const event_loop_mod = @import("event_loop.zig");
const EventLoop = event_loop_mod.EventLoop;
const DOMBridge = z.dom_bridge.DOMBridge;
const RCtx = @import("runtime_context.zig").RuntimeContext;
const ScriptEngine = @import("script_engine.zig").ScriptEngine;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const parseCSV = @import("csv_parser.zig");

const AsyncTask = event_loop_mod.AsyncTask;
const AsyncBridge = @import("async_bridge.zig");
const NativeBridge = @import("js_native_bridge.zig");
const Pt = @import("js_Point.zig");
const Pt2 = @import("Point2.zig");
const JSWorker = @import("js_worker.zig");
const Reflect = @import("reflection.zig");
const Mocks = @import("dom_mocks.zig");
const Native = @import("js_native_bridge.zig");

const native_os = builtin.os.tag;
pub var app_should_quit = std.atomic.Value(bool).init(false);

// toggle the flag
fn handleSigInt(_: c_int) callconv(.c) void {
    app_should_quit.store(true, .seq_cst);
}
// Setup function to call at start of main()
pub fn setupSignalHandler() void {
    if (builtin.os.tag == .windows) {
        // Windows needs a different approach (SetConsoleCtrlHandler),
        // but for now we focus on POSIX (Linux/macOS) as requested.
        return;
    }

    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigInt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    // Catch Ctrl+C (SIGINT)
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    // Optional: Catch Termination request (SIGTERM)
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

pub const TargetFormat = enum {
    binary_png,
    binary_jpeg,
    binary_pdf,
    json_data,
    raw_text,
};

var debug_gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
pub fn main() !void {
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_gpa.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.c_allocator, false },
        };
    };

    defer if (is_debug) {
        _ = .ok == debug_gpa.deinit();
    };

    const sandbox_root = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(sandbox_root);

    setupSignalHandler();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    _ = args.next();

    const verb = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, verb, "render") or std.mem.eql(u8, verb, "run")) {
        var maybe_path: ?[:0]const u8 = null;
        var inline_code: ?[]const u8 = null;
        var output_path: ?[]const u8 = null;
        var load_html_path: ?[]const u8 = null;
        var format_override: ?[]const u8 = null;
        var pretty: bool = false;
        var cli_args: std.ArrayListUnmanaged([]const u8) = .empty;
        defer cli_args.deinit(gpa);

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-o")) {
                output_path = args.next();
            } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--eval")) {
                inline_code = args.next();
            } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--load-html")) {
                load_html_path = args.next();
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
                format_override = args.next();
            } else if (std.mem.eql(u8, arg, "--pretty") or std.mem.eql(u8, arg, "-p")) {
                pretty = true;
            } else if (maybe_path == null and inline_code == null and (std.mem.eql(u8, arg, "-") or !std.mem.startsWith(u8, arg, "-"))) {
                maybe_path = arg;
            } else {
                try cli_args.append(gpa, arg);
            }
        }

        // Resolve script content — inline (-e), stdin (-), or file
        const script_content: []u8 = blk: {
            if (inline_code) |code| {
                break :blk try gpa.dupe(u8, code);
            }
            const path = maybe_path orelse {
                z.print("❌ Error: Missing script path or -e <code>.\n", .{});
                printUsage();
                return;
            };
            if (std.mem.eql(u8, path, "-")) {
                var list: std.ArrayList(u8) = .empty;
                errdefer list.deinit(gpa);
                var buf: [8192]u8 = undefined;
                while (true) {
                    const n = try std.fs.File.stdin().read(&buf);
                    if (n == 0) break;
                    try list.appendSlice(gpa, buf[0..n]);
                }
                break :blk try list.toOwnedSlice(gpa);
            }
            break :blk try std.fs.cwd().readFileAlloc(gpa, path, 10 * 1024 * 1024);
        };
        defer gpa.free(script_content);

        const script_filename: [:0]const u8 = if (inline_code != null)
            "<inline>"
        else if (maybe_path) |p|
            (if (std.mem.eql(u8, p, "-")) "<stdin>" else p)
        else
            "<inline>";

        const format = determineFormat(verb, output_path, format_override);

        var engine = try z.ScriptEngine.init(gpa, sandbox_root);
        defer engine.deinit();

        if (is_debug) engine.printMemoryUsage();

        try runCliRequest(engine, script_content, script_filename, format, output_path, load_html_path, cli_args.items, pretty);
    } else if (std.mem.eql(u8, verb, "convert") or std.mem.eql(u8, verb, "sanitize")) {
        var maybe_path: ?[:0]const u8 = null;
        var maybe_url: ?[]const u8 = null; // --url overrides base URL for stdin input
        var output_path: ?[]const u8 = null;
        var width: u32 = 800; // viewport width in pixels (595=A4@72dpi, 2480=A4@300dpi)
        var load_css: bool = true;
        var load_scripts: bool = true;

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-o")) {
                output_path = args.next();
            } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--width")) {
                if (args.next()) |val| width = std.fmt.parseInt(u32, val, 10) catch 800;
            } else if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                maybe_url = args.next();
            } else if (std.mem.eql(u8, arg, "--no-css")) {
                load_css = false;
            } else if (std.mem.eql(u8, arg, "--no-scripts")) {
                load_scripts = false;
            } else if (maybe_path == null and (std.mem.eql(u8, arg, "-") or !std.mem.startsWith(u8, arg, "-"))) {
                maybe_path = arg;
            }
        }

        const html_content = try readHtmlInput(gpa, maybe_path);
        defer gpa.free(html_content);

        // Determine base URL/dir for resolving relative asset hrefs.
        // Priority: --url flag > URL path input > file path dirname > "." (local stdin)
        const base_dir: []const u8 =
            if (maybe_url) |u| u else if (maybe_path) |p| blk: {
                if (std.mem.startsWith(u8, p, "http://") or std.mem.startsWith(u8, p, "https://"))
                    break :blk @as([]const u8, p); // URL input — use as base for relative resolution
                break :blk std.fs.path.dirname(p) orelse "."; // local file
            } else ".";

        var engine = try z.ScriptEngine.init(gpa, sandbox_root);
        defer engine.deinit();

        if (std.mem.eql(u8, verb, "convert")) {
            try runConvert(engine, html_content, base_dir, output_path, width, load_css, load_scripts);
        } else {
            try runSanitize(engine, html_content, base_dir, output_path, load_css, load_scripts);
        }
    } else {
        z.print("❌ Unknown command: {s}\n", .{verb});
        printUsage();
    }
}

fn readHtmlInput(allocator: std.mem.Allocator, maybe_path: ?[]const u8) ![]u8 {
    const path = maybe_path orelse {
        z.print("❌ Error: Missing HTML file path, URL, or use - for stdin.\n", .{});
        return error.MissingInput;
    };
    if (std.mem.eql(u8, path, "-")) {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = try std.fs.File.stdin().read(&buf);
            if (n == 0) break;
            try list.appendSlice(allocator, buf[0..n]);
        }
        return list.toOwnedSlice(allocator);
    }
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();
        var buf = std.Io.Writer.Allocating.init(allocator);
        const resp = client.fetch(.{
            .method = .GET,
            .location = .{ .url = path },
            .response_writer = &buf.writer,
        }) catch |err| {
            buf.deinit();
            z.print("❌ Failed to fetch URL '{s}': {}\n", .{ path, err });
            return error.FetchFailed;
        };
        if (resp.status != .ok) {
            buf.deinit();
            z.print("❌ HTTP {} fetching '{s}'\n", .{ @intFromEnum(resp.status), path });
            return error.FetchFailed;
        }
        return buf.toOwnedSlice();
    }
    return std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
}

fn runConvert(engine: *ScriptEngine, html: []const u8, base_dir: []const u8, out_path: ?[]const u8, width: u32, load_css: bool, load_scripts: bool) !void {
    try engine.loadPage(html, .{ .base_dir = base_dir, .load_stylesheets = load_css, .execute_scripts = load_scripts });

    const is_pdf = if (out_path) |p| std.mem.endsWith(u8, p, ".pdf") else false;

    // Build script with the requested width.
    // For PDF: render at requested width, read PNG height from header, scale to 595pt.
    // PNG IHDR: bytes 16-19 = width, 20-23 = height (big-endian u32).
    const script = if (is_pdf)
        try std.fmt.allocPrint(engine.allocator,
            \\const _imgBuf = zxp.paintDOM(document.body, {d});
            \\const _view = new DataView(_imgBuf);
            \\const _pxH = _view.getUint32(20, false);
            \\const _pdfH = Math.round(_pxH * (595 / {d}));
            \\const _pdf = new PDFDocument();
            \\_pdf.addPage();
            \\_pdf.drawImageFromBuffer(_imgBuf, 0, 0, 595, _pdfH);
            \\_pdf.toArrayBuffer()
        , .{ width, width })
    else
        try std.fmt.allocPrint(
            engine.allocator,
            "zxp.paintDOM(document.body, {d})",
            .{width},
        );
    defer engine.allocator.free(script);

    const buffer = try engine.evalAsyncAs(engine.allocator, []const u8, script, "<convert>");
    defer engine.allocator.free(buffer);

    if (out_path) |p| {
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = buffer });
        z.print("✅ Saved {d} bytes to {s}\n", .{ buffer.len, p });
    } else {
        try std.fs.File.stdout().writeAll(buffer);
    }
}

fn runSanitize(engine: *ScriptEngine, html: []const u8, base_dir: []const u8, out_path: ?[]const u8, load_css: bool, load_scripts: bool) !void {
    try engine.loadPage(html, .{ .sanitize = true, .base_dir = base_dir, .load_stylesheets = load_css, .execute_scripts = load_scripts });
    const clean_html = try engine.evalAsyncAs(engine.allocator, []const u8, "document.documentElement.outerHTML", "<sanitize>");
    defer engine.allocator.free(clean_html);
    if (out_path) |p| {
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = clean_html });
        z.print("✅ Saved sanitized HTML to {s}\n", .{p});
    } else {
        const stdout = std.fs.File.stdout();
        try stdout.writeAll(clean_html);
        try stdout.writeAll("\n");
    }
}

fn runCliRequest(engine: *ScriptEngine, script: []const u8, filename: [:0]const u8, format: TargetFormat, out_path: ?[]const u8, load_html_path: ?[]const u8, cli_args: []const []const u8, pretty: bool) !void {
    // Inject zxp.args for all modes — scripts can read flags regardless of output format.
    {
        const scope = z.wrapper.Context.GlobalScope.init(engine.ctx);
        defer scope.deinit();
        const zxp_obj = engine.ctx.getPropertyStr(scope.global, "zxp");
        defer engine.ctx.freeValue(zxp_obj);
        const js_args = engine.ctx.newArray();
        for (cli_args, 0..) |arg, i| {
            const js_str = engine.ctx.newString(arg);
            _ = try engine.ctx.setPropertyUint32(js_args, @intCast(i), js_str);
        }
        _ = try engine.ctx.setPropertyStr(zxp_obj, "args", js_args);
    }

    switch (format) {
        .binary_png, .binary_jpeg, .binary_pdf => {
            if (load_html_path) |html_path| {
                const html = try readHtmlInput(engine.allocator, html_path);
                defer engine.allocator.free(html);
                try engine.loadHTML(html);
            } else {
                try engine.loadHTML("<html><head></head><body></body></html>");
            }

            const buffer = try engine.evalAsyncAs(engine.allocator, []const u8, script, filename);
            defer engine.allocator.free(buffer);

            if (out_path) |p| {
                try std.fs.cwd().writeFile(.{ .sub_path = p, .data = buffer });
                z.print("✅ Saved {d} bytes to {s}\n", .{ buffer.len, p });
            } else {
                try std.fs.File.stdout().writeAll(buffer);
            }
        },
        .json_data => {
            const json_str = try engine.evalAsyncAndStringify(engine.allocator, script, filename);
            defer engine.allocator.free(json_str);

            const output: []const u8 = if (pretty) try prettyJson(engine.allocator, json_str) else json_str;
            defer if (pretty) engine.allocator.free(output);

            if (out_path) |p| {
                try std.fs.cwd().writeFile(.{ .sub_path = p, .data = output });
                z.print("✅ Saved JSON to {s}\n", .{p});
            } else {
                const stdout = std.fs.File.stdout();
                try stdout.writeAll(output);
                try stdout.writeAll("\n");
            }
        },
        .raw_text => {
            const text = try engine.evalAsyncAs(engine.allocator, []const u8, script, filename);
            defer engine.allocator.free(text);

            if (out_path) |p| {
                try std.fs.cwd().writeFile(.{ .sub_path = p, .data = text });
                z.print("✅ Saved text to {s}\n", .{p});
            } else {
                const stdout = std.fs.File.stdout();
                try stdout.writeAll(text);
                try stdout.writeAll("\n");
            }
        },
    }
}

fn prettyJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_4 }, &out.writer);
    return out.toOwnedSlice();
}

fn determineFormat(verb: []const u8, out_path: ?[]const u8, format_override: ?[]const u8) TargetFormat {
    // Explicit -f / --format wins over everything else
    if (format_override) |f| {
        if (std.mem.eql(u8, f, "text")) return .raw_text;
        if (std.mem.eql(u8, f, "json")) return .json_data;
        if (std.mem.eql(u8, f, "png")) return .binary_png;
    }

    if (std.mem.eql(u8, verb, "render")) {
        if (out_path) |p| {
            if (std.mem.endsWith(u8, p, ".pdf")) return .binary_pdf;
            if (std.mem.endsWith(u8, p, ".jpg") or std.mem.endsWith(u8, p, ".jpeg")) return .binary_jpeg;
        }
        return .binary_png;
    }

    return .json_data;
}

fn printUsage() void {
    z.print(
        \\Usage: zxp <command> [script] [options]
        \\
        \\Commands:
        \\  run      [script]    Execute script, return data (JSON/text)
        \\  render   [script]    Execute script, return image (PNG)
        \\  convert  <file>      HTML → PNG  (no script needed)
        \\  sanitize <file>      HTML → clean HTML
        \\
        \\Script source for run/render (pick one):
        \\  <file>               Path to a .js file
        \\  -                    Read from stdin
        \\  -e, --eval <code>    Inline JS expression
        \\
        \\Options (run/render):
        \\  -o <file>            Output file path (default: stdout)
        \\  -p, --pretty         Pretty-print JSON output
        \\  -f, --format <fmt>   Output format: json (default), text
        \\  -H, --load-html <f>  Seed render with a real HTML file
        \\
        \\Options (convert/sanitize):
        \\  -o <file>            Output file path (default: stdout)
        \\  -w, --width <px>     Viewport width in pixels (default: 800)
        \\                         595  = A4 at 72 DPI  (screen/PDF quality)
        \\                         1240 = A4 at 150 DPI (good quality)
        \\                         2480 = A4 at 300 DPI (print quality)
        \\  -u, --url <url>      Base URL for resolving relative assets
        \\                         (required when piping HTML from stdin)
        \\  --no-css             Skip loading external stylesheets
        \\  --no-scripts         Skip executing <script> tags
        \\  -  as path           Read HTML from stdin
        \\
        \\Examples:
        \\  zxp run script.js --pretty -o out.json
        \\  zxp run script.js -f text
        \\  zxp run -e "fetch('https://api.example.com').then(r=>r.json())"
        \\  zxp render template.js -o poster.png
        \\  zxp render template.js -H base.html -o poster.png
        \\  zxp convert page.html -o screenshot.png
        \\  zxp convert https://example.com --width 595 -o screenshot.png
        \\  curl https://example.com | zxp convert - --url https://example.com > screenshot.png
        \\  zxp sanitize dirty.html -o clean.html
        \\  zxp sanitize https://amazon.com --no-css > amz.html
        \\  curl https://ziggit.dev | zxp sanitize - --url https://ziggit.dev > clean.html
        \\
    , .{});
}
