//! DOM Events Implementation: map JS_Event to Zig struct
const std = @import("std");
const z = @import("root.zig");
const w = @import("wrapper.zig");
const qjs = @import("root.zig").qjs;
const RuntimeContext = z.RuntimeContext;
const DOMBridge = z.DOMBridge;
const bindings = z.bindings;

// IMPORTS TO AVOID CYCLE (Don't import root.zig)

const DomNode = @import("root.zig").DomNode;

// --- FINALIZER ---
fn Finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const obj_class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque(val, obj_class_id);
    if (ptr) |p| {
        const ev_struct: *DomEvent = @ptrCast(@alignCast(p));
        ev_struct.deinit();
    }
}

pub const EventPhase = enum(u16) {
    NONE = 0,
    CAPTURING_PHASE = 1,
    AT_TARGET = 2,
    BUBBLING_PHASE = 3,
};

pub const DomEvent = struct {
    type: []const u8,
    bubbles: bool = false,
    cancelable: bool = false,

    // State
    phase: EventPhase = .NONE,
    target: ?*DomNode = null,
    current_target: ?*DomNode = null,

    // Flags
    stop_propagation: bool = false,
    stop_immediate: bool = false,
    default_prevented: bool = false,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, type_: []const u8, bubbles: bool, cancelable: bool) !*DomEvent {
        const self = try allocator.create(DomEvent);
        self.* = .{
            .allocator = allocator,
            .type = try allocator.dupe(u8, type_),
            .bubbles = bubbles,
            .cancelable = cancelable,
        };
        return self;
    }

    pub fn deinit(self: *DomEvent) void {
        self.allocator.free(self.type);
        self.allocator.destroy(self);
    }
};

/// [JS] new Event(type, eventInit)
pub fn constructor(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);

    if (argc < 1) return ctx.throwTypeError("Event constructor requires 'type' argument");

    // catch errors because this function is callconv(.c)
    const type_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(type_str);

    var bubbles = false;
    var cancelable = false;

    if (argc > 1) {
        const options = argv[1];
        if (ctx.isObject(options)) {
            // Check 'bubbles'
            const bubbles_val = ctx.getPropertyStr(options, "bubbles");
            if (ctx.isBool(bubbles_val)) {
                bubbles = ctx.toBool(bubbles_val) catch false;
                ctx.freeValue(bubbles_val);
            }
            // Check 'cancelable'
            const cancelable_val = ctx.getPropertyStr(options, "cancelable");
            if (ctx.isBool(cancelable_val)) {
                cancelable = ctx.toBool(cancelable_val) catch false;
                ctx.freeValue(cancelable_val);
            }
        }
    }

    // create Native Event Struct
    const rc = RuntimeContext.get(ctx);
    const ev = DomEvent.init(rc.allocator, type_str, bubbles, cancelable) catch return w.EXCEPTION;

    // Wrap in JS Object: create object using the Class ID registered in RuntimeContext
    const obj = ctx.newObjectClass(rc.classes.event);
    if (qjs.JS_IsException(obj)) {
        ev.deinit(); // Clean up if object creation failed
        return obj;
    }

    // Attach the native pointer to the JS object
    ctx.setOpaque(obj, ev) catch {
        ev.deinit(); // Clean up if attachment failed
        ctx.freeValue(obj);
        return w.EXCEPTION;
    };

    return obj;
}

// --- JS GETTERS ---

pub fn getType(ev: *DomEvent) []const u8 {
    return ev.type;
}

pub fn getBubbles(ev: *DomEvent) bool {
    return ev.bubbles;
}

// Lazy Import Helper
fn wrapNodeHelper(ctx: w.Context, node: ?*DomNode) !w.Value {
    if (node) |n| {
        // Use z.DomNode cast if types don't align perfectly,
        // but since they are opaque, @ptrCast works!
        return DOMBridge.wrapNode(ctx, @ptrCast(n));
    }
    return w.NULL;
}

pub fn getTarget(ev: *DomEvent) ?*DomNode {
    return ev.target;
}

pub fn getCurrentTarget(ev: *DomEvent) ?*DomNode {
    return ev.current_target;
}

pub fn stopPropagation(ev: *DomEvent) void {
    ev.stop_propagation = true;
}

pub fn preventDefault(ev: *DomEvent) void {
    if (ev.cancelable) {
        ev.default_prevented = true;
    }
}

pub fn getDefaultPrevented(ev: *DomEvent) bool {
    return ev.default_prevented;
}

pub const EventBridge = struct {
    pub fn install(ctx: w.Context) !void {
        const rc = RuntimeContext.get(ctx);
        const rt = ctx.getRuntime();

        if (rc.classes.event == 0) {
            rc.classes.event = rt.newClassID();
        }

        try rt.newClass(rc.classes.event, .{
            .class_name = "Event",
            .finalizer = Finalizer,
        });

        // Prototype
        const proto = ctx.newObject();
        bindings.installEventBindings(ctx.ptr, proto);
        ctx.setClassProto(rc.classes.event, proto);

        // Constructor
        const ctor = ctx.newCFunction2(constructor, "Event", 1, qjs.JS_CFUNC_constructor, 0);
        ctx.setConstructor(ctor, proto);

        // Global
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global); // TODO Leak??
        try ctx.setPropertyStr(global, "Event", ctor);
    }
};
