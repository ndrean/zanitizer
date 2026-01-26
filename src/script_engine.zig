const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const js_security = @import("js_security.zig");

// const isSafePath = security.isSafePath;
// const js_secure_module_normalize = security.js_secure_module_normalize;

// Import your sub-systems
const EventLoop = @import("event_loop.zig").EventLoop;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const DOMBridge = @import("dom_bridge.zig").DOMBridge; // Assuming your DOM logic is here
const async_bindings = @import("async_bindings_generated.zig");
const JSWorker = @import("js_worker.zig");
const FetchBridge = @import("js_fetch.zig").FetchBridge;
const AsyncBridge = @import("async_bridge.zig");

const TIMEOUT_MS: i64 = 5000;

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

    /// Initialize the entire JS Environment on the heap
    pub fn init(allocator: std.mem.Allocator, sandbox_root: []const u8) !*ScriptEngine {
        const self = try allocator.create(ScriptEngine);
        self.allocator = allocator;
        errdefer allocator.destroy(self);

        self.sandbox = try js_security.Sandbox.init(allocator, sandbox_root);
        errdefer self.sandbox.deinit();

        // Runtime & Context
        self.rt = try zqjs.Runtime.init(allocator);
        errdefer self.rt.deinit();
        self.rt.setMemoryLimit(16 * 1024 * 1024); // 16 MB
        self.rt.setGCThreshold(1024 * 1024); // 1MB before GC
        self.rt.setMaxStackSize(128 * 1024);

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
        // install DOM APIs
        try self.dom.installAPIs(); // console, etc.
        try JSWorker.registerWorkerClass(self.ctx);
        try FetchBridge.install(self.ctx);

        // Install other async bindings (readFile, etc.)
        // const readFile_fn = self.ctx.newCFunction(async_bindings.js_readFile, "readFile", 1);
        // _ = try self.ctx.setPropertyStr(global, "readFile", readFile_fn);

        // _ = self.ctx.eval(
        //     "Object.freeze(globalThis);",
        //     "<internal>",
        //     z.qjs.JS_EVAL_TYPE_GLOBAL,
        // );
        try self.disableUnsafeFeatures();
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
    }

    pub fn deinit(self: *ScriptEngine) void {
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

    // /// Extracts content from all inline <script> tags.
    // ///
    // /// Caller owns the returned slice and the strings inside it.
    // pub fn getC_Scripts(self: *ScriptEngine) ![][:0]const u8 {
    //     // 1. Find all script tags
    //     const scripts = try z.querySelectorAll(self.allocator, self.dom.doc, "script");
    //     defer self.allocator.free(scripts);

    //     var code_list: std.ArrayList([:0]const u8) = .empty;
    //     errdefer {
    //         for (code_list.items) |s| self.allocator.free(s);
    //         code_list.deinit(self.allocator);
    //     }

    //     for (scripts) |script_el| {
    //         // 2. Filter out external scripts (<script src="...">)
    //         if (z.hasAttribute(script_el, "src")) continue;

    //         // 3. Extract content
    //         // Note: z.elementToNode is needed if textContent expects a Node
    //         const node = z.elementToNode(script_el);
    //         const content = z.textContent_zc(node);

    //         // Only add if not empty
    //         if (content.len > 0) {
    //             const c_content = try self.allocator.dupeZ(u8, content);
    //             try code_list.append(self.allocator, c_content);
    //         }
    //     }

    //     return try code_list.toOwnedSlice(self.allocator);
    // }

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
        z.print("CONT---", .{});

        // 2. Strip the fake root "/" to get a clean relative path
        // e.g. "/js/app.js" -> "js/app.js"
        const clean_path = if (std.mem.startsWith(u8, resolved, "/")) resolved[1..] else resolved;

        // 3. Safety Check: If it's empty, they are trying to open the directory itself
        if (clean_path.len == 0) return error.AccessDenied;

        return self.allocator.dupe(u8, clean_path);
    }

    /// Loads HTML content into the Engine, replacing the current global document.
    pub fn loadHTML(self: *ScriptEngine, html: []const u8) !void {
        const bridge = self.dom;

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

    /// Loads an external CSS string (like a .css file)
    pub fn loadCSS(self: *ScriptEngine, css: []const u8) !void {
        const bridge = self.dom;

        try z.parseStylesheet(bridge.stylesheet, bridge.css_style_parser, css);

        // 2. Re-attach (or ensure it's attached)
        // Calling this again is usually safe/no-op if already attached,
        // or updates the document if Lexbor tracks versioning.
        try z.attachStylesheet(bridge.doc, bridge.stylesheet);
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

    /// [host] Process all <script> tags in the document (Inline and Remote)
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
            // CASE B: Inline Script
            else {
                const text = z.textContent_zc(z.elementToNode(script));
                if (text.len == 0) continue;

                code = text; // borrowed from Lexbor
                // virtual filename for stack
                const name = try std.fmt.allocPrint(self.allocator, "inline-script-{d}.js", .{i});
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
    }

    /// Scans the DOM for <link rel="stylesheet"> and loads them securely
    pub fn loadExternalStylesheets(self: *ScriptEngine, base_dir: []const u8) !void {
        const links = try z.querySelectorAll(self.allocator, self.dom.doc, "link");
        defer self.allocator.free(links);

        for (links) |link_el| {
            var path_owned: ?[]u8 = null;
            var css_owned: ?[]u8 = null;

            defer {
                if (path_owned) |ptr| self.allocator.free(ptr);
                if (css_owned) |ptr| self.allocator.free(ptr);
            }

            const rel = z.getAttribute_zc(link_el, "rel") orelse continue;
            if (!std.mem.eql(u8, rel, "stylesheet")) continue;

            const href = z.getAttribute_zc(link_el, "href") orelse continue;

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

            try self.loadCSS(css_content);
        }
    }

    // Helper to check for remote URLs
    fn isRemote(url: []const u8) bool {
        return std.mem.startsWith(u8, url, "http:") or
            std.mem.startsWith(u8, url, "https:") or
            std.mem.startsWith(u8, url, "//");
    }

    // // Helper to check LFI (Local File Inclusion)
    // fn isPathSafe(allocator: std.mem.Allocator, full_path: []const u8) bool {
    //     const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return false;
    //     defer allocator.free(cwd);
    //     return std.mem.startsWith(u8, full_path, cwd);
    // }
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

// ============================================================================

// fn js_secure_module_normalize(
//     ctx: ?*qjs.JSContext,
//     module_base_name: [*c]const u8,
//     module_name: [*c]const u8,
//     opaque_ptr: ?*anyopaque,
// ) callconv(.c) [*c]u8 {
//     const allocator_ptr: *std.mem.Allocator = @ptrCast(@alignCast(opaque_ptr));
//     const allocator = allocator_ptr.*;

//     // 1. Safety Checks
//     if (module_name == null) return null;
//     const name_slice = std.mem.span(module_name);

//     // 2. BLOCK REMOTE (SSRF Prevention)
//     if (std.mem.startsWith(u8, name_slice, "http:") or
//         std.mem.startsWith(u8, name_slice, "https:") or
//         std.mem.startsWith(u8, name_slice, "//"))
//     {
//         _ = qjs.JS_ThrowReferenceError(ctx, "Security: Remote imports blocked '%s'", module_name);
//         return null;
//     }

//     // 3. RESOLVE PATH (Fixes nested imports)
//     var resolved_path: []u8 = undefined;

//     // Logic: resolve(base_dir, requested_name)
//     // Note: std.fs.path.resolve returns an ABSOLUTE LOGICAL path
//     if (module_base_name) |base| {
//         const base_slice = std.mem.span(base);
//         // Ensure we have a valid directory from the base
//         const base_dir = if (base_slice.len > 0) std.fs.path.dirname(base_slice) orelse "." else ".";
//         resolved_path = std.fs.path.resolve(allocator, &.{ base_dir, name_slice }) catch return null;
//     } else {
//         resolved_path = std.fs.path.resolve(allocator, &.{name_slice}) catch return null;
//     }
//     defer allocator.free(resolved_path);

//     // 4. SANDBOX CHECK (LFI Prevention)
//     var is_safe = false;

//     if (std.fs.path.isAbsolute(resolved_path)) {
//         // CASE A: Absolute Path (e.g. /home/user/project/js/math.js)
//         // Must start with the CWD's absolute path.
//         if (std.process.getCwdAlloc(allocator)) |cwd| {
//             defer allocator.free(cwd);
//             if (std.mem.startsWith(u8, resolved_path, cwd)) {
//                 is_safe = true;
//             }
//         } else |_| {
//             // If we can't determine CWD, fail closed.
//             is_safe = false;
//         }
//     } else {
//         // CASE B: Relative Path (e.g. js/math.js)
//         // Must NOT start with ".." (which means escaping up).
//         // Note: 'resolve' collapses inner "..", so checking the prefix is sufficient.
//         if (!std.mem.startsWith(u8, resolved_path, "..")) {
//             is_safe = true;
//         }
//     }

//     if (!is_safe) {
//         _ = qjs.JS_ThrowReferenceError(ctx, "Security: Path traversal detected '%s'", resolved_path.ptr);
//         return null;
//     }

//     // 5. EXTENSION HANDLING
//     var final_path = resolved_path;
//     var final_path_owned: ?[]u8 = null;

//     // Check if exact file exists
//     const exact_exists = if (std.fs.cwd().access(final_path, .{})) |_| true else |_| false;

//     if (!exact_exists) {
//         // Try appending .js
//         const with_ext = std.fmt.allocPrint(allocator, "{s}.js", .{final_path}) catch return null;
//         if (std.fs.cwd().access(with_ext, .{}) == error.FileNotFound) {
//             allocator.free(with_ext);
//             // Both failed. Throw error so user knows WHY it failed.
//             _ = qjs.JS_ThrowReferenceError(ctx, "Module not found: '%s' (looked in %s)", module_name, final_path.ptr);
//             return null;
//         }
//         final_path = with_ext;
//         final_path_owned = with_ext;
//     }
//     defer if (final_path_owned) |p| allocator.free(p);

//     // 6. RETURN TO QUICKJS
//     return qjs.js_strndup(ctx, final_path.ptr, final_path.len);
// }
