const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;
const DOMBridge = @import("dom_bridge.zig").DOMBridge;

pub const RuntimeContext = struct {
    allocator: std.mem.Allocator,
    loop: *EventLoop,
    dom_bridge: ?*anyopaque = null, // !!! circular ref with ScriptEngine, so use anyopaque
    global_document: ?*z.HTMLDocument = null,

    // Worker-specific data (null for main thread)
    worker_core: ?*anyopaque = null,

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
    } = .{},
    // for data coming from JS to Zig
    last_result: ?zqjs.Value = null,

    /// Install this struct into the JS Context
    /// Static Factory: Allocates, Initializes, and Installs the Context state.
    pub fn create(allocator: std.mem.Allocator, ctx: zqjs.Context, loop: *EventLoop) !*RuntimeContext {
        const self = try allocator.create(RuntimeContext);

        // Initialize fields (ensures .classes is zeroed)
        self.* = .{
            .allocator = allocator,
            .loop = loop,
            .classes = .{},
        };

        // Install into QuickJS immediately
        ctx.setContextOpaque(self);

        return self;
    }

    /// Cleanup function
    pub fn destroy(self: *RuntimeContext) void {
        self.allocator.destroy(self);
    }

    /// Retrieve this struct from the JS Context
    pub fn get(ctx: zqjs.Context) *RuntimeContext {
        const ptr = ctx.getContextOpaque(RuntimeContext);
        if (ptr == null) @panic("RuntimeContext not installed on Context!");
        return @ptrCast(@alignCast(ptr));
    }
};
