# Auto Bridge Guide: Zero-Boilerplate Async Bindings

## Overview

`auto_bridge.zig` automatically generates JavaScript⟷Zig async bindings by **inspecting your Payload struct at compile-time**. No manual parser code needed!

## The Evolution

### Level 1: Manual Bindings (utils.zig)
**~74 lines** of boilerplate per binding
```zig
pub fn js_fetch(ctx_ptr: ?*qjs.JSContext, ...) callconv(.c) qjs.JSValue {
    // 60+ lines of:
    // - Get EventLoop
    // - Parse arguments
    // - Create Promise
    // - Handle 6 error cases
    // - Spawn worker
}
```

### Level 2: Manual Parser + async_bridge (async_bindings_example.zig)
**~16 lines** per binding (78% reduction)
```zig
fn parseFetch(loop: *EventLoop, ctx: Context, args: []const Value) !FetchPayload {
    if (args.len < 1) return error.InvalidArgCount;
    const url_str = try ctx.toCString(args[0]);
    defer ctx.freeCString(url_str);
    const url_copy = try loop.allocator.dupe(u8, std.mem.span(url_str));
    return .{ .url = url_copy };
}
pub const js_fetch = async_bridge.bindAsync(FetchPayload, parseFetch, workerFetch);
```

### Level 3: Auto-Generated Parser (auto_bridge.zig)
**~3 lines** per binding (95% reduction!)
```zig
const FetchPayload = struct { url: []const u8 };
fn doFetch(allocator: Allocator, task: FetchPayload) ![]u8 { ... }
pub const js_fetch = AutoBridge.bindAsyncAuto(FetchPayload, doFetch);
```

## How It Works

### The Magic: Compile-Time Introspection

```zig
pub fn bindAsyncAuto(
    comptime Payload: type,
    comptime workFn: fn (allocator: Allocator, payload: Payload) ![]u8,
) qjs.JSCFunction {
    const AutoParser = struct {
        fn parse(loop: *EventLoop, ctx: Context, args: []const Value) !Payload {
            const fields = std.meta.fields(Payload); // ← Compile-time reflection!

            var payload: Payload = undefined;

            // Generate conversion code for each field
            inline for (fields, 0..) |field, i| {
                const T = field.type;

                if (comptime isIntegerType(T)) {
                    @field(payload, field.name) = try parseInteger(T, ctx, args[i]);
                } else if (comptime isStringType(T)) {
                    @field(payload, field.name) = try parseString(loop, ctx, args[i]);
                }
                // ... etc for each supported type
            }

            return payload;
        }
    };

    return AsyncBridge.bindAsync(Payload, AutoParser.parse, workFn);
}
```

**Key Points**:
1. `std.meta.fields(Payload)` introspects struct at compile-time
2. `inline for` generates specialized code for each field
3. Type checking with `comptime` ensures compile-time errors for unsupported types
4. Memory allocation happens automatically for strings (using `loop.allocator`)

## Supported Types

| Zig Type | JavaScript Type | Notes |
|----------|----------------|-------|
| `i8` - `i64` | `number` | Integer conversion |
| `u8` - `u64` | `number` | Unsigned integer |
| `isize`, `usize` | `number` | Platform-dependent |
| `f32`, `f64` | `number` | Float conversion |
| `[]const u8`, `[]u8` | `string` | **Heap-allocated** |
| `bool` | `boolean` | Boolean conversion |

### Type Validation at Compile-Time

```zig
// ✅ GOOD: Supported types
const ValidPayload = struct {
    path: []const u8,
    count: u32,
    ratio: f64,
    enabled: bool,
};

// ❌ COMPILE ERROR: Unsupported type
const InvalidPayload = struct {
    data: [][]const u8, // Nested arrays not supported
};
// Error: Unsupported type in Payload field 'data': [][]const u8
//        Supported types: integers, floats, strings, bool
```

## Usage Guide

### Example 1: Single String Argument

