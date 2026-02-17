const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const js_security = z.js_security;
const sanitizer_mod = @import("modules/sanitizer.zig");

const EventLoop = @import("event_loop.zig").EventLoop;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const DOMBridge = @import("dom_bridge.zig").DOMBridge;
const async_bindings = @import("async_bindings_generated.zig");
const JSWorker = @import("js_worker.zig");
const FetchBridge = @import("js_fetch.zig").FetchBridge;
const AsyncBridge = @import("async_bridge.zig");
const FormDataBridge = @import("js_formData.zig").FormDataBridge;
const FSBridge = @import("js_fs.zig").FSBridge;
const js_console = @import("js_console.zig");
const js_marshall = @import("js_marshall.zig");
const CurlMulti = @import("curl_multi.zig").CurlMulti;
const ScriptBuffers = @import("curl_multi.zig").ScriptBuffers;

const Sanitizer = sanitizer_mod.Sanitizer;
const SanitizeOptions = sanitizer_mod.SanitizeOptions;

const TIMEOUT_MS: i64 = 5000;
const RUN_TIMEOUT_MS: i64 = 30_000; // 30s wall-clock limit for engine.run()

/// Options for `loadPage()` - the high-level page loading orchestrator.
///
/// Usage:
/// ```zig
/// try engine.loadPage(html, .{ .sanitize = true, .base_dir = "js/app" });
/// ```
pub const LoadPageOptions = struct {
    /// Enable sanitization for untrusted HTML content.
    /// When true, uses Sanitizer to clean HTML before processing.
    sanitize: bool = false,

    /// Base directory for resolving relative paths in <script src> and <link href>.
    /// Paths are resolved relative to the sandbox root.
    base_dir: []const u8 = ".",

    /// Sanitizer options (only used when `sanitize = true`).
    sanitizer_options: SanitizeOptions = .{},

    /// Execute <script> tags after loading HTML and CSS.
    execute_scripts: bool = true,

    /// Load <link rel="stylesheet"> external stylesheets.
    load_stylesheets: bool = true,

    /// Run event loop after loading (process timers, promises, etc.).
    run_loop: bool = false,
};

/// avoid infinte loops like `white (true) {}` by setting a deadline
export fn js_interrupt_handler(_: ?*qjs.JSRuntime, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    // Cast the opaque pointer back to the ScriptEngine
    if (opaque_ptr) |ptr| {
        const engine: *ScriptEngine = @ptrCast(@alignCast(ptr));

        // Check if a deadline is set
        if (engine.interrupt_deadline > 0) {
            // and if we have exceeded the deadline
            if (std.time.milliTimestamp() > engine.interrupt_deadline) {
                // TIMEOUT!
                return 1;
            }
        }
    }
    return 0; // Continue
}

