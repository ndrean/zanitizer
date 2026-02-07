const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const zqjs = z.wrapper;
const RuntimeContext = @import("runtime_context.zig");

pub fn defineMethod(
    ctx: zqjs.Context,
    proto: zqjs.Value,
    name: [:0]const u8,
    func: qjs.JSCFunction,
    len: c_int,
) void {
    const atom = qjs.JS_NewAtom(ctx.ptr, name);
    defer qjs.JS_FreeAtom(ctx.ptr, atom);

    const func_val = qjs.JS_NewCFunction(ctx.ptr, func, name, len);

    // JS_DefinePropertyValue takes ownership of 'func_val'
    _ = qjs.JS_DefinePropertyValue(ctx.ptr, proto, atom, func_val, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_WRITABLE);
}

pub fn defineGetter(
    ctx: zqjs.Context,
    proto: zqjs.Value,
    name: [:0]const u8,
    getter: qjs.JSCFunction,
) void {
    const atom = qjs.JS_NewAtom(ctx.ptr, name);
    defer qjs.JS_FreeAtom(ctx.ptr, atom);

    const get_val = qjs.JS_NewCFunction(ctx.ptr, getter, name, 0);

    // Pass UNDEFINED for setter -> Read Only
    _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, atom, get_val, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
}

pub fn defineAccessor(
    ctx: zqjs.Context,
    proto: zqjs.Value,
    name: [:0]const u8,
    getter: qjs.JSCFunction,
    setter: qjs.JSCFunction,
) void {
    const atom = qjs.JS_NewAtom(ctx.ptr, name);
    defer qjs.JS_FreeAtom(ctx.ptr, atom);

    const get_val = qjs.JS_NewCFunction(ctx.ptr, getter, name, 0);
    const set_val = qjs.JS_NewCFunction(ctx.ptr, setter, name, 1);

    // JS_DefinePropertyGetSet takes ownership of get_val and set_val
    _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, atom, get_val, set_val, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
}
