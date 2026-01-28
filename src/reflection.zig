const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;

pub fn reflect(comptime types: anytype) type {
    return struct {
        pub fn install(ctx: zqjs.Context) !void {
            inline for (types) |T| {
                try Binder(T).register(ctx);
            }
        }
    };
}

fn getAllocator(ctx: zqjs.Context) std.mem.Allocator {
    const rt_ptr = qjs.JS_GetRuntime(ctx.ptr);
    const rt_opaque = qjs.JS_GetRuntimeOpaque(rt_ptr);
    const rt_wrapper: *z.wrapper.Runtime = @ptrCast(@alignCast(rt_opaque));
    return rt_wrapper.allocator;
}

pub fn Binder(comptime T: type) type {
    return struct {
        pub threadlocal var class_id: qjs.JSClassID = 0;
        threadlocal var registered_rt: ?*qjs.JSRuntime = null;

        // --- UNWRAPPER -------------------------------------------------
        fn unwrap(_: zqjs.Context, val: qjs.JSValue) ?*T {
            const obj_id = qjs.JS_GetClassID(val);
            if (obj_id == class_id) {
                const ptr = qjs.JS_GetOpaque(val, class_id);
                if (ptr) |p| return @ptrCast(@alignCast(p));
            }
            // Trust layout for subclasses
            const ptr = qjs.JS_GetOpaque(val, obj_id);
            if (ptr) |p| return @ptrCast(@alignCast(p));
            return null;
        }

        fn finalize(rt_ptr: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
            const obj_id = qjs.JS_GetClassID(val);
            const ptr = qjs.JS_GetOpaque(val, obj_id);
            if (ptr) |p| {
                const self: *T = @ptrCast(@alignCast(p));
                const rt_opaque = qjs.JS_GetRuntimeOpaque(rt_ptr);
                const rt_wrapper: *z.wrapper.Runtime = @ptrCast(@alignCast(rt_opaque));

                if (@hasDecl(T, "deinit")) {
                    const params = @typeInfo(@TypeOf(T.deinit)).@"fn".params;
                    if (params.len == 2) {
                        self.deinit(rt_wrapper.allocator);
                    } else {
                        self.deinit();
                    }
                }
                rt_wrapper.allocator.destroy(self);
            }
        }

        fn constructor(ctx_ptr: ?*qjs.JSContext, new_target: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
            const ctx = zqjs.Context{ .ptr = ctx_ptr };
            _ = new_target;
            const allocator = getAllocator(ctx);
            const self = allocator.create(T) catch return ctx.throwOutOfMemory();
            errdefer allocator.destroy(self);

            if (@hasDecl(T, "constructor")) {
                const res = callZigFn(T, T.constructor, ctx, null, argc, argv, allocator, false) catch {
                    allocator.destroy(self);
                    return zqjs.EXCEPTION;
                };
                self.* = res;
            } else {
                self.* = std.mem.zeroes(T);
            }

            const obj = qjs.JS_NewObjectClass(ctx.ptr, class_id);
            if (qjs.JS_IsException(obj)) {
                allocator.destroy(self);
                return obj;
            }
            _ = qjs.JS_SetOpaque(obj, self);
            return obj;
        }

        pub fn register(ctx: zqjs.Context) !void {
            const rt = ctx.getRuntime();

            // [NUCLEAR FIX] If Runtime changed, invalidate EVERYTHING.
            if (registered_rt != rt.ptr) {
                registered_rt = rt.ptr;
                class_id = 0; // Force QuickJS to allocate a valid ID for *this* Runtime
            }

            // 1. Register Parent First
            if (@hasDecl(T, "prototype")) {
                const PrototypeDecl = T.prototype;
                if (@typeInfo(@TypeOf(PrototypeDecl)) == .pointer) {
                    const Parent = std.meta.Child(PrototypeDecl);
                    try Binder(Parent).register(ctx);
                }
            }

            // 2. Allocate Class ID
            if (class_id == 0) _ = qjs.JS_NewClassID(rt.ptr, &class_id);

            const type_name = comptime blk: {
                const full = @typeName(T);
                if (std.mem.lastIndexOfScalar(u8, full, '.')) |idx| {
                    break :blk full[idx + 1 ..] ++ "";
                }
                break :blk full ++ "";
            };

            const class_def = qjs.JSClassDef{
                .class_name = type_name.ptr,
                .finalizer = finalize,
            };
            _ = qjs.JS_NewClass(rt.ptr, class_id, &class_def);

            // 3. Create Prototype & Link Inheritance
            var parent_proto: ?qjs.JSValue = null;
            if (@hasDecl(T, "prototype")) {
                const PrototypeDecl = T.prototype;
                if (@typeInfo(@TypeOf(PrototypeDecl)) == .pointer) {
                    const Parent = std.meta.Child(PrototypeDecl);
                    const parent_cid = Binder(Parent).class_id; // Safe because of Step 1

                    if (parent_cid != 0) {
                        const pp = qjs.JS_GetClassProto(ctx.ptr, parent_cid);
                        defer qjs.JS_FreeValue(ctx.ptr, pp);
                        if (qjs.JS_IsObject(pp)) {
                            parent_proto = pp;
                        }
                    }
                }
            }

            var proto: qjs.JSValue = undefined;
            if (parent_proto) |pp| {
                // Atomic creation with prototype
                proto = qjs.JS_NewObjectProto(ctx.ptr, pp);
            } else {
                proto = ctx.newObject();
            }

            // 4. Bind Methods
            const type_info = @typeInfo(T);
            switch (type_info) {
                .@"struct" => |info| {
                    inline for (info.decls) |decl| {
                        const decl_val = @field(T, decl.name);
                        if (@typeInfo(@TypeOf(decl_val)) == .@"fn") {
                            if (std.mem.startsWith(u8, decl.name, "get_")) {
                                const prop_name = decl.name[4..];
                                const getter = wrapMethod(decl.name, .getter);
                                const get_fn = ctx.newCFunction(getter, decl.name, 0);
                                var set_fn = zqjs.UNDEFINED;

                                const set_name = "set_" ++ prop_name;
                                if (@hasDecl(T, set_name)) {
                                    const set_val = @field(T, set_name);
                                    if (@typeInfo(@TypeOf(set_val)) == .@"fn") {
                                        const setter = wrapMethod(set_name, .setter);
                                        set_fn = ctx.newCFunction(setter, set_name, 1);
                                    }
                                }
                                const atom = ctx.newAtom(prop_name);
                                defer ctx.freeAtom(atom);
                                _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, atom, get_fn, set_fn, qjs.JS_PROP_C_W_E);
                            } else if (std.mem.startsWith(u8, decl.name, "_")) {
                                const js_name = decl.name[1..] ++ "";
                                const wrapper = wrapMethod(decl.name, .method);
                                const fn_val = ctx.newCFunction(wrapper, js_name, 0);
                                _ = try ctx.setPropertyStr(proto, js_name, fn_val);
                            }
                        }
                    }
                },
                else => @compileError("Reflect only supports Struct types"),
            }

            qjs.JS_SetClassProto(ctx.ptr, class_id, proto);

            const ctor_val = ctx.newCFunction2(constructor, type_name, 1, qjs.JS_CFUNC_constructor, 0);
            _ = try ctx.setPropertyStr(ctor_val, "prototype", ctx.dupValue(proto));
            _ = try ctx.setPropertyStr(proto, "constructor", ctx.dupValue(ctor_val));

            const global = ctx.getGlobalObject();
            defer ctx.freeValue(global);
            _ = try ctx.setPropertyStr(global, type_name, ctor_val);
        }

        fn wrapMethod(comptime func_name: []const u8, comptime mtype: MethodType) qjs.JSCFunction {
            const Wrapper = struct {
                fn call(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
                    const ctx = zqjs.Context{ .ptr = ctx_ptr };
                    const allocator = getAllocator(ctx);

                    const self_opt = unwrap(ctx, this_val);
                    if (self_opt == null) return ctx.throwTypeError("Illegal invocation: type mismatch");
                    const self = self_opt.?;

                    const func = @field(T, func_name);
                    const res = callZigFn(T, func, ctx, self, argc, argv, allocator, true) catch {
                        return zqjs.EXCEPTION;
                    };

                    if (mtype == .setter) return zqjs.UNDEFINED;
                    return toJS(ctx, res);
                }
            };
            return Wrapper.call;
        }
    };
}

