const std = @import("std");
const qjs = @import("root.zig").qjs;

// pub const ClassID = u32;

pub const ArrayBuffer = struct {
    buffer: Value,
    byte_offset: usize,
    byte_length: usize,
    bytes_per_element: usize,
};

pub const Atom = qjs.JSAtom;
pub const Value = qjs.JSValue;

pub const NULL = Value{ .tag = qjs.JS_TAG_NULL, .u = .{ .int32 = 0 } };
pub const UNDEFINED = Value{ .tag = qjs.JS_TAG_UNDEFINED, .u = .{ .int32 = 0 } };
pub const FALSE = Value{ .tag = qjs.JS_TAG_BOOL, .u = .{ .int32 = 0 } };
pub const TRUE = Value{ .tag = qjs.JS_TAG_BOOL, .u = .{ .int32 = 1 } };
pub const EXCEPTION = Value{ .tag = qjs.JS_TAG_EXCEPTION, .u = .{ .int32 = 0 } };
pub const UNINITIALIZED = Value{ .tag = qjs.JS_TAG_UNINITIALIZED, .u = .{ .int32 = 0 } };

// pub const EXCEPTION = qjs.JS_EXCEPTION;

pub const TypedArrayType = enum(c_int) {
    Uint8ClampedArray = qjs.JS_TYPED_ARRAY_UINT8C,
    Int8Array = qjs.JS_TYPED_ARRAY_INT8,
    Uint8Array = qjs.JS_TYPED_ARRAY_UINT8,
    Int16Array = qjs.JS_TYPED_ARRAY_INT16,
    Uint16Array = qjs.JS_TYPED_ARRAY_UINT16,
    Int32Array = qjs.JS_TYPED_ARRAY_INT32,
    Uint32Array = qjs.JS_TYPED_ARRAY_UINT32,
    BigInt64Array = qjs.JS_TYPED_ARRAY_BIG_INT64,
    BigUint64Array = qjs.JS_TYPED_ARRAY_BIG_UINT64,
    Float16Array = qjs.JS_TYPED_ARRAY_FLOAT16,
    Float32Array = qjs.JS_TYPED_ARRAY_FLOAT32,
    Float64Array = qjs.JS_TYPED_ARRAY_FLOAT64,
    _,
};

