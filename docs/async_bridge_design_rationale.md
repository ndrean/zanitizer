# async_bridge Design Rationale: Why Pass EventLoop to Parser?

## The Design Question

Should the parser function signature be:

**Option A** (Original):
```zig
fn parseFn(ctx: zqjs.Context, args: []const zqjs.Value) !Payload
```

**Option B** (Improved):
```zig
fn parseFn(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !Payload
```

## The Answer: Option B is Superior

We chose **Option B** for several critical reasons.

## Reason 1: Explicit Allocator Ownership

### The Problem with Option A

```zig
fn parseReadFile(ctx: zqjs.Context, args: []const zqjs.Value) !Worker.ReadFilePayload {
    // ❌ WHERE DO WE GET THE ALLOCATOR?

    // Option 1: Get from context (requires lookup)
    const loop = EventLoop.getFromContext(ctx) orelse return error.NoEventLoop;
    const owned_path = try loop.allocator.dupe(u8, path_str);

    // Option 2: Use a different allocator? (WRONG! Memory will outlive it)
    // var arena = std.heap.ArenaAllocator.init(...);
    // const owned_path = try arena.allocator().dupe(u8, path_str); // ❌ LEAK!
}
```

### The Solution with Option B

```zig
fn parseReadFile(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !Worker.ReadFilePayload {
    // ✅ DIRECT ACCESS - No ambiguity about which allocator to use
    const owned_path = try loop.allocator.dupe(u8, path_str);
    return .{ .path = owned_path };
}
```

**Why this matters**:
- The parser must allocate memory that will be freed **on a different thread**
- The allocator must be **heap-persisted** (lives longer than the parser call)
- Passing `loop` explicitly makes this contract **clear and enforced**

## Reason 2: Performance - One Lookup vs Two

### Option A: Two Lookups

```zig
pub fn bindAsync(...) {
    const Binder = struct {
        fn callback(...) {
            // Lookup #1: In async_bridge wrapper
            const loop = EventLoop.getFromContext(ctx) orelse return error;

            // Call parser (parser needs loop)
            const payload = parseFn(ctx, args) catch ...;
            //                       ↑
            //                       Parser must do ANOTHER lookup:

            // Lookup #2: Inside parser
            const loop = EventLoop.getFromContext(ctx) orelse return error;
        }
    };
}
```

**Cost**: 2 hash table lookups + 2 null checks

### Option B: One Lookup

```zig
pub fn bindAsync(...) {
    const Binder = struct {
        fn callback(...) {
            // Lookup #1: ONCE in async_bridge wrapper
            const loop = EventLoop.getFromContext(ctx) orelse return error;

            // Pass it down
            const payload = parseFn(loop, ctx, args) catch ...;
            //                       ↑
            //                       Parser uses it directly (no lookup!)
        }
    };
}
```

**Cost**: 1 hash table lookup + 1 null check

**Benefit**: Faster, simpler, clearer intent

## Reason 3: Emphasizes EventLoop.create() Design

The EventLoop uses **heap allocation** intentionally:

```zig
// event_loop.zig
pub fn create(allocator: std.mem.Allocator, rt: *zqjs.Runtime) !*EventLoop {
    // ↓ HEAP allocation (not stack!)
    const self = try allocator.create(EventLoop);

    self.* = .{
        .allocator = allocator,  // ← This allocator persists on the heap
        .rt = rt,
        .thread_pool = undefined,
    };

    return self;  // ← Returns heap pointer
}
```

**Why heap allocation?**
- The EventLoop must outlive the function that creates it
- `self.allocator` must be accessible from **worker threads**
- Stack-allocated EventLoop would cause **use-after-free**

**Why `create()` instead of `init()`?**
- Zig convention: `init()` for stack, `create()` for heap
- Naming emphasizes that this is **heap-allocated state**

**How Option B reinforces this:**
```zig
fn parseReadFile(loop: *EventLoop, ...) {
    //                ↑
    //                This is a POINTER to HEAP memory
    //
    const owned_path = try loop.allocator.dupe(...);
    //                      ↑
    //                      This allocator PERSISTS (heap-allocated)
    //                      Worker thread will safely use it later
}
```