pub const ScriptEngine = struct {
    allocator: std.mem.Allocator,
    rt: *zqjs.Runtime,
    ctx: zqjs.Context,
    loop: *EventLoop,
    rc: *RuntimeContext,
    dom: DOMBridge, // VALUE!! to own the DOMBridge struct so DOMBridge deinit its content and ScriptEngine
    interrupt_deadline: i64 = 0, // in milliseconds, 0 means no deadline
    sandbox: js_security.Sandbox,

    // TODO: need to read the import_map as external
    const import_map_json = @embedFile("examples/cdn_import_map.json");

    /// Initialize JS Environment on the heap
    pub fn init(allocator: std.mem.Allocator, sandbox_root: []const u8) !*ScriptEngine {
        const self = try allocator.create(ScriptEngine);
        self.allocator = allocator;
        errdefer allocator.destroy(self);

        self.sandbox = try js_security.Sandbox.initWithImportMap(allocator, sandbox_root, import_map_json);
        errdefer self.sandbox.deinit();

        // Runtime & Context
        self.rt = try zqjs.Runtime.init(allocator);
        errdefer self.rt.deinit();
        self.rt.setMemoryLimit(256 * 1024 * 1024); // 256 MB
        self.rt.setGCThreshold(32 * 1024 * 1024); // 32MB before GC (avoid mid-render collection)
        self.rt.setMaxStackSize(4 * 1024 * 1024); // 4 MB stack for deep vnode trees

        self.rt.setInterruptHandler(js_interrupt_handler, @ptrCast(self));
        self.rt.setCanBlock(false);

        // Security firewall
        // self.rt.enableModuleLoader();
        self.rt.setModuleLoader(
            js_security.js_secure_module_normalize,
            js_security.js_secure_module_loader,
            &self.sandbox,
        );

        self.ctx = zqjs.Context.init(self.rt);

        self.ctx.setAllocator(&self.allocator);
        errdefer self.ctx.deinit();

        // Event Loop
        self.loop = try EventLoop.create(allocator, self.rt);
        errdefer self.loop.destroy();

        // Runtime Context: allocates, zeroes classes, sets the opaque pointer
        self.rc = try RuntimeContext.create(
            allocator,
            self.ctx,
            self.loop,
            &self.sandbox,
            sandbox_root,
        );
        errdefer self.rc.destroy();

        const dom_bridge = try DOMBridge.init(allocator, self.ctx);
        self.dom = dom_bridge;
        errdefer self.dom.deinit();

        self.rc.dom_bridge = @ptrCast(@alignCast(&self.dom));
        self.rc.engine_ptr = @ptrCast(self);

        // (timers)
        try self.loop.install(self.ctx);
        try js_console.install(self.ctx);
        // try AsyncBridge.install(self.ctx);

        // install DOM APIs
        try self.dom.installAPIs(); // console, etc.
        try JSWorker.registerWorkerClass(self.ctx);
        try FetchBridge.install(self.ctx);
        try FormDataBridge.install(self.ctx);
        try FSBridge.install(self.ctx);

        const global = self.ctx.getGlobalObject();
        defer self.ctx.freeValue(global);

        _ = try self.ctx.setPropertyStr(global, "__native_flush", self.ctx.newCFunction(js_flush, "flush", 0));
        _ = try self.ctx.setPropertyStr(global, "__native_loadPage", self.ctx.newCFunction(js_native_loadPage, "loadPage", 2));

        const stdlib_code = @embedFile("zexplorer.js");
        const eval_res = qjs.JS_Eval(self.ctx.ptr, stdlib_code.ptr, stdlib_code.len, "zexplorer.js", qjs.JS_EVAL_TYPE_GLOBAL);

        if (qjs.JS_IsException(eval_res)) {
            std.debug.print("CRITICAL: Failed to load zexplorer.js standard library!\n", .{});
        }
        defer self.ctx.freeValue(eval_res);

        // TODO Other async bindings (sandboxed readFile, etc.)
        // const readFile_fn = self.ctx.newCFunction(async_bindings.js_readFile, "readFile", 1);
        // _ = try self.ctx.setPropertyStr(global, "readFile", readFile_fn);

        // try self.disableUnsafeFeatures();
        return self;
    }

    pub fn disableUnsafeFeatures(self: *ScriptEngine) !void {
        const global_obj = self.ctx.getGlobalObject();
        defer self.ctx.freeValue(global_obj);

        const keys_to_remove = [_][:0]const u8{
            // "eval",
            "Function",
            "WebAssembly", // not included in build
            "Atomics",
            "ShareArrayBuffer",
        };

        for (keys_to_remove) |key| {
            const atom = self.ctx.newAtom(key);
            defer self.ctx.freeAtom(atom);
            if (!try self.ctx.deleteProperty(global_obj, atom, 0)) return error.FailedToDisableFeature;
        }
        const glob = try self.ctx.eval(
            "Object.freeze(globalThis);",
            "<internal>",
            zqjs.Context.EvalFlags{
                .type = .global,
            },
        );
        self.ctx.freeValue(glob);
    }

    pub fn deinit(self: *ScriptEngine) void {
        self.rc.cleanUp(self.ctx);
        self.sandbox.deinit();
        self.dom.deinit();
        if (self.rc.last_result) |val| {
            self.ctx.freeValue(val);
            self.rc.last_result = null;
        }
        // bridges first (release JS references)
        // release internal slots
        self.rc.destroy();
        // Loop (stops threads, frees tasks)
        self.loop.destroy();
        // GC before context deinit to collect cycles (e.g. img.onload → closure → img)
        self.rt.runGC();
        // Context
        self.ctx.deinit();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        // Runtime (final GC and destroy)
        self.rt.runGC();
        self.rt.deinit();
        self.allocator.destroy(self);
    }

    /// Run Event Loop until completion (or until empty)
    pub fn run(self: *ScriptEngine) !void {
        // Set interrupt deadline so the interrupt handler can kill runaway JS
        // during event loop execution (not just during eval)
        self.interrupt_deadline = std.time.milliTimestamp() + RUN_TIMEOUT_MS;
        defer self.interrupt_deadline = 0;

        // NOTE: No pre-drain here — the event loop's step 2 drains microtasks
        // with a safety limit. A pre-drain without limits caused hangs when
        // JS code (React hydration) called native DOM functions that loop
        // forever on corrupted trees (lxb_selectors_find bypasses JS interrupt).
        try self.loop.run(.Script);
    }

    /// Evaluate code and returns the raw JS Value.
    /// ⚠️ The Caller OWNS this value and must free it with engine.ctx.freeValue(val).
    pub fn eval(self: *ScriptEngine, code: []const u8, filename: []const u8, eval_type: zqjs.Context.EvalType) !zqjs.Value {
        // Save previous deadline so nested eval() calls (e.g. executeScripts
        // called from __native_loadPage during engine.run()) don't cancel
        // the outer deadline set by run().
        const prev_deadline = self.interrupt_deadline;
        self.interrupt_deadline = std.time.milliTimestamp() + TIMEOUT_MS;

        const c_code = try self.allocator.dupeZ(u8, code);
        defer self.allocator.free(c_code);

        const c_name = try self.allocator.dupeZ(u8, filename);
        defer self.allocator.free(c_name);

        // type = .global
        const val = self.ctx.eval(
            c_code,
            c_name,
            .{ .type = eval_type },
        ) catch {
            // The exception is still in the context, print it before returning
            _ = self.ctx.checkAndPrintException();
            self.interrupt_deadline = prev_deadline; // restore outer deadline
            return error.JSException;
        };

        self.interrupt_deadline = prev_deadline; // restore outer deadline

        // Check for JS-level exceptions (syntax errors, throw new Error(), etc.)
        if (self.ctx.isException(val)) {
            _ = self.ctx.checkAndPrintException();
            // We free the exception value here because it's useless to the caller
            self.ctx.freeValue(val);
            return error.JSException;
        }

        return val;
    }

    /// Call a JS function by path (e.g. "console.log" or "document.getElementById")
    /// Handles dot-notation and correct 'this' binding automatically.
    pub fn call(
        self: *ScriptEngine,
        comptime ResultType: type,
        func_path: [:0]const u8,
        arg_payload: anytype,
    ) !std.json.Parsed(ResultType) {

        // Serialize Zig Arg -> JSON String (Zero-Copy / No Leak)
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        try std.json.Stringify.value(arg_payload, .{ .whitespace = .indent_2 }, &out.writer);

        const z_parsed = try out.toOwnedSliceSentinel(0);
        defer self.allocator.free(z_parsed);
        const json_slice = z_parsed[0 .. z_parsed.len - 1];

        // Parse JSON -> JS Object
        const arg_js = self.ctx.parseJSON(json_slice, "<arg>");
        defer self.ctx.freeValue(arg_js);
        if (self.ctx.isException(arg_js)) return error.SerializationFailed;

        // Traversal Logic
        const global = self.ctx.getGlobalObject();

        // 'current' tracks the object we are inspecting (starts at global)
        var current = global;

        // 'parent' tracks the owner of the function (for 'this' binding)
        // If path is just "func", parent is global.
        // If path is "doc.func", parent is doc.
        var parent = global;
        // We increment ref count for parent so we can safely manage lifecycle below
        _ = self.ctx.dupValue(parent);

        var it = std.mem.splitScalar(u8, func_path, '.');

        while (it.next()) |part| {
            // Check container validity
            if (self.ctx.isUndefined(current) or self.ctx.isNull(current)) {
                self.ctx.freeValue(current);
                self.ctx.freeValue(parent);
                return error.FunctionNotFound;
            }

            // Get the next property. Must dupe the part string because split returns a slice, but API needs null-terminated
            const part_z = try self.allocator.dupeZ(u8, part);
            defer self.allocator.free(part_z);

            const next_val = self.ctx.getPropertyStr(current, part_z);

            // Shift Context. The old 'parent' is no longer needed (unless it was global, which is handled
            self.ctx.freeValue(parent);
            // old 'current' becomes the new 'parent'
            parent = current;
            // new property becomes 'current'
            current = next_val;
        }

        // Verification
        const func = current;
        const this_obj = parent;

        // Ensure refs clean up when we exit scope
        defer self.ctx.freeValue(func);
        defer self.ctx.freeValue(this_obj);

        if (!self.ctx.isFunction(func)) {
            // might be a value (like document.title), not a function.
            // to support *getting* values, return 'func' here directly.
            return error.FunctionNotFound;
        }

        // Call Function wth 'this_obj'
        const args = [_]zqjs.Value{arg_js};
        const result_js = self.ctx.call(func, this_obj, &args);
        defer self.ctx.freeValue(result_js);

        if (self.ctx.isException(result_js)) {
            _ = self.ctx.checkAndPrintException();
            return error.JSException;
        }

        // Deserialize Deep Copy JS Value -> Zig Struct via JSON
        const result_json = self.ctx.jsonStringifySimple(result_js) catch return error.SerializationFailed;
        defer self.ctx.freeValue(result_json);

        const result_str = self.ctx.toZString(result_json) catch return error.SerializationFailed;
        defer self.ctx.freeZString(result_str);

        const parsed = std.json.parseFromSlice(ResultType, self.allocator, result_str, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return error.DeserializationFailed;

        return parsed;
    }

    pub fn evalModule(self: *ScriptEngine, code: []const u8, filename: []const u8) !zqjs.Value {
        const flags: c_int = @intCast(qjs.JS_EVAL_TYPE_MODULE);

        const c_code = self.allocator.dupeZ(u8, code) catch return error.OutOfMemory;
        defer self.allocator.free(c_code);

        const c_name = self.allocator.dupeZ(u8, filename) catch return error.OutOfMemory;
        defer self.allocator.free(c_name);

        // Raw call to avoid wrapper defaults if wrapper.eval forces GLOBAL
        const len = code.len;
        const val = qjs.JS_Eval(
            self.ctx.ptr,
            c_code.ptr,
            len,
            c_name.ptr,
            flags,
        );

        if (self.ctx.isException(val)) {
            _ = self.ctx.checkAndPrintException();
            return error.JSException;
        }
        return val;
    }

    /// Evaluates a script and marshals the returned value directly into a Zig struct.
    ///
    /// ⚠️ The script must return a value (not a Promise), evaluated with `.global`.
    pub fn evalAs(self: *ScriptEngine, comptime T: type, code: []const u8, filename: []const u8) !T {
        // 1. Evaluate in global scope to get the result of the last expression
        const val = try self.eval(code, filename, .global);

        // own the handle 'val', so we must free it after marshalling
        defer self.ctx.freeValue(val);

        // (Assumes T is a struct matching the JS object)
        return js_marshall.jsToZig(self.allocator, self.ctx, val, T);
    }

    /// Evaluates JS code that might return a Promise as .global
    ///
    /// Runs the event loop until completion, checks for rejections, and marshals the result with the given type `T` that must match the type returned from JS.
    pub fn evalAsyncAs(self: *ScriptEngine, allocator: std.mem.Allocator, comptime T: type, code: []const u8, name: []const u8) !T {
        const val = try self.eval(code, name, .global);
        defer self.ctx.freeValue(val);

        // Handle the "Sync" case
        if (!self.ctx.isPromise(val)) {
            return js_marshall.jsToZig(allocator, self.ctx, val, T);
        }

        //  Poll event loop until promise settles (don't wait for full drain —
        //  frameworks like Next.js leave timers/workers alive indefinitely).
        var poll_count: u32 = 0;
        const max_polls: u32 = 100_000;
        while (poll_count < max_polls) : (poll_count += 1) {
            const ps = self.ctx.promiseState(val);
            if (ps != .Pending) break;
            // Run one iteration of jobs + timers
            self.processJobs();
            _ = self.loop.processTimers() catch 0;
            _ = self.loop.processAsyncTasks();
            if (self.loop.curl_multi) |cm| {
                _ = cm.poll(0) catch .{ .running = 0, .completed = 0 };
            }
            self.loop.pollWorkers() catch {};
            // Yield CPU if nothing happened this iteration
            std.Thread.sleep(1_000_000); // 1ms
        }

        const state = self.ctx.promiseState(val);
        switch (state) {
            .Pending => {
                // deadlock
                std.debug.print("⚠️  Script finished but Promise is still PENDING.\n", .{});
                return error.JSPromiseStuck;
            },
            .Rejected => {
                const reason = self.ctx.promiseResult(val);
                defer self.ctx.freeValue(reason);

                // Diagnostic: identify the rejection value type
                if (self.ctx.isUndefined(reason)) {
                    std.debug.print("❌ JS Promise Rejected with: undefined\n", .{});
                    std.debug.print("   (catch block swallowed the error — check console output above)\n", .{});
                    return error.JSPromiseRejected;
                }

                // Clear any pending exception before converting to string
                const pending = self.ctx.getException();
                if (!self.ctx.isNull(pending)) self.ctx.freeValue(pending);

                // Try direct toString first
                if (self.ctx.toCString(reason)) |reason_str| {
                    defer self.ctx.freeCString(reason_str);
                    std.debug.print("❌ JS Promise Rejected: {s}\n", .{std.mem.span(reason_str)});
                } else |_| {
                    // Try .message then .stack for Error objects
                    const msg_prop = self.ctx.getPropertyStr(reason, "message");
                    defer self.ctx.freeValue(msg_prop);
                    if (self.ctx.toCString(msg_prop)) |msg_str| {
                        defer self.ctx.freeCString(msg_str);
                        std.debug.print("❌ JS Promise Rejected: {s}\n", .{std.mem.span(msg_str)});

                        const stack_prop = self.ctx.getPropertyStr(reason, "stack");
                        defer self.ctx.freeValue(stack_prop);
                        if (self.ctx.toCString(stack_prop)) |stack_str| {
                            defer self.ctx.freeCString(stack_str);
                            std.debug.print("   Stack: {s}\n", .{std.mem.span(stack_str)});
                        } else |_| {}
                    } else |_| {
                        if (self.ctx.isNull(reason)) {
                            std.debug.print("❌ JS Promise Rejected with: null\n", .{});
                        } else if (self.ctx.isObject(reason)) {
                            std.debug.print("❌ JS Promise Rejected with: [object] (toString failed)\n", .{});
                        } else {
                            std.debug.print("❌ JS Promise Rejected with: (unknown type)\n", .{});
                        }
                    }
                }
                return error.JSPromiseRejected;
            },
            .Fulfilled => {
                // 5. Success! Extract the value.
                const result = self.ctx.promiseResult(val);
                defer self.ctx.freeValue(result);

                // 6. Marshal the inner result to Zig
                return js_marshall.jsToZig(allocator, self.ctx, result, T);
            },
        }
    }

    // Helper to expose C functions easily
    pub fn registerFunction(self: *ScriptEngine, name: [:0]const u8, func: qjs.JSCFunction, args: c_int) !void {
        const global = self.ctx.getGlobalObject();
        defer self.ctx.freeValue(global);

        const js_fn = self.ctx.newCFunction(func, name, args);
        _ = try self.ctx.setPropertyStr(global, name, js_fn);
    }

    /// [helper] Resolves a path logically inside the sandbox.
    /// Returns a path strictly relative to the sandbox root (no leading '/').
    /// Caller owns the memory.
    fn resolvePathInSandbox(self: *ScriptEngine, base_dir: []const u8, user_path: []const u8) ![]u8 {
        // 1. Logically join paths relative to a fake root "/"
        // This collapses ".." segments safely.
        // e.g. "js/libs/" + "../../secrets" -> "/secrets"
        const resolved = try std.fs.path.resolve(self.allocator, &.{ "/", base_dir, user_path });
        defer self.allocator.free(resolved);

        // 2. Strip the fake root "/" to get a clean relative path
        // e.g. "/js/app.js" -> "js/app.js"
        const clean_path = if (std.mem.startsWith(u8, resolved, "/")) resolved[1..] else resolved;

        // 3. Safety Check: If it's empty, they are trying to open the directory itself
        if (clean_path.len == 0) return error.AccessDenied;

        return self.allocator.dupe(u8, clean_path);
    }

    /// Loads HTML content into the Engine, replacing the current global document.
    ///
    /// This is a low-level primitive for trusted content. It does NOT sanitize.
    /// For untrusted content, use `loadPage()` with `.sanitize = true`.
    ///
    /// Example:
    /// ```zig
    /// // Low-level: trusted content, manual control
    /// try engine.loadHTML(trusted_html);
    /// try engine.loadExternalStylesheets(".");
    /// try engine.executeScripts(allocator, ".");
    ///
    /// // High-level: automatic orchestration
    /// try engine.loadPage(html, .{ .sanitize = true, .base_dir = "." });
    /// ```
    pub fn loadHTML(self: *ScriptEngine, html: []const u8) !void {
        const bridge = self.dom;

        // Trusted content: init CSS BEFORE parsing so lexbor's event
        // watchers automatically pick up <style> and inline style=""
        // as elements are created during the parse.
        try z.initDocumentCSS(bridge.doc, true);
        try z.insertHTML(bridge.doc, html);
        // try z.applySanitization(
        //     self.allocator,
        //     z.documentRoot(bridge.doc).?,
        //     .strict,
        // );
        try z.loadStyleTags(self.allocator, bridge.doc, bridge.css_style_parser);
        // try z.attachStylesheet(bridge.doc, bridge.stylesheet);
    }

    /// Loads an external CSS string (like a .css file).
    ///
    /// This is a low-level primitive that does NOT sanitize CSS.
    /// For untrusted CSS, use the Sanitizer directly:
    /// ```zig
    /// var san = try Sanitizer.init(allocator, .{});
    /// defer san.deinit();
    /// try san.loadStylesheet(doc, untrusted_css);
    /// ```
    pub fn loadCSS(self: *ScriptEngine, css: []const u8) !void {
        const bridge = self.dom;

        try z.parseStylesheet(bridge.stylesheet, bridge.css_style_parser, css);

        // 2. Re-attach (or ensure it's attached)
        // Calling this again is usually safe/no-op if already attached,
        // or updates the document if Lexbor tracks versioning.
        try z.attachStylesheet(bridge.doc, bridge.stylesheet);
    }

    // =========================================================================
    // High-level Page Loading API
    // =========================================================================

    /// Load a complete HTML page with optional sanitization.
    ///
    /// This is the primary entry point for loading untrusted HTML content.
    /// Orchestrates: parse → sanitize (optional) → load CSS → execute scripts.
    ///
    /// Usage:
    /// ```zig
    /// // Trusted content (your own templates)
    /// try engine.loadPage(html, .{ .base_dir = "js/app" });
    ///
    /// // Untrusted content (user input, external sources)
    /// try engine.loadPage(user_html, .{
    ///     .sanitize = true,
    ///     .base_dir = "uploads",
    ///     .sanitizer_options = .{ .remove_scripts = true },
    /// });
    /// ```
    pub fn loadPage(self: *ScriptEngine, html: []const u8, options: LoadPageOptions) !void {
        const bridge = self.dom;

        // Store sanitization settings in RuntimeContext for use by innerHTML/outerHTML setters
        self.rc.sanitize_enabled = options.sanitize;
        self.rc.sanitize_options = options.sanitizer_options;

        if (options.sanitize) {
            // Create sanitizer for this operation
            var san = try Sanitizer.init(self.allocator, options.sanitizer_options);
            defer san.deinit();

            // 1. Parse HTML
            try z.insertHTML(bridge.doc, html);

            // 2. Sanitize the static DOM
            try san.sanitize(bridge.doc);

            // 3. Init CSS engine + load all styles from static DOM
            try z.initDocumentCSS(bridge.doc, true);
            if (options.load_stylesheets) {
                try self.loadExternalStylesheetsSanitized(options.base_dir, &san);
            }
            try z.loadStyleTags(self.allocator, bridge.doc, bridge.css_style_parser);
            try z.loadInlineStyles(self.allocator, bridge.doc);
        } else {
            // Trusted content: initDocumentCSS BEFORE parsing (watchers handle everything)
            try self.loadHTML(html);

            // Load external stylesheets
            if (options.load_stylesheets) {
                try self.loadExternalStylesheets(options.base_dir);
            }
        }

        // Execute scripts if requested
        if (options.execute_scripts) {
            try self.executeScripts(self.allocator, options.base_dir);
        }

        // Run event loop if requested
        if (options.run_loop) {
            try self.run();
        }
    }

    /// Load external stylesheets with sanitization.
    /// Called by loadPage() when sanitize=true.
    fn loadExternalStylesheetsSanitized(self: *ScriptEngine, base_dir: []const u8, san: *Sanitizer) !void {
        const links = try z.querySelectorAll(self.allocator, self.dom.doc, "link");
        defer self.allocator.free(links);

        for (links) |link_el| {
            var path_owned: ?[]u8 = null;
            var css_owned: ?[]u8 = null;

            defer {
                if (path_owned) |ptr| {
                    if (ptr.len > 0) self.allocator.free(ptr);
                }
                if (css_owned) |ptr| {
                    if (ptr.len > 0) self.allocator.free(ptr);
                }
            }

            const rel = z.getAttribute_zc(link_el, "rel") orelse continue;
            if (!std.mem.eql(u8, rel, "stylesheet")) continue;

            const href = z.getAttribute_zc(link_el, "href") orelse continue;

            var raw_css: []const u8 = undefined;

            if (isRemote(href)) {
                z.print("[Engine] Fetching remote CSS: {s}\n", .{href});
                const remote_css = self.get(href) catch |err| {
                    z.print("Failed to fetch CSS '{s}': {}\n", .{ href, err });
                    continue;
                };
                css_owned = remote_css;
                raw_css = remote_css;
            } else {
                // Resolve & Secure Check
                const rel_path = self.resolvePathInSandbox(base_dir, href) catch |err| {
                    z.print("Security: Blocked CSS path '{s}' (Error: {any})\n", .{ href, err });
                    continue;
                };
                path_owned = rel_path;

                const css_content = self.sandbox.dir.readFileAlloc(self.allocator, rel_path, 5 * 1024 * 1024) catch |err| {
                    z.print("Failed to load CSS '{s}': {any}\n", .{ rel_path, err });
                    continue;
                };
                css_owned = css_content;
                raw_css = css_content;
            }

            // Sanitize and load via Sanitizer
            try san.loadStylesheet(self.dom.doc, raw_css);
        }
    }

    pub fn loadFileModule(self: *ScriptEngine, path: []const u8) !void {
        const source = std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024 * 10) catch {
            return error.FileNotFound;
        };
        defer self.allocator.free(source);

        const c_path = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(c_path);

        const c_code = try self.allocator.dupeZ(u8, source);
        defer self.allocator.free(c_code);

        return self.runModule(c_code, c_path);
    }

    pub fn runModule(self: *ScriptEngine, code: []const u8, filename: []const u8) !void {
        const c_module = try self.allocator.dupeZ(u8, code);
        defer self.allocator.free(c_module);

        const c_name = try self.allocator.dupeZ(u8, filename);
        defer self.allocator.free(c_name);

        const module_obj = self.ctx.eval(c_module, c_name, .{
            .type = .module,
            .compile_only = true,
        }) catch |err| {
            _ = self.ctx.checkAndPrintException();
            return err;
        };

        const result = self.ctx.evalFunction(module_obj);
        defer self.ctx.freeValue(result);

        if (self.ctx.isException(result)) {
            _ = self.ctx.checkAndPrintException(); // Runtime error during execution
            return error.JSException;
        }
    }

    pub fn processJobs(self: *ScriptEngine) void {
        while (true) {
            // Run pending Jobs (Promises/Microtasks)
            // returns < 0 if exception, 0 if no jobs, > 0 if job executed
            var ctx: ?*qjs.JSContext = self.ctx.ptr;
            const ret = qjs.JS_ExecutePendingJob(self.rt.ptr, &ctx);
            if (ret <= 0) break;
        }
    }

    /// [host] Process all <script> tags in the document (Inline and Remote)
    const ScriptMeta = struct {
        filename: []const u8,
        filename_owned: ?[]u8,
        /// For inline scripts: borrowed pointer into Lexbor DOM (not owned)
        inline_code: ?[]const u8,
        is_module: bool,
        script_element: *z.HTMLElement,
    };

    pub fn executeScripts(self: *ScriptEngine, allocator: std.mem.Allocator, base_dir: []const u8) !void {
        const scripts = try z.querySelectorAll(
            self.allocator,
            self.dom.doc,
            "script",
        );
        defer allocator.free(scripts);
        if (scripts.len == 0) return;

        std.debug.print("[Engine] Found {d} scripts to execute\n", .{scripts.len});

        // ================================================================
        // PHASE 1: Collect metadata & submit parallel fetches
        // ================================================================
        const buffers = try ScriptBuffers.init(self.allocator, scripts.len);
        defer buffers.deinit();

        const metas = try self.allocator.alloc(ScriptMeta, scripts.len);
        defer {
            for (metas) |m| {
                if (m.filename_owned) |f| self.allocator.free(f);
            }
            self.allocator.free(metas);
        }

        var remote_count: u32 = 0;
        const cm = self.loop.getCurlMulti() catch null;

        for (scripts, 0..) |script, i| {
            metas[i] = .{
                .filename = "",
                .filename_owned = null,
                .inline_code = null,
                .is_module = false,
                .script_element = script,
            };

            const type_attr = z.getAttribute_zc(script, "type");

            // Skip non-executable script types (e.g. "application/json", "application/ld+json",
            // "text/template", "importmap"). Only execute: no type, "", "text/javascript", "module".
            if (type_attr) |t| {
                if (t.len > 0 and
                    !std.mem.eql(u8, t, "module") and
                    !std.mem.eql(u8, t, "text/javascript"))
                {
                    continue;
                }
            }

            metas[i].is_module = if (type_attr) |t| std.mem.eql(u8, t, "module") else false;

            // CASE A: External Script (<script src="...">)
            if (z.getAttribute_zc(script, "src")) |src| {
                const src_is_remote = isRemote(src);
                const base_is_remote = isRemote(base_dir);

                if (src_is_remote or base_is_remote) {
                    var fetch_url: []const u8 = src;

                    if (!src_is_remote) {
                        var parser = z.URLParser.create() catch continue;
                        defer parser.destroy();

                        var base_url = parser.parse(base_dir) catch continue;
                        defer base_url.destroy();

                        var target_url = parser.parseRelative(src, &base_url) catch continue;
                        defer target_url.destroy();

                        const resolved_str = target_url.toString(self.allocator) catch continue;
                        metas[i].filename_owned = resolved_str;
                        fetch_url = resolved_str;
                    } else {
                        metas[i].filename_owned = self.allocator.dupe(u8, src) catch continue;
                        fetch_url = metas[i].filename_owned.?;
                    }

                    metas[i].filename = fetch_url;
                    z.print("[Engine] Fetching remote script: {s}\n", .{fetch_url});

                    // Submit to curl_multi for parallel fetch
                    if (cm) |c| {
                        c.submitScriptRequest(self.ctx, fetch_url, buffers, @intCast(i)) catch |err| {
                            z.print("Failed to submit script fetch '{s}': {}\n", .{ fetch_url, err });
                            continue;
                        };
                        remote_count += 1;
                    } else {
                        // Fallback: synchronous fetch via std.http
                        const remote_code = self.get(fetch_url) catch |err| {
                            z.print("Failed to fetch script '{s}': {}\n", .{ fetch_url, err });
                            continue;
                        };
                        buffers.results[i] = remote_code;
                    }
                } else {
                    // Local sandbox script
                    const rel_path = self.resolvePathInSandbox(base_dir, src) catch |err| {
                        z.print("Security: Blocked script path '{s}' (Error: {any})\n", .{ src, err });
                        continue;
                    };
                    metas[i].filename_owned = rel_path;
                    metas[i].filename = rel_path;

                    const file_content = self.sandbox.dir.readFileAlloc(self.allocator, rel_path, 5 * 1024 * 1024) catch |err| {
                        z.print("Failed to load script '{s}' from sandbox: {any}\n", .{ rel_path, err });
                        continue;
                    };
                    buffers.results[i] = file_content;
                }
            }
            // CASE B: Inline Script
            else {
                const text = z.textContent_zc(z.elementToNode(script));
                if (text.len == 0) continue;

                metas[i].inline_code = text; // borrowed from Lexbor
                const name = std.fmt.allocPrint(self.allocator, "{s}/inline-script-{d}.js", .{ base_dir, i }) catch continue;
                metas[i].filename_owned = name;
                metas[i].filename = name;
            }
        }

        // Wait for all parallel fetches to complete
        if (cm) |c| {
            if (remote_count > 0) {
                std.debug.print("[Engine] Waiting for {d} parallel script fetches...\n", .{remote_count});
                while (buffers.pending_count > 0) {
                    _ = c.poll(100) catch break;
                }
                std.debug.print("[Engine] All remote scripts fetched\n", .{});
            }
        }

        // ================================================================
        // PHASE 2: Execute scripts in document order
        // ================================================================
        for (scripts, 0..) |script, i| {
            const meta = metas[i];

            // Get the code: either from buffers (remote/local file) or inline
            const code: []const u8 = if (meta.inline_code) |ic| ic else if (buffers.results[i]) |buf| buf else {
                // No code available (fetch failed or empty)
                continue;
            };
            const filename = if (meta.filename.len > 0) meta.filename else continue;

            // Set document.currentScript before execution
            const global = self.ctx.getGlobalObject();
            const doc_obj = self.ctx.getPropertyStr(global, "document");
            self.ctx.freeValue(global);

            if (meta.is_module) {
                if (!self.ctx.isUndefined(doc_obj)) {
                    _ = self.ctx.setPropertyStr(doc_obj, "currentScript", zqjs.NULL) catch {};
                }
                self.runModule(code, filename) catch |err| {
                    z.print("Module execution failed: {any}\n", .{err});
                };
            } else {
                if (!self.ctx.isUndefined(doc_obj)) {
                    const script_js = DOMBridge.wrapNode(self.ctx, z.elementToNode(script)) catch zqjs.NULL;
                    _ = self.ctx.setPropertyStr(doc_obj, "currentScript", script_js) catch {};
                }

                const val = self.eval(code, filename, .global) catch |err| {
                    z.print("Script execution failed: {any}\n", .{err});
                    if (!self.ctx.isUndefined(doc_obj)) {
                        _ = self.ctx.setPropertyStr(doc_obj, "currentScript", zqjs.NULL) catch {};
                    }
                    self.ctx.freeValue(doc_obj);
                    continue;
                };
                self.ctx.freeValue(val);

                if (!self.ctx.isUndefined(doc_obj)) {
                    _ = self.ctx.setPropertyStr(doc_obj, "currentScript", zqjs.NULL) catch {};
                }
            }
            self.ctx.freeValue(doc_obj);
            std.debug.print("[Engine] Script {d}/{d} done\n", .{ i + 1, scripts.len });
        }
        std.debug.print("[Engine] All {d} scripts executed\n", .{scripts.len});
    }

    /// Scans the DOM for <link rel="stylesheet"> and loads them.
    ///
    /// This is a low-level primitive that does NOT sanitize CSS.
    /// For untrusted content, use `loadPage()` with `.sanitize = true`,
    /// which calls `loadExternalStylesheetsSanitized()` internally.
    pub fn loadExternalStylesheets(self: *ScriptEngine, base_dir: []const u8) !void {
        const links = try z.querySelectorAll(self.allocator, self.dom.doc, "link");
        defer self.allocator.free(links);

        for (links) |link_el| {
            var path_owned: ?[]u8 = null;
            // var css_owned: ?[]u8 = null;
            var css_owned: ?[:0]u8 = null;

            defer {
                if (path_owned) |ptr| {
                    if (ptr.len > 0) self.allocator.free(ptr);
                }
                if (css_owned) |ptr| {
                    if (ptr.len > 0) self.allocator.free(ptr);
                }
            }

            const rel = z.getAttribute_zc(link_el, "rel") orelse continue;
            if (!std.mem.eql(u8, rel, "stylesheet")) continue;

            const href = z.getAttribute_zc(link_el, "href") orelse continue;
            const href_is_remote = isRemote(href);
            const base_is_remote = isRemote(base_dir);

            if (href_is_remote or base_is_remote) {
                var fetch_url: []const u8 = href;

                // If href is relative, resolve it against the remote base_dir
                if (!href_is_remote) {
                    var parser = z.URLParser.create() catch continue;
                    defer parser.destroy();

                    var base_url = parser.parse(base_dir) catch continue;
                    defer base_url.destroy();

                    var target_url = parser.parseRelative(href, &base_url) catch continue;
                    defer target_url.destroy();

                    const resolved_str = target_url.toString(self.allocator) catch continue;
                    path_owned = resolved_str;
                    fetch_url = resolved_str;
                }

                z.print("[Engine] Fetching remote CSS: {s}\n", .{fetch_url});
                const remote_css = self.get(fetch_url) catch |err| {
                    z.print("Failed to fetch CSS '{s}': {}\n", .{ fetch_url, err });
                    continue;
                };

                if (remote_css.len == 0) {
                    self.allocator.free(remote_css);
                    continue;
                }
                const safe_css = try self.allocator.dupeZ(u8, remote_css);
                self.allocator.free(remote_css);
                css_owned = safe_css;
                try self.loadCSS(safe_css);
            } else {

                // Resolve & Secure Check
                const rel_path = self.resolvePathInSandbox(base_dir, href) catch |err| {
                    z.print("Security: Blocked CSS path '{s}' (Error: {any})\n", .{ href, err });
                    continue;
                };
                path_owned = rel_path;

                const css_content = self.sandbox.dir.readFileAlloc(self.allocator, rel_path, 5 * 1024 * 1024) catch |err| {
                    z.print("Failed to load CSS '{s}': {any}\n", .{ rel_path, err });
                    continue;
                };
                // css_owned = css_content;
                // try self.loadCSS(css_content);
                const safe_css = try self.allocator.dupeZ(u8, css_content);
                self.allocator.free(css_content);
                css_owned = safe_css;
                try self.loadCSS(safe_css);
            }
        }
    }

    /// Synchronous HTTP GET (still used for CSS loading)
    pub fn get(self: *ScriptEngine, url: []const u8) ![]u8 {
        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();

        var client: std.http.Client = .{
            .allocator = self.allocator,
        };
        defer client.deinit();

        const response = try client.fetch(.{
            .method = .GET,
            .location = .{ .url = url },
            .response_writer = &allocating.writer,
        });

        std.debug.assert(response.status == .ok);
        return allocating.toOwnedSlice();
    }

    // Helper to check for remote URLs
    fn isRemote(url: []const u8) bool {
        return std.mem.startsWith(u8, url, "http:") or
            std.mem.startsWith(u8, url, "https:") or
            std.mem.startsWith(u8, url, "//");
    }
};

