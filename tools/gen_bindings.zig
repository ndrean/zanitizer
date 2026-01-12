//! Build-time QuickJS binding generator
//! Generates type-safe wrappers using wrapper.zig types consistently
//! Refactored to use RuntimeContext for isolation.
//!
//! Usage: zig run tools/gen_bindings.zig -- src/bindings_generated.zig

const std = @import("std");

const BindingKind = enum { static, method, property };
const BindingSpec = struct {
    name: []const u8,
    kind: BindingKind, // static = on document, method = on prototype

    zig_func_name: []const u8 = "",
    args: []const ArgType = &.{},
    return_type: ReturnType = .void_type,

    getter: []const u8 = "", // e.g. "z.innerHTML"
    setter: []const u8 = "", // e.g. "z.setInnerHTML"
    prop_type: ReturnType = .void_type, // Type of the property (e.g. .string)
    prop_this: ArgType = .this_element, // What 'this' maps to (.this_element or .this_node)
};

const ArgType = union(enum) {
    allocator, // Uses rc.allocator
    context, // <--- Passes 'ctx' to Zig function
    callback, // <-- passes raw JS_Value
    dom_bridge,

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
    void_type, // Returns void (no error check)
    void_with_error, // Returns !void (generates 'catch return w.EXCEPTION')
    element, // *HTMLElement
    optional_element, // ?*HTMLElement
    node, // *DomNode
    optional_node, // ?*DomNode
    document, // *HTMLDocument (No error)

    string, // []const u8 (allocated, will be freed with allocator from args)
    optional_string, // ?[]const u8
    int32,
    uint32,
    boolean,

    // Special cases
    error_string, // ![]const u8
    error_document, // !*HTMLDocument
};

