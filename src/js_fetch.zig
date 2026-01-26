const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const curl = @import("curl");

pub const FetchBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        const func = ctx.newCFunction(js_fetch, "fetch", 2);
        _ = try ctx.setPropertyStr(global, "fetch", func);
    }
};

const FetchContext = struct {
    url: []const u8,
    method: []const u8,
    body: ?[]u8 = null,
    headers: [][]const u8,
    status: i64 = 0,
    resp_body: ?[]u8 = null,
    resp_headers_lines: [][]u8,
    err_msg: ?[]u8 = null,

    fn deinit(self: *FetchContext, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.method);
        if (self.body) |b| allocator.free(b);
        if (self.err_msg) |e| allocator.free(e);
        for (self.headers) |h| allocator.free(h);
        allocator.free(self.headers);
        if (self.resp_body) |b| allocator.free(b);
        for (self.resp_headers_lines) |h| allocator.free(h);
        allocator.free(self.resp_headers_lines);
        allocator.destroy(self);
    }

    fn fail(self: *FetchContext, allocator: std.mem.Allocator, err: anytype) void {
        if (self.err_msg != null) return;
        self.err_msg = std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}) catch null;
    }
};

const FetchTask = struct {
    loop: *EventLoop,
    ctx: zqjs.Context,
    resolve: zqjs.Value,
    reject: zqjs.Value,
    data: *FetchContext,
};

fn js_fetch(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("fetch requires an URL string");

    const url_str = ctx.toCString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(url_str);

    const rc = RuntimeContext.get(ctx);
    const loop = rc.loop;

    const data = loop.allocator.create(FetchContext) catch return ctx.throwOutOfMemory();
    data.* = .{
        .url = loop.allocator.dupe(u8, std.mem.span(url_str)) catch return failAlloc(ctx, loop, data),
        .method = loop.allocator.dupe(u8, "GET") catch return failAlloc(ctx, loop, data),
        .headers = &[_][]const u8{},
        .resp_headers_lines = &[_][]u8{},
    };

    if (argc > 1 and ctx.isObject(argv[1])) {
        const opts = argv[1];

        // Method
        const method_prop = ctx.getPropertyStr(opts, "method");
        defer ctx.freeValue(method_prop);
        if (!ctx.isUndefined(method_prop)) {
            const m_str = ctx.toCString(method_prop) catch return failAlloc(ctx, loop, data);
            defer ctx.freeCString(m_str);
            loop.allocator.free(data.method);
            data.method = loop.allocator.dupe(u8, std.mem.span(m_str)) catch return failAlloc(ctx, loop, data);
        }

        // Body
        const body_prop = ctx.getPropertyStr(opts, "body");
        defer ctx.freeValue(body_prop);
        if (!ctx.isUndefined(body_prop) and !ctx.isNull(body_prop)) {
            var body_slice: []const u8 = "";
            var needs_free_cstr = false;
            var cstr_ptr: [*c]const u8 = undefined;
            if (ctx.isString(body_prop)) {
                cstr_ptr = ctx.toCString(body_prop) catch return failAlloc(ctx, loop, data);
                body_slice = std.mem.span(cstr_ptr);
                needs_free_cstr = true;
            } else {
                var len: usize = 0;
                const ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &len, body_prop);
                if (ptr != null) body_slice = ptr[0..len];
            }
            if (body_slice.len > 0) {
                data.body = loop.allocator.dupe(u8, body_slice) catch return failAlloc(ctx, loop, data);
            }
            if (needs_free_cstr) ctx.freeCString(cstr_ptr);
        }

        // Headers
        const headers_prop = ctx.getPropertyStr(opts, "headers");
        defer ctx.freeValue(headers_prop);
        if (ctx.isObject(headers_prop)) {
            var tab: ?[*]qjs.JSPropertyEnum = undefined;
            var len: u32 = 0;
            const flags = qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_ENUM_ONLY;

            if (qjs.JS_GetOwnPropertyNames(ctx.ptr, &tab, &len, headers_prop, flags) == 0) {
                if (tab) |props| {
                    var list: std.ArrayList([]const u8) = .empty;
                    defer list.deinit(loop.allocator);

                    var i: u32 = 0;
                    while (i < len) : (i += 1) {
                        const atom = props[i].atom;
                        const val = qjs.JS_GetProperty(ctx.ptr, headers_prop, atom);
                        const key_cstr = qjs.JS_AtomToCString(ctx.ptr, atom);
                        const val_cstr = qjs.JS_ToCString(ctx.ptr, val);

                        if (key_cstr != null and val_cstr != null) {
                            const header_line = std.fmt.allocPrint(loop.allocator, "{s}: {s}", .{ std.mem.span(key_cstr), std.mem.span(val_cstr) }) catch break;
                            list.append(loop.allocator, header_line) catch {};
                        }

                        if (key_cstr != null) qjs.JS_FreeCString(ctx.ptr, key_cstr);
                        if (val_cstr != null) qjs.JS_FreeCString(ctx.ptr, val_cstr);

                        // [CRASH FIX]
                        // qjs.JS_FreeAtom(ctx.ptr, atom);

                        qjs.JS_FreeValue(ctx.ptr, val);
                    }
                    qjs.JS_FreePropertyEnum(ctx.ptr, props, len);
                    data.headers = list.toOwnedSlice(loop.allocator) catch &[_][]const u8{};
                }
            }
        }
    }

    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);
    if (ctx.isException(promise)) {
        data.deinit(loop.allocator);
        return promise;
    }

    const task = loop.allocator.create(FetchTask) catch return failAlloc(ctx, loop, data);
    task.* = .{ .loop = loop, .ctx = ctx, .resolve = resolvers[0], .reject = resolvers[1], .data = data };

    loop.spawnWorker(workerWrapper, task) catch {
        loop.allocator.destroy(task);
        data.deinit(loop.allocator);
        ctx.freeValue(resolvers[0]);
        ctx.freeValue(resolvers[1]);
        ctx.freeValue(promise);
        return ctx.throwInternalError("Failed to spawn worker");
    };
    return promise;
}

