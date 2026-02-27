//! fetchAll(urls, headers?) — parallel HTTP fetcher using libcurl multi.
//!
//! JS API:
//!   const results = fetchAll(
//!     ["https://...", "https://..."],
//!     { "Accept": "image/webp,...", "Referer": "https://example.com/" }
//!   );
//!   // results[i]: { ok: bool, status: number, data: ArrayBuffer, type: string }
//!   //             or null if the URL could not be set up.
//!
//! All requests are issued concurrently via curl_multi; returns when all complete.

const std = @import("std");
const z = @import("root.zig");
const curl = z.curl;
const zqjs = z.wrapper;
const qjs = z.qjs;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const c = curl.libcurl;

const MAX_CONCURRENT = 128;

/// State kept alive for one in-flight request.
/// `writer` is a POINTER into the bodies arena so that the address passed to
/// curl (via easy.setWriter) remains stable after entries are appended to the
/// ArrayList.  Writer.Allocating uses @fieldParentPtr internally, so copying
/// the struct by value would silently point curl at the wrong buffer.
const Entry = struct {
    easy: curl.Easy,
    url_z: [:0]u8,
    writer: *std.Io.Writer.Allocating, // heap-allocated; owned by bodies_arena
    orig_idx: usize, // maps back to the JS array index

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        // writer memory is arena-owned; deinit() is a no-op for the buffer
        // (arena.free is a no-op), but it zeroes the struct — harmless.
        self.writer.deinit();
        self.easy.deinit();
        allocator.free(self.url_z);
    }
};

