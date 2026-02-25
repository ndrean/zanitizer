//! TreeWalker API — DOM spec compliant pull-based tree traversal
//!
//! Usage from JS:
//!   const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
//!   while (walker.nextNode()) { ... walker.currentNode ... }

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const w = zqjs;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const DOMBridge = @import("dom_bridge.zig").DOMBridge;

// NodeFilter whatToShow bitmask constants (DOM spec)
const SHOW_ALL: u32 = 0xFFFFFFFF;
const SHOW_ELEMENT: u32 = 0x1;
const SHOW_ATTRIBUTE: u32 = 0x2;
const SHOW_TEXT: u32 = 0x4;
const SHOW_CDATA_SECTION: u32 = 0x8;
const SHOW_PROCESSING_INSTRUCTION: u32 = 0x40;
const SHOW_COMMENT: u32 = 0x80;
const SHOW_DOCUMENT: u32 = 0x100;
const SHOW_DOCUMENT_TYPE: u32 = 0x200;
const SHOW_DOCUMENT_FRAGMENT: u32 = 0x400;

pub const TreeWalkerObject = struct {
    root: *z.DomNode,
    current_node: *z.DomNode,
    what_to_show: u32,
};

// ============================================================================
// FILTER
// ============================================================================

fn matchesWhatToShow(node: *z.DomNode, what_to_show: u32) bool {
    if (what_to_show == SHOW_ALL) return true;
    const node_type = z.nodeType(node);
    const flag: u32 = switch (node_type) {
        .element => SHOW_ELEMENT,
        .attribute => SHOW_ATTRIBUTE,
        .text => SHOW_TEXT,
        .cdata_section => SHOW_CDATA_SECTION,
        .processing_instruction => SHOW_PROCESSING_INSTRUCTION,
        .comment => SHOW_COMMENT,
        .document => SHOW_DOCUMENT,
        .document_type => SHOW_DOCUMENT_TYPE,
        .document_fragment => SHOW_DOCUMENT_FRAGMENT,
        .unknown => 0,
    };
    return (what_to_show & flag) != 0;
}

// ============================================================================
// JS METHODS
// ============================================================================

/// TreeWalker.nextNode() — depth-first forward traversal
fn js_nextNode(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = getPtr(TreeWalkerObject, this_val, rc.classes.tree_walker) orelse
        return ctx.throwTypeError("Not a TreeWalker");

    var node: *z.DomNode = self.current_node;

    // 1. Try to descend into first child
    if (z.firstChild(node)) |child| {
        node = child;
        if (matchesWhatToShow(node, self.what_to_show)) {
            self.current_node = node;
            return DOMBridge.wrapNode(ctx, node) catch return w.EXCEPTION;
        }
        // Not accepted — but still descend to find accepted descendants
        return advanceFrom(ctx, self, node);
    }

    // 2. No children — try siblings, walking up as needed
    return advanceSibling(ctx, self, node);
}

/// Advance from a non-accepted node: try its children first, then siblings
fn advanceFrom(ctx: w.Context, self: *TreeWalkerObject, start: *z.DomNode) qjs.JSValue {
    var node = start;

    while (true) {
        // Try first child
        if (z.firstChild(node)) |child| {
            node = child;
            if (matchesWhatToShow(node, self.what_to_show)) {
                self.current_node = node;
                return DOMBridge.wrapNode(ctx, node) catch return w.EXCEPTION;
            }
            continue; // Keep descending
        }

        // No children — try siblings, walking up
        const result = advanceSiblingRaw(self, node);
        if (result) |found| {
            self.current_node = found;
            return DOMBridge.wrapNode(ctx, found) catch return w.EXCEPTION;
        }
        return w.NULL;
    }
}

/// Try nextSibling, walking up via parentNode until root
fn advanceSibling(ctx: w.Context, self: *TreeWalkerObject, start: *z.DomNode) qjs.JSValue {
    const result = advanceSiblingRaw(self, start);
    if (result) |found| {
        self.current_node = found;
        return DOMBridge.wrapNode(ctx, found) catch return w.EXCEPTION;
    }
    return w.NULL;
}