// Define the bindings to generate
const bindings = [_]BindingSpec{
    .{
        .name = "addEventListener",
        .zig_func_name = "z.addEventListener",
        .kind = .method,
        // Pass Context first, then 'this' (Node), then Event Name, then Function
        .args = &.{ .context, .dom_bridge, .this_node, .string, .callback },
        .return_type = .void_with_error,
    },
    // Optional: Dispatch for manual testing
    .{
        .name = "dispatchEvent",
        .zig_func_name = "z.dispatchEvent",
        .kind = .method,
        .args = &.{ .context, .dom_bridge, .this_node, .string },
        .return_type = .void_with_error,
    },
    // Document methods (Static on document object)
    .{
        .name = "createElement",
        .zig_func_name = "z.createElement",
        .kind = .static,
        .args = &.{ .document, .string },
        .return_type = .element, // Returns !*HTMLElement
    },
    .{
        .name = "documentRoot",
        .zig_func_name = "z.documentRoot",
        .kind = .static,
        .args = &.{.document},
        .return_type = .optional_node,
    },
    .{
        .name = "bodyElement",
        .zig_func_name = "z.bodyElement",
        .kind = .static,
        .args = &.{.document},
        .return_type = .optional_element,
    },
    .{
        .name = "ownerDocument",
        .zig_func_name = "z.ownerDocument",
        .kind = .static,
        .args = &.{.this_node},
        .return_type = .document,
    },
    .{
        .name = "createTextNode",
        .zig_func_name = "z.createTextNode",
        .kind = .static,
        .args = &.{ .document, .string },
        .return_type = .node, // Returns !*DomNode
    },
    .{
        .name = "getElementById",
        .zig_func_name = "z.getElementById",
        .kind = .static,
        .args = &.{ .document_root, .string },
        .return_type = .optional_element,
    },

    // Node/Element methods (Prototype methods)
    .{
        .name = "appendChild",
        .zig_func_name = "z.appendChild",
        .kind = .method,
        .args = &.{ .this_node, .node },
        .return_type = .void_type,
    },
    .{
        .name = "firstChild",
        .zig_func_name = "z.firstChild",
        .kind = .method,
        .args = &.{.this_node},
        .return_type = .optional_node,
    },
    .{
        .name = "parentNode",
        .zig_func_name = "z.parentNode",
        .kind = .method,
        .args = &.{.this_node},
        .return_type = .optional_node,
    },
    .{
        .name = "remove",
        .zig_func_name = "z.removeNode",
        .kind = .method,
        .args = &.{.this_node},
        .return_type = .void_type,
    },
    .{
        .name = "setAttribute",
        .zig_func_name = "z.setAttribute",
        .kind = .method,
        .args = &.{ .this_element, .string, .string },
        .return_type = .void_type,
    },
    .{
        .name = "getAttribute",
        .zig_func_name = "z.getAttribute_zc",
        .kind = .method,
        .args = &.{ .this_element, .string },
        .return_type = .optional_string,
    },
    .{
        .name = "removeAttribute",
        .zig_func_name = "z.removeAttribute",
        .kind = .method,
        .args = &.{ .this_element, .string },
        .return_type = .void_with_error,
    },
    .{
        .name = "textContent",
        .zig_func_name = "z.textContent_zc",
        .kind = .method,
        .args = &.{.this_node},
        .return_type = .string,
    },
    .{
        .name = "setContentAsText",
        .zig_func_name = "z.setContentAsText",
        .kind = .method,
        .args = &.{ .this_node, .string },
        .return_type = .void_with_error,
    },

    .{
        .name = "innerHTML",
        .kind = .property,
        .getter = "z.innerHTML",
        .setter = "z.setInnerHTML",
        .prop_type = .error_string, // returns ![]u8
        .prop_this = .this_element,
    },
    // Add more bindings: 'id', 'className', 'children', etc.
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.debug.print("Usage: {s} <output_file>\n", .{args[0]});
        return;
    }

    const output_file_path = args[1];

    // Use Allocating writer to build output in memory
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const stdout = &aw.writer;

    try stdout.writeAll(
        \\// THIS FILE IS AUTO-GENERATED BY tools/gen_bindings.zig
        \\// DO NOT EDIT MANUALLY
        \\
        \\const std = @import("std");
        \\const z = @import("root.zig");
        \\const w = @import("wrapper.zig");
        \\const qjs = z.qjs;
        \\const DOMBridge = @import("dom_bridge.zig").DOMBridge;
        \\const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
        \\
        \\
    );

    for (bindings) |binding| {
        try genFunction(stdout, binding);
    }

    // Generate installers
    try stdout.writeAll("\n\n// Install static bindings (document-level factories)\n");
    try stdout.writeAll("pub fn installStaticBindings(ctx: ?*qjs.JSContext, doc_obj: qjs.JSValue) void {\n");
    for (bindings) |binding| {
        if (binding.kind == .static) {
            try stdout.print("    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, \"{s}\", qjs.JS_NewCFunction(ctx, js_{s}, \"{s}\", {d}));\n", .{ binding.name, binding.name, binding.name, countJsArgs(binding.args) });
        }
    }
    try stdout.writeAll("}\n");

    try stdout.writeAll("\n// Install method bindings (shared via prototype)\n");
    try stdout.writeAll("pub fn installMethodBindings(ctx: ?*qjs.JSContext, proto: qjs.JSValue) void {\n");
    for (bindings) |binding| {
        if (binding.kind == .method) {
            // Install Method
            try stdout.print("    _ = qjs.JS_SetPropertyStr(ctx, proto, \"{s}\", qjs.JS_NewCFunction(ctx, js_{s}, \"{s}\", {d}));\n", .{ binding.name, binding.name, binding.name, countJsArgs(binding.args) });
        } else if (binding.kind == .property) {
            // Install Property
            try stdout.print(
                \\    {{
                \\        const atom = qjs.JS_NewAtom(ctx, "{s}");
                \\        const get_fn = qjs.JS_NewCFunction2(ctx, js_get_{s}, "get_{s}", 0, qjs.JS_CFUNC_getter, 0);
                \\        const set_fn = qjs.JS_NewCFunction2(ctx, js_set_{s}, "set_{s}", 1, qjs.JS_CFUNC_setter, 0);
                \\        _ = qjs.JS_DefinePropertyGetSet(ctx, proto, atom, get_fn, set_fn, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
                \\        qjs.JS_FreeAtom(ctx, atom);
                \\    }}
                \\
            , .{ binding.name, binding.name, binding.name, binding.name, binding.name });
        }
    }
    try stdout.writeAll("}\n");

    // Write the accumulated output to file
    const file = try std.fs.cwd().createFile(output_file_path, .{});
    defer file.close();
    try file.writeAll(aw.writer.buffer[0..aw.writer.end]);
}