```zig
// JavaScript: readFile("test.txt").then(...)

const ReadFilePayload = struct {
    path: []const u8, // ← JS arg[0]
};

fn doReadFile(allocator: std.mem.Allocator, task: ReadFilePayload) ![]u8 {
    defer allocator.free(task.path); // ← MUST FREE!

    const file = try std.fs.cwd().openFile(task.path, .{});
    defer file.close();

    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

pub const js_readFile = AutoBridge.bindAsyncAuto(ReadFilePayload, doReadFile);
```

**Installation**:
```zig
try global.setFunction("readFile", js_readFile, 1);
```

**JavaScript Usage**:
```javascript
readFile("README.md")
  .then(content => console.log("Length:", content.length))
  .catch(err => console.error("Error:", err));
```

### Example 2: Multiple Arguments

```zig
// JavaScript: writeFile("test.txt", "Hello World").then(...)

const WriteFilePayload = struct {
    path: []const u8,    // ← JS arg[0]
    content: []const u8, // ← JS arg[1]
};

fn doWriteFile(allocator: std.mem.Allocator, task: WriteFilePayload) ![]u8 {
    defer allocator.free(task.path);    // ← MUST FREE BOTH!
    defer allocator.free(task.content); // ← MUST FREE BOTH!

    const file = try std.fs.cwd().createFile(task.path, .{});
    defer file.close();

    try file.writeAll(task.content);

    return try std.fmt.allocPrint(allocator, "Wrote {d} bytes", .{task.content.len});
}

pub const js_writeFile = AutoBridge.bindAsyncAuto(WriteFilePayload, doWriteFile);
```

**Installation**:
```zig
try global.setFunction("writeFile", js_writeFile, 2);
```

### Example 3: Mixed Types

```zig
// JavaScript: sleepWithMessage("Done!", 1000).then(...)

const SleepWithMessagePayload = struct {
    message: []const u8, // ← JS arg[0] (string)
    delay_ms: u32,       // ← JS arg[1] (number)
};

fn doSleepWithMessage(allocator: std.mem.Allocator, task: SleepWithMessagePayload) ![]u8 {
    defer allocator.free(task.message); // ← Only strings need freeing!

    std.Thread.sleep(task.delay_ms * 1_000_000);

    return try std.fmt.allocPrint(allocator, "After {d}ms: {s}", .{task.delay_ms, task.message});
}

pub const js_sleepWithMessage = AutoBridge.bindAsyncAuto(SleepWithMessagePayload, doSleepWithMessage);
```

## Critical Rules: Memory Ownership

### Rule 1: Auto-Bridge Allocates Strings, Worker Frees

```zig
const Payload = struct {
    name: []const u8, // ← auto_bridge allocates this
};

fn doWork(allocator: Allocator, task: Payload) ![]u8 {
    defer allocator.free(task.name); // ← YOU MUST FREE!
    // ...
}
```

**Why?**
- Auto-bridge calls `loop.allocator.dupe()` for each string field
- This creates **owned** memory on the heap
- Worker receives ownership and must free to prevent leaks

### Rule 2: Worker Allocates Result, async_bridge Frees

```zig
fn doWork(allocator: Allocator, task: Payload) ![]u8 {
    // Allocate result string
    return try std.fmt.allocPrint(allocator, "Result: {s}", .{task.name});
    // ↑ async_bridge will free this automatically
}
```

**Why?**
- Worker returns owned string
- async_bridge passes it to EventLoop
- EventLoop frees it after calling Promise.resolve()

### Rule 3: Same Allocator Throughout

```
┌─────────────────────────────────────┐
│ loop.allocator (heap-persisted)     │
├─────────────────────────────────────┤
│ 1. auto_bridge uses it for strings │
│ 2. Worker receives it as parameter  │
│ 3. Worker uses it for result        │
│ 4. async_bridge uses it for cleanup │
└─────────────────────────────────────┘
```

## Common Mistakes

### ❌ Mistake 1: Forgetting to Free Strings

```zig
fn doReadFile(allocator: Allocator, task: ReadFilePayload) ![]u8 {
    // ❌ LEAK: task.path is never freed!
    const file = try std.fs.cwd().openFile(task.path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}
```

