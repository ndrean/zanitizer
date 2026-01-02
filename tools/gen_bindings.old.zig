//! Build-time QuickJS binding generator
//! Generates type-safe wrappers using wrapper.zig types consistently
//!
//! Usage: zig run tools/gen_bindings.zig -- src/bindings_generated.zig

const std = @import("std");

const BindingSpec = struct {
    name: []const u8,
    zig_func_name: []const u8,
    kind: enum { static, method }, // static = on document, method = on prototype
    args: []const ArgType,
    return_type: ReturnType,
};

const ArgType = union(enum) {
    allocator, // std.mem.Allocator (retrieved from context, hidden from JS)

    // SOURCES
    this_element, // *HTMLElement from 'this'
    this_node, // *DomNode from 'this'
    element, // *HTMLElement from argv (passed as argument argv[i])
    node, // *DomNode from argv (passed as argument argv[i])
    document, // *HTMLDocument from global
    document_root, // *DomNode (root of document) from global

    // Primitives
    string, // []const u8
    int32, // i32
    uint32, // u32
    boolean, // bool
};

const ReturnType = union(enum) {
    void_type,
    element, // *HTMLElement
    optional_element, // ?*HTMLElement
    node, // *DomNode
    optional_node, // ?*DomNode
    string, // []const u8 (allocated, will be freed with allocator from args)
    optional_string, // ?[]const u8 (zero-copy, no allocator needed)
    int32, // i32
    uint32, // u32
    boolean, // bool

    error_void, // !void
    error_element, // !*HTMLElement
    error_node, // !*DomNode
    error_string, // ![]const u8
    error_document, // !*HTMLDocument
};