const S = @sizeOf(usize);
const H = @max(8, S);

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    ptr: ?*qjs.JSRuntime,

    // Legacy QuickJS uses JSMallocState instead of runtime_ptr
    fn js_malloc(state: [*c]qjs.JSMallocState, size: usize) callconv(.c) ?*anyopaque {
        // Get Runtime from the opaque field in JSMallocState
        const runtime: *const Runtime = @ptrCast(@alignCast(state.*.@"opaque"));
        const result = runtime.allocator.alloc(u8, H + size) catch |err|
            @panic(@errorName(err));
        std.mem.writeInt(usize, result[0..S], size, .little);
        return result[H..].ptr;
    }

    fn js_free(state: [*c]qjs.JSMallocState, ptr: ?*anyopaque) callconv(.c) void {
        if (ptr == null) return;
        const runtime: *const Runtime = @ptrCast(@alignCast(state.*.@"opaque"));
        const result: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - H);
        const len = std.mem.readInt(usize, result[0..S], .little);
        runtime.allocator.free(result[0 .. H + len]);
    }

    fn js_realloc(state: [*c]qjs.JSMallocState, ptr: ?*anyopaque, new_len: usize) callconv(.c) ?*anyopaque {
        const runtime: *const Runtime = @ptrCast(@alignCast(state.*.@"opaque"));
        if (ptr == null) {
            // Realloc with null pointer is same as malloc
            const result = runtime.allocator.alloc(u8, H + new_len) catch |err|
                @panic(@errorName(err));
            std.mem.writeInt(usize, result[0..S], new_len, .little);
            return result[H..].ptr;
        }
        const old_ptr: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - H);
        const old_len = std.mem.readInt(usize, old_ptr[0..S], .little);
        const result = runtime.allocator.realloc(old_ptr[0 .. H + old_len], H + new_len) catch |err|
            @panic(@errorName(err));
        std.mem.writeInt(usize, result[0..S], new_len, .little);
        return result[H..].ptr;
    }

    fn js_malloc_usable_size(_: ?*const anyopaque) callconv(.c) usize {
        return 0;
    }

    const malloc_functions = qjs.JSMallocFunctions{
        .js_malloc = &js_malloc,
        .js_free = &js_free,
        .js_realloc = &js_realloc,
        .js_malloc_usable_size = &js_malloc_usable_size,
    };

    pub fn init(allocator: std.mem.Allocator) !*Runtime {
        const runtime = try allocator.create(Runtime);
        runtime.allocator = allocator;
        runtime.ptr = qjs.JS_NewRuntime2(&malloc_functions, @constCast(runtime));
        return runtime;
    }

    pub fn deinit(self: *const Runtime) void {
        qjs.JS_FreeRuntime(self.ptr);
        self.allocator.destroy(self);
    }

    /// use 0 to disable memory limit
    pub inline fn setMemoryLimit(self: *const Runtime, limit: usize) void {
        qjs.JS_SetMemoryLimit(self.ptr, limit);
    }

    pub inline fn setGCThreshold(self: *const Runtime, gc_threshold: usize) void {
        qjs.JS_SetGCThreshold(self.ptr, gc_threshold);
    }

    pub inline fn getGCThreshold(self: *const Runtime) usize {
        return qjs.JS_GetGCThreshold(self.ptr);
    }

    pub inline fn setMaxStackSize(self: *const Runtime, stack_size: usize) void {
        qjs.JS_SetMaxStackSize(self.ptr, stack_size);
    }

    pub inline fn updateStackTop(self: *const Runtime) void {
        qjs.JS_UpdateStackTop(self.ptr);
    }

    pub inline fn setRuntimeInfo(self: *const Runtime, info: []const u8) void {
        qjs.JS_SetRuntimeInfo(self.ptr, info.ptr);
    }

    pub inline fn setDumpFlags(self: *const Runtime, flags: u64) void {
        qjs.JS_SetDumpFlags(self.ptr, flags);
    }

    pub inline fn getDumpFlags(self: *const Runtime) u64 {
        return qjs.JS_GetDumpFlags(self.ptr);
    }

    pub inline fn setRuntimeOpaque(self: *const Runtime, ptr: ?*anyopaque) void {
        qjs.JS_SetRuntimeOpaque(self.ptr, ptr);
    }

    pub inline fn getRuntimeOpaque(self: *const Runtime) ?*anyopaque {
        return qjs.JS_GetRuntimeOpaque(self.ptr);
    }

    pub inline fn runGC(self: *const Runtime) void {
        qjs.JS_RunGC(self.ptr);
    }

    pub inline fn isLiveObject(self: *const Runtime, obj: Value) bool {
        return qjs.JS_IsLiveObject(self.ptr, obj);
    }

    pub inline fn markValue(self: *const Runtime, val: Value, mark_func: qjs.JS_MarkFunc) void {
        qjs.JS_MarkValue(self.ptr, val, mark_func);
    }

    pub inline fn freeValue(self: *const Runtime, val: Value) void {
        qjs.JS_FreeValueRT(self.ptr, val);
    }

    pub inline fn dupValue(self: *const Runtime, val: Value) Value {
        return qjs.JS_DupValueRT(self.ptr, val);
    }

    // pub inline fn newClassID(self: Runtime) !ClassID {
    //     var class_id: ClassID = qjs.JS_INVALID_CLASS_ID;
    //     if (qjs.JS_NewClassID(self.ptr, &class_id) == 0)
    //         return error.ClassIDFailed;

    //     return class_id;
    // }

    // pub inline fn isRegisteredClass(self: Runtime, class_id: ClassID) bool {
    //     return qjs.JS_IsRegisteredClass(self.ptr, class_id);
    // }

    // pub const ClassFinalizer = fn (?*Runtime, Value) void;
    // // pub const MarkFunc = fn (?*Runtime, ?*GCObjectHeader) void;
    // // pub const GCMark = fn (?*Runtime, Value, ?*const MarkFunc) void;
    // pub const ClassDef = struct {
    //     class_name: [*:0]const u8 = null,
    //     finalizer: ?*const ClassFinalizer = null,
    //     // gc_mark: ?*const JSClassGCMark = @import("std").mem.zeroes(?*const JSClassGCMark),
    //     // call: ?*const JSClassCall = @import("std").mem.zeroes(?*const JSClassCall),
    //     // exotic: [*c]JSClassExoticMethods = @import("std").mem.zeroes([*c]JSClassExoticMethods),
    // };

    // pub inline fn newClass(self: Runtime, class_id: ClassID, class_def: *const qjs.JSClassDef) !void {
    //     if (qjs.JS_NewClass(self.ptr, class_id, class_def) < 0)
    //         return error.NewClassFailed;
    // }

    // Job queue management
    pub inline fn isJobPending(self: *const Runtime) bool {
        return qjs.JS_IsJobPending(self.ptr);
    }

    pub inline fn executePendingJob(self: *const Runtime) !?Context {
        var pctx: ?*qjs.JSContext = null;
        const ret = qjs.JS_ExecutePendingJob(self.ptr, &pctx);
        if (ret < 0) return error.ExecuteJobFailed;
        if (pctx == null) return null;
        return Context{ .ptr = pctx };
    }

    pub const MemoryUsage = packed struct {
        malloc_size: i64,
        malloc_limit: i64,
        memory_used_size: i64,
        malloc_count: i64,
        memory_used_count: i64,
        atom_count: i64,
        atom_size: i64,
        str_count: i64,
        str_size: i64,
        obj_count: i64,
        obj_size: i64,
        prop_count: i64,
        prop_size: i64,
        shape_count: i64,
        shape_size: i64,
        js_func_count: i64,
        js_func_size: i64,
        js_func_code_size: i64,
        js_func_pc2line_count: i64,
        js_func_pc2line_size: i64,
        c_func_count: i64,
        array_count: i64,
        fast_array_count: i64,
        fast_array_elements: i64,
        binary_object_count: i64,
        binary_object_size: i64,
    };

    // Memory management utilities
    pub inline fn computeMemoryUsage(self: *const Runtime) MemoryUsage {
        var usage: qjs.JSMemoryUsage = undefined;
        qjs.JS_ComputeMemoryUsage(self.ptr, &usage);
        return .{
            .malloc_size = usage.malloc_size,
            .malloc_limit = usage.malloc_limit,
            .memory_used_size = usage.memory_used_size,
            .malloc_count = usage.malloc_count,
            .memory_used_count = usage.memory_used_count,
            .atom_count = usage.atom_count,
            .atom_size = usage.atom_size,
            .str_count = usage.str_count,
            .str_size = usage.str_size,
            .obj_count = usage.obj_count,
            .obj_size = usage.obj_size,
            .prop_count = usage.prop_count,
            .prop_size = usage.prop_size,
            .shape_count = usage.shape_count,
            .shape_size = usage.shape_size,
            .js_func_count = usage.js_func_count,
            .js_func_size = usage.js_func_size,
            .js_func_code_size = usage.js_func_code_size,
            .js_func_pc2line_count = usage.js_func_pc2line_count,
            .js_func_pc2line_size = usage.js_func_pc2line_size,
            .c_func_count = usage.c_func_count,
            .array_count = usage.array_count,
            .fast_array_count = usage.fast_array_count,
            .fast_array_elements = usage.fast_array_elements,
            .binary_object_count = usage.binary_object_count,
            .binary_object_size = usage.binary_object_size,
        };
    }

    pub inline fn dumpMemoryUsage(self: *const Runtime, usage: *const MemoryUsage, file: std.fs.File) void {
        qjs.JS_DumpMemoryUsage(file.handle, &.{
            .malloc_size = usage.malloc_size,
            .malloc_limit = usage.malloc_limit,
            .memory_used_size = usage.memory_used_size,
            .malloc_count = usage.malloc_count,
            .memory_used_count = usage.memory_used_count,
            .atom_count = usage.atom_count,
            .atom_size = usage.atom_size,
            .str_count = usage.str_count,
            .str_size = usage.str_size,
            .obj_count = usage.obj_count,
            .obj_size = usage.obj_size,
            .prop_count = usage.prop_count,
            .prop_size = usage.prop_size,
            .shape_count = usage.shape_count,
            .shape_size = usage.shape_size,
            .js_func_count = usage.js_func_count,
            .js_func_size = usage.js_func_size,
            .js_func_code_size = usage.js_func_code_size,
            .js_func_pc2line_count = usage.js_func_pc2line_count,
            .js_func_pc2line_size = usage.js_func_pc2line_size,
            .c_func_count = usage.c_func_count,
            .array_count = usage.array_count,
            .fast_array_count = usage.fast_array_count,
            .fast_array_elements = usage.fast_array_elements,
            .binary_object_count = usage.binary_object_count,
            .binary_object_size = usage.binary_object_size,
        }, self.ptr);
    }

    // Shared ArrayBuffer support
    // pub inline fn setSharedArrayBufferFunctions(self: Runtime, functions: *const qjs.JSSharedArrayBufferFunctions) void {
    //     qjs.JS_SetSharedArrayBufferFunctions(self.ptr, functions);
    // }

    // Host callbacks
    // pub inline fn setInterruptHandler(self: Runtime, cb: ?qjs.JSInterruptHandler, ptr: ?*anyopaque) void {
    //     qjs.JS_SetInterruptHandler(self.ptr, cb, ptr);
    // }

    pub inline fn setCanBlock(self: *const Runtime, can_block: bool) void {
        qjs.JS_SetCanBlock(self.ptr, can_block);
    }

    // pub inline fn setHostPromiseRejectionTracker(self: Runtime, cb: ?qjs.JSHostPromiseRejectionTracker, ptr: ?*anyopaque) void {
    //     qjs.JS_SetHostPromiseRejectionTracker(self.ptr, cb, ptr);
    // }

    // Module system
    // pub inline fn setModuleLoaderFunc(
    //     self: Runtime,
    //     module_normalize: ?qjs.JSModuleNormalizeFunc,
    //     module_loader: ?qjs.JSModuleLoaderFunc,
    //     ptr: ?*anyopaque,
    // ) void {
    //     qjs.JS_SetModuleLoaderFunc(self.ptr, module_normalize, module_loader, ptr);
    // }

    // Runtime finalizer
    // pub inline fn addRuntimeFinalizer(self: Runtime, finalizer: qjs.JSRuntimeFinalizer, arg: ?*anyopaque) !void {
    //     const ret = qjs.JS_AddRuntimeFinalizer(self.ptr, finalizer, arg);
    //     if (ret < 0) return error.AddFinalizerFailed;
    // }
};

