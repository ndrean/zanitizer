const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;

// Import your sub-systems
const EventLoop = @import("event_loop.zig").EventLoop;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const DOMBridge = @import("dom_bridge.zig").DOMBridge; // Assuming your DOM logic is here
const async_bindings = @import("async_bindings_generated.zig");
const JSWorker = @import("js_worker.zig");
const FetchBridge = @import("fetch_bridge.zig").FetchBridge;
const AsyncBridge = @import("async_bridge.zig");

pub const ScriptEngine = struct {
    allocator: std.mem.Allocator,
    rt: *zqjs.Runtime,
    ctx: zqjs.Context,
    loop: *EventLoop,
    rc: *RuntimeContext,
    dom: DOMBridge, // VALUE!! to own the DOMBridge struct so DOMBridge deinit its content and ScriptEngine

    /// Initialize the entire JS Environment on the heap
    pub fn init(allocator: std.mem.Allocator) !*ScriptEngine {
        const self = try allocator.create(ScriptEngine);
        self.allocator = allocator;
        errdefer allocator.destroy(self);

        // 1. Runtime & Context
        self.rt = try zqjs.Runtime.init(allocator);
        errdefer self.rt.deinit();

        self.rt.enableModuleLoader();

        self.ctx = zqjs.Context.init(self.rt);
        // (Optional: set allocator on ctx if wrapper needs it, but RCtx handles mostly)
        self.ctx.setAllocator(&self.allocator);
        errdefer self.ctx.deinit();

        // 2. Event Loop
        self.loop = try EventLoop.create(allocator, self.rt);
        errdefer self.loop.destroy();

        // 3. Runtime Context (The Glue)
        // Allocates, zeroes classes, and sets the opaque pointer
        self.rc = try RuntimeContext.create(allocator, self.ctx, self.loop);
        errdefer self.rc.destroy();

        self.dom = try DOMBridge.init(allocator, self.ctx);
        errdefer self.dom.deinit();

        self.rc.dom_bridge = @ptrCast(@alignCast(&self.dom));

        // Install Bridges (timers)
        try self.loop.install(self.ctx);
        // install DOM APIs
        // try self.dom.init();
        try self.dom.installAPIs(); // console, etc.
        // Worker class
        try JSWorker.registerWorkerClass(self.ctx);
        // Fetch Bridge
        try FetchBridge.install(self.ctx);

        // // 5. Install Async Worker Bindings
        // const global = self.ctx.getGlobalObject();
        // defer self.ctx.freeValue(global);

        // // Install custom fetch (builds Response object, no double JSON)
        // const fetch_fn = self.ctx.newCFunction(workers.js_fetch, "fetch", 1);
        // _ = try self.ctx.setPropertyStr(global, "fetch", fetch_fn);

        // // Install other async bindings (readFile, etc.)
        // const readFile_fn = self.ctx.newCFunction(async_bindings.js_readFile, "readFile", 1);
        // _ = try self.ctx.setPropertyStr(global, "readFile", readFile_fn);

        return self;
    }

    /// Tear down everything in the correct reverse order
    pub fn deinit(self: *ScriptEngine) void {
        // 1. Bridges first (release JS references)
        self.dom.deinit();

        // 2. Glue (release internal slots)
        self.rc.destroy();

        // 3. Loop (stops threads, frees tasks)
        self.loop.destroy();

        // 4. Context
        self.ctx.deinit();
        std.Thread.sleep(10 * std.time.ns_per_ms);

        // 5. Runtime (GC and destroy)
        self.rt.runGC();
        self.rt.deinit();

        // 6. Self
        self.allocator.destroy(self);
    }

    /// Run the Event Loop until completion (or until empty)
    pub fn run(self: *ScriptEngine) !void {
        while ((try self.rt.executePendingJob()) != null) {}
        try self.loop.run(.Script);
    }

    /// Evaluates code and returns the raw JS Value.
    /// ⚠️ The Caller OWNS this value and must free it with engine.ctx.freeValue(val).
    pub fn eval(self: *ScriptEngine, code: [:0]const u8, filename: [:0]const u8) !zqjs.Value {
        const val = self.ctx.eval(
            code,
            filename,
            .{ .type = .global },
        ) catch {
            // The exception is still in the context, print it before returning
            _ = self.ctx.checkAndPrintException();
            return error.JSException;
        };

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

        // 1. Serialize Zig Arg -> JSON String (Zero-Copy / No Leak)
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        try std.json.Stringify.value(arg_payload, .{ .whitespace = .indent_2 }, &out.writer);

        const z_parsed = try out.toOwnedSliceSentinel(0);
        defer self.allocator.free(z_parsed);
        const json_slice = z_parsed[0 .. z_parsed.len - 1];

        // 2. Parse JSON -> JS Object
        const arg_js = self.ctx.parseJSON(json_slice, "<arg>");
        defer self.ctx.freeValue(arg_js);
        if (self.ctx.isException(arg_js)) return error.SerializationFailed;

        // 3. Traversal Logic (The Refinement)
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
            // A. Check if the container is valid
            if (self.ctx.isUndefined(current) or self.ctx.isNull(current)) {
                self.ctx.freeValue(current);
                self.ctx.freeValue(parent);
                return error.FunctionNotFound;
            }

            // B. Get the next property
            // (We must dupe the part string because split returns a slice, but API needs null-terminated)
            const part_z = try self.allocator.dupeZ(u8, part);
            defer self.allocator.free(part_z);

            const next_val = self.ctx.getPropertyStr(current, part_z);

            // C. Shift Context
            // The old 'parent' is no longer needed (unless it was global, which we handle carefully)
            self.ctx.freeValue(parent);

            // The old 'current' becomes the new 'parent'
            parent = current;

            // The new property becomes 'current'
            current = next_val;
        }

        // 4. Verification
        const func = current;
        const this_obj = parent;

        // Ensure we clean up these references when we exit scope
        defer self.ctx.freeValue(func);
        defer self.ctx.freeValue(this_obj);

        if (!self.ctx.isFunction(func)) {
            // It might be a value (like document.title), not a function.
            // If you want to support *getting* values, you could return 'func' here directly.
            return error.FunctionNotFound;
        }

        // 5. Call Function (With correct 'this_obj'!)
        const args = [_]zqjs.Value{arg_js};
        const result_js = self.ctx.call(func, this_obj, &args);
        defer self.ctx.freeValue(result_js);

        if (self.ctx.isException(result_js)) {
            _ = self.ctx.checkAndPrintException();
            return error.JSException;
        }

        // 6. Deserialize Result (Deep Copy)
        const result_json = self.ctx.jsonStringifySimple(result_js) catch return error.SerializationFailed;
        defer self.ctx.freeValue(result_json);

        const result_str = self.ctx.toZString(result_json) catch return error.SerializationFailed;
        defer self.ctx.freeZString(result_str);

        const parsed = std.json.parseFromSlice(ResultType, self.allocator, result_str, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return error.DeserializationFailed;

        return parsed;
    }

    pub fn evalModule(self: *ScriptEngine, code: [:0]const u8, filename: [:0]const u8) !zqjs.Value {
        // Use JS_EVAL_TYPE_MODULE
        const flags: c_int = @intCast(qjs.JS_EVAL_TYPE_MODULE);

        // Raw call to avoid wrapper defaults if wrapper.eval forces GLOBAL
        const len = code.len;
        const val = qjs.JS_Eval(
            self.ctx.ptr,
            code.ptr,
            len,
            filename.ptr,
            flags,
        );

        if (self.ctx.isException(val)) {
            _ = self.ctx.checkAndPrintException();
            return error.JSException;
        }
        return val;
    }

    // Helper to expose C Functions easily
    pub fn registerFunction(self: *ScriptEngine, name: [:0]const u8, func: qjs.JSCFunction, args: c_int) !void {
        const global = self.ctx.getGlobalObject();
        defer self.ctx.freeValue(global);

        const js_fn = self.ctx.newCFunction(func, name, args);
        _ = try self.ctx.setPropertyStr(global, name, js_fn);
    }

    /// Loads HTML content into the Engine, replacing the current global document.
    pub fn loadHTML(self: *ScriptEngine, html: []const u8) !void {
        const new_doc = try z.parseHTML(self.allocator, html);

        // 2. Destroy the old document to prevent leaks
        // (DOMBridge owns the global doc, so we must clean up the old one)
        if (self.dom.doc != new_doc) {
            z.destroyDocument(self.dom.doc);
        }

        // 3. Update Zig References
        self.dom.doc = new_doc;
        self.rc.global_document = new_doc;

        // 4. Update the JavaScript 'window.document' reference
        // We must update the hidden '_native_doc' property to point to the new C struct.
        const global = self.ctx.getGlobalObject();
        defer self.ctx.freeValue(global);

        const doc_obj = self.ctx.getPropertyStr(global, "document");
        defer self.ctx.freeValue(doc_obj);

        // Create a new opaque handle for the new document.
        // CRITICAL: We use 'rc.classes.document' (NO Finalizer).
        // Why? Because 'self.dom' owns this document and will free it in deinit().
        // If we used 'owned_document' (With Finalizer), we would double-free it!
        // const new_handle = self.ctx.newObjectClass(self.rc.classes.document);
        // try self.ctx.setOpaque(new_handle, new_doc);

        // Perform the transplant
        // try self.ctx.setPropertyStr(doc_obj, "_native_doc", new_handle);

        try self.ctx.setOpaque(doc_obj, new_doc);
    }
};

// ============================================================================
// Custom Fetch Binding - Builds Response object directly (no double JSON)
// ============================================================================

/// Payload for custom fetch
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
