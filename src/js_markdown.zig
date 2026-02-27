//! Markdown ↔ HTML utilities
//!
//! Zig side (md4c — native, GFM-compatible):
//!   markdownToHTML(alloc, md)    ![]u8  — Markdown → HTML
//!   js_native_markdownToHTML            — QuickJS binding
//!
//! JS side (turndown — embedded, DOM-walk):
//!   TurndownService is available globally after boot (turndown.js bytecode).
//!   zxp.toMarkdown(element)      — DOM element → Markdown string
//!   zxp.markdownToHTML(md)       — Markdown string → HTML string (wraps native)
//!
//! Recommended pipeline:
//!   // HTML → Markdown (for LLM input, token compression)
//!   const md = zxp.toMarkdown(document.body);
//!
//!   // Markdown → HTML (for LLM output rendering)
//!   zxp.loadHTML(zxp.markdownToHTML(llmResponse));

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;

const c_md4c = @cImport({
    @cInclude("md4c-html.h");
});

// MD_DIALECT_GITHUB = permissive autolinks | tables | strikethrough | tasklists
// Raw HTML blocks/spans are kept (default on) so embedded <div> layout works.
const PARSER_FLAGS: c_uint = c_md4c.MD_DIALECT_GITHUB;

// ---------------------------------------------------------------------------
// md4c write callback — appends rendered HTML chunks to an ArrayList
// ---------------------------------------------------------------------------

const Md4cCtx = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,
};

fn md4cWrite(text: [*c]const u8, size: c_uint, userdata: ?*anyopaque) callconv(.c) void {
    const ctx: *Md4cCtx = @ptrCast(@alignCast(userdata.?));
    ctx.buf.appendSlice(ctx.allocator, text[0..@intCast(size)]) catch {};
}

// ---------------------------------------------------------------------------
// markdownToHTML — public Zig API
// ---------------------------------------------------------------------------

/// Convert a Markdown string to HTML using md4c (GFM dialect).
/// Caller owns the returned slice and must free it.
pub fn markdownToHTML(alloc: std.mem.Allocator, md: []const u8) ![]u8 {
    var ctx = Md4cCtx{ .buf = .empty, .allocator = alloc };
    errdefer ctx.buf.deinit(alloc);

    const rc = c_md4c.md_html(
        md.ptr,
        @intCast(md.len),
        md4cWrite,
        &ctx,
        PARSER_FLAGS,
        0, // renderer flags: default (no XHTML, no verbatim entities)
    );
    if (rc != 0) return error.Md4cError;

    return ctx.buf.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// JS binding: __native_markdownToHTML(md_string) → html_string
// ---------------------------------------------------------------------------

pub fn js_native_markdownToHTML(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = z.RuntimeContext.get(ctx);
    const alloc = rc.allocator;

    if (argc < 1 or !ctx.isString(argv[0]))
        return qjs.JS_ThrowTypeError(ctx.ptr, "markdownToHTML: expected a string");

    const zs = ctx.toZString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(zs);

    const html = markdownToHTML(alloc, zs) catch |e|
        return qjs.JS_ThrowInternalError(ctx.ptr, "markdownToHTML failed: %s", @errorName(e).ptr);
    defer alloc.free(html);

    return ctx.newString(html);
}