fn countJsArgs(args: []const ArgType) usize {
    var count: usize = 0;
    for (args) |arg| {
        switch (arg) {
            .string, .int32, .uint32, .boolean, .element, .node => count += 1,
            else => {},
        }
    }
    return count;
}

fn genFunction(writer: *std.Io.Writer, func: BindingSpec) !void {

    // Handle property bindings
    // 1. HANDLE PROPERTIES
    if (func.kind == .property) {

        // --- GENERATE GETTER ------------------------------------------------
        try writer.print(
            \\
            \\// Property Getter for {s}
            \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
            \\    _ = argc; _ = argv;
            \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
            \\    const rc = RuntimeContext.get(ctx);
            \\
        , .{ func.name, func.name });

        // 1. Extract 'this'
        const cast_type = if (func.prop_this == .this_element) "*z.HTMLElement" else "*z.DomNode";
        try writer.print(
            \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.dom_node);
            \\    if (ptr == null) return w.EXCEPTION;
            \\    const this_arg: {s} = @ptrCast(@alignCast(ptr));
            \\
        , .{cast_type});

        // 2. Call Zig Getter
        if (func.prop_type == .error_string or func.prop_type == .string) {
            try writer.print("    const result = {s}(rc.allocator, this_arg)", .{func.getter});
        } else {
            try writer.print("    const result = {s}(this_arg)", .{func.getter});
        }

        // 3. Catch & Marshal
        if (func.prop_type == .error_string) {
            try writer.writeAll(" catch return w.EXCEPTION;\n");
            try writer.writeAll("    defer rc.allocator.free(result);\n");
            try writer.writeAll("    return ctx.newString(result);\n");
        } else if (func.prop_type == .string) {
            try writer.writeAll(";\n");
            try writer.writeAll("    defer rc.allocator.free(result);\n");
            try writer.writeAll("    return ctx.newString(result);\n");
        } else if (func.prop_type == .boolean) {
            try writer.writeAll(";\n    return ctx.newBool(result);\n");
        } else {
            try writer.writeAll(";\n    return w.UNDEFINED;\n");
        }
        try writer.writeAll("}\n");

        // --- GENERATE SETTER ------------------------------------------------
        try writer.print(
            \\
            \\// Property Setter for {s}
            \\pub fn js_set_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
            \\    _ = argc;
            \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
            \\    const rc = RuntimeContext.get(ctx);
            \\
        , .{ func.name, func.name });

        // 1. Extract 'this'
        try writer.print(
            \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.dom_node);
            \\    if (ptr == null) return w.EXCEPTION;
            \\    const this_arg: {s} = @ptrCast(@alignCast(ptr));
            \\
        , .{cast_type});

        // 2. Extract Value (From argv[0]!)
        if (func.prop_type == .error_string or func.prop_type == .string) {
            try writer.writeAll(
                \\    const val = argv[0];
                \\    const val_str = ctx.toZString(val) catch return w.EXCEPTION;
                \\    defer ctx.freeZString(val_str);
                \\
            );
            try writer.print("    {s}(this_arg, val_str) catch return w.EXCEPTION;\n", .{func.setter});
        } else if (func.prop_type == .boolean) {
            try writer.writeAll("    const val_bool = qjs.JS_ToBool(ctx_ptr, argv[0]) != 0;\n");
            try writer.print("    {s}(this_arg, val_bool);\n", .{func.setter});
        }

        try writer.writeAll("    return w.UNDEFINED;\n}\n");
        return; // DONE
    }

    // --- GENERATE FUNCTION BINDING ---
    try writer.print(
        \\
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(
        \\    ctx_ptr: ?*qjs.JSContext,
        \\    this_val: qjs.JSValue,
        \\    argc: c_int,
        \\    argv: [*c]qjs.JSValue,
        \\) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\
    , .{ func.zig_func_name, func.name });

    // 1. ARGUMENT CHECKS
    const js_arg_count = countJsArgs(func.args);
    if (js_arg_count > 0) {
        try writer.print("    if (argc < {d}) return w.EXCEPTION;\n", .{js_arg_count});
    }

    // 2. UNUSED VARS SUPPRESSION
    if (js_arg_count == 0) {
        try writer.writeAll("    _ = argc; _ = argv;\n");
    }
    var uses_this = false;
    var uses_ctx = false;
    for (func.args) |arg| {
        switch (arg) {
            .this_element, .this_node => uses_this = true,
            .string, .document, .document_root, .element, .node => uses_ctx = true,
            // Allocator removed from uses_ctx because we use rc.allocator now

            else => {},
        }
    }
    if (!uses_this) {
        try writer.writeAll("    _ = this_val;\n");
    }

    // Suppress ctx usage check if nothing uses it
    const return_needs_ctx = (func.return_type == .element or func.return_type == .node or
        func.return_type == .optional_element or func.return_type == .optional_node or
        func.return_type == .string or func.return_type == .error_string or func.return_type == .optional_string or
        func.return_type == .int32 or func.return_type == .uint32 or func.return_type == .boolean);

    // Note: 'rc' uses ctx, so ctx is almost always used now.
    // We'll keep the suppression logic just in case, but updated.
    if (!uses_ctx and !return_needs_ctx) {
        // try writer.writeAll("    _ = ctx;\n"); // Context is used for RuntimeContext.get(ctx)
    }

    // 3. EXTRACT ARGUMENTS
    var js_arg_idx: usize = 0;
    var allocator_idx: ?usize = null;

    for (func.args, 0..) |arg, i| {
        switch (arg) {
            .dom_bridge => {
                // rc is already defined at the top of the generated function
                try writer.print("    const arg{d}: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));\n", .{i});
            },
            .context => {
                try writer.print("    const arg{d} = ctx;\n", .{i});
                // No js_arg_idx increment (internal arg)
            },
            .callback => {
                try writer.print("    const arg{d} = argv[{d}];\n", .{ i, js_arg_idx });
                js_arg_idx += 1;
            },
            .allocator => {
                // [FIX] Use rc.allocator (Thread-local allocator)
                try writer.print("    const arg{d} = rc.allocator;\n", .{i});
                allocator_idx = i;
            },
            .this_element => {
                // [FIX] Use rc.classes.dom_node
                try writer.print(
                    \\    const elem_ptr{d} = qjs.JS_GetOpaque(this_val, rc.classes.dom_node);
                    \\    if (elem_ptr{d} == null) return w.EXCEPTION;
                    \\    const arg{d}: *z.HTMLElement = @ptrCast(@alignCast(elem_ptr{d}));
                    \\
                , .{ i, i, i, i });
            },
            .this_node => {
                // [FIX] Use rc.classes.dom_node
                try writer.print(
                    \\    const node_ptr{d} = qjs.JS_GetOpaque(this_val, rc.classes.dom_node);
                    \\    if (node_ptr{d} == null) return w.EXCEPTION;
                    \\    const arg{d}: *z.DomNode = @ptrCast(@alignCast(node_ptr{d}));
                    \\
                , .{ i, i, i, i });
            },
            .document => {
                // [FIX] Use rc.classes.dom_node
                try writer.print(
                    \\    const global{d} = ctx.getGlobalObject();
                    \\    defer ctx.freeValue(global{d});
                    \\    const doc_obj{d} = ctx.getPropertyStr(global{d}, "document");
                    \\    defer ctx.freeValue(doc_obj{d});
                    \\    const native_doc{d} = ctx.getPropertyStr(doc_obj{d}, "_native_doc");
                    \\    defer ctx.freeValue(native_doc{d});
                    \\    const doc_ptr{d} = qjs.JS_GetOpaque(native_doc{d}, rc.classes.dom_node);
                    \\    if (doc_ptr{d} == null) return w.EXCEPTION;
                    \\    const arg{d}: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr{d}));
                    \\
                , .{ i, i, i, i, i, i, i, i, i, i, i, i, i });
            },
            .document_root => {
                // [FIX] Use rc.classes.dom_node
                try writer.print(
                    \\    const global{d} = ctx.getGlobalObject();
                    \\    defer ctx.freeValue(global{d});
                    \\    const doc_obj{d} = ctx.getPropertyStr(global{d}, "document");
                    \\    defer ctx.freeValue(doc_obj{d});
                    \\    const native_doc{d} = ctx.getPropertyStr(doc_obj{d}, "_native_doc");
                    \\    defer ctx.freeValue(native_doc{d});
                    \\    const doc_ptr{d} = qjs.JS_GetOpaque(native_doc{d}, rc.classes.dom_node);
                    \\    if (doc_ptr{d} == null) return w.EXCEPTION;
                    \\    const doc{d}: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr{d}));
                    \\    const root{d} = z.documentRoot(doc{d});
                    \\    if (root{d} == null) return w.EXCEPTION;
                    \\    const arg{d} = root{d}.?;
                    \\
                , .{ i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i });
            },
            .element => {
                // [FIX] Use rc.classes.dom_node
                try writer.print(
                    \\    const elem_arg_ptr{d} = qjs.JS_GetOpaque(argv[{d}], rc.classes.dom_node);
                    \\    if (elem_arg_ptr{d} == null) return ctx.throwTypeError("Argument {d} must be a DOM Element");
                    \\    const arg{d}: *z.HTMLElement = @ptrCast(@alignCast(elem_arg_ptr{d}));
                    \\
                , .{ i, js_arg_idx, i, js_arg_idx, i, i });
                js_arg_idx += 1;
            },
            .node => {
                // [FIX] Use rc.classes.dom_node
                try writer.print(
                    \\    const node_arg_ptr{d} = qjs.JS_GetOpaque(argv[{d}], rc.classes.dom_node);
                    \\    if (node_arg_ptr{d} == null) return ctx.throwTypeError("Argument {d} must be a DOM Node");
                    \\    const arg{d}: *z.DomNode = @ptrCast(@alignCast(node_arg_ptr{d}));
                    \\
                , .{ i, js_arg_idx, i, js_arg_idx, i, i });
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
                    \\    var arg{d}: i32 = 0;
                    \\    if (qjs.JS_ToInt32(ctx_ptr, &arg{d}, argv[{d}]) != 0) return w.EXCEPTION;
                    \\
                , .{ i, i, js_arg_idx });
                js_arg_idx += 1;
            },
            .uint32 => {
                try writer.print(
                    \\    var arg{d}: u32 = 0;
                    \\    if (qjs.JS_ToUint32(ctx_ptr, &arg{d}, argv[{d}]) != 0) return w.EXCEPTION;
                    \\
                , .{ i, i, js_arg_idx });
                js_arg_idx += 1;
            },
            .boolean => {
                try writer.print("    const arg{d} = qjs.JS_ToBool(ctx_ptr, argv[{d}]) != 0;\n", .{ i, js_arg_idx });
                js_arg_idx += 1;
            },
        }
    }

    // 4. CALL NATIVE FUNCTION
    try writer.writeAll("    // Call native Zig function\n");

    // Special case: setAttribute returns a value we need to discard
    // TODO: refactor to return !void from Zig side
    const is_set_attribute = std.mem.eql(u8, func.name, "setAttribute");

    if (func.return_type != .void_type and func.return_type != .void_with_error) {
        try writer.writeAll("    const result = ");
    } else if (is_set_attribute and func.return_type == .void_type) {
        // Only discard if it's the legacy void_type setAttribute
        try writer.writeAll("    _ = ");
    } else {
        try writer.writeAll("    ");
    }

    // Call
    try writer.print("{s}(", .{func.zig_func_name});
    for (func.args, 0..) |_, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("arg{d}", .{i});
    }
    try writer.writeAll(")");

    // Catch errors for non-void returns that are errors
    if (func.return_type == .element or func.return_type == .node or func.return_type == .error_string or func.return_type == .error_document or func.return_type == .void_with_error) {
        try writer.writeAll(" catch return w.EXCEPTION");
    } else if (func.return_type == .void_type and !is_set_attribute) {
        // For void functions, only catch errors for specific functions we know return errors
        const is_remove_attr = std.mem.eql(u8, func.name, "removeAttribute");
        const is_set_content = std.mem.eql(u8, func.name, "setContentAsText");
        const is_set_inner = std.mem.eql(u8, func.name, "setInnerHTML");
        const is_add_evt = std.mem.eql(u8, func.name, "addEventListener");
        const is_dispatch = std.mem.eql(u8, func.name, "dispatchEvent");

        if (is_remove_attr or is_set_content or is_set_inner or is_add_evt or is_dispatch) {
            try writer.writeAll(" catch return w.EXCEPTION");
        }
        // if (is_remove_attr or is_set_content or is_set_inner) {
        //     try writer.writeAll(" catch return w.EXCEPTION");
        // }
    }
    try writer.writeAll(";\n\n");

    // 5. RETURN VALUE
    switch (func.return_type) {
        .void_type, .void_with_error => try writer.writeAll("    return w.UNDEFINED;\n"),

        .element => try writer.writeAll("    return DOMBridge.wrapElement(ctx, result) catch w.EXCEPTION;\n"),
        .node => try writer.writeAll("    return DOMBridge.wrapNode(ctx, result) catch w.EXCEPTION;\n"),

        .optional_element => try writer.writeAll("    if (result) |elem| { return DOMBridge.wrapElement(ctx, elem) catch w.EXCEPTION; } else { return w.NULL; }\n"),
        .optional_node => try writer.writeAll("    if (result) |node| { return DOMBridge.wrapNode(ctx, node) catch w.EXCEPTION; } else { return w.NULL; }\n"),

        .string, .error_string => {
            if (allocator_idx) |idx| {
                try writer.print("    defer arg{d}.free(result);\n    return ctx.newString(result);\n", .{idx});
            } else {
                try writer.writeAll("    return ctx.newString(result);\n");
            }
        },
        .optional_string => try writer.writeAll("    if (result) |str| { return ctx.newString(str); } else { return w.NULL; }\n"),
        .int32 => try writer.writeAll("    return ctx.newInt32(result);\n"),
        .uint32 => try writer.writeAll("    return ctx.newUint32(result);\n"),
        .boolean => try writer.writeAll("    return ctx.newBool(result);\n"),

        .document, .error_document => {
            // [FIX] Use rc.classes.dom_node instead of z.dom_class_id.*
            try writer.writeAll(
                \\    const doc_obj = qjs.JS_NewObjectClass(ctx_ptr, @intCast(rc.classes.dom_node));
                \\    _ = qjs.JS_SetOpaque(doc_obj, @ptrCast(result));
                \\    return doc_obj;
                \\
            );
        },
    }

    try writer.writeAll("}\n");
}
