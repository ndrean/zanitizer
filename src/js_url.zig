const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

// ============================================================================
// URL Class
// ============================================================================

pub const URLObject = struct {
    parent_allocator: std.mem.Allocator,
    parser: *z.URLParser,
    url: *z.URL,

    pub fn deinit(self: *URLObject) void {
        self.url.destroy();
        self.parser.destroy();
        self.parent_allocator.destroy(self.url);
        self.parent_allocator.destroy(self.parser);
        self.parent_allocator.destroy(self);
    }
};

fn js_URL_constructor(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (argc < 1) return ctx.throwTypeError("URL constructor requires at least 1 argument");

    const url_str = ctx.toZString(argv[0]) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(url_str);

    // Create URL object
    const url_obj = rc.allocator.create(URLObject) catch return ctx.throwOutOfMemory();
    errdefer rc.allocator.destroy(url_obj);

    url_obj.parent_allocator = rc.allocator;
    url_obj.parser = rc.allocator.create(z.URLParser) catch {
        rc.allocator.destroy(url_obj);
        return ctx.throwOutOfMemory();
    };
    errdefer rc.allocator.destroy(url_obj.parser);

    url_obj.parser.* = z.URLParser.create() catch {
        rc.allocator.destroy(url_obj.parser);
        rc.allocator.destroy(url_obj);
        return ctx.throwTypeError("Failed to create URL parser");
    };

    // Parse URL (with optional base)
    if (argc >= 2 and !ctx.isUndefined(argv[1])) {
        // The base can be a URL object OR a string!
        var base_url: ?*z.URL = null;
        var temp_parser: ?*z.URLParser = null;
        var temp_url: ?*z.URL = null;

        const base_ptr = qjs.JS_GetOpaque(argv[1], rc.classes.url);
        if (base_ptr != null) {
            // Path A: It's already a URL Object
            const base_url_obj: *URLObject = @ptrCast(@alignCast(base_ptr));
            base_url = base_url_obj.url;
        } else if (ctx.isString(argv[1])) {
            // Path B: It's a string. We must parse it temporarily!
            const base_str = ctx.toZString(argv[1]) catch return ctx.throwOutOfMemory();
            defer ctx.freeZString(base_str);

            temp_parser = rc.allocator.create(z.URLParser) catch return ctx.throwOutOfMemory();
            temp_parser.?.* = z.URLParser.create() catch return ctx.throwTypeError("Failed to create temp parser");

            temp_url = rc.allocator.create(z.URL) catch return ctx.throwOutOfMemory();
            temp_url.?.* = temp_parser.?.parse(base_str) catch return ctx.throwTypeError("Invalid base URL string");

            base_url = temp_url;
        } else {
            return ctx.throwTypeError("Second argument must be a URL object or a valid URL string");
        }

        url_obj.url = rc.allocator.create(z.URL) catch return ctx.throwOutOfMemory();

        // Perform the relative parsing
        url_obj.url.* = url_obj.parser.parseRelative(url_str, base_url.?) catch {
            // Cleanup temp allocations on failure
            if (temp_url) |tu| {
                tu.destroy();
                rc.allocator.destroy(tu);
            }
            if (temp_parser) |tp| {
                tp.destroy();
                rc.allocator.destroy(tp);
            }
            return ctx.throwTypeError("Invalid URL");
        };

        // Cleanup temp allocations on success
        if (temp_url) |tu| {
            tu.destroy();
            rc.allocator.destroy(tu);
        }
        if (temp_parser) |tp| {
            tp.destroy();
            rc.allocator.destroy(tp);
        }
    } else {
        // Parse absolute URL
        url_obj.url = rc.allocator.create(z.URL) catch {
            url_obj.parser.destroy();
            rc.allocator.destroy(url_obj.parser);
            rc.allocator.destroy(url_obj);
            return ctx.throwOutOfMemory();
        };

        url_obj.url.* = url_obj.parser.parse(url_str) catch {
            rc.allocator.destroy(url_obj.url);
            url_obj.parser.destroy();
            rc.allocator.destroy(url_obj.parser);
            rc.allocator.destroy(url_obj);
            return ctx.throwTypeError("Invalid URL");
        };
    }

    const proto = ctx.getClassProto(rc.classes.url);
    defer ctx.freeValue(proto);

    const obj = ctx.newObjectProtoClass(proto, rc.classes.url);
    _ = qjs.JS_SetOpaque(obj, url_obj);
    return obj;
}

