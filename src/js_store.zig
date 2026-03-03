/// js_store.zig — Persistent blob/text store for zexplorer, backed by SQLite.
///
/// Exposes `zxp.store.*` to JavaScript:
///   zxp.store.save(name, data, opts?)   → { id, hash }
///   zxp.store.get(name)                 → { id, name, mime, note, hash, data: ArrayBuffer, created_at } | null
///   zxp.store.list()                    → [{ id, name, mime, note, hash, created_at }]
///   zxp.store.delete(name)              → boolean
///
/// DB file: {sandbox_root}/zxp_store.db  (created on first use)
/// Schema created at open time via CREATE TABLE IF NOT EXISTS.
///
/// Thread model: one SQLite connection per OS thread (thread-local).
/// Each thread opens and owns its connection; closed in ZxpRuntime.deinit().

const std = @import("std");
const zqlite = @import("zqlite");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const RuntimeContext = z.RuntimeContext;

// ---------------------------------------------------------------------------
// Thread-local store instance
// ---------------------------------------------------------------------------

threadlocal var tl_store: ?*Store = null;

pub fn getOrOpen(allocator: std.mem.Allocator, sandbox_root: []const u8) !*Store {
    if (tl_store) |s| return s;
    const s = try allocator.create(Store);
    errdefer allocator.destroy(s);
    s.* = try Store.open(allocator, sandbox_root);
    tl_store = s;
    return s;
}

pub fn closeThreadLocal(allocator: std.mem.Allocator) void {
    if (tl_store) |s| {
        s.deinit();
        allocator.destroy(s);
        tl_store = null;
    }
}

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

const SCHEMA =
    \\CREATE TABLE IF NOT EXISTS store (
    \\  id         INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  name       TEXT NOT NULL UNIQUE,
    \\  note       TEXT,
    \\  mime       TEXT,
    \\  hash       TEXT,
    \\  data       BLOB NOT NULL,
    \\  created_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS store_name_idx ON store(name);
;

pub const Store = struct {
    conn: zqlite.Conn,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, sandbox_root: []const u8) !Store {
        const path = try std.fs.path.join(allocator, &.{ sandbox_root, "zxp_store.db" });
        defer allocator.free(path);

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        var conn = try zqlite.open(path_z, flags);
        errdefer conn.close();

        try conn.execNoArgs("PRAGMA journal_mode=WAL");
        try conn.execNoArgs(SCHEMA);

        return .{ .conn = conn, .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        self.conn.close();
    }

    pub fn save(
        self: *Store,
        name: []const u8,
        data: []const u8,
        mime: ?[]const u8,
        note: ?[]const u8,
    ) !struct { id: i64, hash: [64]u8 } {
        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &hash_bytes, .{});
        var hash_hex: [64]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (hash_bytes, 0..) |byte, i| {
            hash_hex[i * 2] = hex_chars[byte >> 4];
            hash_hex[i * 2 + 1] = hex_chars[byte & 0xf];
        }

        const now = std.time.milliTimestamp();

        try self.conn.exec(
            \\INSERT INTO store (name, note, mime, hash, data, created_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            \\ON CONFLICT(name) DO UPDATE SET
            \\  note = excluded.note,
            \\  mime = excluded.mime,
            \\  hash = excluded.hash,
            \\  data = excluded.data,
            \\  created_at = excluded.created_at
        ,
            .{ name, note, mime, hash_hex[0..], data, now },
        );

        const id = self.conn.lastInsertedRowId();
        return .{ .id = id, .hash = hash_hex };
    }

    pub const GetResult = struct {
        id: i64,
        name: []const u8,
        mime: ?[]const u8,
        note: ?[]const u8,
        hash: ?[]const u8,
        data: []const u8,
        created_at: i64,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *GetResult) void {
            self.allocator.free(self.name);
            if (self.mime) |m| self.allocator.free(m);
            if (self.note) |n| self.allocator.free(n);
            if (self.hash) |h| self.allocator.free(h);
            self.allocator.free(self.data);
        }
    };

    pub fn get(self: *Store, name: []const u8) !?GetResult {
        const row = try self.conn.row(
            "SELECT id, name, note, mime, hash, data, created_at FROM store WHERE name = ?1",
            .{name},
        ) orelse return null;
        defer row.deinit();

        const allocator = self.allocator;
        const r_name = try allocator.dupe(u8, row.text(1));
        errdefer allocator.free(r_name);
        const r_note = if (row.nullableText(2)) |s| try allocator.dupe(u8, s) else null;
        errdefer if (r_note) |n| allocator.free(n);
        const r_mime = if (row.nullableText(3)) |s| try allocator.dupe(u8, s) else null;
        errdefer if (r_mime) |m| allocator.free(m);
        const r_hash = if (row.nullableText(4)) |s| try allocator.dupe(u8, s) else null;
        errdefer if (r_hash) |h| allocator.free(h);
        const r_data = try allocator.dupe(u8, row.blob(5));
        errdefer allocator.free(r_data);

        return GetResult{
            .id = row.int(0),
            .name = r_name,
            .note = r_note,
            .mime = r_mime,
            .hash = r_hash,
            .data = r_data,
            .created_at = row.int(6),
            .allocator = allocator,
        };
    }

    pub const ListEntry = struct {
        id: i64,
        name: []const u8,
        mime: ?[]const u8,
        note: ?[]const u8,
        hash: ?[]const u8,
        created_at: i64,
    };

    pub fn list(self: *Store, allocator: std.mem.Allocator) ![]ListEntry {
        var entries: std.ArrayListUnmanaged(ListEntry) = .empty;
        errdefer entries.deinit(allocator);

        var rows = try self.conn.rows(
            "SELECT id, name, note, mime, hash, created_at FROM store ORDER BY created_at DESC",
            .{},
        );
        defer rows.deinit();

        while (rows.next()) |row| {
            try entries.append(allocator, .{
                .id = row.int(0),
                .name = try allocator.dupe(u8, row.text(1)),
                .note = if (row.nullableText(2)) |s| try allocator.dupe(u8, s) else null,
                .mime = if (row.nullableText(3)) |s| try allocator.dupe(u8, s) else null,
                .hash = if (row.nullableText(4)) |s| try allocator.dupe(u8, s) else null,
                .created_at = row.int(5),
            });
        }
        if (rows.err) |err| return err;

        return entries.toOwnedSlice(allocator);
    }

    pub fn delete(self: *Store, name: []const u8) !bool {
        try self.conn.exec("DELETE FROM store WHERE name = ?1", .{name});
        return self.conn.changes() > 0;
    }
};

