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

    const data: [*]const u8 = @ptrCast(ptr);
    buf.list.appendSlice(buf.allocator, data[0..total_size]) catch {
        return 0; // Signal error to curl
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

/// Represents a pending HTTP request with its promise resolvers
pub const PendingRequest = struct {
    /// The curl Easy handle for this request
    easy: curl.Easy,
    /// QuickJS context for callbacks
    ctx: zqjs.Context,
    /// Promise resolve function
    resolve: zqjs.Value,
    /// Promise reject function
    reject: zqjs.Value,
    /// Response body buffer with allocator
    write_buffer: WriteBuffer,
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
        if (self.headers) |*h| h.deinit();
        if (self.multipart) |mp| mp.deinit();
        self.arena.deinit();
        // Free the JS values
        self.ctx.freeValue(self.resolve);
        self.ctx.freeValue(self.reject);
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
        // Clean up any remaining pending requests
        var it = self.pending.valueIterator();
        while (it.next()) |req| {
            req.*.deinit(self.allocator);
        }
        self.pending.deinit();

        self.multi.deinit();
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

        // Set URL
        const url_z = try arena.dupeZ(u8, url);
        try easy.setUrl(url_z);

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
            .resolve = ctx.dupValue(resolve),
            .reject = ctx.dupValue(reject),
            .write_buffer = .{ .list = .empty, .allocator = self.allocator },
            .url = try arena.dupe(u8, url),
            .headers = curl_headers,
            .multipart = null,
            .arena = req.arena,
        };

        // Set write callback to capture response body
        try easy.setWritedata(&req.write_buffer);
        try easy.setWritefunction(writeCallback);

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

        if (msg.data.result != c.CURLE_OK) {
            // Request failed
            const err_str = ctx.newString("Network request failed");
            defer ctx.freeValue(err_str);
            const ret = ctx.call(req.reject, zqjs.UNDEFINED, &.{err_str});
            ctx.freeValue(ret);
        } else {
            // Get status code
            var status_code: c_long = 0;
            _ = c.curl_easy_getinfo(req.easy.handle, c.CURLINFO_RESPONSE_CODE, &status_code);

            // Build Response object
            const resp = ctx.newObject();

            // status
            ctx.setPropertyStr(resp, "status", ctx.newInt64(status_code)) catch {};

            // ok
            const ok = (status_code >= 200 and status_code < 300);
            ctx.setPropertyStr(resp, "ok", ctx.newBool(ok)) catch {};

            // url
            ctx.setPropertyStr(resp, "url", ctx.newString(req.url)) catch {};

            // _body (ArrayBuffer)
            const body_ab = ctx.newArrayBufferCopy(req.write_buffer.list.items);
            ctx.setPropertyStr(resp, "_body", body_ab) catch {
                ctx.freeValue(body_ab);
            };

            // Add response methods: text(), json(), arrayBuffer(), blob(), body
            js_response.addResponseMethods(ctx, resp);

            const ret = ctx.call(req.resolve, zqjs.UNDEFINED, &.{resp});
            ctx.freeValue(ret);
            ctx.freeValue(resp);
        }

        // Cleanup
        req.deinit(self.allocator);
    }

    /// Get count of pending requests
    pub fn pendingCount(self: *CurlMulti) usize {
        return self.pending.count();
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

        // Set URL
        const url_z = try arena.dupeZ(u8, url);
        try easy.setUrl(url_z);

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
            .resolve = ctx.dupValue(resolve),
            .reject = ctx.dupValue(reject),
            .write_buffer = .{ .list = .empty, .allocator = self.allocator },
            .url = try arena.dupe(u8, url),
            .headers = curl_headers,
            .multipart = multipart,
            .arena = req.arena,
        };

        // Set write callback to capture response body
        try easy.setWritedata(&req.write_buffer);
        try easy.setWritefunction(writeCallback);

        // Add to multi handle
        try self.multi.addHandle(easy);

        // Track by handle pointer
        try self.pending.put(@ptrCast(easy.handle), req);
    }
};