fn js_URL_finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const obj_class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque(val, obj_class_id);
    if (ptr) |p| {
        const self: *URLObject = @ptrCast(@alignCast(p));
        self.deinit();
    }
}

// URL getters
fn js_URL_get_href(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url);
    if (ptr == null) return ctx.throwTypeError("Not a URL object");
    const self: *URLObject = @ptrCast(@alignCast(ptr));

    const str = self.url.toString(rc.allocator) catch return ctx.throwOutOfMemory();
    defer rc.allocator.free(str);

    return ctx.newString(str);
}

fn js_URL_get_protocol(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url);
    if (ptr == null) return ctx.throwTypeError("Not a URL object");
    const self: *URLObject = @ptrCast(@alignCast(ptr));

    const scheme = self.url.scheme();
    const protocol = std.fmt.allocPrint(rc.allocator, "{s}:", .{scheme}) catch return ctx.throwOutOfMemory();
    defer rc.allocator.free(protocol);

    return ctx.newString(protocol);
}

fn js_URL_get_username(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url);
    if (ptr == null) return ctx.throwTypeError("Not a URL object");
    const self: *URLObject = @ptrCast(@alignCast(ptr));

    return ctx.newString(self.url.username());
}

fn js_URL_get_password(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url);
    if (ptr == null) return ctx.throwTypeError("Not a URL object");
    const self: *URLObject = @ptrCast(@alignCast(ptr));

    return ctx.newString(self.url.password());
}

fn js_URL_get_hostname(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url);
    if (ptr == null) return ctx.throwTypeError("Not a URL object");
    const self: *URLObject = @ptrCast(@alignCast(ptr));

    const host_str = self.url.hostname(rc.allocator) catch return ctx.throwOutOfMemory();
    defer rc.allocator.free(host_str);

    return ctx.newString(host_str);
}

fn js_URL_get_port(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url);
    if (ptr == null) return ctx.throwTypeError("Not a URL object");
    const self: *URLObject = @ptrCast(@alignCast(ptr));

    if (self.url.hasPort()) {
        const port_str = std.fmt.allocPrint(rc.allocator, "{d}", .{self.url.port()}) catch return ctx.throwOutOfMemory();
        defer rc.allocator.free(port_str);
        return ctx.newString(port_str);
    }
    return ctx.newString("");
}

fn js_URL_get_pathname(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url);
    if (ptr == null) return ctx.throwTypeError("Not a URL object");
    const self: *URLObject = @ptrCast(@alignCast(ptr));

    return ctx.newString(self.url.pathname());
}

fn js_URL_get_search(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url);
    if (ptr == null) return ctx.throwTypeError("Not a URL object");
    const self: *URLObject = @ptrCast(@alignCast(ptr));

    const search = self.url.search();
    if (search.len > 0) {
        const with_q = std.fmt.allocPrint(rc.allocator, "?{s}", .{search}) catch return ctx.throwOutOfMemory();
        defer rc.allocator.free(with_q);
        return ctx.newString(with_q);
    }
    return ctx.newString("");
}

fn js_URL_get_hash(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url);
    if (ptr == null) return ctx.throwTypeError("Not a URL object");
    const self: *URLObject = @ptrCast(@alignCast(ptr));

    const hash = self.url.hash();
    if (hash.len > 0) {
        const with_hash = std.fmt.allocPrint(rc.allocator, "#{s}", .{hash}) catch return ctx.throwOutOfMemory();
        defer rc.allocator.free(with_hash);
        return ctx.newString(with_hash);
    }
    return ctx.newString("");
}

fn js_URL_toString(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_URL_get_href(ctx_ptr, this, 0, null);
}

