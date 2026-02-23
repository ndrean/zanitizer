//! Curl Multi Interface - Non-blocking HTTP request manager
//!
//! This module provides a multiplexed HTTP client using libcurl's multi interface.
//! Instead of spawning threads for each request, it handles thousands of concurrent
//! connections in a single thread using select/poll/epoll.
//!
//! Benefits over thread pool:
//! - No thread overhead per request (~1MB stack each)
//! - HTTP/2 connection multiplexing
//! - Scales to thousands of concurrent requests
//! - Lower latency (no thread scheduling)

const std = @import("std");
const curl = @import("curl");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const js_response = @import("js_response.zig");

// Access raw libcurl C API for constants
const c = curl.libcurl;

// ============================================================================
// Fetch Security Limits (exported via root.zig)
// ============================================================================

pub const FETCH_TIMEOUT_MS: c_long = 30_000; // 30s total request timeout
pub const FETCH_CONNECT_TIMEOUT_MS: c_long = 10_000; // 10s connection timeout
pub const FETCH_MAX_REDIRECTS: c_long = 5; // max redirect hops
pub const FETCH_MAX_RESPONSE_SIZE: usize = 50 * 1024 * 1024; // 50 MB

/// Apply security limits to any curl Easy handle: timeout, redirect cap,
/// response size, protocol restriction. Call after setUrl() on every handle.
pub fn hardenEasy(easy: curl.Easy) void {
    const handle = easy.handle;
    _ = c.curl_easy_setopt(handle, c.CURLOPT_TIMEOUT_MS, FETCH_TIMEOUT_MS);
    _ = c.curl_easy_setopt(handle, c.CURLOPT_CONNECTTIMEOUT_MS, FETCH_CONNECT_TIMEOUT_MS);
    _ = c.curl_easy_setopt(handle, c.CURLOPT_MAXREDIRS, FETCH_MAX_REDIRECTS);
    _ = c.curl_easy_setopt(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = c.curl_easy_setopt(handle, c.CURLOPT_PROTOCOLS_STR, "http,https");
    _ = c.curl_easy_setopt(handle, c.CURLOPT_ACCEPT_ENCODING, ""); // "" = all supported (gzip, br, deflate); curl decompresses transparently
}

/// SSRF pre-flight check: returns true if the URL targets localhost, private
/// IP ranges, or cloud metadata endpoints. Only enforced in sanitize mode
/// (untrusted content) — trusted code / local dev can fetch localhost freely.
pub fn isBlockedUrl(url: []const u8) bool {
    const host = extractHost(url) orelse return false;

    // Exact matches
    if (std.mem.eql(u8, host, "localhost")) return true;
    if (std.mem.eql(u8, host, "0.0.0.0")) return true;
    if (std.mem.eql(u8, host, "[::1]")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;

    // IPv4 prefix checks
    if (std.mem.startsWith(u8, host, "127.")) return true; // loopback
    if (std.mem.startsWith(u8, host, "10.")) return true; // private class A
    if (std.mem.startsWith(u8, host, "192.168.")) return true; // private class C
    if (std.mem.startsWith(u8, host, "169.254.")) return true; // link-local + cloud metadata

    // 172.16.0.0 – 172.31.255.255
    if (std.mem.startsWith(u8, host, "172.")) {
        // Parse second octet
        const rest = host[4..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
        const second = std.fmt.parseInt(u8, rest[0..dot], 10) catch return false;
        if (second >= 16 and second <= 31) return true;
    }

    return false;
}

/// Extract hostname from a URL like "http://host:port/path" or "https://host/path"
fn extractHost(url: []const u8) ?[]const u8 {
    // Skip scheme
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else return null;
    if (after_scheme.len == 0) return null;

    // Handle IPv6 bracket notation [::1]
    if (after_scheme[0] == '[') {
        const close = std.mem.indexOfScalar(u8, after_scheme, ']') orelse return null;
        return after_scheme[0 .. close + 1]; // include brackets
    }

    // Find end of host (port separator or path separator)
    var end = after_scheme.len;
    if (std.mem.indexOfScalar(u8, after_scheme, ':')) |i| end = @min(end, i);
    if (std.mem.indexOfScalar(u8, after_scheme, '/')) |i| end = @min(end, i);
    if (std.mem.indexOfScalar(u8, after_scheme, '?')) |i| end = @min(end, i);

    return if (end > 0) after_scheme[0..end] else null;
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Wrapper struct to hold ArrayList and allocator together for write callback
const WriteBuffer = struct {
    list: std.ArrayList(u8),
    allocator: std.mem.Allocator,
};

/// Write callback for libcurl - appends data to response buffer
fn writeCallback(
    ptr: [*c]c_char,
    size: c_uint,
    nmemb: c_uint,
    user_data: *anyopaque,
) callconv(.c) c_uint {
    const total_size = size * nmemb;
    const buf: *WriteBuffer = @ptrCast(@alignCast(user_data));

    // Abort transfer if response exceeds size limit
    if (buf.list.items.len + total_size > FETCH_MAX_RESPONSE_SIZE) {
        return 0; // Signal error to curl, stops transfer
    }

    const data: [*]const u8 = @ptrCast(ptr);
    buf.list.appendSlice(buf.allocator, data[0..total_size]) catch {
        return 0; // Signal error to curl
    };

    return total_size;
}

/// Header callback for libcurl - appends each header line to buffer
fn headerCallback(
    ptr: [*c]c_char,
    size: c_uint,
    nmemb: c_uint,
    user_data: *anyopaque,
) callconv(.c) c_uint {
    const total_size = size * nmemb;
    const buf: *WriteBuffer = @ptrCast(@alignCast(user_data));
    const data: [*]const u8 = @ptrCast(ptr);
    buf.list.appendSlice(buf.allocator, data[0..total_size]) catch {
        return 0;
    };
    return total_size;
}

/// Entry for multipart form data submission
pub const MultipartEntry = struct {
    name: []const u8,
    /// In-memory data (for Blobs created from strings/arrays)
    data: ?[]const u8 = null,
    /// File path for disk streaming (zero-copy for large files)
    file_path: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
};

/// Shared state for a batch of parallel script fetches
pub const ScriptBuffers = struct {
    /// One slot per script. null = not yet fetched / fetch failed / inline
    results: []?[]const u8,
    /// How many remote fetches are still pending
    pending_count: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, count: usize) !*ScriptBuffers {
        const self = try allocator.create(ScriptBuffers);
        self.* = .{
            .results = try allocator.alloc(?[]const u8, count),
            .pending_count = 0,
            .allocator = allocator,
        };
        @memset(self.results, null);
        return self;
    }

    pub fn deinit(self: *ScriptBuffers) void {
        for (self.results) |r| if (r) |data| self.allocator.free(data);
        self.allocator.free(self.results);
        self.allocator.destroy(self);
    }
};

/// Determines how a completed request is handled
pub const CompletionKind = union(enum) {
    /// fetch(): resolve/reject Promise with Response object
    fetch_response: struct { resolve: zqjs.Value, reject: zqjs.Value },
    /// Image load: deliver raw bytes via callback (no Response object built)
    image_load: struct {
        this_val: zqjs.Value,
        on_complete: *const fn (ctx: zqjs.Context, this_val: zqjs.Value, body: []const u8, ok: bool) void,
    },
    /// Script load: store body into a shared buffer at a given index
    script_load: struct {
        buffers: *ScriptBuffers,
        index: u32,
    },
};

/// Represents a pending HTTP request
pub const PendingRequest = struct {
    /// The curl Easy handle for this request
    easy: curl.Easy,
    /// QuickJS context for callbacks
    ctx: zqjs.Context,
    /// How to handle completion (fetch Response vs image load callback)
    completion: CompletionKind,
    /// Response body buffer with allocator
    write_buffer: WriteBuffer,
    /// Response headers buffer with allocator (unused for image_load)
    header_buffer: WriteBuffer,
    /// Request URL (for Response object)
    url: []const u8,
    /// Custom headers list (must be kept alive during request)
    headers: ?curl.Easy.Headers,
    /// Multipart handle (must be kept alive during request)
    multipart: ?curl.Easy.MultiPart,
    /// Arena for this request's allocations
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *PendingRequest, allocator: std.mem.Allocator) void {
        // Clean up curl easy handle
        self.easy.deinit();
        self.write_buffer.list.deinit(allocator);
        self.header_buffer.list.deinit(allocator);
        if (self.headers) |*h| h.deinit();
        if (self.multipart) |mp| mp.deinit();
        self.arena.deinit();
        // Free the JS values based on completion kind
        switch (self.completion) {
            .fetch_response => |fr| {
                self.ctx.freeValue(fr.resolve);
                self.ctx.freeValue(fr.reject);
            },
            .image_load => {
                // this_val is freed by the on_complete callback
            },
            .script_load => {
                // No JS values to free — buffers are managed by the caller
            },
        }
        allocator.destroy(self);
    }
};

/// Curl Multi manager - handles non-blocking HTTP requests
pub const CurlMulti = struct {
    allocator: std.mem.Allocator,
    multi: curl.Multi,
    /// Map from curl handle pointer to PendingRequest
    pending: std.AutoHashMap(*anyopaque, *PendingRequest),

    pub fn init(allocator: std.mem.Allocator) !*CurlMulti {
        const self = try allocator.create(CurlMulti);
        errdefer allocator.destroy(self);

        const multi = curl.Multi.init() catch return error.CurlMultiInit;

        self.* = .{
            .allocator = allocator,
            .multi = multi,
            .pending = std.AutoHashMap(*anyopaque, *PendingRequest).init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *CurlMulti) void {
        // Remove and clean up any remaining pending requests.
        // libcurl requires curl_multi_remove_handle BEFORE curl_easy_cleanup.
        var it = self.pending.valueIterator();
        while (it.next()) |req| {
            self.multi.removeHandle(req.*.easy.handle) catch {};
            req.*.deinit(self.allocator);
        }
        self.pending.deinit();

        // zig-curl Multi.deinit() is a no-op — call curl_multi_cleanup directly.
        _ = c.curl_multi_cleanup(self.multi.multi);
        self.allocator.destroy(self);
    }

    /// Submit a new HTTP request (non-blocking)
    pub fn submitRequest(
        self: *CurlMulti,
        ctx: zqjs.Context,
        url: []const u8,
        method: []const u8,
        body: ?[]const u8,
        headers: []const []const u8,
        resolve: zqjs.Value,
        reject: zqjs.Value,
    ) !void {
        const req = try self.allocator.create(PendingRequest);
        errdefer self.allocator.destroy(req);

        req.arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena = req.arena.allocator();
        errdefer req.arena.deinit();

        // Allocate CA bundle for SSL/TLS
        const ca_bundle = curl.allocCABundle(arena) catch return error.CABundleAlloc;

        // Create Easy handle with CA bundle
        var easy = curl.Easy.init(.{ .ca_bundle = ca_bundle }) catch return error.EasyInit;
        errdefer easy.deinit();

        // Set URL + apply security limits
        const url_z = try arena.dupeZ(u8, url);
        try easy.setUrl(url_z);
        hardenEasy(easy);

        // Copy body to arena if present (curl doesn't copy, just stores pointer)
        const body_copy: ?[]const u8 = if (body) |b| try arena.dupe(u8, b) else null;

        // Set method
        if (std.mem.eql(u8, method, "POST")) {
            try easy.setMethod(.POST);
            if (body_copy) |b| try easy.setPostFields(b);
        } else if (std.mem.eql(u8, method, "PUT")) {
            try easy.setMethod(.PUT);
            if (body_copy) |b| try easy.setPostFields(b);
        } else if (std.mem.eql(u8, method, "PATCH")) {
            try easy.setMethod(.PATCH);
            if (body_copy) |b| try easy.setPostFields(b);
        } else if (std.mem.eql(u8, method, "DELETE")) {
            try easy.setMethod(.DELETE);
        } else if (std.mem.eql(u8, method, "HEAD")) {
            try easy.setMethod(.HEAD);
        } else {
            try easy.setMethod(.GET);
        }

        // Set headers
        var curl_headers: ?curl.Easy.Headers = null;
        if (headers.len > 0) {
            curl_headers = curl.Easy.Headers{};
            for (headers) |h| {
                const h_z = try arena.dupeZ(u8, h);
                try curl_headers.?.add(h_z);
            }
            try easy.setHeaders(curl_headers.?);
        }

        // Store complete request struct
        req.* = .{
            .easy = easy,
            .ctx = ctx,
            .completion = .{ .fetch_response = .{
                .resolve = ctx.dupValue(resolve),
                .reject = ctx.dupValue(reject),
            } },
            .write_buffer = .{ .list = .empty, .allocator = self.allocator },
            .header_buffer = .{ .list = .empty, .allocator = self.allocator },
            .url = try arena.dupe(u8, url),
            .headers = curl_headers,
            .multipart = null,
            .arena = req.arena,
        };

        // Set write callback to capture response body
        try easy.setWritedata(&req.write_buffer);
        try easy.setWritefunction(writeCallback);

        // Set header callback to capture response headers
        _ = c.curl_easy_setopt(easy.handle, c.CURLOPT_HEADERFUNCTION, @as(*const fn ([*c]c_char, c_uint, c_uint, *anyopaque) callconv(.c) c_uint, &headerCallback));
        _ = c.curl_easy_setopt(easy.handle, c.CURLOPT_HEADERDATA, @as(*anyopaque, @ptrCast(&req.header_buffer)));

        // Add to multi handle
        try self.multi.addHandle(easy);

        // Track by handle pointer
        try self.pending.put(@ptrCast(easy.handle), req);
    }

    /// Poll for completed requests (call from event loop)
    /// Returns number of still-running transfers
    pub fn poll(self: *CurlMulti, timeout_ms: c_int) !struct { running: c_int, completed: u32 } {
        // Perform transfers
        const still_running = self.multi.perform() catch |err| {
            std.debug.print("[CurlMulti] perform error: {}\n", .{err});
            return .{ .running = 0, .completed = 0 };
        };

        // Poll for activity
        _ = self.multi.poll(null, timeout_ms) catch {};

        // Check for completed transfers
        var completed: u32 = 0;
        while (true) {
            const info = self.multi.readInfo() catch break;

            if (info.msg.msg == c.CURLMSG_DONE) {
                const handle: *anyopaque = @ptrCast(info.msg.easy_handle);

                if (self.pending.get(handle)) |req| {
                    completed += 1;

                    // Remove from multi BEFORE handling completion (and deiniting easy handle)
                    self.multi.removeHandle(info.msg.easy_handle.?) catch {};
                    _ = self.pending.remove(handle);

                    self.handleCompletion(req, info.msg);
                }
            }
        }

        return .{ .running = still_running, .completed = completed };
    }

    fn handleCompletion(self: *CurlMulti, req: *PendingRequest, msg: *c.CURLMsg) void {
        const ctx = req.ctx;
        const curl_ok = (msg.data.result == c.CURLE_OK);

        switch (req.completion) {
            .fetch_response => |fr| {
                if (!curl_ok) {
                    const err_str = ctx.newString("Network request failed");
                    defer ctx.freeValue(err_str);
                    const ret = ctx.call(fr.reject, zqjs.UNDEFINED, &.{err_str});
                    ctx.freeValue(ret);
                } else {
                    var status_code: c_long = 0;
                    _ = c.curl_easy_getinfo(req.easy.handle, c.CURLINFO_RESPONSE_CODE, &status_code);

                    const resp = ctx.newObject();
                    ctx.setPropertyStr(resp, "status", ctx.newInt64(status_code)) catch {};
                    const ok = (status_code >= 200 and status_code < 300);
                    ctx.setPropertyStr(resp, "ok", ctx.newBool(ok)) catch {};
                    ctx.setPropertyStr(resp, "url", ctx.newString(req.url)) catch {};

                    const body_ab = ctx.newArrayBufferCopy(req.write_buffer.list.items);
                    ctx.setPropertyStr(resp, "_body", body_ab) catch {
                        ctx.freeValue(body_ab);
                    };

                    // Parse response headers into a Headers object
                    {
                        const headers_init = ctx.newObject();
                        const header_data = req.header_buffer.list.items;
                        var iter = std.mem.splitSequence(u8, header_data, "\r\n");
                        while (iter.next()) |line| {
                            if (line.len == 0 or std.mem.startsWith(u8, line, "HTTP/")) continue;
                            if (std.mem.indexOfScalar(u8, line, ':')) |idx| {
                                const key = std.mem.trim(u8, line[0..idx], " \t");
                                const val = std.mem.trim(u8, line[idx + 1 ..], " \t");
                                if (key.len > 0) {
                                    const val_js = ctx.newString(val);
                                    const atom = ctx.newAtom(key);
                                    defer ctx.freeAtom(atom);
                                    _ = qjs.JS_SetProperty(ctx.ptr, headers_init, atom, val_js);
                                }
                            }
                        }
                        const global = ctx.getGlobalObject();
                        defer ctx.freeValue(global);
                        const headers_ctor = ctx.getPropertyStr(global, "Headers");
                        defer ctx.freeValue(headers_ctor);
                        if (!ctx.isUndefined(headers_ctor)) {
                            var args = [_]qjs.JSValue{headers_init};
                            const headers_obj = qjs.JS_CallConstructor(ctx.ptr, headers_ctor, 1, &args);
                            ctx.freeValue(headers_init);
                            ctx.setPropertyStr(resp, "headers", headers_obj) catch {
                                ctx.freeValue(headers_obj);
                            };
                        } else {
                            ctx.setPropertyStr(resp, "headers", headers_init) catch {
                                ctx.freeValue(headers_init);
                            };
                        }
                    }

                    js_response.addResponseMethods(ctx, resp);

                    const ret = ctx.call(fr.resolve, zqjs.UNDEFINED, &.{resp});
                    ctx.freeValue(ret);
                    ctx.freeValue(resp);
                }
            },
            .image_load => |il| {
                var http_ok = false;
                if (curl_ok) {
                    var status_code: c_long = 0;
                    _ = c.curl_easy_getinfo(req.easy.handle, c.CURLINFO_RESPONSE_CODE, &status_code);
                    http_ok = (status_code >= 200 and status_code < 300);
                }
                il.on_complete(ctx, il.this_val, req.write_buffer.list.items, http_ok);
            },
            .script_load => |sl| {
                sl.buffers.pending_count -= 1;
                if (curl_ok) {
                    var status_code: c_long = 0;
                    _ = c.curl_easy_getinfo(req.easy.handle, c.CURLINFO_RESPONSE_CODE, &status_code);
                    if (status_code >= 200 and status_code < 300) {
                        sl.buffers.results[sl.index] = sl.buffers.allocator.dupe(u8, req.write_buffer.list.items) catch null;
                    } else {
                        std.debug.print("[CurlMulti] Script fetch HTTP {d} for index {d}\n", .{ status_code, sl.index });
                    }
                } else {
                    std.debug.print("[CurlMulti] Script fetch failed for index {d}\n", .{sl.index});
                }
            },
        }

        // Cleanup
        req.deinit(self.allocator);
    }

    /// Get count of pending requests
    pub fn pendingCount(self: *CurlMulti) usize {
        return self.pending.count();
    }

    /// Submit a GET request for raw bytes (e.g. image load).
    /// On completion, calls on_complete with the body bytes instead of
    /// building a Response object. No headers/body/method params needed.
    pub fn submitImageRequest(
        self: *CurlMulti,
        ctx: zqjs.Context,
        url: []const u8,
        this_val: zqjs.Value,
        on_complete: *const fn (ctx: zqjs.Context, this_val: zqjs.Value, body: []const u8, ok: bool) void,
    ) !void {
        const req = try self.allocator.create(PendingRequest);
        errdefer self.allocator.destroy(req);

        req.arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena = req.arena.allocator();
        errdefer req.arena.deinit();

        const ca_bundle = curl.allocCABundle(arena) catch return error.CABundleAlloc;

        var easy = curl.Easy.init(.{ .ca_bundle = ca_bundle }) catch return error.EasyInit;
        errdefer easy.deinit();

        const url_z = try arena.dupeZ(u8, url);
        try easy.setUrl(url_z);
        hardenEasy(easy);
        try easy.setMethod(.GET);

        req.* = .{
            .easy = easy,
            .ctx = ctx,
            .completion = .{ .image_load = .{
                .this_val = this_val,
                .on_complete = on_complete,
            } },
            .write_buffer = .{ .list = .empty, .allocator = self.allocator },
            .header_buffer = .{ .list = .empty, .allocator = self.allocator },
            .url = try arena.dupe(u8, url),
            .headers = null,
            .multipart = null,
            .arena = req.arena,
        };

        // Set write callback to capture response body
        try easy.setWritedata(&req.write_buffer);
        try easy.setWritefunction(writeCallback);

        try self.multi.addHandle(easy);
        try self.pending.put(@ptrCast(easy.handle), req);
    }

    /// Submit a GET request for a script. On completion, stores the response
    /// body into buffers.results[index]. No JS values involved.
    pub fn submitScriptRequest(
        self: *CurlMulti,
        ctx: zqjs.Context,
        url: []const u8,
        buffers: *ScriptBuffers,
        index: u32,
    ) !void {
        const req = try self.allocator.create(PendingRequest);
        errdefer self.allocator.destroy(req);

        req.arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena = req.arena.allocator();
        errdefer req.arena.deinit();

        const ca_bundle = curl.allocCABundle(arena) catch return error.CABundleAlloc;

        var easy = curl.Easy.init(.{ .ca_bundle = ca_bundle }) catch return error.EasyInit;
        errdefer easy.deinit();

        const url_z = try arena.dupeZ(u8, url);
        try easy.setUrl(url_z);
        hardenEasy(easy);
        try easy.setMethod(.GET);

        req.* = .{
            .easy = easy,
            .ctx = ctx,
            .completion = .{ .script_load = .{
                .buffers = buffers,
                .index = index,
            } },
            .write_buffer = .{ .list = .empty, .allocator = self.allocator },
            .header_buffer = .{ .list = .empty, .allocator = self.allocator },
            .url = try arena.dupe(u8, url),
            .headers = null,
            .multipart = null,
            .arena = req.arena,
        };

        // Set write callback to capture response body
        try easy.setWritedata(&req.write_buffer);
        try easy.setWritefunction(writeCallback);

        try self.multi.addHandle(easy);
        try self.pending.put(@ptrCast(easy.handle), req);

        buffers.pending_count += 1;
    }

    /// Submit a multipart/form-data request using curl's native MIME API
    /// This is more efficient than manual serialization for large files
    pub fn submitMultipartRequest(
        self: *CurlMulti,
        ctx: zqjs.Context,
        url: []const u8,
        entries: []const MultipartEntry,
        headers: []const []const u8,
        resolve: zqjs.Value,
        reject: zqjs.Value,
    ) !void {
        const req = try self.allocator.create(PendingRequest);
        errdefer self.allocator.destroy(req);

        req.arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena = req.arena.allocator();
        errdefer req.arena.deinit();

        // Allocate CA bundle for SSL/TLS
        const ca_bundle = curl.allocCABundle(arena) catch return error.CABundleAlloc;

        // Create Easy handle with CA bundle
        var easy = curl.Easy.init(.{ .ca_bundle = ca_bundle }) catch return error.EasyInit;
        errdefer easy.deinit();

        // Set URL + apply security limits
        const url_z = try arena.dupeZ(u8, url);
        try easy.setUrl(url_z);
        hardenEasy(easy);

        // Method is always POST for multipart
        try easy.setMethod(.POST);

        // Build multipart using curl's MIME API - use raw C API for filename/mime_type support
        var multipart = try easy.createMultiPart();
        errdefer multipart.deinit();

        for (entries) |entry| {
            const name_z = try arena.dupeZ(u8, entry.name);

            // Use raw libcurl API to get part pointer for filename/mime_type
            const part = c.curl_mime_addpart(multipart.mime_handle) orelse return error.MimeAddPart;

            // Set name
            if (c.curl_mime_name(part, name_z) != c.CURLE_OK) return error.MimeSetName;

            // Choose data source: file path (zero-copy streaming) or in-memory data
            if (entry.file_path) |path| {
                // Stream directly from disk - no memory copy for large files!
                const path_z = try arena.dupeZ(u8, path);
                if (c.curl_mime_filedata(part, path_z) != c.CURLE_OK) return error.MimeSetFileData;
            } else if (entry.data) |data| {
                // In-memory data (curl copies internally)
                if (c.curl_mime_data(part, data.ptr, data.len) != c.CURLE_OK) return error.MimeSetData;
            }

            // Set filename if provided (required for server to recognize as file upload)
            if (entry.filename) |fname| {
                const fname_z = try arena.dupeZ(u8, fname);
                if (c.curl_mime_filename(part, fname_z) != c.CURLE_OK) return error.MimeSetFilename;
            }

            // Set MIME type if provided
            if (entry.mime_type) |mime| {
                const mime_z = try arena.dupeZ(u8, mime);
                if (c.curl_mime_type(part, mime_z) != c.CURLE_OK) return error.MimeSetType;
            }
        }

        // Set the multipart as the request body
        try easy.setMultiPart(multipart);

        // Set additional headers (but NOT Content-Type - curl handles that for multipart)
        var curl_headers: ?curl.Easy.Headers = null;
        if (headers.len > 0) {
            curl_headers = curl.Easy.Headers{};
            for (headers) |h| {
                // Skip Content-Type header for multipart requests
                if (std.ascii.startsWithIgnoreCase(h, "content-type:")) continue;
                const h_z = try arena.dupeZ(u8, h);
                try curl_headers.?.add(h_z);
            }
            if (curl_headers) |ch| {
                if (ch.headers != null) {
                    try easy.setHeaders(ch);
                }
            }
        }

        // Store complete request struct
        req.* = .{
            .easy = easy,
            .ctx = ctx,
            .completion = .{ .fetch_response = .{
                .resolve = ctx.dupValue(resolve),
                .reject = ctx.dupValue(reject),
            } },
            .write_buffer = .{ .list = .empty, .allocator = self.allocator },
            .header_buffer = .{ .list = .empty, .allocator = self.allocator },
            .url = try arena.dupe(u8, url),
            .headers = curl_headers,
            .multipart = multipart,
            .arena = req.arena,
        };

        // Set write callback to capture response body
        try easy.setWritedata(&req.write_buffer);
        try easy.setWritefunction(writeCallback);

        // Set header callback to capture response headers
        _ = c.curl_easy_setopt(easy.handle, c.CURLOPT_HEADERFUNCTION, @as(*const fn ([*c]c_char, c_uint, c_uint, *anyopaque) callconv(.c) c_uint, &headerCallback));
        _ = c.curl_easy_setopt(easy.handle, c.CURLOPT_HEADERDATA, @as(*anyopaque, @ptrCast(&req.header_buffer)));

        // Add to multi handle
        try self.multi.addHandle(easy);

        // Track by handle pointer
        try self.pending.put(@ptrCast(easy.handle), req);
    }
};