/// Core sibling/parent walk logic — returns next accepted node or null
fn advanceSiblingRaw(self: *TreeWalkerObject, start: *z.DomNode) ?*z.DomNode {
    var node = start;

    while (true) {
        // Try next sibling
        if (z.nextSibling(node)) |sibling| {
            node = sibling;
            if (matchesWhatToShow(node, self.what_to_show)) {
                return node;
            }
            // Not accepted — try descending into this sibling
            if (descendToAccepted(self, node)) |found| {
                return found;
            }
            // Continue to next sibling
            continue;
        }

        // No more siblings — walk up to parent
        const parent = z.parentNode(node) orelse return null;
        if (parent == self.root) return null; // Don't go above root
        node = parent;
    }
}

/// Descend depth-first from a node to find first accepted descendant
fn descendToAccepted(self: *TreeWalkerObject, start: *z.DomNode) ?*z.DomNode {
    var node = start;

    while (true) {
        if (z.firstChild(node)) |child| {
            node = child;
            if (matchesWhatToShow(node, self.what_to_show)) {
                return node;
            }
            continue;
        }
        // No children — try siblings within this subtree
        var current = node;
        while (true) {
            if (current == start) return null; // Back to where we started
            if (z.nextSibling(current)) |sibling| {
                node = sibling;
                if (matchesWhatToShow(node, self.what_to_show)) {
                    return node;
                }
                break; // Continue outer loop to descend into this sibling
            }
            current = z.parentNode(current) orelse return null;
            if (current == start) return null;
        }
    }
}

/// TreeWalker.previousNode() — reverse depth-first traversal
fn js_previousNode(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = getPtr(TreeWalkerObject, this_val, rc.classes.tree_walker) orelse
        return ctx.throwTypeError("Not a TreeWalker");

    var node: *z.DomNode = self.current_node;

    while (true) {
        // Try previous sibling
        if (z.previousSibling(node)) |sibling| {
            node = sibling;
            // Descend to last descendant
            while (z.lastChild(node)) |last| {
                node = last;
            }
            if (matchesWhatToShow(node, self.what_to_show)) {
                self.current_node = node;
                return DOMBridge.wrapNode(ctx, node) catch return w.EXCEPTION;
            }
            continue;
        }

        // No previous sibling — go to parent
        const parent = z.parentNode(node) orelse return w.NULL;
        if (parent == self.root) return w.NULL;
        node = parent;
        if (matchesWhatToShow(node, self.what_to_show)) {
            self.current_node = node;
            return DOMBridge.wrapNode(ctx, node) catch return w.EXCEPTION;
        }
    }
}

/// TreeWalker.parentNode() — walk to first accepted ancestor
fn js_parentNode(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = getPtr(TreeWalkerObject, this_val, rc.classes.tree_walker) orelse
        return ctx.throwTypeError("Not a TreeWalker");

    var node = self.current_node;
    while (true) {
        const parent = z.parentNode(node) orelse return w.NULL;
        if (parent == self.root) return w.NULL;
        node = parent;
        if (matchesWhatToShow(node, self.what_to_show)) {
            self.current_node = node;
            return DOMBridge.wrapNode(ctx, node) catch return w.EXCEPTION;
        }
    }
}

/// TreeWalker.firstChild() — first accepted child
fn js_firstChild(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = getPtr(TreeWalkerObject, this_val, rc.classes.tree_walker) orelse
        return ctx.throwTypeError("Not a TreeWalker");

    var child = z.firstChild(self.current_node) orelse return w.NULL;
    while (true) {
        if (matchesWhatToShow(child, self.what_to_show)) {
            self.current_node = child;
            return DOMBridge.wrapNode(ctx, child) catch return w.EXCEPTION;
        }
        child = z.nextSibling(child) orelse return w.NULL;
    }
}

/// TreeWalker.nextSibling() — next accepted sibling
fn js_nextSibling(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = getPtr(TreeWalkerObject, this_val, rc.classes.tree_walker) orelse
        return ctx.throwTypeError("Not a TreeWalker");

    var node = z.nextSibling(self.current_node) orelse return w.NULL;
    while (true) {
        if (matchesWhatToShow(node, self.what_to_show)) {
            self.current_node = node;
            return DOMBridge.wrapNode(ctx, node) catch return w.EXCEPTION;
        }
        node = z.nextSibling(node) orelse return w.NULL;
    }
}