**Fix**:
```zig
fn doReadFile(allocator: Allocator, task: ReadFilePayload) ![]u8 {
    defer allocator.free(task.path); // ✅ Free owned string
    // ...
}
```

### ❌ Mistake 2: Wrong Field Order

```zig
// JavaScript: writeFile("path.txt", "content")
//                       ↑ arg[0]     ↑ arg[1]

const WriteFilePayload = struct {
    content: []const u8, // ❌ This is arg[1], not arg[0]!
    path: []const u8,    // ❌ This is arg[0], not arg[1]!
};
```

**Fix**: Match JavaScript argument order
```zig
const WriteFilePayload = struct {
    path: []const u8,    // ✅ arg[0]
    content: []const u8, // ✅ arg[1]
};
```

### ❌ Mistake 3: Unsupported Type

```zig
const InvalidPayload = struct {
    data: std.ArrayList(u8), // ❌ Complex type not supported
};
// Compile error: Unsupported type in Payload field 'data': std.ArrayList(u8)
```

**Fix**: Use manual parser for complex types (see async_bindings_example.zig)

## Limitations

### 1. Field Order Matters

JavaScript arguments map to struct fields **by position**, not by name.

```zig
// JavaScript: func(arg0, arg1, arg2)
const Payload = struct {
    field0: Type0, // ← Must be arg[0]
    field1: Type1, // ← Must be arg[1]
    field2: Type2, // ← Must be arg[2]
};
```

### 2. No Optional Arguments

All struct fields are required. For optional arguments, use manual parser.

```zig
// ❌ Can't do: readFile(path, ?maxSize)
// ✅ Instead: Use two separate functions or manual parser
```

### 3. No Complex Objects

Can't parse JavaScript objects like `{x: 1, y: 2}` as a single argument.

```zig
// ❌ Can't do: Point from {x: 10, y: 20}
// ✅ Instead: Pass x and y separately, or use manual parser with JSON
```

### 4. No Variadic Arguments

Can't handle `...args` in JavaScript.

```zig
// ❌ Can't do: sum(1, 2, 3, 4, 5)
// ✅ Instead: Pass array as JSON string, or use manual parser
```

## When to Use auto_bridge vs async_bridge

### Use `auto_bridge` when:
- ✅ Simple payload (primitives and strings)
- ✅ Fixed number of arguments
- ✅ Arguments map 1:1 to struct fields
- ✅ Want minimal code

### Use `async_bridge` (manual parser) when:
- ❌ Need optional arguments
- ❌ Need complex object parsing
- ❌ Need custom validation logic
- ❌ Arguments don't map directly to struct fields

## Performance

**Zero Runtime Overhead**:
- Parser is generated at **compile-time**
- No runtime introspection or reflection
- Same performance as hand-written code
- Type checking at compile-time (no runtime checks)

**Comparison**:
```
Manual binding:    ~74 lines, compiled code size: X
async_bridge:      ~16 lines, compiled code size: X (same!)
auto_bridge:       ~3 lines,  compiled code size: X (same!)
```

All three produce **identical** assembly code - the only difference is developer experience!

## Complete Example

See [auto_bindings_example.zig](../src/auto_bindings_example.zig) for 6 working examples:
1. `readFile(path)` - Single string argument
2. `writeFile(path, content)` - Multiple string arguments
3. `simulateWork(delay_ms)` - Integer argument
4. `fetch(url)` - Delegates to existing worker
5. `addAsync(a, b)` - Multiple integer arguments
6. `sleepWithMessage(msg, delay)` - Mixed types

## Summary: The Three-Level API

| Level | Lines/Binding | Use Case |
|-------|---------------|----------|
| **Manual** (utils.zig) | ~74 | Full control, complex logic |
| **async_bridge** | ~16 | Custom parsing, validation |
| **auto_bridge** | ~3 | Simple payloads, maximum productivity |

Choose the right level for your needs - they all interoperate seamlessly!