Passing `loop: *EventLoop` makes it **obvious** that:
1. We're dealing with a heap-allocated struct
2. The allocator inside it persists beyond this function call
3. Memory allocated here will be freed elsewhere (worker thread)

## Reason 4: Type Safety and Documentation

### Option A: Hidden Contract

```zig
// ❌ Not obvious where allocator comes from
fn parseReadFile(ctx: zqjs.Context, args: []const zqjs.Value) !Worker.ReadFilePayload {
    // Developer must know:
    // 1. Use EventLoop.getFromContext(ctx)
    // 2. Don't use ctx's allocator (if it had one)
    // 3. Don't use a temporary allocator
    // 4. The allocator must persist across threads

    // Easy to get wrong!
}
```

### Option B: Explicit Contract

```zig
// ✅ Signature documents the requirement
fn parseReadFile(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !Worker.ReadFilePayload {
    //             ↑
    //             "You have access to the EventLoop and should use loop.allocator"

    const owned_path = try loop.allocator.dupe(u8, path_str);
    // ↑ Obvious and correct
}
```

**Benefits**:
- **Self-documenting**: Function signature tells you what you need
- **Harder to misuse**: No ambiguity about which allocator to use
- **Better IDE support**: Autocomplete shows `loop.allocator` immediately

## Reason 5: Consistency with Worker Function

The worker function already receives the allocator explicitly:

```zig
fn workerReadFile(allocator: std.mem.Allocator, payload: ReadFilePayload) ![]u8 {
    //             ↑
    //             Explicit allocator parameter
}
```

With Option B, the parser mirrors this pattern:

```zig
fn parseReadFile(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !ReadFilePayload {
    //             ↑
    //             Explicit EventLoop parameter (contains allocator)
}
```

**Consistency**: Both functions explicitly receive their allocator source as a parameter.

## Real-World Impact

Consider a developer adding a new async operation:

### With Option A (Implicit)

```zig
fn parseMyNewThing(ctx: zqjs.Context, args: []const zqjs.Value) !MyPayload {
    // Hmm, I need to allocate a string...
    // Where do I get an allocator?

    // ❌ Wrong: Use a temporary allocator
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const data = try fba.allocator().dupe(u8, str); // LEAK!

    // ❌ Wrong: Look up loop but forget error handling
    const loop = EventLoop.getFromContext(ctx).?; // Panic if null!

    // ✅ Right: But had to read docs / existing code to learn this
    const loop = EventLoop.getFromContext(ctx) orelse return error.NoEventLoop;
    const data = try loop.allocator.dupe(u8, str);
}
```

### With Option B (Explicit)

```zig
fn parseMyNewThing(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !MyPayload {
    // I need to allocate a string
    // I have 'loop' parameter
    // Obviously I should use loop.allocator!

    // ✅ Right: Obvious from function signature
    const data = try loop.allocator.dupe(u8, str);
}
```

**Result**: Fewer bugs, clearer code, faster development.

## Comparison Table

| Aspect | Option A (Implicit) | Option B (Explicit) |
|--------|---------------------|---------------------|
| **Performance** | 2 lookups | 1 lookup |
| **Clarity** | Hidden contract | Self-documenting |
| **Safety** | Easy to use wrong allocator | Hard to misuse |
| **Consistency** | Different from worker | Consistent with worker |
| **Emphasis** | Obscures heap allocation | Emphasizes heap allocation |
| **Onboarding** | Requires reading docs | Obvious from signature |

## Conclusion

**Option B** (`loop: *EventLoop` parameter) is the superior design because it:

1. ✅ Makes allocator ownership **explicit and unambiguous**
2. ✅ Reduces redundant EventLoop lookups (**better performance**)
3. ✅ Reinforces the `EventLoop.create()` heap-allocation design
4. ✅ Provides **type safety** through the function signature
5. ✅ Maintains **consistency** with worker function patterns
6. ✅ Makes the code **self-documenting** and harder to misuse

The key insight: **Passing `loop` makes the async boundary visible and explicit**. When you see `loop: *EventLoop` in the signature, you immediately know:
- This is part of an async operation
- The allocator persists beyond this call
- Memory ownership will transfer to a worker thread

This design makes the entire async_bridge framework **clearer, safer, and faster**.