fn failAlloc(ctx: zqjs.Context, loop: *EventLoop, data: *FetchContext) qjs.JSValue {
    data.deinit(loop.allocator);
    return ctx.throwOutOfMemory();
}

fn destroyFetchTask(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const task: *FetchTask = @ptrCast(@alignCast(ptr));
    task.data.deinit(allocator);
    allocator.destroy(task);
}

fn workerWrapper(ptr: *anyopaque) void {
    const task: *FetchTask = @ptrCast(@alignCast(ptr));
    performCurlRequest(task.loop.allocator, task.data);
    task.loop.enqueueTask(.{
        .ctx = task.ctx,
        .resolve = task.resolve,
        .reject = task.reject,
        .result = .{ .custom = .{ .data = task, .callback = onFetchComplete, .destroy = destroyFetchTask } },
    });
}

fn performCurlRequest(allocator: std.mem.Allocator, ctx: *FetchContext) void {
    const ca_bundle = curl.allocCABundle(allocator) catch |err| return ctx.fail(allocator, err);
    defer ca_bundle.deinit();

    var easy = curl.Easy.init(.{ .ca_bundle = ca_bundle }) catch |err| return ctx.fail(allocator, err);
    defer easy.deinit();

    const url_z = allocator.dupeZ(u8, ctx.url) catch |err| return ctx.fail(allocator, err);
    defer allocator.free(url_z);
    easy.setUrl(url_z) catch |err| return ctx.fail(allocator, err);

    var headers = curl.Easy.Headers{};
    defer headers.deinit();
    for (ctx.headers) |h_str| {
        const h_z = allocator.dupeZ(u8, h_str) catch |err| return ctx.fail(allocator, err);
        defer allocator.free(h_z);
        headers.add(h_z) catch |err| return ctx.fail(allocator, err);
    }
    easy.setHeaders(headers) catch |err| return ctx.fail(allocator, err);

    if (std.mem.eql(u8, ctx.method, "POST")) easy.setMethod(.POST) catch |err| return ctx.fail(allocator, err) else if (std.mem.eql(u8, ctx.method, "PUT")) easy.setMethod(.PUT) catch |err| return ctx.fail(allocator, err) else easy.setMethod(.GET) catch |err| return ctx.fail(allocator, err);

    if (ctx.body) |b| easy.setPostFields(b) catch |err| return ctx.fail(allocator, err);

    // ✅ FIX: Use std.Io.Writer.Allocating (Zig 0.15.2 standard)
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    easy.setWriter(&writer.writer) catch |err| return ctx.fail(allocator, err);

    var res = easy.perform() catch |err| return ctx.fail(allocator, err);

    ctx.status = res.status_code;
    ctx.resp_body = writer.toOwnedSlice() catch |err| return ctx.fail(allocator, err);

    // Capture Response Headers
    if (curl.hasParseHeaderSupport()) {
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |i| allocator.free(i);
            list.deinit(allocator);
        }
        var iter = res.iterateHeaders(.{}) catch |err| return ctx.fail(allocator, err);
        while (iter.next() catch |err| return ctx.fail(allocator, err)) |h| {
            const line = std.fmt.allocPrint(allocator, "{s}: {s}", .{ h.name, h.get() }) catch |err| return ctx.fail(allocator, err);
            list.append(allocator, line) catch |err| {
                allocator.free(line);
                return ctx.fail(allocator, err);
            };
        }
        ctx.resp_headers_lines = list.toOwnedSlice(allocator) catch |err| return ctx.fail(allocator, err);
    }
}

