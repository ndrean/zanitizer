const std = @import("std");
const z = @import("root.zig");
const w = z.wrapper;
const qjs = z.qjs;

/// Generic Class Builder for QuickJS bindings
///
/// Usage:
/// ```zig
/// const PointClass = ClassBuilder.build(Point, .{
///     .class_name = "Point",
///     .custom_methods = &.{
///         .{ .name = "distance", .func = js_distance },
///     },
/// });
/// ```
pub const ClassBuilder = struct {
    /// Options for building a class
    pub fn Options(comptime T: type) type {
        return struct {
            class_name: [:0]const u8,
            custom_methods: []const MethodDef = &.{},
            /// Optional custom finalizer - if null, uses default free
            finalizer: ?*const fn (*T, std.mem.Allocator) void = null,
        };
    }

    pub const MethodDef = struct {
        name: [:0]const u8,
        func: qjs.JSCFunction,
    };

    /// Build a complete class binding for type T
    pub fn build(comptime T: type, comptime opts: Options(T)) type {
        return struct {
            pub var class_id: qjs.JSClassID = 0;

            const class_name = opts.class_name;

            // ================================================================
            // 1. Auto-generated Constructor
            // ================================================================

            /// Generic constructor that accepts an object with field values
            pub fn js_constructor(
                ctx_ptr: ?*qjs.JSContext,
                new_target: qjs.JSValue,
                argc: c_int,
                argv: [*c]qjs.JSValue,
            ) callconv(.c) qjs.JSValue {
                const ctx = w.Context.from(ctx_ptr);
                _ = new_target;

                // Get allocator from runtime
                const rt_opaque = qjs.JS_GetRuntimeOpaque(qjs.JS_GetRuntime(ctx.ptr));
                const rt: *w.Runtime = @ptrCast(@alignCast(rt_opaque));

                // Allocate instance
                const instance = rt.allocator.create(T) catch return ctx.throwOutOfMemory();
                errdefer rt.allocator.destroy(instance);

                // Initialize with defaults or from arguments
                if (argc > 0) {
                    // Parse object argument to set fields
                    inline for (std.meta.fields(T)) |field| {
                        const val = ctx.getPropertyStr(argv[0], field.name);
                        if (!ctx.isUndefined(val)) {
                            defer ctx.freeValue(val);

                            switch (@typeInfo(field.type)) {
                                .int, .comptime_int => {
                                    if (field.type == i64 or field.type == i32 or field.type == i16 or field.type == i8) {
                                        var result: i64 = 0;
                                        if (qjs.JS_ToInt64(ctx.ptr, &result, val) == 0) {
                                            @field(instance, field.name) = @intCast(result);
                                        }
                                    } else {
                                        var result: u64 = 0;
                                        if (qjs.JS_ToIndex(ctx.ptr, &result, val) == 0) {
                                            @field(instance, field.name) = @intCast(result);
                                        }
                                    }
                                },
                                .float, .comptime_float => {
                                    var result: f64 = 0;
                                    if (qjs.JS_ToFloat64(ctx.ptr, &result, val) == 0) {
                                        @field(instance, field.name) = @floatCast(result);
                                    }
                                },
                                else => {
                                    // Skip unsupported types
                                },
                            }
                        }
                    }
                } else {
                    // Initialize with zero values
                    instance.* = std.mem.zeroes(T);
                }

                // Create JS object
                const obj = qjs.JS_NewObjectClass(ctx.ptr, class_id);
                if (ctx.isException(obj)) {
                    rt.allocator.destroy(instance);
                    return obj;
                }

                // Set opaque pointer to our instance
                _ = qjs.JS_SetOpaque(obj, instance);

                return obj;
            }

            // ================================================================
            // 2. Auto-generated Finalizer
            // ================================================================

            fn js_finalizer(rt_ptr: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
                const rt_opaque_ptr = qjs.JS_GetRuntimeOpaque(rt_ptr);
                if (rt_opaque_ptr == null) return;
                const rt: *w.Runtime = @ptrCast(@alignCast(rt_opaque_ptr));

                const opaque_ptr = qjs.JS_GetOpaque(val, class_id);
                if (opaque_ptr == null) return;

                const instance: *T = @ptrCast(@alignCast(opaque_ptr));

                // Call custom finalizer if provided
                if (opts.finalizer) |finalizer_fn| {
                    finalizer_fn(instance, rt.allocator);
                }

                rt.allocator.destroy(instance);
            }

            // ================================================================
            // 3. Auto-generated Getters/Setters
            // ================================================================

            fn makeGetter(comptime field_name: []const u8) qjs.JSCFunction {
                const Impl = struct {
                    fn getter(
                        ctx_ptr: ?*qjs.JSContext,
                        this: qjs.JSValue,
                        _: c_int,
                        _: [*c]qjs.JSValue,
                    ) callconv(.c) qjs.JSValue {
                        const ctx = w.Context.from(ctx_ptr);
                        const opaque_ptr = qjs.JS_GetOpaque2(ctx.ptr, this, class_id);
                        if (opaque_ptr == null) return ctx.throwTypeError("Invalid this");

                        const instance: *T = @ptrCast(@alignCast(opaque_ptr));
                        const value = @field(instance, field_name);

                        const FieldType = @TypeOf(value);
                        return switch (@typeInfo(FieldType)) {
                            .int => ctx.newInt64(@intCast(value)),
                            .float => ctx.newFloat64(@floatCast(value)),
                            else => w.UNDEFINED,
                        };
                    }
                };
                return Impl.getter;
            }

            fn makeSetter(comptime field_name: []const u8) qjs.JSCFunction {
                const Impl = struct {
                    fn setter(
                        ctx_ptr: ?*qjs.JSContext,
                        this: qjs.JSValue,
                        argc: c_int,
                        argv: [*c]qjs.JSValue,
                    ) callconv(.c) qjs.JSValue {
                        const ctx = w.Context.from(ctx_ptr);
                        if (argc < 1) return ctx.throwTypeError("Missing value");

                        const opaque_ptr = qjs.JS_GetOpaque2(ctx.ptr, this, class_id);
                        if (opaque_ptr == null) return ctx.throwTypeError("Invalid this");

                        const instance: *T = @ptrCast(@alignCast(opaque_ptr));

                        const field_info = comptime blk: {
                            for (std.meta.fields(T)) |f| {
                                if (std.mem.eql(u8, f.name, field_name)) {
                                    break :blk f;
                                }
                            }
                            unreachable;
                        };

                        switch (@typeInfo(field_info.type)) {
                            .int => {
                                var val: i64 = 0;
                                if (qjs.JS_ToInt64(ctx.ptr, &val, argv[0]) == 0) {
                                    @field(instance, field_name) = @intCast(val);
                                }
                            },
                            .float => {
                                var val: f64 = 0;
                                if (qjs.JS_ToFloat64(ctx.ptr, &val, argv[0]) == 0) {
                                    @field(instance, field_name) = @floatCast(val);
                                }
                            },
                            else => return ctx.throwTypeError("Unsupported type"),
                        }

                        return w.UNDEFINED;
                    }
                };
                return Impl.setter;
            }

            // ================================================================
            // 4. Auto-generated toString
            // ================================================================

            fn js_toString(
                ctx_ptr: ?*qjs.JSContext,
                this: qjs.JSValue,
                _: c_int,
                _: [*c]qjs.JSValue,
            ) callconv(.c) qjs.JSValue {
                const ctx = w.Context.from(ctx_ptr);
                const opaque_ptr = qjs.JS_GetOpaque2(ctx.ptr, this, class_id);
                if (opaque_ptr == null) return ctx.throwTypeError("Invalid this");

                const instance: *T = @ptrCast(@alignCast(opaque_ptr));

                // Get allocator from runtime
                const rt_opaque_ptr = qjs.JS_GetRuntimeOpaque(qjs.JS_GetRuntime(ctx.ptr));
                const rt: *w.Runtime = @ptrCast(@alignCast(rt_opaque_ptr));

                // Build string representation
                var str: std.ArrayList(u8) = .empty;
                defer str.deinit(rt.allocator);

                str.writer(rt.allocator).print(class_name ++ "(", .{}) catch return ctx.throwOutOfMemory();

                inline for (std.meta.fields(T), 0..) |field, i| {
                    if (i > 0) str.writer(rt.allocator).writeAll(", ") catch return ctx.throwOutOfMemory();

                    const value = @field(instance, field.name);
                    switch (@typeInfo(field.type)) {
                        .int, .float => {
                            str.writer(rt.allocator).print("{d}", .{value}) catch return ctx.throwOutOfMemory();
                        },
                        else => {
                            str.writer(rt.allocator).writeAll("?") catch return ctx.throwOutOfMemory();
                        },
                    }
                }

                str.writer(rt.allocator).writeAll(")") catch return ctx.throwOutOfMemory();

                return ctx.newString(str.toOwnedSlice(rt.allocator) catch return ctx.throwOutOfMemory());
            }

            // ================================================================
            // 5. Class Registration
            // ================================================================

            pub fn register(ctx: w.Context) !void {
                const rt = ctx.getRuntime();

                // Register class ID
                _ = qjs.JS_NewClassID(rt.ptr, &class_id);

                // Create class definition
                var class_def: qjs.JSClassDef = .{
                    .class_name = class_name,
                    .finalizer = js_finalizer,
                    .gc_mark = null,
                    .call = null,
                    .exotic = null,
                };

                if (qjs.JS_NewClass(rt.ptr, class_id, &class_def) < 0) {
                    return error.ClassRegistrationFailed;
                }

                // Create prototype
                const proto = qjs.JS_NewObject(ctx.ptr);
                defer ctx.freeValue(proto);

                // Add toString
                const toString_fn = ctx.newCFunction(js_toString, "toString", 0);
                _ = try ctx.setPropertyStr(proto, "toString", toString_fn);

                // Add custom methods
                inline for (opts.custom_methods) |method| {
                    const method_fn = ctx.newCFunction(method.func, method.name, 1);
                    _ = try ctx.setPropertyStr(proto, method.name, method_fn);
                }

                // Add getters/setters for all fields
                inline for (std.meta.fields(T)) |field| {
                    // Only create accessors for supported types
                    switch (@typeInfo(field.type)) {
                        .int, .float => {
                            const getter_fn = ctx.newCFunction(makeGetter(field.name), "get_" ++ field.name, 0);
                            const setter_fn = ctx.newCFunction(makeSetter(field.name), "set_" ++ field.name, 1);

                            // Create property descriptor with getter/setter
                            const atom = qjs.JS_NewAtom(ctx.ptr, field.name);
                            defer qjs.JS_FreeAtom(ctx.ptr, atom);

                            _ = qjs.JS_DefinePropertyGetSet(
                                ctx.ptr,
                                proto,
                                atom,
                                getter_fn,
                                setter_fn,
                                qjs.JS_PROP_C_W_E,
                            );
                        },
                        else => {},
                    }
                }

                // Set prototype
                qjs.JS_SetClassProto(ctx.ptr, class_id, proto);

                // Register constructor
                const global = ctx.getGlobalObject();
                defer ctx.freeValue(global);

                const ctor = ctx.newCFunction2(js_constructor, class_name, 1, qjs.JS_CFUNC_constructor, 0);
                _ = try ctx.setPropertyStr(global, class_name, ctor);
            }
        };
    }
};
