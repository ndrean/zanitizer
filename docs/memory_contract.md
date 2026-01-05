# Memory Contract: AutoBridge Allocation Rules

## The Critical Contract

**AutoBridge allocates memory. Your worker MUST free it.**

When you use `auto_bridge.zig`, you enter into an **implicit memory contract**:

```zig
┌─────────────────────────────────────────────────────────────┐
│ AutoBridge allocates:                                       │
│   - ALL string fields ([]const u8, []u8) in Payload struct  │
│   - Uses loop.allocator (heap-persisted)                    │
│   - Happens in parseString() during argument extraction     │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Your Worker MUST free:                                      │
│   - ALL string fields received in payload                   │
│   - Use the same allocator passed as parameter              │
│   - Failure to do so = MEMORY LEAK                          │
└─────────────────────────────────────────────────────────────┘
```

## Example: Single String Field

```zig
const ReadFilePayload = struct {
    path: []const u8, // ← AutoBridge allocates this
};

fn doReadFile(allocator: std.mem.Allocator, task: ReadFilePayload) ![]u8 {
    // ⚠️ CRITICAL: Free the string AutoBridge allocated!
    defer allocator.free(task.path);

    const file = try std.fs.cwd().openFile(task.path, .{});
    defer file.close();

    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}
```

## Example: Multiple String Fields

```zig
const WriteFilePayload = struct {
    path: []const u8,    // ← AutoBridge allocates this
    content: []const u8, // ← AutoBridge allocates this
};

fn doWriteFile(allocator: std.mem.Allocator, task: WriteFilePayload) ![]u8 {
    // ⚠️ CRITICAL: Free BOTH strings!
    defer allocator.free(task.path);
    defer allocator.free(task.content);

    const file = try std.fs.cwd().createFile(task.path, .{});
    defer file.close();

    try file.writeAll(task.content);

    return try std.fmt.allocPrint(allocator, "Wrote {d} bytes to {s}", .{task.content.len, task.path});
}
```

## Why This Contract Exists

### The Memory Boundary Problem

JavaScript and Zig have different memory models:

```
JavaScript Side                 Zig Side
┌─────────────────┐            ┌─────────────────┐
│ Garbage         │            │ Manual          │
│ Collected       │   Bridge   │ Management      │
│ Strings         │  ════════► │ (allocator)     │
└─────────────────┘            └─────────────────┘
     Temporary                      Persistent
```

**The Bridge's Job**: Convert temporary JS strings to persistent Zig strings

```zig
// In parseString():
const temp_str = try ctx.toCString(arg);  // ← Temporary (JS owns)
defer ctx.freeCString(temp_str);

const heap_str = try loop.allocator.dupe(u8, std.mem.span(temp_str));
//    ↑ Persistent (You now own!)

return heap_str; // ← Ownership transferred to worker
```

### Why Not Free in AutoBridge?

**Q**: Why doesn't AutoBridge free the strings itself?

**A**: Because the worker needs them!

```zig
// ❌ BAD: If AutoBridge freed immediately
fn parse(...) !Payload {
    const str = try loop.allocator.dupe(u8, temp_str);
    defer loop.allocator.free(str); // ← String freed before worker runs!
    return .{ .path = str }; // ← Dangling pointer!
}
```

**The worker runs on a different thread, later.** The parser can't know when the worker is done.

### The Ownership Transfer

```
┌─────────────────────────────────────────────────────────────┐
│ parseString()                                               │
├─────────────────────────────────────────────────────────────┤
│ 1. Extract "test.txt" from JS (temporary)                   │
│ 2. Allocate heap copy: loop.allocator.dupe()                │
│ 3. Return heap copy                                         │
│    → Ownership transferred to caller                        │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ AutoParser.parse()                                          │
├─────────────────────────────────────────────────────────────┤
│ 1. Receive heap copy from parseString()                     │
│ 2. Store in payload.path                                    │
│ 3. Return payload                                           │
│    → Ownership transferred to async_bridge                  │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ async_bridge (spawns worker)                                │
├─────────────────────────────────────────────────────────────┤
│ 1. Receive payload                                          │
│ 2. Spawn worker with payload                                │
│    → Ownership transferred to worker                        │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Worker Thread: doReadFile()                                 │
├─────────────────────────────────────────────────────────────┤
│ 1. Receive payload (now owns payload.path)                  │
│ 2. defer allocator.free(payload.path) ← MUST FREE!          │
│ 3. Use path to open file                                    │
│ 4. When function returns, defer triggers → memory freed     │
└─────────────────────────────────────────────────────────────┘
```

## Compile-Time Safety Features

### 1. Documentation in Doc Comments

The function documentation clearly states the contract:

```zig
/// ⚠️ CRITICAL MEMORY CONTRACT:
/// AutoBridge allocates memory for ALL string fields in your Payload struct.
/// Your worker function MUST free these fields, or you will leak memory!
```

### 2. Compile-Time Warnings