// ============================================================================
// Custom Fetch Binding - Builds Response object directly (no double JSON)
// ============================================================================

/// Payload for fetch
const FetchPayload = struct {
    url: []const u8,
};

/// Parser for fetch arguments
fn parseFetchArgs(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !FetchPayload {
    if (args.len < 1) {
        _ = ctx.throwTypeError("fetch() requires a URL");
        return error.InvalidArgs;
    }

    const url_str = try ctx.toZString(args[0]);
    defer ctx.freeZString(url_str);

    return FetchPayload{
        .url = try loop.allocator.dupe(u8, url_str),
    };
}

fn js_native_loadPage(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    // Extract the engine from the context backpack!
    const engine_ptr = rc.engine_ptr orelse {
        return qjs.JS_ThrowInternalError(ctx.ptr, "Fatal: ScriptEngine pointer lost");
    };
    const engine: *ScriptEngine = @ptrCast(@alignCast(engine_ptr));

    if (argc < 1) return qjs.JS_ThrowTypeError(ctx.ptr, "loadPage requires an HTML string");

    const html = ctx.toZString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(html);

    // Extract options from argv[1] if provided
    var base_dir_owned: ?[]u8 = null;
    defer if (base_dir_owned) |b| engine.allocator.free(b);

    var options = LoadPageOptions{
        .sanitize = false,
        .execute_scripts = true,
        .load_stylesheets = true,
    };

    if (argc >= 2 and ctx.isObject(argv[1])) {
        // base_dir: string — critical for resolving relative script src against remote URLs
        const base_dir_val = ctx.getPropertyStr(argv[1], "base_dir");
        defer ctx.freeValue(base_dir_val);
        if (!ctx.isUndefined(base_dir_val)) {
            if (ctx.toZString(base_dir_val)) |str| {
                defer ctx.freeZString(str);
                base_dir_owned = engine.allocator.dupe(u8, str) catch null;
                if (base_dir_owned) |owned| {
                    options.base_dir = owned;
                }
            } else |_| {}
        }

        // sanitize: bool
        const sanitize_val = ctx.getPropertyStr(argv[1], "sanitize");
        defer ctx.freeValue(sanitize_val);
        if (!ctx.isUndefined(sanitize_val)) {
            options.sanitize = qjs.JS_ToBool(ctx.ptr, sanitize_val) != 0;
        }

        // execute_scripts: bool
        const exec_val = ctx.getPropertyStr(argv[1], "execute_scripts");
        defer ctx.freeValue(exec_val);
        if (!ctx.isUndefined(exec_val)) {
            options.execute_scripts = qjs.JS_ToBool(ctx.ptr, exec_val) != 0;
        }

        // load_stylesheets: bool
        const css_val = ctx.getPropertyStr(argv[1], "load_stylesheets");
        defer ctx.freeValue(css_val);
        if (!ctx.isUndefined(css_val)) {
            options.load_stylesheets = qjs.JS_ToBool(ctx.ptr, css_val) != 0;
        }
    }

    engine.loadPage(html, options) catch |err| {
        std.debug.print("{any}\n", .{err});
    };

    return zqjs.UNDEFINED;
}

pub fn js_flush(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const rt = qjs.JS_GetRuntime(ctx_ptr);
    var ctx_out: ?*qjs.JSContext = ctx_ptr;

    // Drain all pending jobs (microtasks/promises)
    var iterations: u32 = 0;
    const max_iterations: u32 = 10000; // Safety limit
    const deadline = std.time.milliTimestamp() + 5000; // 5s wall-clock limit

    while (iterations < max_iterations) : (iterations += 1) {
        const ret = qjs.JS_ExecutePendingJob(rt, &ctx_out);
        if (ret <= 0) break; // No more jobs or error
        // Check wall-clock timeout every 100 iterations
        if (iterations % 100 == 0 and std.time.milliTimestamp() > deadline) {
            std.debug.print("[flush] wall-clock timeout after {d} iterations\n", .{iterations});
            break;
        }
    }

    return zqjs.UNDEFINED;
}
