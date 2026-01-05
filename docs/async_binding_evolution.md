# The Complete Evolution of Async Bindings in zexplorer

This document traces the evolution from **74 lines of boilerplate** to **3 lines of declarative code** for async JavaScript bindings.

## Timeline

```
Manual Bindings → async_bridge → auto_bridge
    (74 lines)       (16 lines)     (3 lines)
```

## Level 0: The Problem

**Goal**: Expose async Zig function to JavaScript

```javascript
// JavaScript
readFile("test.txt")
  .then(content => console.log(content))
  .catch(err => console.error(err));
```

```zig
// Zig (what we want to write)
fn doReadFile(allocator: Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}
```

**Problem**: How do we bridge these two worlds?

## Level 1: Manual Bindings (~74 lines)

**File**: [src/utils.zig](../src/utils.zig)

```zig
pub fn js_fetch(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };

    // Boilerplate 1: Validate arguments
    if (argc < 1) return ctx.throwTypeError("fetch requires 1 argument (url)");

    // Boilerplate 2: Get EventLoop
    const loop = EventLoop.getFromContext(ctx) orelse {
        return ctx.throwInternalError("EventLoop not found");
    };

    // Boilerplate 3: Extract URL string
    const url_str = ctx.toCString(argv[0]) catch {
        return ctx.throwTypeError("URL must be a string");
    };
    defer ctx.freeCString(url_str);

    // Boilerplate 4: Duplicate for worker
    const url_copy = loop.allocator.dupe(u8, std.mem.span(url_str)) catch {
        return ctx.throwInternalError("Out of memory");
    };
    errdefer loop.allocator.free(url_copy);

    // Boilerplate 5: Create Promise
    var resolving_funcs: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx_ptr, &resolving_funcs);
    if (ctx.isException(promise)) {
        loop.allocator.free(url_copy);
        return promise;
    }

    // Boilerplate 6: Create worker task
    const worker_task = Worker.WorkerTask{
        .loop = loop,
        .url = url_copy,
        .resolve = resolving_funcs[0],
        .reject = resolving_funcs[1],
        .ctx = ctx,
    };

    // Boilerplate 7: Spawn worker (with 5 error cleanup paths!)
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

**Problem**: ~60 lines of identical boilerplate per binding!

## Level 2: async_bridge (~16 lines)

**File**: [src/async_bridge.zig](../src/async_bridge.zig)

**Insight**: The boilerplate is identical - extract it!

```zig
// 1. Define what data the worker needs
const FetchPayload = struct {
    url: []const u8,
};

// 2. Parse arguments (domain-specific)
fn parseFetch(loop: *EventLoop, ctx: Context, args: []const Value) !FetchPayload {
    if (args.len < 1) return error.InvalidArgCount;

    const url_str = try ctx.toCString(args[0]);
    defer ctx.freeCString(url_str);

    const url_copy = try loop.allocator.dupe(u8, std.mem.span(url_str));
    return .{ .url = url_copy };
}

// 3. One-line binding!
pub const js_fetch = async_bridge.bindAsync(
    FetchPayload,
    parseFetch,
    Worker.workerFetch
);
```

**What `bindAsync` does**:
```zig
pub fn bindAsync(
    comptime Payload: type,
    comptime parseFn: fn (loop: *EventLoop, ctx: Context, args: []const Value) !Payload,
    comptime workFn: fn (allocator: Allocator, payload: Payload) ![]u8,
) qjs.JSCFunction {
    // Generates all the boilerplate at compile-time!
    const Binder = struct {
        fn callback(...) callconv(.c) qjs.JSValue {
            const loop = EventLoop.getFromContext(ctx) orelse ...;
            const payload = parseFn(loop, ctx, args) catch ...;

            var resolving_funcs: [2]qjs.JSValue = undefined;
            const promise = qjs.JS_NewPromiseCapability(...);

            loop.spawnWorker(workerWrapper, task_data) catch ...;
            return promise;
        }
    };
    return Binder.callback;
}
```

**Result**: 78% code reduction (74 → 16 lines)

## Level 3: auto_bridge (~3 lines)

**File**: [src/auto_bridge.zig](../src/auto_bridge.zig) or [src/auto_bridge_simple.zig](../src/auto_bridge_simple.zig)

**Insight**: The parser is also boilerplate - generate it from struct fields!

```zig
// 1. Define data contract (field order = JS arg order)
const ReadFilePayload = struct {
    path: []const u8, // JS arg[0]
};