const MethodType = enum { getter, setter, method };

fn callZigFn(comptime Type: type, comptime func: anytype, ctx: zqjs.Context, self: ?*Type, argc: c_int, argv: [*c]qjs.JSValue, allocator: std.mem.Allocator, comptime is_method: bool) !@typeInfo(@TypeOf(func)).@"fn".return_type.? {
    const FnType = @typeInfo(@TypeOf(func)).@"fn";
    const ArgsTuple = std.meta.ArgsTuple(@TypeOf(func));
    var args: ArgsTuple = undefined;

    comptime var js_idx = 0;

    inline for (FnType.params, 0..) |param, i| {
        if (is_method and i == 0 and (param.type == Type or param.type == *Type)) {
            if (param.type == *Type) {
                args[i] = self.?;
            } else {
                args[i] = self.?.*;
            }
        } else {
            if (js_idx >= argc) return error.MissingArgument;
            const val = argv[js_idx];
            js_idx += 1;
            args[i] = try fromJS(ctx, param.type.?, val, allocator);
        }
    }

    return @call(.auto, func, args);
}

fn fromJS(ctx: zqjs.Context, comptime T: type, val: qjs.JSValue, allocator: std.mem.Allocator) !T {
    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.bits <= 32) {
                var out: i32 = 0;
                _ = qjs.JS_ToInt32(ctx.ptr, &out, val);
                return @intCast(out);
            } else {
                var out: i64 = 0;
                _ = qjs.JS_ToInt64(ctx.ptr, &out, val);
                return @intCast(out);
            }
        },
        .float => {
            var out: f64 = 0;
            _ = qjs.JS_ToFloat64(ctx.ptr, &out, val);
            return @floatCast(out);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                const str = ctx.toZString(val) catch return error.JSException;
                return try allocator.dupe(u8, str);
            }
        },
        else => {},
    }
    return error.UnsupportedType;
}

fn toJS(ctx: zqjs.Context, val: anytype) qjs.JSValue {
    const T = @TypeOf(val);
    switch (@typeInfo(T)) {
        .void => return zqjs.UNDEFINED,
        .int => return ctx.newInt64(@intCast(val)),
        .float => return ctx.newFloat64(@floatCast(val)),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return ctx.newString(val);
            }
        },
        else => {},
    }
    return zqjs.UNDEFINED;
}