// ============================================================================
// URLSearchParams Class
// ============================================================================

pub const URLSearchParamsObject = struct {
    parent_allocator: std.mem.Allocator,
    params: z.URLSearchParams,

    pub fn deinit(self: *URLSearchParamsObject) void {
        self.params.deinit();
        self.parent_allocator.destroy(self);
    }
};

fn js_URLSearchParams_constructor(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const params_obj = rc.allocator.create(URLSearchParamsObject) catch return ctx.throwOutOfMemory();
    errdefer rc.allocator.destroy(params_obj);

    params_obj.parent_allocator = rc.allocator;

    // Parse query string if provided
    if (argc > 0 and !ctx.isUndefined(argv[0])) {
        const query_str = ctx.toZString(argv[0]) catch {
            rc.allocator.destroy(params_obj);
            return ctx.throwOutOfMemory();
        };
        defer ctx.freeZString(query_str);

        // Strip leading '?' if present
        const clean_query = if (query_str.len > 0 and query_str[0] == '?')
            query_str[1..]
        else
            query_str;

        params_obj.params = z.URLSearchParams.init(rc.allocator, clean_query) catch {
            rc.allocator.destroy(params_obj);
            return ctx.throwTypeError("Failed to parse query string");
        };
    } else {
        params_obj.params = z.URLSearchParams.initEmpty(rc.allocator) catch {
            rc.allocator.destroy(params_obj);
            return ctx.throwOutOfMemory();
        };
    }

    const proto = ctx.getClassProto(rc.classes.url_search_params);
    defer ctx.freeValue(proto);

    const obj = ctx.newObjectProtoClass(proto, rc.classes.url_search_params);
    _ = qjs.JS_SetOpaque(obj, params_obj);
    return obj;
}

fn js_URLSearchParams_finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const obj_class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque(val, obj_class_id);
    if (ptr) |p| {
        const self: *URLSearchParamsObject = @ptrCast(@alignCast(p));
        self.deinit();
    }
}

fn js_URLSearchParams_append(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (argc < 2) return ctx.throwTypeError("append requires 2 arguments");

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url_search_params);
    if (ptr == null) return ctx.throwTypeError("Not a URLSearchParams object");
    const self: *URLSearchParamsObject = @ptrCast(@alignCast(ptr));

    const name = ctx.toZString(argv[0]) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(name);
    const value = ctx.toZString(argv[1]) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(value);

    self.params.append(name, value) catch return ctx.throwOutOfMemory();
    return zqjs.UNDEFINED;
}

fn js_URLSearchParams_delete(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (argc < 1) return ctx.throwTypeError("delete requires 1 argument");

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url_search_params);
    if (ptr == null) return ctx.throwTypeError("Not a URLSearchParams object");
    const self: *URLSearchParamsObject = @ptrCast(@alignCast(ptr));

    const name = ctx.toZString(argv[0]) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(name);

    self.params.delete(name);
    return zqjs.UNDEFINED;
}

fn js_URLSearchParams_get(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (argc < 1) return ctx.throwTypeError("get requires 1 argument");

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url_search_params);
    if (ptr == null) return ctx.throwTypeError("Not a URLSearchParams object");
    const self: *URLSearchParamsObject = @ptrCast(@alignCast(ptr));

    const name = ctx.toZString(argv[0]) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(name);

    if (self.params.get(name)) |value| {
        return ctx.newString(value);
    }
    return zqjs.NULL;
}

fn js_URLSearchParams_has(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (argc < 1) return ctx.throwTypeError("has requires 1 argument");

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url_search_params);
    if (ptr == null) return ctx.throwTypeError("Not a URLSearchParams object");
    const self: *URLSearchParamsObject = @ptrCast(@alignCast(ptr));

    const name = ctx.toZString(argv[0]) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(name);

    return ctx.newBool(self.params.has(name));
}