// ============================================================================
// API DEFINITION - Add bindings to 'root.zig' here
// ============================================================================
const api_functions = [_]BindingSpec{
    // ---------------------------------------
    // STATIC FUNCTIONS
    // ---------------------------------------
    // createElement(doc: *HTMLDocument, tag_name: []const u8) !*HTMLElement
    .{
        .name = "createElement",
        .zig_func_name = "createElement",
        .kind = .static,
        .args = &.{ .document, .string },
        .return_type = .error_element,
    },
    // JS: document.documentRoot() !*DomNode
    .{
        .name = "documentRoot",
        .zig_func_name = "documentRoot",
        .kind = .static,
        .args = &.{.document},
        .return_type = .optional_node,
    },

    // JS: document.bodyElement() !*HTMLElement
    .{
        .name = "bodyElement",
        .zig_func_name = "bodyElement",
        .kind = .static,
        .args = &.{.document},
        .return_type = .optional_element,
    },

    // JS: node.ownerDocument() !*HTMLDocument

    .{
        .name = "ownerDocument",
        .zig_func_name = "ownerDocument",
        .kind = .static,
        .args = &.{.this_node},
        .return_type = .error_document,
    },

    // JS: document.createTextNode(data: []const u8) !*DomNode
    .{
        .name = "createTextNode",
        .zig_func_name = "createTextNode",
        .kind = .static,
        .args = &.{ .document, .string },
        .return_type = .error_node, // a *DomNode
    },
    // Currently, `getElementById` starts the search from a given node, not from the document root. TODO: adda a static version that takes a document, extracts the root, and calls the existing function.
    // JS: document.getElementById(id: []const u8) ?*HTMLElement
    .{
        .name = "getElementById",
        .zig_func_name = "getElementById",
        .kind = .static,
        .args = &.{ .document_root, .string },
        .return_type = .optional_element, // Returns null if not found
    },
    // ---------------------------------------
    // METHODS (attached to DOMNode.prototype)
    // ---------------------------------------

    // appendChild(parent: *DomNode, child: *DomNode) void
    .{
        .name = "appendChild",
        .zig_func_name = "appendChild",
        .kind = .method,
        .args = &.{ .this_node, .node },
        .return_type = .void_type,
    },

    // JS: node.firstChild() ?*DomNode
    .{
        .name = "firstChild",
        .zig_func_name = "firstChild",
        .kind = .method,
        .args = &.{.this_node},
        .return_type = .optional_node,
    },

    // JS: node.parentNode() ?*DomNode
    .{
        .name = "parentNode",
        .zig_func_name = "parentNode",
        .kind = .method,
        .args = &.{.this_node},
        .return_type = .optional_node,
    },

    // JS: node.remove() void
    .{
        .name = "remove",
        .zig_func_name = "removeNode",
        .kind = .method,
        .args = &.{.this_node},
        .return_type = .void_type,
    },

    // JS: setAttribute(elem: *HTMLElement, name: []const u8, value: []const u8) ?*DomAttr
    // Returns ?*DomAttr but we don't need to wrap it
    .{
        .name = "setAttribute",
        .zig_func_name = "setAttribute",
        .kind = .method,
        .args = &.{ .this_element, .string, .string },
        .return_type = .void_type, // Treat as void (ignore optional return)
    },

    // JS: getAttribute(elem: *HTMLElement, name: []const u8) ?[]const u8
    .{
        .name = "getAttribute",
        .zig_func_name = "getAttribute_zc",
        .kind = .method,
        .args = &.{ .this_element, .string },
        .return_type = .optional_string, // zero-copy, returns null or string
    },
    // JS: removeAttribute(elem: *HTMLElement, name: []const u8) !void
    .{
        .name = "removeAttribute",
        .zig_func_name = "removeAttribute",
        .kind = .method,
        .args = &.{ .this_element, .string },
        .return_type = .error_void,
    },

    // textContent(allocator: Allocator, node: *DomNode) ![]const u8
    .{
        .name = "textContent",
        .zig_func_name = "textContent_zc",
        .kind = .method,
        .args = &.{.this_node},
        .return_type = .string,
    },
    // JS: el.setInnerHTML("...") - returns element for chaining but we discard it
    .{
        .name = "setInnerHTML",
        .zig_func_name = "setInnerHTML",
        .kind = .method,
        .args = &.{ .this_element, .string },
        .return_type = .error_element, // Returns the element but we could discard
    },
    // JS: el.innerHTML() ![]const u8
    .{
        .name = "innerHTML",
        .zig_func_name = "innerHTML",
        .kind = .method,
        .args = &.{ .allocator, .this_element },
        .return_type = .error_string,
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.debug.print("Usage: {s} <output_path>\n", .{args[0]});
        std.debug.print("Example: zig run tools/gen_bindings.zig -- src/bindings_generated.zig\n", .{});
        return error.InvalidArgs;
    }

    const out_path = args[1];

    std.debug.print("Generating bindings to: {s}\n", .{out_path});
    std.debug.print("Binding {d} functions...\n", .{api_functions.len});

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writeHeader(writer);
    for (api_functions) |spec| {
        try generateWrapper(writer, spec);
    }
    try writeFooter(writer);

    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = output.items });
    std.debug.print("✓ Generated {d} bindings successfully!\n", .{api_functions.len});
}

fn writeHeader(writer: anytype) !void {
    try writer.writeAll(
        \\// THIS FILE IS AUTO-GENERATED BY tools/gen_bindings.zig
        \\// DO NOT EDIT MANUALLY - Your changes will be overwritten!
        \\//
        \\// To regenerate: zig build gen-bindings
        \\
        \\const std = @import("std");
        \\const z = @import("root.zig");
        \\const w = @import("wrapper.zig");
        \\const qjs = z.qjs;
        \\const DOMBridge = @import("dom_bridge.zig").DOMBridge;
        \\
        \\// Helper to get allocator from context opaque pointer
        \\fn getAllocator(ctx_ptr: ?*qjs.JSContext) std.mem.Allocator {
        \\    const opaque_ptr = qjs.JS_GetContextOpaque(ctx_ptr);
        \\    const allocator_ptr: *std.mem.Allocator = @ptrCast(@alignCast(opaque_ptr));
        \\    return allocator_ptr.*;
        \\}
        \\
        \\
    );
}

