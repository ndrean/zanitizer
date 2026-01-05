# Complete Example: Adding `readFile()` Async Binding

This document shows the **complete workflow** for adding an async operation to your JavaScript runtime using the `async_bridge.zig` framework.

## The Goal

Add this JavaScript API:
```javascript
readFile("test.txt")
  .then(content => console.log("File content:", content))
  .catch(err => console.error("Read failed:", err));
```

## Step-by-Step Implementation

### Step 1: Define the Payload Type

In [Worker.zig:22-24](../src/Worker.zig#L22-L24):

```zig
/// Payload for file reading operation
pub const ReadFilePayload = struct {
    path: []const u8, // Owned, will be freed by worker
};
```

**Key Points**:
- This struct holds the data needed by the worker thread
- The `path` is **owned** - it will be allocated by the parser and freed by the worker
- All strings in payloads should be `[]const u8` (owned slices, not pointers)

### Step 2: Write the Worker Function

In [Worker.zig:158-173](../src/Worker.zig#L158-L173):

```zig
/// Worker for file reading - async_bridge compatible
pub fn workerReadFile(allocator: std.mem.Allocator, payload: ReadFilePayload) ![]u8 {
    // CRITICAL: Free the path when done - it was allocated by the parser
    defer allocator.free(payload.path);

    // BLOCKING I/O (runs on worker thread)
    const file = try std.fs.cwd().openFile(payload.path, .{});
    defer file.close();

    // Read entire file into memory
    const max_size = 10 * 1024 * 1024; // 10MB limit
    const content = try file.readToEndAlloc(allocator, max_size);

    // Return owned string - async_bridge will pass it to Promise.resolve()
    return content;
}
```

**Key Points**:
- **Signature**: `fn(allocator: std.mem.Allocator, payload: PayloadType) ![]u8`
- **Ownership**:
  - `payload.path` is freed by worker (`defer allocator.free(payload.path)`)
  - `content` is returned (ownership transferred to async_bridge)
- **Allocator**: The `allocator` passed here is `loop.allocator` (heap-persisted)
- **Error handling**: Any error is caught by async_bridge and sent to Promise.reject()

### Step 3: Write the Parser Function

In [async_bindings_example.zig:44-59](../src/async_bindings_example.zig#L44-L59):

```zig
/// Parse arguments for readFile(path)
fn parseReadFile(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !Worker.ReadFilePayload {
    if (args.len < 1) {
        _ = ctx.throwTypeError("readFile requires 1 argument (path)");
        return error.InvalidArgCount;
    }

    // Extract path string from JS
    const path_str = try ctx.toCString(args[0]);
    defer ctx.freeCString(path_str);

    // DIRECT ACCESS to the correct allocator. No lookups.
    // This is CRITICAL: We use the heap-persisted EventLoop allocator
    const owned_path = try loop.allocator.dupe(u8, std.mem.span(path_str));

    return .{ .path = owned_path };
}
```

**Key Points**:
- **Signature**: `fn(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !PayloadType`
- **Why `loop` parameter?**:
  - Direct access to `loop.allocator` (heap-persisted, created by `EventLoop.create()`)
  - No need for `EventLoop.getFromContext()` lookup
  - Makes allocator ownership explicit
- **String handling**:
  - `ctx.toCString()` returns a C string (must be freed with `defer ctx.freeCString()`)
  - `std.mem.span()` converts sentinel-terminated to slice
  - `loop.allocator.dupe()` creates owned copy for worker
- **Error handling**: Throw JS errors with `ctx.throwTypeError()` for invalid arguments

### Step 4: Create the Binding (One Line!)

In [async_bindings_example.zig:81-87](../src/async_bindings_example.zig#L81-L87):

```zig
/// readFile(path) -> Promise<string>
/// Reads a file asynchronously and returns its contents
pub const js_readFile = async_bridge.bindAsync(
    Worker.ReadFilePayload,
    parseReadFile,
    Worker.workerReadFile,
);
```

**That's it!** The `bindAsync()` function generates all the boilerplate:
- Getting EventLoop from context
- Creating Promise with `JS_NewPromiseCapability`
- Error handling (6+ different error paths)
- Spawning worker on thread pool
- Enqueuing result back to main thread

### Step 5: Install the Binding

In [async_bindings_example.zig:114-119](../src/async_bindings_example.zig#L114-L119):

```zig
pub fn installAsyncBindings(ctx: zqjs.Context, global: zqjs.Object) !void {
    _ = ctx;
    try global.setFunction("fetch", js_fetch, 1);
    try global.setFunction("simulateWork", js_simulateWork, 1);
    try global.setFunction("readFile", js_readFile, 1);  // ← Add this line
}
```

## Memory Ownership Flow

Understanding ownership is **critical** for preventing leaks:

```
┌─────────────────────────────────────────────────────────────┐
│ Main Thread (Parser)                                        │
├─────────────────────────────────────────────────────────────┤
│ 1. parseReadFile() called                                   │
│ 2. Extract "test.txt" from JS (temporary C string)          │
│ 3. Duplicate to loop.allocator → owned_path                 │
│ 4. Return ReadFilePayload{ .path = owned_path }             │
│                                                              │
│    Ownership transferred to async_bridge ─────────┐         │
└───────────────────────────────────────────────────┼─────────┘
                                                     │
                                                     ↓
┌─────────────────────────────────────────────────────────────┐
│ Worker Thread (workerReadFile)                              │
├─────────────────────────────────────────────────────────────┤
│ 1. Receives payload (now owns payload.path)                 │
│ 2. defer allocator.free(payload.path) ← CRITICAL            │
│ 3. Open file using payload.path                             │
│ 4. Read content → content (owned)                           │
│ 5. Return content                                           │
│                                                              │
│    Ownership transferred to async_bridge ─────────┐         │
└───────────────────────────────────────────────────┼─────────┘
                                                     │
                                                     ↓
┌─────────────────────────────────────────────────────────────┐
│ Main Thread (async_bridge → EventLoop)                      │
├─────────────────────────────────────────────────────────────┤
│ 1. async_bridge receives content (owns it)                  │
│ 2. Enqueues to EventLoop task queue                         │
│ 3. EventLoop.processAsyncTasks() runs                       │
│ 4. Creates JS string from content                           │
│ 5. Calls Promise.resolve(js_string)                         │
│ 6. defer allocator.free(content) ← CRITICAL                 │
└─────────────────────────────────────────────────────────────┘
```

### Critical Ownership Rules

1. **Parser allocates, Worker frees payload fields**:
   ```zig
   // Parser:
   const owned_path = try loop.allocator.dupe(u8, path_str);
   return .{ .path = owned_path };

   // Worker:
   defer allocator.free(payload.path); // ← Must free!
   ```

2. **Worker allocates result, async_bridge frees**:
   ```zig
   // Worker:
   const content = try file.readToEndAlloc(allocator, max_size);
   return content; // Transfer ownership

   // async_bridge (automatic):
   defer allocator.free(content); // ← Handled by framework
   ```

3. **Same allocator throughout**: `loop.allocator` is used everywhere
   - Created by `EventLoop.create()` (heap-allocated)
   - Persists for the lifetime of the EventLoop
   - Thread-safe when used correctly (parsing on main thread, freeing on worker thread)

## Why This Design is Better

### Before (Manual Binding in utils.zig)

74 lines of boilerplate for `js_fetch`:
```zig
pub fn js_fetch(ctx_ptr: ?*qjs.JSContext, ...) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };

    // Boilerplate 1: Get EventLoop
    const loop = EventLoop.getFromContext(ctx) orelse {
        return ctx.throwInternalError("EventLoop not found");
    };

    // Boilerplate 2: Parse arguments
    const url_str = ctx.toCString(argv[0]) catch {
        return ctx.throwTypeError("URL must be a string");
    };
    defer ctx.freeCString(url_str);

    const url_copy = loop.allocator.dupe(u8, std.mem.span(url_str)) catch {
        return ctx.throwInternalError("Out of memory");
    };
    errdefer loop.allocator.free(url_copy);

    // Boilerplate 3: Create Promise
    var resolving_funcs: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx_ptr, &resolving_funcs);
    if (ctx.isException(promise)) {
        loop.allocator.free(url_copy);
        return promise;
    }

    // Boilerplate 4: Create worker task
    const worker_task = Worker.WorkerTask{
        .loop = loop,
        .url = url_copy,
        .resolve = resolving_funcs[0],
        .reject = resolving_funcs[1],
        .ctx = ctx,
    };

    // Boilerplate 5: Spawn worker with error handling
    loop.spawnWorker(Worker.workerFetchHTTP, worker_task) catch {
        qjs.JS_FreeValue(ctx_ptr, resolving_funcs[0]);
        qjs.JS_FreeValue(ctx_ptr, resolving_funcs[1]);
        loop.allocator.free(url_copy);
        qjs.JS_FreeValue(ctx_ptr, promise);
        return ctx.throwInternalError("Failed to spawn worker");
    };

    return promise;
}
```

### After (Using async_bridge)

~16 lines total:
```zig
// Parser (domain-specific logic only)
fn parseReadFile(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !Worker.ReadFilePayload {
    if (args.len < 1) {
        _ = ctx.throwTypeError("readFile requires 1 argument (path)");
        return error.InvalidArgCount;
    }
    const path_str = try ctx.toCString(args[0]);
    defer ctx.freeCString(path_str);
    const owned_path = try loop.allocator.dupe(u8, std.mem.span(path_str));
    return .{ .path = owned_path };
}

// Binding (one line!)
pub const js_readFile = async_bridge.bindAsync(
    Worker.ReadFilePayload, parseReadFile, Worker.workerReadFile
);
```

**Result**: 78% code reduction, zero boilerplate!

## Testing

To test the new `readFile()` binding:

```zig
// In main.zig
const async_bindings = @import("async_bindings_example.zig");

// Install bindings
const global = ctx.getGlobalObject();
defer ctx.freeValue(global);
try async_bindings.installAsyncBindings(ctx, global);

// Run JavaScript
const js_code =
    \\readFile("README.md")
    \\  .then(content => console.log("File size:", content.length))
    \\  .catch(err => console.error("Error:", err));
;
_ = try ctx.evalScript(js_code, "test.js");

// Run event loop
try loop.run(.Script);
```

## Summary: Complete Checklist

To add a new async operation:

- [ ] **Step 1**: Define `Payload` struct in `Worker.zig`
- [ ] **Step 2**: Write `workerXxx(allocator, payload) ![]u8` in `Worker.zig`
  - [ ] Free all owned fields in payload with `defer`
  - [ ] Return owned result string
- [ ] **Step 3**: Write `parseXxx(loop, ctx, args) !Payload`
  - [ ] Extract arguments from JS
  - [ ] Allocate owned copies using `loop.allocator`
  - [ ] Return payload struct
- [ ] **Step 4**: Create binding: `pub const js_xxx = bindAsync(...)`
- [ ] **Step 5**: Install: `try global.setFunction("xxx", js_xxx, arg_count)`

**That's it!** No boilerplate, type-safe, and memory-safe.