fn js_URLSearchParams_set(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (argc < 2) return ctx.throwTypeError("set requires 2 arguments");

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url_search_params);
    if (ptr == null) return ctx.throwTypeError("Not a URLSearchParams object");
    const self: *URLSearchParamsObject = @ptrCast(@alignCast(ptr));

    const name = ctx.toZString(argv[0]) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(name);
    const value = ctx.toZString(argv[1]) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(value);

    self.params.set(name, value) catch return ctx.throwOutOfMemory();
    return zqjs.UNDEFINED;
}

fn js_URLSearchParams_sort(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url_search_params);
    if (ptr == null) return ctx.throwTypeError("Not a URLSearchParams object");
    const self: *URLSearchParamsObject = @ptrCast(@alignCast(ptr));

    self.params.sort();
    return zqjs.UNDEFINED;
}

fn js_URLSearchParams_toString(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this, rc.classes.url_search_params);
    if (ptr == null) return ctx.throwTypeError("Not a URLSearchParams object");
    const self: *URLSearchParamsObject = @ptrCast(@alignCast(ptr));

    const str = self.params.toString(rc.allocator) catch return ctx.throwOutOfMemory();
    defer rc.allocator.free(str);

    return ctx.newString(str);
}

// === ObjectURL ============================================

pub fn js_createObjectURL(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx); //  access state

    if (argc < 1) return ctx.throwTypeError("Blob expected");
    const blob_val = argv[0];

    //  isBlob? (check ClassID)
    if (ctx.getOpaque2(blob_val, rc.classes.blob) == null) {
        return ctx.throwTypeError("Argument provided is not a Blob");
    }

    // 2. Generate UUID
    // (Simple random implementation, replace with std.rand or uuid lib if available)
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const uuid = bytes;

    const blob_url = std.fmt.allocPrint(rc.allocator, "blob:{x}", .{uuid}) catch return zqjs.EXCEPTION;
    // no defer free(blob_url) because the registry will own it now.

    // Store in Registry
    // !! Duplicate value to keep Blob alive in GC while URL exists
    const blob_dup = ctx.dupValue(blob_val);

    rc.blob_registry.put(blob_url, blob_dup) catch {
        rc.allocator.free(blob_url);
        ctx.freeValue(blob_dup);
        return ctx.throwError();
    };

    return ctx.newString(blob_url);
}

/// static URL.revokeObjectURL(url)
pub fn js_revokeObjectURL(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (argc < 1) return zqjs.UNDEFINED;

    const url_str = ctx.toZString(argv[0]) catch return zqjs.UNDEFINED;
    defer ctx.freeZString(url_str);

    // Remove from registry
    if (rc.blob_registry.fetchRemove(url_str)) |entry| {
        // Free key  = string  allocated in createObjectURL
        rc.allocator.free(entry.key);
        // Free JS reference (allowing Blob to be GC'd)
        ctx.freeValue(entry.value);
    }

    return zqjs.UNDEFINED;
}
// === Installation ====================================