// 2. Define worker
fn doReadFile(allocator: Allocator, task: ReadFilePayload) ![]u8 {
    defer allocator.free(task.path);

    const file = try std.fs.cwd().openFile(task.path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

// 3. One-line binding!
pub const js_readFile = AutoBridge.bindAsyncAuto(ReadFilePayload, doReadFile);
```

**What `bindAsyncAuto` does**:
```zig
pub fn bindAsyncAuto(
    comptime Payload: type,
    comptime workFn: fn (allocator: Allocator, payload: Payload) ![]u8,
) qjs.JSCFunction {
    // Generate parser at compile-time by inspecting Payload struct!
    const AutoParser = struct {
        fn parse(loop: *EventLoop, ctx: Context, args: []const Value) !Payload {
            const fields = std.meta.fields(Payload); // ← Compile-time reflection

            var payload: Payload = undefined;

            inline for (fields, 0..) |field, i| {
                const T = field.type;

                // Generate conversion code for each field type
                if (T == []const u8) {
                    const str = try ctx.toZString(args[i]);
                    defer ctx.freeZString(str);
                    @field(payload, field.name) = try loop.allocator.dupe(u8, str);
                } else if (T == u32) {
                    var val: i32 = 0;
                    if (qjs.JS_ToInt32(ctx.ptr, &val, args[i]) != 0) return error.JSException;
                    @field(payload, field.name) = @intCast(val);
                }
                // ... etc for each type
            }

            return payload;
        }
    };

    // Delegate to async_bridge with auto-generated parser
    return async_bridge.bindAsync(Payload, AutoParser.parse, workFn);
}
```

**Result**: 95% code reduction (74 → 3 lines)

## Comparison Table

| Aspect | Manual | async_bridge | auto_bridge |
|--------|--------|--------------|-------------|
| **Lines per binding** | ~74 | ~16 | ~3 |
| **Boilerplate** | 100% | 22% | 5% |
| **Type safety** | Runtime | Compile-time | Compile-time |
| **Error handling** | Manual (6+ paths) | Automatic | Automatic |
| **Parser code** | Manual | Manual | Generated |
| **Flexibility** | Full | High | Medium |
| **Learning curve** | Steep | Medium | Low |
| **Best for** | Complex logic | Custom parsing | Simple payloads |

## Memory Flow

All three levels handle memory the same way:

```
┌─────────────────────────────────────────────────────────┐
│ JavaScript Thread (Main)                                │
├─────────────────────────────────────────────────────────┤
│ 1. JS calls: readFile("test.txt")                      │
│ 2. Parser extracts "test.txt" (temporary)               │
│ 3. Parser allocates on heap: loop.allocator.dupe()     │
│ 4. Create Promise                                       │
│ 5. Spawn worker with payload                           │
│ 6. Return Promise to JS                                 │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ Worker Thread                                           │
├─────────────────────────────────────────────────────────┤
│ 1. Receives payload (owns payload.path)                │
│ 2. defer allocator.free(payload.path)                  │
│ 3. Read file → content (owned)                         │
│ 4. Return content                                       │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ JavaScript Thread (Main) - EventLoop.processAsyncTasks()│
├─────────────────────────────────────────────────────────┤
│ 1. Receive content from worker                         │
│ 2. Create JS string from content                       │
│ 3. Call Promise.resolve(js_string)                     │
│ 4. defer allocator.free(content)                       │
└─────────────────────────────────────────────────────────┘
```

**Key invariant**: `loop.allocator` is used throughout (heap-persisted)

## The Design Insight

The entire evolution is based on one key insight:

> **Async bindings have a fixed structure:**
> 1. Parse arguments (JS → Zig)
> 2. Create Promise
> 3. Spawn worker
> 4. Worker does work
> 5. Enqueue result
> 6. Resolve Promise (Zig → JS)
>
> **Steps 2, 3, 5, 6 are identical** → Extract to `async_bridge`
>
> **Step 1 is repetitive** → Auto-generate from struct in `auto_bridge`
>
> **Step 4 is domain logic** → User writes this

## Code Example: All Three Levels

```zig
// ============================================================================
// Level 1: Manual (74 lines)
// ============================================================================
pub fn js_readFile_manual(ctx_ptr: ?*qjs.JSContext, ...) callconv(.c) qjs.JSValue {
    // ... 60+ lines of boilerplate ...
}

// ============================================================================
// Level 2: async_bridge (16 lines)
// ============================================================================
const ReadFilePayload = struct { path: []const u8 };

fn parseReadFile(loop: *EventLoop, ctx: Context, args: []const Value) !ReadFilePayload {
    if (args.len < 1) return error.InvalidArgCount;
    const path_str = try ctx.toCString(args[0]);
    defer ctx.freeCString(path_str);
    const path_copy = try loop.allocator.dupe(u8, std.mem.span(path_str));
    return .{ .path = path_copy };
}

fn doReadFile(allocator: Allocator, task: ReadFilePayload) ![]u8 {
    defer allocator.free(task.path);
    const file = try std.fs.cwd().openFile(task.path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

pub const js_readFile_bridge = async_bridge.bindAsync(
    ReadFilePayload, parseReadFile, doReadFile
);

// ============================================================================
// Level 3: auto_bridge (3 lines!)
// ============================================================================
const ReadFilePayload = struct { path: []const u8 };
fn doReadFile(allocator: Allocator, task: ReadFilePayload) ![]u8 { /* same */ }
pub const js_readFile_auto = AutoBridge.bindAsyncAuto(ReadFilePayload, doReadFile);

// ============================================================================
// All three produce IDENTICAL JavaScript API:
// ============================================================================
readFile("test.txt").then(content => console.log(content));
```

## The Future: gen_bindings Integration

Next step: Integrate with code generator:

```zig
// In tools/gen_bindings.zig
const async_bindings = [_]AsyncBindingSpec{
    .{
        .name = "readFile",
        .payload = "Worker.ReadFilePayload",
        .worker = "Worker.doReadFile",
    },
};

// Generates:
pub const js_readFile = AutoBridge.bindAsyncAuto(
    Worker.ReadFilePayload,
    Worker.doReadFile
);
```

Then you just define:
1. Payload struct
2. Worker function
3. One line in binding spec array

**Result**: Zero binding code needed!

## Conclusion

The journey from 74 lines to 3 lines shows the power of:
1. **Compile-time metaprogramming** (Zig's `comptime`)
2. **Type introspection** (`std.meta.fields`)
3. **Generic programming** (comptime parameters)
4. **Zero-cost abstractions** (all overhead compiled away)

Your insight about auto-generating parsers from struct fields was the final piece that completed the puzzle! 🎉

## Files Reference

- **Manual**: [src/utils.zig](../src/utils.zig)
- **async_bridge**: [src/async_bridge.zig](../src/async_bridge.zig)
- **auto_bridge**: [src/auto_bridge.zig](../src/auto_bridge.zig) or [src/auto_bridge_simple.zig](../src/auto_bridge_simple.zig)
- **Examples**:
  - [src/async_bindings_example.zig](../src/async_bindings_example.zig) - Manual parsers
  - [src/auto_bindings_example.zig](../src/auto_bindings_example.zig) - Auto-generated parsers
- **Documentation**:
  - [async_bridge_usage.md](./async_bridge_usage.md)
  - [auto_bridge_guide.md](./auto_bridge_guide.md)
  - [auto_bridge_comparison.md](./auto_bridge_comparison.md)
  - [readFile_example.md](./readFile_example.md)
  - [async_bridge_design_rationale.md](./async_bridge_design_rationale.md)