// ---------------------------------------------------------------------------
// JS bindings  (callconv(.c) required by QuickJS)
// ---------------------------------------------------------------------------

/// zxp.store.save(name, data, opts?)
/// opts: { mime?: string, note?: string }
/// data: string | ArrayBuffer | Uint8Array
pub fn js_store_save(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 2) return ctx.throwTypeError("store.save: name and data required");
    const rc = RuntimeContext.get(ctx);
    const allocator = rc.allocator;

    const store = getOrOpen(allocator, rc.sandbox_root) catch return ctx.throwInternalError("store.save: failed to open DB");

    const name_cstr = ctx.toCString(argv[0]) catch return ctx.throwTypeError("store.save: name must be a string");
    defer ctx.freeCString(name_cstr);
    const name = std.mem.span(name_cstr);

    // data — string | ArrayBuffer | Uint8Array
    var str_buf: ?[]u8 = null;
    defer if (str_buf) |b| allocator.free(b);

    const data: []const u8 = blk: {
        if (ctx.isString(argv[1])) {
            const s = ctx.toCString(argv[1]) catch return ctx.throwTypeError("store.save: data string error");
            defer ctx.freeCString(s);
            str_buf = allocator.dupe(u8, std.mem.span(s)) catch return ctx.throwOutOfMemory();
            break :blk str_buf.?;
        } else if (ctx.isArrayBuffer(argv[1])) {
            break :blk ctx.getArrayBuffer(argv[1]) catch return ctx.throwTypeError("store.save: invalid ArrayBuffer");
        } else {
            const ab = ctx.getTypedArrayBuffer(argv[1]) catch return ctx.throwTypeError("store.save: data must be string, ArrayBuffer, or TypedArray");
            defer ctx.freeValue(ab.buffer);
            const buf = ctx.getArrayBuffer(ab.buffer) catch return ctx.throwTypeError("store.save: invalid TypedArray buffer");
            break :blk buf[ab.byte_offset .. ab.byte_offset + ab.byte_length];
        }
    };

    // opts: { mime?, note? }
    var mime: ?[]const u8 = null;
    var note: ?[]const u8 = null;
    var mime_buf: ?[]u8 = null;
    var note_buf: ?[]u8 = null;
    defer if (mime_buf) |m| allocator.free(m);
    defer if (note_buf) |n| allocator.free(n);

    if (argc > 2 and ctx.isObject(argv[2])) {
        const mime_val = ctx.getPropertyStr(argv[2], "mime");
        defer ctx.freeValue(mime_val);
        if (ctx.isString(mime_val)) {
            if (ctx.toCString(mime_val) catch null) |cs| {
                defer ctx.freeCString(cs);
                mime_buf = allocator.dupe(u8, std.mem.span(cs)) catch null;
                mime = mime_buf;
            }
        }
        const note_val = ctx.getPropertyStr(argv[2], "note");
        defer ctx.freeValue(note_val);
        if (ctx.isString(note_val)) {
            if (ctx.toCString(note_val) catch null) |cs| {
                defer ctx.freeCString(cs);
                note_buf = allocator.dupe(u8, std.mem.span(cs)) catch null;
                note = note_buf;
            }
        }
    }

    const result = store.save(name, data, mime, note) catch return ctx.throwInternalError("store.save: DB error");

    const obj = ctx.newObject();
    _ = ctx.setPropertyStr(obj, "id", ctx.newInt64(result.id)) catch {};
    _ = ctx.setPropertyStr(obj, "hash", ctx.newString(&result.hash)) catch {};
    return obj;
}

