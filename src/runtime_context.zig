const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = z.EventLoop;
const DOMBridge = z.DOMBridge;
const js_security = z.js_security;
const sanitizer_mod = z.sanitizer_mod;
pub const SanitizeOptions = sanitizer_mod.SanitizeOptions;

const Font = z.font.Font;
const default_font_data = @embedFile("fonts/Roboto-Regular.ttf");

pub const RuntimeContext = struct {
    allocator: std.mem.Allocator,
    loop: *EventLoop,
    dom_bridge: ?*anyopaque = null, // !!! circular ref with ScriptEngine, so use anyopaque
    engine_ptr: ?*anyopaque = null,
    sandbox: *js_security.Sandbox, // ScriptEngine owns this
    sandbox_root: []const u8, // for worker threads
    global_document: ?*z.HTMLDocument = null,
    // Worker-specific data (null for main thread)
    worker_core: ?*anyopaque = null,
    payload: ?*anyopaque = null, // generic pointer to pass in/out of callbacks
    blob_registry: std.StringHashMap(z.qjs.JSValue), // "blob:uuid" (owned string) -> Blob Object (JSValue)
    global_font: ?*Font = null,

    // Base directory for resolving relative asset paths (set by loadPage).
    // Always read via rc.base_dir. Owned copy lives in base_dir_heap (freed by setBaseDir/destroy).
    base_dir: []const u8 = ".",
    base_dir_heap: ?[]u8 = null,

    // Sanitization settings (set by loadPage when sanitize=true)
    // When enabled, innerHTML/outerHTML will sanitize content before insertion
    sanitize_enabled: bool = false,
    sanitize_options: SanitizeOptions = .{},

    // Central Registry of Class IDs for this Runtime
    // Zig struct -> Opaque pointer -> QuickJS Class ID
    classes: struct {
        dom_node: zqjs.ClassID = 0,
        worker: zqjs.ClassID = 0,
        event_loop: zqjs.ClassID = 0,
        document_fragment: zqjs.ClassID = 0,
        html_element: zqjs.ClassID = 0,
        dom_parser: zqjs.ClassID = 0,
        document: zqjs.ClassID = 0,
        owned_document: zqjs.ClassID = 0,
        event: zqjs.ClassID = 0,
        css_style_decl: zqjs.ClassID = 0,
        dom_token_list: zqjs.ClassID = 0,
        dom_string_map: zqjs.ClassID = 0,
        blob: zqjs.ClassID = 0,
        file: qjs.JSClassID = 0,
        file_list: qjs.JSClassID = 0,
        reader_sync: zqjs.ClassID = 0,
        // reader_async: zqjs.ClassID = 0,
        form_data: zqjs.ClassID = 0,
        url: zqjs.ClassID = 0,
        url_search_params: zqjs.ClassID = 0,
        headers: zqjs.ClassID = 0,
        text_encoder: zqjs.ClassID = 0,
        text_decoder: zqjs.ClassID = 0,
        readable_stream: zqjs.ClassID = 0,
        readable_stream_reader: zqjs.ClassID = 0,
        writable_stream: zqjs.ClassID = 0,
        writable_stream_writer: zqjs.ClassID = 0,
        range: zqjs.ClassID = 0,
        tree_walker: zqjs.ClassID = 0,
        xml_serializer: zqjs.ClassID = 0,
        canvas: zqjs.ClassID = 0,
        html_canvas: zqjs.ClassID = 0,
        image: zqjs.ClassID = 0,
        html_image: zqjs.ClassID = 0,
        pdf_document: zqjs.ClassID = 0,
    } = .{},
    local_storage: std.StringHashMap([]const u8) = undefined,
    // for data coming from JS to Zig
    last_result: ?zqjs.Value = null,

    /// Install struct into JS Context
    /// Static Factory: Allocates, Initializes, and Installs the Context state.
    pub fn create(
        allocator: std.mem.Allocator,
        ctx: zqjs.Context,
        loop: *EventLoop,
        sandbox: *js_security.Sandbox,
        sandbox_root: []const u8,
    ) !*RuntimeContext {
        const self = try allocator.create(RuntimeContext);

        // Initialize fields (ensures .classes is zeroed)
        self.* = .{
            .allocator = allocator,
            .loop = loop,
            .classes = .{},
            .sandbox = sandbox,
            .sandbox_root = sandbox_root,
            .blob_registry = std.StringHashMap(z.qjs.JSValue).init(allocator),
            .local_storage = std.StringHashMap([]const u8).init(allocator),
            .global_font = null,
        };

        if (Font.init(allocator, default_font_data)) |font| {
            self.global_font = font;
        } else |_| {
            std.debug.print("⚠️ Failed to load embedded default font.\n", .{});
        }

        // Install into QuickJS immediately
        ctx.setContextOpaque(self);

        return self;
    }

    pub fn cleanUp(self: *RuntimeContext, ctx: zqjs.Context) void {
        var it = self.blob_registry.iterator();
        while (it.next()) |entry| {
            // Free the key string (Zig allocator)
            self.allocator.free(entry.key_ptr.*);

            //  Free the Blob Value (QuickJS refcount decrement)
            // !!! It brings the refcount to 0 so GC can collect it.
            ctx.freeValue(entry.value_ptr.*);
        }

        // empty the map
        self.blob_registry.clearAndFree();
    }

    /// Set base_dir, taking an owned copy. Frees the previous owned copy if any.
    pub fn setBaseDir(self: *RuntimeContext, dir: []const u8) void {
        if (self.base_dir_heap) |old| self.allocator.free(old);
        self.base_dir_heap = self.allocator.dupe(u8, dir) catch null;
        self.base_dir = self.base_dir_heap orelse ".";
    }

    /// Cleanup function
    pub fn destroy(self: *RuntimeContext) void {
        var it = self.blob_registry.iterator();
        while (it.next()) |entry| {
            // Free the "blob:..." string keys we allocated
            self.allocator.free(entry.key_ptr.*);
            // Note: We don't JS_FreeValue the values here because
            // the Runtime is usually destroyed before the RuntimeContext.
        }
        if (self.base_dir_heap) |b| self.allocator.free(b);
        if (self.global_font) |f| {
            f.deinit();
        }
        self.blob_registry.deinit();

        var ls_it = self.local_storage.iterator();
        while (ls_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.local_storage.deinit();

        self.allocator.destroy(self);
        // z.print("\n⌛️ RT destroyed --------\n\n", .{});
    }

    /// Retrieve this struct from the JS Context
    pub fn get(ctx: zqjs.Context) *RuntimeContext {
        const ptr = ctx.getContextOpaque(RuntimeContext);
        if (ptr == null) @panic("RuntimeContext not installed on Context!");
        return @ptrCast(@alignCast(ptr));
    }
};