/// Property getter: TreeWalker.currentNode
fn js_get_currentNode(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = getPtr(TreeWalkerObject, this_val, rc.classes.tree_walker) orelse
        return ctx.throwTypeError("Not a TreeWalker");
    return DOMBridge.wrapNode(ctx, self.current_node) catch return w.EXCEPTION;
}

/// Property setter: TreeWalker.currentNode
fn js_set_currentNode(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    // 1. Get the TreeWalker instance
    const self = getPtr(TreeWalkerObject, this_val, rc.classes.tree_walker) orelse
        return ctx.throwTypeError("Not a TreeWalker");

    if (argc < 1) return ctx.throwTypeError("Requires 1 argument");

    // 2. Unwrap the Node passed from JS
    const new_node = DOMBridge.unwrapNode(ctx, argv[0]) orelse
        return ctx.throwTypeError("Value must be a Node");

    // 3. Update the internal pointer!
    self.current_node = new_node;

    return w.UNDEFINED;
}

/// Property getter: TreeWalker.root
fn js_get_root(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = getPtr(TreeWalkerObject, this_val, rc.classes.tree_walker) orelse
        return ctx.throwTypeError("Not a TreeWalker");
    return DOMBridge.wrapNode(ctx, self.root) catch return w.EXCEPTION;
}

/// Property getter: TreeWalker.whatToShow
fn js_get_whatToShow(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = getPtr(TreeWalkerObject, this_val, rc.classes.tree_walker) orelse
        return ctx.throwTypeError("Not a TreeWalker");
    return qjs.JS_NewUint32(ctx.ptr, self.what_to_show);
}

// ===-------------

fn getPtr(comptime T: type, val: qjs.JSValue, class_id: qjs.JSClassID) ?*T {
    const ptr = qjs.JS_GetOpaque(val, class_id);
    if (ptr == null) return null;
    return @ptrCast(@alignCast(ptr));
}

fn tree_walker_finalizer(rt_ptr: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const opaque_ptr = qjs.JS_GetRuntimeOpaque(rt_ptr);
    if (opaque_ptr == null) return;

    const runtime: *zqjs.Runtime = @ptrCast(@alignCast(opaque_ptr));
    const allocator = runtime.allocator;

    const class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque(val, class_id);
    if (ptr) |p| {
        const tw: *TreeWalkerObject = @ptrCast(@alignCast(p));
        allocator.destroy(tw);
    }
}