When you use `bindAsyncAuto`, the compiler will log warnings:

```
⚠️  MEMORY CONTRACT WARNING for Worker.WriteFilePayload:
   AutoBridge allocated string fields: 'path', 'content'
   Your worker function MUST free these with:
     defer allocator.free(payload.'path', 'content');
   Failure to do so will cause memory leaks!
```

### 3. Type Safety

Only supported types are allowed:

```zig
const InvalidPayload = struct {
    data: std.ArrayList(u8), // ❌ Compile error!
};
```

## Common Mistakes

### ❌ Mistake 1: Forgetting to Free

```zig
fn doReadFile(allocator: std.mem.Allocator, task: ReadFilePayload) ![]u8 {
    // ❌ LEAK: task.path is never freed!
    const file = try std.fs.cwd().openFile(task.path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, max_size);
}
```

**Fix**: Add `defer allocator.free(task.path);`

### ❌ Mistake 2: Using Wrong Allocator

```zig
fn doReadFile(allocator: std.mem.Allocator, task: ReadFilePayload) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // ❌ LEAK: task.path was allocated with loop.allocator,
    // but you're trying to free with arena.allocator()!
    arena.allocator().free(task.path); // Won't work!

    // ...
}
```

**Fix**: Use the `allocator` parameter (which IS `loop.allocator`)

```zig
defer allocator.free(task.path); // ✅ Correct!
```

### ❌ Mistake 3: Freeing Too Early

```zig
fn doReadFile(allocator: std.mem.Allocator, task: ReadFilePayload) ![]u8 {
    allocator.free(task.path); // ❌ Freed immediately!

    // ❌ Dangling pointer - use-after-free!
    const file = try std.fs.cwd().openFile(task.path, .{});
    // ...
}
```

**Fix**: Use `defer` to free at function exit

```zig
defer allocator.free(task.path); // ✅ Freed when function returns
```

## Non-String Fields Don't Need Freeing

```zig
const MixedPayload = struct {
    name: []const u8,  // ← String: AutoBridge allocates, YOU free
    count: u32,        // ← Integer: Copied by value, no allocation
    ratio: f64,        // ← Float: Copied by value, no allocation
    enabled: bool,     // ← Boolean: Copied by value, no allocation
};

fn doWork(allocator: std.mem.Allocator, task: MixedPayload) ![]u8 {
    // Only free the string field!
    defer allocator.free(task.name);

    // count, ratio, enabled don't need freeing (stack values)

    // ...
}
```

**Rule**: Only `[]const u8` and `[]u8` fields are heap-allocated.

## Verification Checklist

Before deploying your worker function:

- [ ] **Identified all string fields** in your Payload struct
- [ ] **Added `defer allocator.free()`** for each string field
- [ ] **Used the correct allocator** (the one passed as parameter)
- [ ] **Placed `defer` at function start** (not in the middle)
- [ ] **Tested with multiple calls** (to catch leaks)

## Memory Leak Detection

To detect leaks during development:

```zig
// In your test code
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer {
    const leaked = gpa.deinit();
    if (leaked == .leak) {
        std.debug.print("❌ MEMORY LEAK DETECTED!\n", .{});
    }
}

// Use GPA for EventLoop
const loop = try EventLoop.create(gpa.allocator(), rt);
```

Run your tests - if you see "MEMORY LEAK DETECTED", check your worker functions!

## Summary

The memory contract is simple but critical:

1. **AutoBridge allocates** string fields automatically
2. **You own** those strings when they arrive in your worker
3. **You must free** them using the allocator parameter
4. **Use `defer`** to ensure cleanup happens

**Remember**: This is the price of zero-boilerplate convenience. AutoBridge does the parsing for you, but ownership rules still apply!

## Example: Perfect Worker Function

```zig
const CompleteExample = struct {
    input_path: []const u8,  // AutoBridge allocates
    output_path: []const u8, // AutoBridge allocates
    mode: u32,               // Copied by value
};

fn perfectWorker(allocator: std.mem.Allocator, task: CompleteExample) ![]u8 {
    // ✅ STEP 1: Free ALL string fields at function exit
    defer allocator.free(task.input_path);
    defer allocator.free(task.output_path);

    // ✅ STEP 2: Use the strings safely (they're valid until function returns)
    const input = try std.fs.cwd().openFile(task.input_path, .{});
    defer input.close();

    const output = try std.fs.cwd().createFile(task.output_path, .{});
    defer output.close();

    // ✅ STEP 3: Do your work
    // ... copy input to output ...

    // ✅ STEP 4: Return owned result (allocator will be freed by async_bridge)
    return try std.fmt.allocPrint(
        allocator,
        "Processed {s} -> {s} (mode: {d})",
        .{ task.input_path, task.output_path, task.mode },
    );

    // ✅ When function returns:
    // - defer frees task.input_path
    // - defer frees task.output_path
    // - Result is owned by caller (async_bridge)
}
```

**This is the pattern.** Follow it, and you'll never leak memory! 🎯