pub fn js_fetchAll(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const allocator = rc.allocator;

    if (argc < 1) return ctx.throwTypeError("fetchAll: requires a URL array");

    // ── Arena for response body buffers ───────────────────────────────────────
    // Each Writer.Allocating is heap-allocated here so its address is stable.
    // The arena is dropped after all bodies have been copied into JS ArrayBuffers.
    var bodies_arena = std.heap.ArenaAllocator.init(allocator);
    defer bodies_arena.deinit();
    const ba = bodies_arena.allocator();

    // ── URL count ─────────────────────────────────────────────────────────────
    const len_js = ctx.getPropertyStr(argv[0], "length");
    defer ctx.freeValue(len_js);
    const n_raw = ctx.toInt32(len_js) catch
        return ctx.throwTypeError("fetchAll: first arg must be an array");
    if (n_raw <= 0) return ctx.newArray();
    const n: usize = @min(@as(usize, @intCast(n_raw)), MAX_CONCURRENT);

    // ── Shared headers (built once, set on every easy handle) ─────────────────
    // Kept alive until after the poll loop completes.
    var shared_headers = curl.Easy.Headers{};
    defer shared_headers.deinit();

    if (argc >= 2 and !ctx.isUndefined(argv[1]) and !ctx.isNull(argv[1])) {
        var prop_enum: ?[*]qjs.JSPropertyEnum = null;
        var prop_count: u32 = 0;
        if (qjs.JS_GetOwnPropertyNames(
            ctx.ptr,
            &prop_enum,
            &prop_count,
            argv[1],
            qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_ENUM_ONLY,
        ) == 0) {
            defer if (prop_enum) |pe| qjs.JS_FreePropertyEnum(ctx.ptr, pe, prop_count);
            if (prop_enum) |pe| {
                var j: u32 = 0;
                while (j < prop_count) : (j += 1) {
                    const k = qjs.JS_AtomToString(ctx.ptr, pe[j].atom);
                    const v = qjs.JS_GetProperty(ctx.ptr, argv[1], pe[j].atom);
                    defer {
                        qjs.JS_FreeValue(ctx.ptr, k);
                        qjs.JS_FreeValue(ctx.ptr, v);
                    }
                    const ks = ctx.toZString(k) catch continue;
                    defer ctx.freeZString(ks);
                    const vs = ctx.toZString(v) catch continue;
                    defer ctx.freeZString(vs);
                    // Build "Key: Value\0" on the stack (headers are short)
                    var line_buf: [2048]u8 = undefined;
                    const line = std.fmt.bufPrintZ(&line_buf, "{s}: {s}", .{ ks, vs }) catch continue;
                    shared_headers.add(line) catch {};
                }
            }
        }
    }

    // ── CA bundle ─────────────────────────────────────────────────────────────
    const ca_bundle = curl.allocCABundle(allocator) catch
        return ctx.throwTypeError("fetchAll: CA bundle init failed");
    defer ca_bundle.deinit();

    // ── curl_multi handle ─────────────────────────────────────────────────────
    const multi = curl.Multi.init() catch
        return ctx.throwTypeError("fetchAll: curl_multi_init failed");
    defer _ = c.curl_multi_cleanup(multi.multi);

    // ── Spin up one easy handle per URL ───────────────────────────────────────
    var entries: std.ArrayList(Entry) = .empty;
    // Cleanup: remove from multi first, then free each entry.
    // (shared_headers.deinit runs after entries via LIFO defer order.)
    defer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    for (0..n) |i| {
        const url_val = qjs.JS_GetPropertyUint32(ctx.ptr, argv[0], @intCast(i));
        defer ctx.freeValue(url_val);

        const url_s = ctx.toZString(url_val) catch continue;
        defer ctx.freeZString(url_s);

        var easy = curl.Easy.init(.{ .ca_bundle = ca_bundle }) catch continue;

        const url_z = allocator.dupeZ(u8, url_s) catch {
            easy.deinit();
            continue;
        };

        easy.setUrl(url_z) catch {
            easy.deinit();
            allocator.free(url_z);
            continue;
        };
        z.hardenEasy(easy);

        // Apply shared headers (curl stores the pointer; slist stays alive until
        // shared_headers.deinit() which runs after entries are cleaned up).
        if (shared_headers.headers != null) {
            easy.setHeaders(shared_headers) catch {};
        }

        // Allocate the writer on the heap (arena) so its address is stable.
        // curl stores &writer_ptr.writer via setWriter; @fieldParentPtr in drain()
        // requires that pointer to remain valid until multi.perform() completes.
        const writer_ptr = ba.create(std.Io.Writer.Allocating) catch {
            easy.deinit();
            allocator.free(url_z);
            continue;
        };
        writer_ptr.* = std.Io.Writer.Allocating.init(ba);

        easy.setWriter(&writer_ptr.writer) catch {
            easy.deinit();
            allocator.free(url_z);
            continue;
        };

        multi.addHandle(easy) catch {
            easy.deinit();
            allocator.free(url_z);
            continue;
        };

        entries.append(allocator, .{
            .easy = easy,
            .url_z = url_z,
            .writer = writer_ptr,
            .orig_idx = i,
        }) catch {
            _ = c.curl_multi_remove_handle(multi.multi, easy.handle);
            easy.deinit();
            allocator.free(url_z);
        };
    }

    // ── Poll until all transfers complete ─────────────────────────────────────
    var running: c_int = 1;
    while (running > 0) {
        running = multi.perform() catch break;
        if (running > 0) _ = multi.poll(null, 100) catch {};
    }

    // ── Remove handles from multi before easy.deinit() ────────────────────────
    for (entries.items) |e| {
        _ = c.curl_multi_remove_handle(multi.multi, e.easy.handle);
    }

    // ── Build JS result array ─────────────────────────────────────────────────
    // Body slices live in bodies_arena; newArrayBufferCopy copies into QJS memory
    // before the arena is dropped (defer bodies_arena.deinit() runs on return).
    const arr = ctx.newArray();
    for (entries.items) |*entry| {
        var status: c_long = 0;
        _ = c.curl_easy_getinfo(entry.easy.handle, c.CURLINFO_RESPONSE_CODE, &status);

        var ct_raw: [*c]const u8 = null;
        _ = c.curl_easy_getinfo(entry.easy.handle, c.CURLINFO_CONTENT_TYPE, &ct_raw);
        const content_type: []const u8 =
            if (ct_raw != null) std.mem.span(ct_raw) else "application/octet-stream";

        const body = entry.writer.toOwnedSlice() catch &[_]u8{};

        const ok = status >= 200 and status < 300;
        const obj = ctx.newObject();
        ctx.setPropertyStr(obj, "ok", ctx.newBool(ok)) catch {};
        ctx.setPropertyStr(obj, "status", ctx.newInt32(@intCast(status))) catch {};
        ctx.setPropertyStr(obj, "data", ctx.newArrayBufferCopy(body)) catch {};
        ctx.setPropertyStr(obj, "type", ctx.newString(content_type)) catch {};

        _ = qjs.JS_SetPropertyUint32(ctx.ptr, arr, @intCast(entry.orig_idx), obj);
    }

    return arr;
}