pub const TreeWalkerBridge = struct {
    pub fn install(ctx: w.Context) !void {
        const rt_ptr = qjs.JS_GetRuntime(ctx.ptr);
        const rc = RuntimeContext.get(ctx);

        if (rc.classes.tree_walker == 0) {
            var class_id: qjs.JSClassID = 0;
            _ = qjs.JS_NewClassID(rt_ptr, &class_id);
            rc.classes.tree_walker = class_id;

            const class_def = qjs.JSClassDef{
                .class_name = "TreeWalker",
                .finalizer = tree_walker_finalizer,
            };
            _ = qjs.JS_NewClass(rt_ptr, class_id, &class_def);
        }
        const class_id = rc.classes.tree_walker;

        // Prototype with methods
        const proto = ctx.newObject();
        defer ctx.freeValue(proto);

        try ctx.setPropertyStr(proto, "nextNode", ctx.newCFunction(js_nextNode, "nextNode", 0));
        try ctx.setPropertyStr(proto, "previousNode", ctx.newCFunction(js_previousNode, "previousNode", 0));
        try ctx.setPropertyStr(proto, "parentNode", ctx.newCFunction(js_parentNode, "parentNode", 0));
        try ctx.setPropertyStr(proto, "firstChild", ctx.newCFunction(js_firstChild, "firstChild", 0));
        try ctx.setPropertyStr(proto, "nextSibling", ctx.newCFunction(js_nextSibling, "nextSibling", 0));

        // Property getters (currentNode, root, whatToShow)
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "currentNode");
            const get_fn = qjs.JS_NewCFunction2(ctx.ptr, js_get_currentNode, "get_currentNode", 0, qjs.JS_CFUNC_generic, 0);
            const set_fn = qjs.JS_NewCFunction2(ctx.ptr, js_set_currentNode, "set_currentNode", 1, qjs.JS_CFUNC_generic, 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, atom, get_fn, set_fn, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
            qjs.JS_FreeAtom(ctx.ptr, atom);
        }
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "root");
            const get_fn = qjs.JS_NewCFunction2(ctx.ptr, js_get_root, "get_root", 0, qjs.JS_CFUNC_generic, 0);
            const set_fn = w.UNDEFINED;
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, atom, get_fn, set_fn, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
            qjs.JS_FreeAtom(ctx.ptr, atom);
        }
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "whatToShow");
            const get_fn = qjs.JS_NewCFunction2(ctx.ptr, js_get_whatToShow, "get_whatToShow", 0, qjs.JS_CFUNC_generic, 0);
            const set_fn = w.UNDEFINED;
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, atom, get_fn, set_fn, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
            qjs.JS_FreeAtom(ctx.ptr, atom);
        }

        qjs.JS_SetClassProto(ctx.ptr, class_id, ctx.dupValue(proto));

        // Install NodeFilter constants on global
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        const nf = ctx.newObject();
        try ctx.setPropertyStr(nf, "FILTER_ACCEPT", qjs.JS_NewUint32(ctx.ptr, 1));
        try ctx.setPropertyStr(nf, "FILTER_REJECT", qjs.JS_NewUint32(ctx.ptr, 2));
        try ctx.setPropertyStr(nf, "FILTER_SKIP", qjs.JS_NewUint32(ctx.ptr, 3));
        try ctx.setPropertyStr(nf, "SHOW_ALL", qjs.JS_NewUint32(ctx.ptr, SHOW_ALL));
        try ctx.setPropertyStr(nf, "SHOW_ELEMENT", qjs.JS_NewUint32(ctx.ptr, SHOW_ELEMENT));
        try ctx.setPropertyStr(nf, "SHOW_ATTRIBUTE", qjs.JS_NewUint32(ctx.ptr, SHOW_ATTRIBUTE));
        try ctx.setPropertyStr(nf, "SHOW_TEXT", qjs.JS_NewUint32(ctx.ptr, SHOW_TEXT));
        try ctx.setPropertyStr(nf, "SHOW_CDATA_SECTION", qjs.JS_NewUint32(ctx.ptr, SHOW_CDATA_SECTION));
        try ctx.setPropertyStr(nf, "SHOW_PROCESSING_INSTRUCTION", qjs.JS_NewUint32(ctx.ptr, SHOW_PROCESSING_INSTRUCTION));
        try ctx.setPropertyStr(nf, "SHOW_COMMENT", qjs.JS_NewUint32(ctx.ptr, SHOW_COMMENT));
        try ctx.setPropertyStr(nf, "SHOW_DOCUMENT", qjs.JS_NewUint32(ctx.ptr, SHOW_DOCUMENT));
        try ctx.setPropertyStr(nf, "SHOW_DOCUMENT_TYPE", qjs.JS_NewUint32(ctx.ptr, SHOW_DOCUMENT_TYPE));
        try ctx.setPropertyStr(nf, "SHOW_DOCUMENT_FRAGMENT", qjs.JS_NewUint32(ctx.ptr, SHOW_DOCUMENT_FRAGMENT));
        try ctx.setPropertyStr(global, "NodeFilter", nf);
    }
};

/// document.createTreeWalker(root, whatToShow) — factory function
pub fn js_createTreeWalker(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    if (argc < 1) return ctx.throwTypeError("createTreeWalker requires at least 1 argument");

    const root_node = DOMBridge.unwrapNode(ctx, argv[0]) orelse
        return ctx.throwTypeError("Argument 1 must be a Node");

    // whatToShow defaults to SHOW_ALL
    const what_to_show: u32 = if (argc >= 2) blk: {
        break :blk ctx.toUint32(argv[1]) catch SHOW_ALL;
    } else SHOW_ALL;

    // Allocate TreeWalkerObject
    const rt = ctx.getRuntime();
    const self = rt.allocator.create(TreeWalkerObject) catch return ctx.throwOutOfMemory();
    self.* = .{
        .root = root_node,
        .current_node = root_node,
        .what_to_show = what_to_show,
    };

    // Create JS object with TreeWalker class
    const proto = qjs.JS_GetClassProto(ctx.ptr, rc.classes.tree_walker);
    const obj = qjs.JS_NewObjectProtoClass(ctx.ptr, proto, rc.classes.tree_walker);
    qjs.JS_FreeValue(ctx.ptr, proto);

    _ = qjs.JS_SetOpaque(obj, self);
    return obj;
}
