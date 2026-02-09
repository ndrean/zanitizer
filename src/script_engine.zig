const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const js_security = @import("js_security.zig");
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

const Sanitizer = sanitizer_mod.Sanitizer;
const SanitizeOptions = sanitizer_mod.SanitizeOptions;

const TIMEOUT_MS: i64 = 5000;

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
            "eval",
            "Function",
            "WebAssembly", // If included in your build
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
        // Context
        self.ctx.deinit();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        // Runtime (GC and destroy)
        self.rt.runGC();
        self.rt.deinit();
        self.allocator.destroy(self);
    }

    /// Run Event Loop until completion (or until empty)
    pub fn run(self: *ScriptEngine) !void {
        while ((try self.rt.executePendingJob()) != null) {}
        try self.loop.run(.Script);
    }

    /// Evaluate code and returns the raw JS Value.
    /// ⚠️ The Caller OWNS this value and must free it with engine.ctx.freeValue(val).
    pub fn eval(self: *ScriptEngine, code: []const u8, filename: []const u8, eval_type: zqjs.Context.EvalType) !zqjs.Value {
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
            return error.JSException;
        };

        self.interrupt_deadline = 0; // reset deadline after eval

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

        //  executes pending jobs (microtasks) and timers.
        try self.run();

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

                const reason_str = self.ctx.toCString(reason) catch "Unknown Rejection";
                defer self.ctx.freeCString(reason_str);

                std.debug.print("❌ JS Promise Rejected: {s}\n", .{reason_str});
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
    pub fn executeScripts(self: *ScriptEngine, allocator: std.mem.Allocator, base_dir: []const u8) !void {
        const scripts = try z.querySelectorAll(
            self.allocator,
            self.dom.doc,
            "script",
        );
        defer allocator.free(scripts);
        if (scripts.len == 0) return;

        for (scripts, 0..) |script, i| {
            var code_owned: ?[]u8 = null;
            var filename_owned: ?[]u8 = null;

            defer {
                if (filename_owned) |f| self.allocator.free(f);
                if (code_owned) |c| self.allocator.free(c);
            }

            var filename: []const u8 = "";
            var code: []const u8 = "";

            // CASE A: External Script (<script src="...">)
            if (z.getAttribute_zc(script, "src")) |src| {
                if (isRemote(src)) {
                    if (isRemote(src)) {
                        z.print("[Engine] Fetching remote script: {s}\n", .{src});
                        const remote_code = self.get(src) catch |err| {
                            z.print("Failed to fetch script '{s}': {}\n", .{ src, err });
                            continue;
                        };
                        code_owned = remote_code;
                        code = remote_code;
                        filename = src;
                    }
                } else {
                    // resolve Path relative to Sandbox
                    const rel_path = self.resolvePathInSandbox(base_dir, src) catch |err| {
                        z.print("Security: Blocked script path '{s}' (Error: {any})\n", .{ src, err });
                        continue;
                    };

                    filename_owned = rel_path;
                    filename = rel_path;

                    const file_content = self.sandbox.dir.readFileAlloc(self.allocator, filename, 5 * 1024 * 1024) catch |err| {
                        z.print("Failed to load script '{s}' from sandbox: {any}\n", .{ filename, err });
                        continue;
                    };
                    code_owned = file_content;
                    code = file_content;
                }
            }
            // CASE B: Inline Script
            else {
                const text = z.textContent_zc(z.elementToNode(script));
                if (text.len == 0) continue;

                code = text; // borrowed from Lexbor
                // virtual filename for stack
                const name = try std.fmt.allocPrint(self.allocator, "{s}/inline-script-{d}.js", .{ base_dir, i });
                filename_owned = name;
                filename = name;
            }

            // EXECUTE
            const type_attr = z.getAttribute_zc(script, "type");
            const is_module = if (type_attr) |t| std.mem.eql(u8, t, "module") else false;

            if (is_module) {
                // Returns Promise (ignored here)
                self.runModule(code, filename) catch |err| {
                    z.print("Module execution failed: {any}\n", .{err});
                };
            } else {
                // Classic Script
                // We must use .global type
                const val = self.eval(code, filename, .global) catch |err| {
                    z.print("Script execution failed: {any}\n", .{err});
                    continue;
                };
                self.ctx.freeValue(val);
            }
        }
        // self.processJobs(); // force jobs after all scripts have been executed
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
            if (isRemote(href)) {
                z.print("[Engine] Fetching remote CSS: {s}\n", .{href});
                const remote_css = self.get(href) catch |err| {
                    z.print("Failed to fetch CSS '{s}': {}\n", .{ href, err });
                    continue;
                };

                std.debug.assert(remote_css.len > 0);
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

    /// TO BE REMOVED. NOT SAFE. Helper to fetch remote resources synchronously
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