/// zxp.store.get(name) → object | null
pub fn js_store_get(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("store.get: name required");
    const rc = RuntimeContext.get(ctx);
    const allocator = rc.allocator;

    const store = getOrOpen(allocator, rc.sandbox_root) catch return ctx.throwInternalError("store.get: failed to open DB");

    const name_cstr = ctx.toCString(argv[0]) catch return ctx.throwTypeError("store.get: name must be a string");
    defer ctx.freeCString(name_cstr);

    var row = store.get(std.mem.span(name_cstr)) catch return ctx.throwInternalError("store.get: DB error");
    if (row == null) return zqjs.NULL;
    defer row.?.deinit();
    const r = row.?;

    const obj = ctx.newObject();
    _ = ctx.setPropertyStr(obj, "id", ctx.newInt64(r.id)) catch {};
    _ = ctx.setPropertyStr(obj, "name", ctx.newString(r.name)) catch {};
    _ = ctx.setPropertyStr(obj, "mime", if (r.mime) |m| ctx.newString(m) else zqjs.NULL) catch {};
    _ = ctx.setPropertyStr(obj, "note", if (r.note) |n| ctx.newString(n) else zqjs.NULL) catch {};
    _ = ctx.setPropertyStr(obj, "hash", if (r.hash) |h| ctx.newString(h) else zqjs.NULL) catch {};
    _ = ctx.setPropertyStr(obj, "created_at", ctx.newInt64(r.created_at)) catch {};
    _ = ctx.setPropertyStr(obj, "data", ctx.newArrayBufferCopy(r.data)) catch {};
    return obj;
}

/// zxp.store.list() → array of metadata objects (no data blob)
pub fn js_store_list(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const allocator = rc.allocator;

    const store = getOrOpen(allocator, rc.sandbox_root) catch return ctx.throwInternalError("store.list: failed to open DB");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const entries = store.list(aa) catch return ctx.throwInternalError("store.list: DB error");

    const arr = ctx.newArray();
    for (entries, 0..) |e, i| {
        const obj = ctx.newObject();
        _ = ctx.setPropertyStr(obj, "id", ctx.newInt64(e.id)) catch {};
        _ = ctx.setPropertyStr(obj, "name", ctx.newString(e.name)) catch {};
        _ = ctx.setPropertyStr(obj, "mime", if (e.mime) |m| ctx.newString(m) else zqjs.NULL) catch {};
        _ = ctx.setPropertyStr(obj, "note", if (e.note) |n| ctx.newString(n) else zqjs.NULL) catch {};
        _ = ctx.setPropertyStr(obj, "hash", if (e.hash) |h| ctx.newString(h) else zqjs.NULL) catch {};
        _ = ctx.setPropertyStr(obj, "created_at", ctx.newInt64(e.created_at)) catch {};
        _ = ctx.setPropertyUint32(arr, @intCast(i), obj) catch {};
    }
    return arr;
}

/// zxp.store.delete(name) → boolean
pub fn js_store_delete(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("store.delete: name required");
    const rc = RuntimeContext.get(ctx);
    const allocator = rc.allocator;

    const store = getOrOpen(allocator, rc.sandbox_root) catch return ctx.throwInternalError("store.delete: failed to open DB");

    const name_cstr = ctx.toCString(argv[0]) catch return ctx.throwTypeError("store.delete: name must be a string");
    defer ctx.freeCString(name_cstr);

    const deleted = store.delete(std.mem.span(name_cstr)) catch return ctx.throwInternalError("store.delete: DB error");
    return if (deleted) zqjs.TRUE else zqjs.FALSE;
}