pub const URLBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const rc = RuntimeContext.get(ctx);
        const rt = ctx.getRuntime();

        // Register URL class
        if (rc.classes.url == 0) {
            rc.classes.url = rt.newClassID();
            try rt.newClass(rc.classes.url, .{ .class_name = "URL", .finalizer = js_URL_finalizer });
        }

        const url_proto = ctx.newObject();

        // Install getters
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "href");
            defer qjs.JS_FreeAtom(ctx.ptr, atom);
            const get_fn = ctx.newCFunction(js_URL_get_href, "get_href", 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, url_proto, atom, get_fn, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "protocol");
            defer qjs.JS_FreeAtom(ctx.ptr, atom);
            const get_fn = ctx.newCFunction(js_URL_get_protocol, "get_protocol", 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, url_proto, atom, get_fn, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "username");
            defer qjs.JS_FreeAtom(ctx.ptr, atom);
            const get_fn = ctx.newCFunction(js_URL_get_username, "get_username", 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, url_proto, atom, get_fn, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "password");
            defer qjs.JS_FreeAtom(ctx.ptr, atom);
            const get_fn = ctx.newCFunction(js_URL_get_password, "get_password", 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, url_proto, atom, get_fn, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "hostname");
            defer qjs.JS_FreeAtom(ctx.ptr, atom);
            const get_fn = ctx.newCFunction(js_URL_get_hostname, "get_hostname", 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, url_proto, atom, get_fn, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "port");
            defer qjs.JS_FreeAtom(ctx.ptr, atom);
            const get_fn = ctx.newCFunction(js_URL_get_port, "get_port", 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, url_proto, atom, get_fn, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "pathname");
            defer qjs.JS_FreeAtom(ctx.ptr, atom);
            const get_fn = ctx.newCFunction(js_URL_get_pathname, "get_pathname", 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, url_proto, atom, get_fn, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "search");
            defer qjs.JS_FreeAtom(ctx.ptr, atom);
            const get_fn = ctx.newCFunction(js_URL_get_search, "get_search", 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, url_proto, atom, get_fn, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "hash");
            defer qjs.JS_FreeAtom(ctx.ptr, atom);
            const get_fn = ctx.newCFunction(js_URL_get_hash, "get_hash", 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, url_proto, atom, get_fn, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }

        // Install toString method
        const toString_fn = ctx.newCFunction(js_URL_toString, "toString", 0);
        try ctx.setPropertyStr(url_proto, "toString", toString_fn);

        const url_ctor = ctx.newCFunctionConstructor(js_URL_constructor, "URL", 1);
        try ctx.setPropertyStr(url_ctor, "prototype", ctx.dupValue(url_proto));
        try ctx.setPropertyStr(url_proto, "constructor", ctx.dupValue(url_ctor));
        ctx.setClassProto(rc.classes.url, url_proto);

        const create_fn = ctx.newCFunction(js_createObjectURL, "createObjectURL", 1);
        try ctx.setPropertyStr(url_ctor, "createObjectURL", create_fn);

        const revoke_fn = ctx.newCFunction(js_revokeObjectURL, "revokeObjectURL", 1);
        try ctx.setPropertyStr(url_ctor, "revokeObjectURL", revoke_fn);

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        try ctx.setPropertyStr(global, "URL", url_ctor);

        // Register URLSearchParams class
        if (rc.classes.url_search_params == 0) {
            rc.classes.url_search_params = rt.newClassID();
            try rt.newClass(rc.classes.url_search_params, .{ .class_name = "URLSearchParams", .finalizer = js_URLSearchParams_finalizer });
        }

        const params_proto = ctx.newObject();

        const append_fn = ctx.newCFunction(js_URLSearchParams_append, "append", 2);
        try ctx.setPropertyStr(params_proto, "append", append_fn);

        const delete_fn = ctx.newCFunction(js_URLSearchParams_delete, "delete", 1);
        try ctx.setPropertyStr(params_proto, "delete", delete_fn);

        const get_fn = ctx.newCFunction(js_URLSearchParams_get, "get", 1);
        try ctx.setPropertyStr(params_proto, "get", get_fn);

        const has_fn = ctx.newCFunction(js_URLSearchParams_has, "has", 1);
        try ctx.setPropertyStr(params_proto, "has", has_fn);

        const set_fn = ctx.newCFunction(js_URLSearchParams_set, "set", 2);
        try ctx.setPropertyStr(params_proto, "set", set_fn);

        const sort_fn = ctx.newCFunction(js_URLSearchParams_sort, "sort", 0);
        try ctx.setPropertyStr(params_proto, "sort", sort_fn);

        const params_toString_fn = ctx.newCFunction(js_URLSearchParams_toString, "toString", 0);
        try ctx.setPropertyStr(params_proto, "toString", params_toString_fn);

        const params_ctor = ctx.newCFunctionConstructor(js_URLSearchParams_constructor, "URLSearchParams", 0);
        try ctx.setPropertyStr(params_ctor, "prototype", ctx.dupValue(params_proto));
        try ctx.setPropertyStr(params_proto, "constructor", ctx.dupValue(params_ctor));
        ctx.setClassProto(rc.classes.url_search_params, params_proto);

        try ctx.setPropertyStr(global, "URLSearchParams", params_ctor);
    }
};