pub const Context = packed struct {
    ptr: ?*qjs.JSContext,

    pub inline fn init(runtime: *const Runtime) Context {
        return .{ .ptr = qjs.JS_NewContext(runtime.ptr) };
    }

    pub inline fn deinit(self: Context) void {
        qjs.JS_FreeContext(self.ptr);
    }

    // pub inline fn getRuntime(self: Context) Runtime {
    //     return .{ .ptr = qjs.JS_GetRuntime(self.ptr) };
    // }

    pub inline fn isEqual(self: Context, a: Value, b: Value) bool {
        return qjs.JS_IsEqual(self.ptr, a, b);
    }

    pub inline fn isStrictEqual(self: Context, a: Value, b: Value) bool {
        return qjs.JS_IsStrictEqual(self.ptr, a, b);
    }

    pub inline fn isSameValue(self: Context, a: Value, b: Value) bool {
        return qjs.JS_IsSameValue(self.ptr, a, b);
    }

    pub inline fn isSameValueZero(self: Context, a: Value, b: Value) bool {
        return qjs.JS_IsSameValueZero(self.ptr, a, b);
    }

    // Value creation methods

    pub inline fn dupValue(self: Context, value: Value) Value {
        return qjs.JS_DupValue(self.ptr, value);
    }

    pub inline fn newBool(_: Context, val: bool) Value {
        return qjs.JSValue{
            .tag = @as(i64, @bitCast(@as(c_longlong, qjs.JS_TAG_BOOL))),
            .u = qjs.JSValueUnion{
                .int32 = @as(c_int, @intFromBool(val)),
            },
        };
    }

    pub inline fn newInt32(self: Context, val: i32) Value {
        return qjs.JS_NewInt32(self.ptr, val);
    }

    pub inline fn newFloat64(self: Context, val: f64) Value {
        return qjs.JS_NewFloat64(self.ptr, val);
    }

    pub inline fn newInt64(self: Context, val: i64) Value {
        return qjs.JS_NewInt64(self.ptr, val);
    }

    pub inline fn newUint32(self: Context, val: u32) Value {
        return qjs.JS_NewUint32(self.ptr, val);
    }

    pub inline fn newString(self: Context, str: []const u8) Value {
        return qjs.JS_NewStringLen(self.ptr, str.ptr, str.len);
    }

    pub inline fn newSymbol(self: Context, description: []const u8, is_global: bool) Value {
        return qjs.JS_NewSymbol(self.ptr, description.ptr, is_global);
    }

    pub inline fn newAtomString(self: Context, str: []const u8) Value {
        return qjs.JS_NewAtomString(self.ptr, str.ptr);
    }

    pub inline fn newObject(self: Context) Value {
        return qjs.JS_NewObject(self.ptr);
    }

    pub inline fn newObjectClass(self: Context, class_id: i32) Value {
        return qjs.JS_NewObjectClass(self.ptr, class_id);
    }

    // pub inline fn newObjectProtoClass(self: Context, proto: Value, class_id: ClassID) Value {
    //     return qjs.JS_NewObjectProtoClass(self.ptr, proto, class_id);
    // }

    pub inline fn newArray(self: Context) Value {
        return qjs.JS_NewArray(self.ptr);
    }

    pub inline fn newDate(self: Context, epoch_ms: f64) Value {
        return qjs.JS_NewDate(self.ptr, epoch_ms);
    }

    pub inline fn newBigInt64(self: Context, val: i64) Value {
        return qjs.JS_NewBigInt64(self.ptr, val);
    }

    pub inline fn newBigUint64(self: Context, val: u64) Value {
        return qjs.JS_NewBigUint64(self.ptr, val);
    }

    // Value conversion methods
    pub inline fn toBool(self: Context, val: Value) !bool {
        const result = qjs.JS_ToBool(self.ptr, val);
        if (result == -1) return error.Exception;
        return result != 0;
    }

    pub inline fn toBoolean(self: Context, val: Value) Value {
        return self.newBool(qjs.JS_ToBool(self.ptr, val) != 0);
    }

    pub inline fn toNumber(self: Context, val: Value) Value {
        return qjs.JS_ToNumber(self.ptr, val);
    }

    pub inline fn toInt32(self: Context, val: Value) !i32 {
        var result: i32 = undefined;
        const ret = qjs.JS_ToInt32(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toUint32(self: Context, val: Value) !u32 {
        var result: u32 = undefined;
        const ret = qjs.JS_ToUint32(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toInt64(self: Context, val: Value) !i64 {
        var result: i64 = undefined;
        const ret = qjs.JS_ToInt64(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toFloat64(self: Context, val: Value) !f64 {
        var result: f64 = undefined;
        const ret = qjs.JS_ToFloat64(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toBigInt64(self: Context, val: Value) !i64 {
        var result: i64 = undefined;
        const ret = qjs.JS_ToBigInt64(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toBigUint64(self: Context, val: Value) !u64 {
        var result: u64 = undefined;
        const ret = qjs.JS_ToBigUint64(self.ptr, &result, val);
        if (ret != 0) return error.Exception;
        return result;
    }

    pub inline fn toString(self: Context, val: Value) Value {
        return qjs.JS_ToString(self.ptr, val);
    }

    pub inline fn toZString(self: Context, val: Value) ![]const u8 {
        const c_str = qjs.JS_ToCString(self.ptr, val) orelse return error.Exception;
        return std.mem.span(c_str);
    }

    pub inline fn toCString(self: Context, val: Value) ![*:0]const u8 {
        return qjs.JS_ToCString(self.ptr, val) orelse return error.Exception;
    }

    pub inline fn toCStringLen(self: Context, val: Value) ![:0]const u8 {
        var len: usize = undefined;
        const ptr = qjs.JS_ToCStringLen(self.ptr, &len, val) orelse
            return error.Exception;
        return ptr[0..len :0];
    }

    // pub inline fn toCStringOwned(self: Context, val: Value) ?[:0]const u8 {
    //     var len: usize = undefined;
    //     const str = qjs.JS_ToCStringLen(self.ptr, &len, val);
    //     if (str == null) return null;
    //     return str[0..len :0];
    // }

    pub inline fn freeCString(self: Context, ptr: [*:0]const u8) void {
        qjs.JS_FreeCString(self.ptr, ptr);
    }

    pub inline fn freeZString(self: Context, st: []const u8) void {
        qjs.JS_FreeCString(self.ptr, st.ptr);
    }

    pub inline fn toPropertyKey(self: Context, val: Value) Value {
        return qjs.JS_ToPropertyKey(self.ptr, val);
    }

    pub inline fn toObject(self: Context, val: Value) Value {
        return qjs.JS_ToObject(self.ptr, val);
    }

    // Function, object, class, and prototype related methods
    pub inline fn isNumber(_: Context, self: Value) bool {
        return qjs.JS_IsNumber(self);
    }

    pub inline fn isNull(_: Context, self: Value) bool {
        return qjs.JS_IsNull(self);
    }

    pub inline fn isUndefined(_: Context, self: Value) bool {
        return qjs.JS_IsUndefined(self);
    }

    pub inline fn isUninitialized(_: Context, self: Value) bool {
        return qjs.JS_IsUninitialized(self);
    }

    pub inline fn isString(_: Context, self: Value) bool {
        return qjs.JS_IsString(self);
    }

    pub inline fn isSymbol(_: Context, self: Value) bool {
        return qjs.JS_IsSymbol(self);
    }

    pub inline fn isObject(_: Context, self: Value) bool {
        return qjs.JS_IsObject(self);
    }

    pub inline fn isBool(_: Context, self: Value) bool {
        return qjs.JS_IsBool(self);
    }

    pub inline fn isModule(_: Context, self: Value) bool {
        return qjs.JS_IsModule(self);
    }

    pub inline fn isArray(_: Context, self: Value) bool {
        return qjs.JS_IsArray(self);
    }

    pub inline fn isDate(_: Context, self: Value) bool {
        return qjs.JS_IsDate(self);
    }

    pub inline fn isException(_: Context, self: Value) bool {
        return qjs.JS_IsException(self);
    }

    pub inline fn isPromise(_: Context, self: Value) bool {
        return qjs.JS_IsPromise(self);
    }

    pub inline fn isRegExp(_: Context, self: Value) bool {
        return qjs.JS_IsRegExp(self);
    }

    pub inline fn isMap(_: Context, self: Value) bool {
        return qjs.JS_IsMap(self);
    }

    pub inline fn isProxy(_: Context, self: Value) bool {
        return qjs.JS_IsProxy(self);
    }

    pub inline fn isArrayBuffer(_: Context, self: Value) bool {
        return qjs.JS_IsArrayBuffer(self);
    }

    pub inline fn isFunction(self: Context, val: Value) bool {
        return qjs.JS_IsFunction(self.ptr, val);
    }

    pub inline fn isConstructor(self: Context, val: Value) bool {
        return qjs.JS_IsConstructor(self.ptr, val);
    }

    pub inline fn isError(self: Context, val: Value) bool {
        return qjs.JS_IsError(self.ptr, val);
    }

    pub inline fn isBigInt(self: Context, val: Value) bool {
        return qjs.JS_IsBigInt(self.ptr, val);
    }

    pub inline fn getPrototype(self: Context, val: Value) Value {
        return qjs.JS_GetPrototype(self.ptr, val);
    }

    pub inline fn setPrototype(self: Context, obj: Value, proto: Value) !void {
        const ret = qjs.JS_SetPrototype(self.ptr, obj, proto);
        if (ret < 0) return error.Exception;
    }

    pub inline fn getProxyTarget(self: Context, proxy: Value) Value {
        return qjs.JS_GetProxyTarget(self.ptr, proxy.val);
    }

    pub inline fn getProxyHandler(self: Context, proxy: Value) Value {
        return qjs.JS_GetProxyHandler(self.ptr, proxy.val);
    }

    // Error handling
    pub inline fn throwError(self: Context) Value {
        return qjs.JS_NewError(self.ptr);
    }

    pub inline fn throwTypeError(self: Context, fmt: [*:0]const u8) Value {
        return qjs.JS_ThrowTypeError(self.ptr, fmt);
    }

    pub inline fn throwSyntaxError(self: Context, fmt: [*:0]const u8) Value {
        return qjs.JS_ThrowSyntaxError(self.ptr, fmt);
    }

    pub inline fn throwReferenceError(self: Context, fmt: [*:0]const u8) Value {
        return qjs.JS_ThrowReferenceError(self.ptr, fmt);
    }

    pub inline fn throwRangeError(self: Context, fmt: [*:0]const u8) Value {
        return qjs.JS_ThrowRangeError(self.ptr, fmt);
    }

    pub inline fn throwInternalError(self: Context, fmt: [*:0]const u8) Value {
        return qjs.JS_ThrowInternalError(self.ptr, fmt);
    }

    pub inline fn throwOutOfMemory(self: Context) Value {
        return qjs.JS_ThrowOutOfMemory(self.ptr);
    }

    pub inline fn throw(self: Context, obj: Value) Value {
        return qjs.JS_Throw(self.ptr, obj);
    }

    pub inline fn getException(self: Context) Value {
        return qjs.JS_GetException(self.ptr);
    }

    pub inline fn hasException(self: Context) bool {
        return qjs.JS_HasException(self.ptr);
    }

    // Value lifecycle management
    pub inline fn freeValue(self: Context, val: Value) void {
        qjs.JS_FreeValue(self.ptr, val);
    }

    // Property access
    pub inline fn getProperty(self: Context, obj: Value, prop: Atom) Value {
        return qjs.JS_GetProperty(self.ptr, obj, prop);
    }

    pub inline fn getPropertyStr(self: Context, obj: Value, prop: [*:0]const u8) Value {
        return qjs.JS_GetPropertyStr(self.ptr, obj, prop);
    }

    pub inline fn getPropertyUint32(self: Context, obj: Value, idx: u32) Value {
        return qjs.JS_GetPropertyUint32(self.ptr, obj, idx);
    }

    pub inline fn getPropertyInt64(self: Context, obj: Value, idx: i64) Value {
        return qjs.JS_GetPropertyInt64(self.ptr, obj, idx);
    }

    pub inline fn setProperty(self: Context, obj: Value, prop: Atom, val: Value) !void {
        const ret = qjs.JS_SetProperty(self.ptr, obj, prop, val);
        if (ret < 0) return error.Exception;
    }

    pub inline fn setPropertyStr(self: Context, obj: Value, prop: [*:0]const u8, val: Value) !void {
        const ret = qjs.JS_SetPropertyStr(self.ptr, obj, prop, val);
        if (ret < 0) return error.Exception;
    }

    pub inline fn setPropertyUint32(self: Context, obj: Value, idx: u32, val: Value) !void {
        const ret = qjs.JS_SetPropertyUint32(self.ptr, obj, idx, val);
        if (ret < 0) return error.Exception;
    }

    pub inline fn setPropertyInt64(self: Context, obj: Value, idx: i64, val: Value) !void {
        const ret = qjs.JS_SetPropertyInt64(self.ptr, obj, idx, val);
        if (ret < 0) return error.Exception;
    }

    pub inline fn hasProperty(self: Context, obj: Value, prop: Atom) !bool {
        const ret = qjs.JS_HasProperty(self.ptr, obj, prop);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn deleteProperty(self: Context, obj: Value, prop: Atom, flags: c_int) !bool {
        const ret = qjs.JS_DeleteProperty(self.ptr, obj, prop, flags);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    // Execution and evaluation

    pub const EvalType = enum {
        global,
        module,
    };

    pub const EvalFlags = struct {
        type: EvalType = .global,
        strict: bool = false,
        compile_only: bool = false,
        backtrace_barrier: bool = false,
        async: bool = false,
    };

    pub inline fn eval(self: Context, input: []const u8, filename: [*:0]const u8, flags: EvalFlags) error{Exception}!Value {
        var c_flags: c_int = 0;

        // Set eval type flag
        switch (flags.type) {
            .global => c_flags |= qjs.JS_EVAL_TYPE_GLOBAL,
            .module => c_flags |= qjs.JS_EVAL_TYPE_MODULE,
        }

        // Set other flags
        if (flags.strict) c_flags |= qjs.JS_EVAL_FLAG_STRICT;
        if (flags.compile_only) c_flags |= qjs.JS_EVAL_FLAG_COMPILE_ONLY;
        if (flags.backtrace_barrier) c_flags |= qjs.JS_EVAL_FLAG_BACKTRACE_BARRIER;
        if (flags.async) c_flags |= qjs.JS_EVAL_FLAG_ASYNC;

        const result = qjs.JS_Eval(self.ptr, input.ptr, input.len, filename, c_flags);
        if (qjs.JS_IsException(result) != 0) {
            return error.Exception;
        } else {
            return result;
        }
    }

    pub inline fn getGlobalObject(self: Context) Value {
        return qjs.JS_GetGlobalObject(self.ptr);
    }

    pub inline fn isInstanceOf(self: Context, val: Value, obj: Value) !bool {
        const ret = qjs.JS_IsInstanceOf(self.ptr, val, obj);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn call(self: Context, func_obj: Value, this_obj: Value, args: []const Value) Value {
        return qjs.JS_Call(self.ptr, func_obj, this_obj, @intCast(args.len), @constCast(args.ptr));
    }

    pub inline fn callConstructor(self: Context, func_obj: Value, args: []const Value) Value {
        return qjs.JS_CallConstructor(self.ptr, func_obj, @intCast(args.len), args.ptr);
    }

    // ArrayBuffer related methods
    pub inline fn getArrayBuffer(self: Context, val: Value) ![]u8 {
        var size: usize = undefined;
        const ptr = qjs.JS_GetArrayBuffer(self.ptr, &size, val);
        if (ptr == null) return error.NotArrayBuffer;
        return ptr[0..size];
    }

    // pub inline fn newArrayBuffer(self: Context, buf: []u8, free_func: ?qjs.JSFreeArrayBufferDataFunc, ptr: ?*anyopaque, is_shared: bool) Value {
    //     return qjs.JS_NewArrayBuffer(self.ptr, buf.ptr, buf.len, free_func, ptr, is_shared);
    // }

    pub inline fn newArrayBufferCopy(self: Context, buf: []const u8) Value {
        return qjs.JS_NewArrayBufferCopy(self.ptr, buf.ptr, buf.len);
    }

    pub inline fn detachArrayBuffer(self: Context, obj: Value) void {
        qjs.JS_DetachArrayBuffer(self.ptr, obj);
    }

    pub inline fn getUint8Array(self: Context, obj: Value) ![]u8 {
        var size: usize = undefined;
        const ptr = qjs.JS_GetUint8Array(self.ptr, &size, obj);
        if (ptr == null) return error.TypeError;
        return ptr[0..size];
    }

    // pub inline fn newUint8Array(self: Context, buf: []u8, free_func: ?qjs.JSFreeArrayBufferDataFunc, ptr: ?*anyopaque, is_shared: bool) Value {
    //     return qjs.JS_NewUint8Array(self.ptr, buf.ptr, buf.len, free_func, ptr, is_shared);
    // }

    pub inline fn newUint8ArrayCopy(self: Context, buf: []const u8) Value {
        return qjs.JS_NewUint8ArrayCopy(self.ptr, buf.ptr, buf.len);
    }

    pub inline fn getTypedArrayType(self: Context, obj: Value) !TypedArrayType {
        _ = self;
        const type_int = qjs.JS_GetTypedArrayType(obj);
        if (type_int < 0) return error.TypeError;
        return @enumFromInt(type_int);
    }

    pub inline fn getTypedArrayBuffer(self: Context, obj: Value) !ArrayBuffer {
        var byte_offset: usize = undefined;
        var byte_length: usize = undefined;
        var bytes_per_element: usize = undefined;

        const buffer_val = qjs.JS_GetTypedArrayBuffer(self.ptr, obj, &byte_offset, &byte_length, &bytes_per_element);
        if (qjs.JS_IsException(buffer_val)) return error.Exception;

        return .{
            .buffer = buffer_val,
            .byte_offset = byte_offset,
            .byte_length = byte_length,
            .bytes_per_element = bytes_per_element,
        };
    }

    // Promise related methods
    pub const PromiseState = enum(c_int) {
        Pending = qjs.JS_PROMISE_PENDING,
        Fulfilled = qjs.JS_PROMISE_FULFILLED,
        Rejected = qjs.JS_PROMISE_REJECTED,
    };

    pub inline fn promiseState(self: Context, promise: Value) PromiseState {
        return @enumFromInt(qjs.JS_PromiseState(self.ptr, promise));
    }

    pub inline fn promiseResult(self: Context, promise: Value) Value {
        return qjs.JS_PromiseResult(self.ptr, promise);
    }

    // JSON methods
    pub inline fn parseJSON(self: Context, buf: []const u8, filename: [*:0]const u8) Value {
        return qjs.JS_ParseJSON(self.ptr, buf.ptr, buf.len, filename);
    }

    pub inline fn jsonStringify(self: Context, obj: Value, replacer: Value, space: Value) Value {
        return qjs.JS_JSONStringify(self.ptr, obj, replacer, space);
    }

    // Atom handling
    pub inline fn newAtom(self: Context, str: []const u8) Atom {
        return qjs.JS_NewAtomLen(self.ptr, str.ptr, str.len);
    }

    pub inline fn newAtomUint32(self: Context, n: u32) Atom {
        return qjs.JS_NewAtomUInt32(self.ptr, n);
    }

    pub inline fn dupAtom(self: Context, atom: Atom) Atom {
        return qjs.JS_DupAtom(self.ptr, atom);
    }

    pub inline fn freeAtom(self: Context, atom: Atom) void {
        qjs.JS_FreeAtom(self.ptr, atom);
    }

    pub inline fn atomToValue(self: Context, atom: Atom) Value {
        return qjs.JS_AtomToValue(self.ptr, atom);
    }

    pub inline fn atomToString(self: Context, atom: Atom) Value {
        return qjs.JS_AtomToString(self.ptr, atom);
    }

    pub inline fn atomToCString(self: Context, atom: Atom) ![*:0]const u8 {
        return qjs.JS_AtomToCString(self.ptr, atom) orelse return error.Exception;
    }

    pub inline fn valueToAtom(self: Context, val: Value) Atom {
        return qjs.JS_ValueToAtom(self.ptr, val);
    }

    // Property descriptors and enumeration
    pub const PropertyEnumFlags = packed struct {
        strings: bool = true,
        symbols: bool = false,
        private: bool = false,
        enum_only: bool = false,
        set_enum: bool = false,
    };

    // pub const PropertyEnum = packed struct {
    //     is_enumerable: bool,
    //     atom: Atom,
    // };

    // typedef struct JSPropertyEnum {
    //     bool is_enumerable;
    //     JSAtom atom;
    // } JSPropertyEnum;

    // pub inline fn getOwnPropertyNames(self: Context, obj: Value, flags: PropertyEnumFlags) ![]const qjs.JSPropertyEnum {
    //     var c_flags: c_int = 0;
    //     if (flags.strings) c_flags |= qjs.JS_GPN_STRING_MASK;
    //     if (flags.symbols) c_flags |= qjs.JS_GPN_SYMBOL_MASK;
    //     if (flags.private) c_flags |= qjs.JS_GPN_PRIVATE_MASK;
    //     if (flags.enum_only) c_flags |= qjs.JS_GPN_ENUM_ONLY;
    //     if (flags.set_enum) c_flags |= qjs.JS_GPN_SET_ENUM;

    //     var ptab: [*c]qjs.JSPropertyEnum = undefined;
    //     var len: u32 = 0;

    //     const ret = qjs.JS_GetOwnPropertyNames(self.ptr, &ptab, &len, obj, c_flags);
    //     if (ret < 0) return error.Exception;

    //     return ptab[0..len];
    // }

    // pub inline fn freePropertyEnum(self: Context, tab: []const qjs.JSPropertyEnum) void {
    //     qjs.JS_FreePropertyEnum(self.ptr, @constCast(tab.ptr), @intCast(tab.len));
    // }

    // Property descriptor structure

    pub const PropertyFlags = packed struct {
        configurable: bool,
        writable: bool,
        enumerable: bool,
        normal: bool,
        getset: bool,

        pub fn fromInt(flags: c_int) PropertyFlags {
            return .{
                .configurable = ((flags | qjs.JS_PROP_CONFIGURABLE) != 0),
                .writable = ((flags | qjs.JS_PROP_WRITABLE) != 0),
                .enumerable = ((flags | qjs.JS_PROP_ENUMERABLE) != 0),
                .normal = ((flags | qjs.JS_PROP_NORMAL) != 0),
                .getset = ((flags | qjs.JS_PROP_GETSET) != 0),
            };
        }

        pub fn toInt(self: PropertyFlags) c_int {
            var flags: c_int = 0;
            if (self.configurable) flags |= qjs.JS_PROP_CONFIGURABLE;
            if (self.writable) flags |= qjs.JS_PROP_WRITABLE;
            if (self.enumerable) flags |= qjs.JS_PROP_ENUMERABLE;
            if (self.normal) flags |= qjs.JS_PROP_NORMAL;
            if (self.getset) flags |= qjs.JS_PROP_GETSET;
            return flags;
        }
    };

    pub const PropertyDescriptor = struct {
        flags: PropertyFlags,
        value: Value,
        getter: Value,
        setter: Value,
    };

    pub inline fn getOwnProperty(self: Context, obj: Value, prop: Atom) !PropertyDescriptor {
        var desc: qjs.JSPropertyDescriptor = undefined;
        const ret = qjs.JS_GetOwnProperty(self.ptr, &desc, obj, prop);
        if (ret < 0) return error.Exception;
        if (ret == 0) return error.PropertyNotFound;

        return PropertyDescriptor{
            .flags = PropertyFlags.fromInt(desc.flags),
            .value = desc.value,
            .getter = desc.getter,
            .setter = desc.setter,
        };
    }

    // Object extensibility and related operations
    pub inline fn isExtensible(self: Context, obj: Value) !bool {
        const ret = qjs.JS_IsExtensible(self.ptr, obj);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn preventExtensions(self: Context, obj: Value) !bool {
        const ret = qjs.JS_PreventExtensions(self.ptr, obj);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub const DefinePropertyFlags = packed struct {
        configurable: bool = false,
        writable: bool = false,
        enumerable: bool = false,
        has_configurable: bool = false,
        has_writable: bool = false,
        has_enumerable: bool = false,
        has_get: bool = false,
        has_set: bool = false,
        has_value: bool = false,
        throw: bool = false,
        no_exotic: bool = false,

        pub fn toInt(self: DefinePropertyFlags) c_int {
            var flags: c_int = 0;
            if (self.configurable) flags |= qjs.JS_PROP_CONFIGURABLE;
            if (self.writable) flags |= qjs.JS_PROP_WRITABLE;
            if (self.enumerable) flags |= qjs.JS_PROP_ENUMERABLE;
            if (self.has_configurable) flags |= qjs.JS_PROP_HAS_CONFIGURABLE;
            if (self.has_writable) flags |= qjs.JS_PROP_HAS_WRITABLE;
            if (self.has_enumerable) flags |= qjs.JS_PROP_HAS_ENUMERABLE;
            if (self.has_get) flags |= qjs.JS_PROP_HAS_GET;
            if (self.has_set) flags |= qjs.JS_PROP_HAS_SET;
            if (self.has_value) flags |= qjs.JS_PROP_HAS_VALUE;
            if (self.throw) flags |= qjs.JS_PROP_THROW;
            return flags;
        }
    };

    pub inline fn defineProperty(self: Context, obj: Value, prop: Atom, val: Value, getter: Value, setter: Value, flags: DefinePropertyFlags) !bool {
        const c_flags = flags.toInt();
        const ret = qjs.JS_DefineProperty(self.ptr, obj, prop, val, getter, setter, c_flags);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn definePropertyValue(self: Context, obj: Value, prop: Atom, val: Value, flags: DefinePropertyFlags) !bool {
        const c_flags = flags.toInt();
        const ret = qjs.JS_DefinePropertyValue(self.ptr, obj, prop, val, c_flags);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn definePropertyValueStr(self: Context, obj: Value, prop: []const u8, val: Value, flags: PropertyFlags) !bool {
        const c_flags = flags.toInt();
        const ret = qjs.JS_DefinePropertyValueStr(self.ptr, obj, prop.ptr, val, c_flags);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn definePropertyValueUint32(self: Context, obj: Value, idx: u32, val: Value, flags: PropertyFlags) !bool {
        const c_flags = flags.toInt();
        const ret = qjs.JS_DefinePropertyValueUint32(self.ptr, obj, idx, val, c_flags);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    pub inline fn definePropertyGetSet(self: Context, obj: Value, prop: Atom, getter: Value, setter: Value, flags: PropertyFlags) !bool {
        const c_flags = flags.toInt();
        const ret = qjs.JS_DefinePropertyGetSet(self.ptr, obj, prop, getter, setter, c_flags);
        if (ret < 0) return error.Exception;
        return ret != 0;
    }

    // pub inline fn setOpaque(_: Context, obj: Value, ptr: ?*anyopaque) !void {
    //     if (qjs.JS_SetOpaque(obj, ptr) < 0)
    //         return error.OpaqueSetFailed;
    // }

    // pub inline fn getOpaque(_: Context, obj: Value, class_id: ClassID) ?*anyopaque {
    //     return qjs.JS_GetOpaque(obj, class_id);
    // }

    // pub inline fn getOpaque2(self: Context, obj: Value, class_id: ClassID) ?*anyopaque {
    //     return qjs.JS_GetOpaque2(self.ptr, obj, class_id);
    // }

    // // Class and prototype handling
    // pub inline fn setClassProto(self: Context, class_id: ClassID, proto: Value) void {
    //     qjs.JS_SetClassProto(self.ptr, class_id, proto);
    // }

    // pub inline fn getClassProto(self: Context, class_id: ClassID) Value {
    //     return qjs.JS_GetClassProto(self.ptr, class_id);
    // }

    pub inline fn getFunctionProto(self: Context) Value {
        return qjs.JS_GetFunctionProto(self.ptr);
    }

    // Intrinsic object loading
    pub inline fn addIntrinsicBaseObjects(self: Context) void {
        qjs.JS_AddIntrinsicBaseObjects(self.ptr);
    }

    pub inline fn addIntrinsicDate(self: Context) void {
        qjs.JS_AddIntrinsicDate(self.ptr);
    }

    pub inline fn addIntrinsicEval(self: Context) void {
        qjs.JS_AddIntrinsicEval(self.ptr);
    }

    pub inline fn addIntrinsicRegExpCompiler(self: Context) void {
        qjs.JS_AddIntrinsicRegExpCompiler(self.ptr);
    }

    pub inline fn addIntrinsicRegExp(self: Context) void {
        qjs.JS_AddIntrinsicRegExp(self.ptr);
    }

    pub inline fn addIntrinsicJSON(self: Context) void {
        qjs.JS_AddIntrinsicJSON(self.ptr);
    }

    pub inline fn addIntrinsicProxy(self: Context) void {
        qjs.JS_AddIntrinsicProxy(self.ptr);
    }

    pub inline fn addIntrinsicMapSet(self: Context) void {
        qjs.JS_AddIntrinsicMapSet(self.ptr);
    }

    pub inline fn addIntrinsicTypedArrays(self: Context) void {
        qjs.JS_AddIntrinsicTypedArrays(self.ptr);
    }

    pub inline fn addIntrinsicPromise(self: Context) void {
        qjs.JS_AddIntrinsicPromise(self.ptr);
    }

    pub inline fn addIntrinsicBigInt(self: Context) void {
        qjs.JS_AddIntrinsicBigInt(self.ptr);
    }

    pub inline fn addIntrinsicWeakRef(self: Context) void {
        qjs.JS_AddIntrinsicWeakRef(self.ptr);
    }

    pub inline fn addPerformance(self: Context) void {
        qjs.JS_AddPerformance(self.ptr);
    }

    // // C function integration
    // pub inline fn newCFunction(self: Context, func: qjs.JSCFunction, name: []const u8, length: c_int) Value {
    //     return qjs.JS_NewCFunction(self.ptr, func, name.ptr, length);
    // }

    // pub inline fn newCFunction2(self: Context, func: qjs.JSCFunction, name: []const u8, length: c_int, cproto: qjs.JSCFunctionEnum, magic: c_int) Value {
    //     return qjs.JS_NewCFunction2(self.ptr, func, name.ptr, length, cproto, magic);
    // }

    // pub inline fn newCFunctionMagic(self: Context, func: qjs.JSCFunctionMagic, name: []const u8, length: c_int, cproto: qjs.JSCFunctionEnum, magic: c_int) Value {
    //     return qjs.JS_NewCFunctionMagic(self.ptr, func, name.ptr, length, cproto, magic);
    // }

    pub inline fn setConstructor(self: Context, func_obj: Value, proto: Value) void {
        qjs.JS_SetConstructor(self.ptr, func_obj, proto);
    }

    pub inline fn setConstructorBit(self: Context, func_obj: Value, val: bool) bool {
        return qjs.JS_SetConstructorBit(self.ptr, func_obj, val) != 0;
    }

    // pub inline fn newCFunctionData(self: Context, func: qjs.JSCFunctionData, length: c_int, magic: c_int, data: []const Value) Value {
    //     return qjs.JS_NewCFunctionData(self.ptr, func, length, magic, data.len, data.ptr);
    // }

    // Module type
    pub const Module = struct {
        ptr: *qjs.JSModuleDef,
    };

    // Module support
    pub inline fn getModuleNamespace(self: Context, m: Module) Value {
        return qjs.JS_GetModuleNamespace(self.ptr, m.ptr);
    }

    pub inline fn getModuleName(self: Context, m: Module) Atom {
        return qjs.JS_GetModuleName(self.ptr, m.ptr);
    }

    pub inline fn getImportMeta(self: Context, m: Module) Value {
        return qjs.JS_GetImportMeta(self.ptr, m.ptr);
    }

    pub inline fn resolveModule(self: Context, obj: Value) !void {
        const ret = qjs.JS_ResolveModule(self.ptr, obj);
        if (ret < 0) return error.ModuleResolutionFailed;
    }

    pub inline fn evalFunction(self: Context, fun_obj: Value) Value {
        return qjs.JS_EvalFunction(self.ptr, fun_obj);
    }

    pub inline fn getScriptOrModuleName(self: Context, n_stack_levels: i32) Atom {
        return qjs.JS_GetScriptOrModuleName(self.ptr, n_stack_levels);
    }

    pub inline fn loadModule(self: Context, basename: ?[]const u8, filename: []const u8) Value {
        const basename_ptr = if (basename) |b| b.ptr else null;
        return qjs.JS_LoadModule(self.ptr, basename_ptr, filename.ptr);
    }

    // C module creation helpers
    pub inline fn newCModule(self: Context, name: []const u8, func: qjs.JSModuleInitFunc) ?Module {
        const ptr = qjs.JS_NewCModule(self.ptr, name.ptr, func);
        return if (ptr != null) Module{ .ptr = ptr.? } else null;
    }

    pub inline fn addModuleExport(self: Context, m: Module, name: []const u8) !void {
        const ret = qjs.JS_AddModuleExport(self.ptr, m.ptr, name.ptr);
        if (ret < 0) return error.ModuleExportFailed;
    }

    pub inline fn setModuleExport(self: Context, m: Module, name: []const u8, val: Value) !void {
        const ret = qjs.JS_SetModuleExport(self.ptr, m.ptr, name.ptr, val);
        if (ret < 0) return error.ModuleExportFailed;
    }

    // // Job queue management
    // pub inline fn enqueueJob(self: Context, job_func: qjs.JSJobFunc, args: []const Value) !void {
    //     const ret = qjs.JS_EnqueueJob(self.ptr, job_func, args.len, args.ptr);
    //     if (ret < 0) return error.EnqueueJobFailed;
    // }

    // Object serialization
    pub const WriteObjectFlags = packed struct {
        bytecode: bool = false,
        sab: bool = false,
        reference: bool = false,
        strip_source: bool = false,
        strip_debug: bool = false,
    };

    pub inline fn writeObject(self: Context, obj: Value, flags: WriteObjectFlags) ![]u8 {
        var c_flags: c_int = 0;
        if (flags.bytecode) c_flags |= qjs.JS_WRITE_OBJ_BYTECODE;
        if (flags.sab) c_flags |= qjs.JS_WRITE_OBJ_SAB;
        if (flags.reference) c_flags |= qjs.JS_WRITE_OBJ_REFERENCE;
        if (flags.strip_source) c_flags |= qjs.JS_WRITE_OBJ_STRIP_SOURCE;
        if (flags.strip_debug) c_flags |= qjs.JS_WRITE_OBJ_STRIP_DEBUG;

        var size: usize = undefined;
        const ptr = qjs.JS_WriteObject(self.ptr, &size, obj, c_flags);
        if (ptr == null) return error.SerializationFailed;
        return ptr[0..size];
    }

    pub const ReadObjectFlags = packed struct {
        bytecode: bool = false,
        sab: bool = false,
        reference: bool = false,
    };

    pub inline fn readObject(self: Context, buf: []const u8, flags: ReadObjectFlags) Value {
        var c_flags: c_int = 0;
        if (flags.bytecode) c_flags |= qjs.JS_READ_OBJ_BYTECODE;
        if (flags.sab) c_flags |= qjs.JS_READ_OBJ_SAB;
        if (flags.reference) c_flags |= qjs.JS_READ_OBJ_REFERENCE;

        return qjs.JS_ReadObject(self.ptr, buf.ptr, buf.len, c_flags);
    }

    // Memory allocation functions
    pub inline fn malloc(self: Context, size: usize) ?*anyopaque {
        return qjs.js_malloc(self.ptr, size);
    }

    pub inline fn calloc(self: Context, count: usize, size: usize) ?*anyopaque {
        return qjs.js_calloc(self.ptr, count, size);
    }

    pub inline fn free(self: Context, ptr: ?*anyopaque) void {
        qjs.js_free(self.ptr, ptr);
    }

    pub inline fn realloc(self: Context, ptr: ?*anyopaque, size: usize) ?*anyopaque {
        return qjs.js_realloc(self.ptr, ptr, size);
    }

    pub inline fn mallocz(self: Context, size: usize) ?*anyopaque {
        return qjs.js_mallocz(self.ptr, size);
    }

    pub inline fn strdup(self: Context, str: []const u8) ?[*:0]u8 {
        return qjs.js_strdup(self.ptr, str.ptr);
    }

    pub inline fn strndup(self: Context, str: []const u8, n: usize) ?[*:0]u8 {
        return qjs.js_strndup(self.ptr, str.ptr, n);
    }

    pub inline fn mallocUsableSize(self: Context, ptr: ?*const anyopaque) usize {
        return qjs.js_malloc_usable_size(self.ptr, ptr);
    }
};
