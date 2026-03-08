//! WASM entry point for zanitize.
//!
//! Two-phase interface:
//!
//!   INIT (once at module load):
//!     1. Host calls init(config_ptr, config_len).
//!        config_ptr/config_len: UTF-8 JSON SanitizerConfig (0/0 = defaults).
//!        Returns 1 on success, 0 on error.
//!        Parses config, builds the Sanitizer, warms up the allocator.
//!        A new config requires re-calling init() (or reloading the module).
//!
//!   PER CALL (many times):
//!     2. Host calls alloc(n), writes HTML bytes there.
//!     3. Host calls sanitize(html_ptr, html_len).
//!        Returns a pointer to the sanitized output (owned by this module).
//!     4. Host reads result_len() bytes starting at the returned pointer.
//!     5. Host calls free_result() to release the output buffer.
//!     6. Host calls dealloc(ptr, n) to release any input buffers it allocated.
//!
//! Rationale for the split: config parsing (JSON arena) and Sanitizer init
//! (CssSanitizer setup) happen once. Per-call work is only: parse HTML →
//! walk DOM → serialize. WASM memory.grow calls also happen at init time
//! (warmup parse), so subsequent sanitize() calls hit pre-grown pages.

const std = @import("std");
const z = @import("root.zig");
const config = @import("modules/config.zig");

// wasm32-wasi: use libc malloc (from Zig's bundled wasi-libc) so that
// both Zig allocations and Lexbor's internal malloc use the same heap.
const allocator = std.heap.c_allocator;

// wasm32-wasi's crt1-command.o startup requires a `main` symbol even when
// entry is disabled.  This stub satisfies the linker without doing anything.
export fn main() i32 {
    return 0;
}

// ── Module-lifetime state (set by init()) ────────────────────────────────────

/// Arena that owns config string slices (survives for the module's lifetime).
var config_arena: ?std.heap.ArenaAllocator = null;
/// Pre-built sanitizer shared across all sanitize() calls.
var global_sanitizer: ?z.Sanitizer = null;

// ── Per-call output buffer ────────────────────────────────────────────────────

var result_buf: ?[]u8 = null;

// ── Exported functions ────────────────────────────────────────────────────────

/// Initialize the sanitizer with a JSON SanitizerConfig.
/// config_ptr/config_len: UTF-8 JSON (pass 0/0 for safe defaults).
/// Returns 1 on success, 0 on error.
/// Safe to call multiple times — tears down the previous state first.
export fn init(config_ptr: [*]const u8, config_len: usize) u32 {
    // Tear down previous state if re-initializing.
    if (global_sanitizer) |*san| {
        san.deinit();
        global_sanitizer = null;
    }
    if (config_arena) |*arena| {
        arena.deinit();
        config_arena = null;
    }

    // Parse config into a module-lifetime arena (no free until next init()).
    var arena = std.heap.ArenaAllocator.init(allocator);
    // IMPORTANT: copy config bytes into the arena BEFORE parsing.
    // std.json.parseFromSlice creates string slices that reference INTO the
    // input buffer, not copies.  After init() returns the JS host calls
    // dealloc(config_ptr, config_len), freeing that buffer.  Lexbor's malloc
    // can then reuse the same address during the next sanitize() call,
    // silently corrupting the stored option strings (e.g. removeElements[0]).
    // Owning the bytes in the arena keeps them alive for the module's lifetime.
    const json_src: ?[]const u8 = if (config_len > 0)
        arena.allocator().dupe(u8, config_ptr[0..config_len]) catch {
            arena.deinit();
            return 0;
        }
    else
        null;
    const opts = config.resolveOptions(
        arena.allocator(),
        null,
        json_src,
    ) catch {
        arena.deinit();
        return 0;
    };
    global_sanitizer = z.Sanitizer.init(
        allocator,
        opts,
    ) catch {
        arena.deinit();
        return 0;
    };
    config_arena = arena;

    return 1;
}

/// Sanitize HTML using the pre-built global sanitizer.
/// Call init() at least once before calling sanitize().
/// html_ptr/html_len: UTF-8 HTML input.
/// Returns a pointer to the sanitized output; call result_len() for its length.
/// Returns 0 on error.
export fn sanitize(html_ptr: [*]const u8, html_len: usize) ?[*]const u8 {
    if (result_buf) |old| {
        allocator.free(old);
        result_buf = null;
    }

    // Auto-init with defaults if init() was never called.
    if (global_sanitizer == null) {
        if (init(undefined, 0) == 0) return null;
    }

    const html = html_ptr[0..html_len];

    const doc = z.parseHTML(allocator, html) catch return null;
    defer z.destroyDocument(doc);

    global_sanitizer.?.sanitize(doc) catch return null;

    const root = z.documentRoot(doc) orelse return null;
    const out = z.outerNodeHTML(allocator, root) catch return null;

    result_buf = out;
    return out.ptr;
}

/// Length of the last sanitize() output in bytes.
export fn result_len() usize {
    return if (result_buf) |b| b.len else 0;
}

/// Free the last sanitize() output buffer.
export fn free_result() void {
    if (result_buf) |b| {
        allocator.free(b);
        result_buf = null;
    }
}

/// Allocate n bytes for the host to write into. Returns null on OOM.
export fn alloc(n: usize) ?[*]u8 {
    const buf = allocator.alloc(u8, n) catch return null;
    return buf.ptr;
}

/// Free a buffer previously allocated with alloc().
export fn dealloc(ptr: [*]u8, n: usize) void {
    allocator.free(ptr[0..n]);
}

// ── Internal helpers ──────────────────────────────────────────────────────────