fn countJSArgs(args: []const ArgType) u32 {
    var count: u32 = 0;
    for (args) |arg| {
        switch (arg) {
            .string, .int32, .uint32, .boolean, .element, .node => count += 1,
            .allocator, .document, .document_root, .this_element, .this_node => {},
        }
    }
    return count;
}

fn writeFooter(writer: anytype) !void {
    // Generate STATIC bindings installer (for document object)
    try writer.writeAll(
        \\
        \\// Install static bindings (document-level factories)
        \\pub fn installStaticBindings(ctx: ?*qjs.JSContext, doc_obj: qjs.JSValue) void {
        \\
    );

    for (api_functions) |spec| {
        if (spec.kind == .static) {
            const js_argc = countJSArgs(spec.args);
            try writer.print(
                \\    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "{s}", qjs.JS_NewCFunction(ctx, js_{s}, "{s}", {d}));
                \\
            , .{ spec.name, spec.name, spec.name, js_argc });
        }
    }

    try writer.writeAll("}\n\n");

    // Generate METHOD bindings installer (for prototype)
    try writer.writeAll(
        \\// Install method bindings (shared via prototype)
        \\pub fn installMethodBindings(ctx: ?*qjs.JSContext, proto: qjs.JSValue) void {
        \\
    );

    for (api_functions) |spec| {
        if (spec.kind == .method) {
            const js_argc = countJSArgs(spec.args);
            try writer.print(
                \\    _ = qjs.JS_SetPropertyStr(ctx, proto, "{s}", qjs.JS_NewCFunction(ctx, js_{s}, "{s}", {d}));
                \\
            , .{ spec.name, spec.name, spec.name, js_argc });
        }
    }

    try writer.writeAll("}\n");
}

fn generateWrapper(writer: anytype, spec: BindingSpec) !void {
    // C-compatible signature (required by QuickJS runtime)
    try writer.print(
        \\/// Generated wrapper for z.{s}
        \\pub fn js_{s}(
        \\    ctx_ptr: ?*qjs.JSContext,
        \\    this_val: qjs.JSValue,
        \\    argc: c_int,
        \\    argv: [*c]qjs.JSValue,
        \\) callconv(.c) qjs.JSValue {{
        \\    // Use wrapper types internally for type safety
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\
    , .{ spec.zig_func_name, spec.name });

    // Check argument count
    const expected_js_args = countJSArgs(spec.args);
    if (expected_js_args > 0) {
        try writer.print(
            \\    if (argc < {d}) return w.EXCEPTION; // Not enough arguments
            \\
        , .{expected_js_args});
    } else {
        try writer.writeAll(
            \\    _ = argc;
            \\    _ = argv;
            \\
        );
    }

    // Handle unused this_val if not needed
    const uses_this = blk: {
        for (spec.args) |arg| {
            if (arg == .this_element or arg == .this_node) break :blk true;
        }
        break :blk false;
    };
    if (!uses_this) {
        try writer.writeAll("    _ = this_val;\n");
    }

    // Handle unused ctx if not needed
    // ctx is used for: document/root lookup, string conversion, return values
    const uses_ctx = blk: {
        for (spec.args) |arg| {
            // ctx needed for document lookups
            if (arg == .document or arg == .document_root) break :blk true;
            // ctx needed for string args (toZString, freeZString)
            if (arg == .string) break :blk true;
        }
        // ctx needed for string/element return values
        switch (spec.return_type) {
            .string, .error_string, .optional_string => break :blk true,
            else => {},
        }
        break :blk false;
    };
    if (!uses_ctx) {
        try writer.writeAll("    _ = ctx;\n");
    }

    try writer.writeAll("\n");

    // Generate argument unpacking - track allocator for cleanup
    var js_arg_idx: u32 = 0;
    var allocator_var_name: ?[]const u8 = null;

    for (spec.args, 0..) |arg, i| {
        switch (arg) {
            .allocator => {
                try writer.print(
                    \\    const arg{d} = getAllocator(ctx_ptr);
                    \\
                , .{i});
                // Track allocator variable name for return value cleanup
                allocator_var_name = "arg";
            },

            .document => {
                try writer.print(
                    \\    // Get document from global scope
                    \\    const global{d} = ctx.getGlobalObject();
                    \\    defer ctx.freeValue(global{d});
                    \\    const doc_obj{d} = ctx.getPropertyStr(global{d}, "document");
                    \\    defer ctx.freeValue(doc_obj{d});
                    \\    const native_doc{d} = ctx.getPropertyStr(doc_obj{d}, "_native_doc");
                    \\    defer ctx.freeValue(native_doc{d});
                    \\    const doc_ptr{d} = qjs.JS_GetOpaque(native_doc{d}, z.dom_class_id.*);
                    \\    if (doc_ptr{d} == null) return w.EXCEPTION;
                    \\    const arg{d}: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr{d}));
                    \\
                , .{ i, i, i, i, i, i, i, i, i, i, i, i, i });
            },

            .document_root => {
                try writer.print(
                    \\    // Get document root node from global scope
                    \\    const global{d} = ctx.getGlobalObject();
                    \\    defer ctx.freeValue(global{d});
                    \\    const doc_obj{d} = ctx.getPropertyStr(global{d}, "document");
                    \\    defer ctx.freeValue(doc_obj{d});
                    \\    const native_doc{d} = ctx.getPropertyStr(doc_obj{d}, "_native_doc");
                    \\    defer ctx.freeValue(native_doc{d});
                    \\    const doc_ptr{d} = qjs.JS_GetOpaque(native_doc{d}, z.dom_class_id.*);
                    \\    if (doc_ptr{d} == null) return w.EXCEPTION;
                    \\    const doc{d}: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr{d}));
                    \\    const root{d} = z.documentRoot(doc{d});
                    \\    if (root{d} == null) return w.EXCEPTION;
                    \\    const arg{d} = root{d}.?;
                    \\
                , .{ i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i });
            },

            .this_element => {
                try writer.print(
                    \\    // Get native element from 'this' (class instance)
                    \\    const elem_ptr{d} = qjs.JS_GetOpaque(this_val, z.dom_class_id.*);
                    \\    if (elem_ptr{d} == null) return w.EXCEPTION;
                    \\    const arg{d}: *z.HTMLElement = @ptrCast(@alignCast(elem_ptr{d}));
                    \\
                , .{ i, i, i, i });
            },

            .this_node => {
                try writer.print(
                    \\    // Get native node from 'this' (class instance)
                    \\    const node_ptr{d} = qjs.JS_GetOpaque(this_val, z.dom_class_id.*);
                    \\    if (node_ptr{d} == null) return w.EXCEPTION;
                    \\    const arg{d}: *z.DomNode = @ptrCast(@alignCast(node_ptr{d}));
                    \\
                , .{ i, i, i, i });
            },

            .node => {
                try writer.print(
                    \\    // Get native node from JS argument
                    \\    const node_arg_ptr{d} = qjs.JS_GetOpaque(argv[{d}], z.dom_class_id.*);
                    \\    if (node_arg_ptr{d} == null) return w.EXCEPTION;
                    \\    const arg{d}: *z.DomNode = @ptrCast(@alignCast(node_arg_ptr{d}));
                    \\
                , .{ i, js_arg_idx, i, i, i });
                js_arg_idx += 1;
            },

            .string => {
                try writer.print(
                    \\    const arg{d} = ctx.toZString(argv[{d}]) catch return w.EXCEPTION;
                    \\    defer ctx.freeZString(arg{d});
                    \\
                , .{ i, js_arg_idx, i });
                js_arg_idx += 1;
            },

            .int32 => {
                try writer.print(
                    \\    const arg{d} = ctx.toInt32(argv[{d}]) catch return w.EXCEPTION;
                    \\
                , .{ i, js_arg_idx });
                js_arg_idx += 1;
            },

            .uint32 => {
                try writer.print(
                    \\    const arg{d} = ctx.toUint32(argv[{d}]) catch return w.EXCEPTION;
                    \\
                , .{ i, js_arg_idx });
                js_arg_idx += 1;
            },

            .boolean => {
                try writer.print(
                    \\    const arg{d} = ctx.toBool(argv[{d}]);
                    \\
                , .{ i, js_arg_idx });
                js_arg_idx += 1;
            },
        }
    }

    // Call the Zig function
    try writer.writeAll("\n    // Call native Zig function\n");

    const has_return = switch (spec.return_type) {
        .void_type, .error_void => false,
        else => true,
    };

    const is_error_union = switch (spec.return_type) {
        .error_void, .error_element, .error_node, .error_string => true,
        else => false,
    };

    // Check if setAttribute (returns optional but we ignore it)
    const discard_result = std.mem.eql(u8, spec.zig_func_name, "setAttribute");

    if (discard_result) {
        try writer.writeAll("    _ = ");
    } else if (has_return) {
        try writer.writeAll("    const result = ");
    } else {
        try writer.writeAll("    ");
    }

    // Build function call - simple and straightforward!
    try writer.print("z.{s}(", .{spec.zig_func_name});
    for (spec.args, 0..) |_, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("arg{d}", .{i});
    }
    try writer.writeAll(")");

    if (is_error_union) {
        try writer.writeAll(" catch return w.EXCEPTION;\n");
    } else {
        try writer.writeAll(";\n");
    }

    // Marshal return value
    try writer.writeAll("\n");
    switch (spec.return_type) {
        .void_type, .error_void => {
            try writer.writeAll("    return w.UNDEFINED;\n");
        },

        .element, .error_element => {
            try writer.writeAll(
                \\    return DOMBridge.wrapElement(ctx_ptr, result) catch w.EXCEPTION;
                \\
            );
        },

        .optional_element => {
            try writer.writeAll(
                \\    // Optional element (returns null if not found)
                \\    if (result) |elem| {
                \\        return DOMBridge.wrapElement(ctx_ptr, elem) catch w.EXCEPTION;
                \\    } else {
                \\        return w.NULL;
                \\    }
                \\
            );
        },

        .node, .error_node => {
            try writer.writeAll(
                \\    return DOMBridge.wrapNode(ctx_ptr, result) catch w.EXCEPTION;
                \\
            );
        },

        .optional_node => {
            try writer.writeAll(
                \\    // Optional node (returns null if not found)
                \\    if (result) |node| {
                \\        return DOMBridge.wrapNode(ctx_ptr, node) catch w.EXCEPTION;
                \\    } else {
                \\        return w.NULL;
                \\    }
                \\
            );
        },

        .string, .error_string => {
            // Find the allocator argument index for cleanup
            if (allocator_var_name) |_| {
                // Find which arg index was the allocator
                for (spec.args, 0..) |arg, i| {
                    if (arg == .allocator) {
                        try writer.print(
                            \\    // String was allocated by Zig - free with same allocator
                            \\    defer arg{d}.free(result);
                            \\    return ctx.newString(result);
                            \\
                        , .{i});
                        break;
                    }
                }
            } else {
                try writer.writeAll(
                    \\    // WARNING: String return without allocator - potential memory leak!
                    \\    return ctx.newString(result);
                    \\
                );
            }
        },

        .optional_string => {
            try writer.writeAll(
                \\    // Zero-copy optional string (returns null or JS string)
                \\    if (result) |str| {
                \\        return ctx.newString(str);
                \\    } else {
                \\        return w.NULL;
                \\    }
                \\
            );
        },

        .int32, .uint32 => {
            try writer.writeAll(
                \\    return ctx.newInt32(result);
                \\
            );
        },

        .boolean => {
            try writer.writeAll(
                \\    return ctx.newBool(result);
                \\
            );
        },

        .error_document => {
            try writer.writeAll(
                \\    // HTMLDocument - wrap as opaque object
                \\    const doc_obj = qjs.JS_NewObjectClass(ctx_ptr, @intCast(z.dom_class_id.*));
                \\    _ = qjs.JS_SetOpaque(doc_obj, @ptrCast(result));
                \\    return doc_obj;
                \\
            );
        },
    }

    try writer.writeAll("}\n\n");
}