// ✅ Restored Helper: .text() implementation
fn js_res_text(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const body_val = ctx.getPropertyStr(this, "_body");
    defer ctx.freeValue(body_val);

    if (ctx.isUndefined(body_val)) return ctx.newString("");

    var len: usize = 0;
    const ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &len, body_val);
    if (ptr == null) return ctx.newString("");

    return ctx.newString(ptr[0..len]);
}

// Helper for .json()
fn js_res_json(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };

    // ✅ FIX: Call .text() method (Standard API behavior)
    const text_fn = ctx.getPropertyStr(this, "text");
    defer ctx.freeValue(text_fn);

    // Call the function on 'this'
    const text_res = ctx.call(text_fn, this, &.{});
    defer ctx.freeValue(text_res);

    if (ctx.isException(text_res)) return text_res;

    const c_str = ctx.toCString(text_res) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(c_str);
    return ctx.parseJSON(std.mem.span(c_str), "<json>");
}

// Methods (bytes, arrayBuffer)
fn js_res_arrayBuffer(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    return ctx.getPropertyStr(this, "_body");
}

fn js_res_bytes(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const body = ctx.getPropertyStr(this, "_body");
    defer ctx.freeValue(body);
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const ctor = ctx.getPropertyStr(global, "Uint8Array");
    defer ctx.freeValue(ctor);

    var args = [_]qjs.JSValue{body};
    return qjs.JS_CallConstructor(ctx.ptr, ctor, 1, &args);
}

pub fn onFetchComplete(ctx: zqjs.Context, ptr: *anyopaque) void {
    const task: *FetchTask = @ptrCast(@alignCast(ptr));
    defer destroyFetchTask(task.loop.allocator, task);

    if (task.data.err_msg) |msg| {
        const err_val = ctx.newString(msg);
        defer ctx.freeValue(err_val);
        const ret = ctx.call(task.reject, zqjs.UNDEFINED, &[_]zqjs.Value{err_val});
        ctx.freeValue(ret);
    } else {
        const resp = ctx.newObject();
        defer ctx.freeValue(resp);

        // ✅ 1. Status & OK (Standard Compliance)
        const status_val = ctx.newInt64(task.data.status);
        ctx.setPropertyStr(resp, "status", status_val) catch {};

        const is_ok = (task.data.status >= 200 and task.data.status < 300);
        const ok_val = ctx.newBool(is_ok);
        ctx.setPropertyStr(resp, "ok", ok_val) catch {};

        // ✅ 2. URL (Standard Compliance)
        const url_val = ctx.newString(task.data.url);
        ctx.setPropertyStr(resp, "url", url_val) catch {};

        // 3. Headers
        const headers = ctx.newObject();
        for (task.data.resp_headers_lines) |line| {
            if (std.mem.indexOfScalar(u8, line, ':')) |idx| {
                const key = std.ascii.allocLowerString(task.loop.allocator, std.mem.trim(u8, line[0..idx], " ")) catch continue;
                defer task.loop.allocator.free(key);
                const val = std.mem.trim(u8, line[idx + 1 ..], " ");
                const val_js = ctx.newString(val);
                const c_key = task.loop.allocator.dupeZ(u8, key) catch {
                    ctx.freeValue(val_js);
                    continue;
                };
                defer task.loop.allocator.free(c_key);
                ctx.setPropertyStr(headers, c_key, val_js) catch {};
            }
        }
        ctx.setPropertyStr(resp, "headers", headers) catch {};

        // 4. Body
        if (task.data.resp_body) |b| {
            const ab = ctx.newArrayBufferCopy(b);
            ctx.setPropertyStr(resp, "_body", ab) catch {};
        } else {
            const empty = ctx.newArrayBufferCopy(&.{});
            ctx.setPropertyStr(resp, "_body", empty) catch {};
        }

        // 5. Methods
        ctx.setPropertyStr(resp, "text", ctx.newCFunction(js_res_text, "text", 0)) catch {};
        ctx.setPropertyStr(resp, "json", ctx.newCFunction(js_res_json, "json", 0)) catch {};
        ctx.setPropertyStr(resp, "arrayBuffer", ctx.newCFunction(js_res_arrayBuffer, "arrayBuffer", 0)) catch {};
        ctx.setPropertyStr(resp, "bytes", ctx.newCFunction(js_res_bytes, "bytes", 0)) catch {};

        const ret = ctx.call(task.resolve, zqjs.UNDEFINED, &[_]zqjs.Value{resp});
        ctx.freeValue(ret);
    }
}
