const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lexbor_src = b.path("vendor/lexbor_src_master/source");
    const md4c_src = b.path("vendor/md4c/src");

    const md4c = buildMd4c(b, target, optimize, md4c_src);
    const lexbor = buildLexbor(b, target, optimize);

    const c_flags = &.{ "-std=c99", "-DLEXBOR_STATIC" };

    // Main executable: zanitize
    const exe = b.addExecutable(.{
        .name = "zan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.addIncludePath(lexbor_src);
    exe.addIncludePath(md4c_src);
    exe.addCSourceFiles(.{ .files = &.{ "src/c/css_shim.c", "src/c/minimal.c" }, .flags = c_flags });
    exe.linkLibrary(lexbor);
    exe.linkLibrary(md4c);
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run zanitize").dependOn(&run_cmd.step);

    // Tests
    buildTests(b, target, optimize, lexbor, lexbor_src, md4c_src, md4c, c_flags);

    // Docs
    buildDocs(b, target, optimize, lexbor, lexbor_src, md4c_src, md4c, c_flags);

    // WASM: zanitize.wasm (wasm32-wasi)
    buildWasm(b, optimize);
}

/// Compile Lexbor from source for the given target.
/// Enumerates all .c files under vendor/lexbor_src_master/source at build time,
/// excluding the port directory that doesn't match the target OS.
/// No cmake or Makefile needed — zig build handles everything.
fn buildLexbor(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "lexbor",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    const src_dir_rel = "vendor/lexbor_src_master/source";
    lib.addIncludePath(b.path(src_dir_rel));

    const is_windows = target.result.os.tag == .windows;

    var files: std.ArrayListUnmanaged([]const u8) = .empty;

    var dir = b.build_root.handle.openDir(src_dir_rel, .{ .iterate = true }) catch
        @panic("Cannot open vendor/lexbor_src_master/source — did you run: git submodule update --init?");
    defer dir.close();

    var walker = dir.walk(b.allocator) catch @panic("OOM during lexbor source walk");
    defer walker.deinit();

    while (walker.next() catch @panic("error walking lexbor source")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".c")) continue;
        // Exclude the port directory that doesn't match the target OS.
        if (is_windows) {
            if (std.mem.indexOf(u8, entry.path, "posix") != null) continue;
        } else {
            if (std.mem.indexOf(u8, entry.path, "windows_nt") != null) continue;
        }
        files.append(b.allocator, b.dupe(entry.path)) catch @panic("OOM");
    }

    lib.addCSourceFiles(.{
        .root = b.path(src_dir_rel),
        .files = files.items,
        .flags = &.{ "-std=c99", "-DLEXBOR_STATIC", "-w" }, // -w: suppress warnings from vendored code
    });
    lib.linkLibC();

    return lib;
}

fn buildMd4c(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, md4c_src: std.Build.LazyPath) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "md4c",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    lib.addCSourceFiles(.{
        .root = md4c_src,
        .files = &.{ "md4c.c", "md4c-html.c", "entity.c" },
        .flags = &.{"-O2"},
    });
    lib.addIncludePath(md4c_src);
    lib.linkLibC();
    return lib;
}

fn buildTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, lexbor: *std.Build.Step.Compile, lexbor_src: std.Build.LazyPath, md4c_src: std.Build.LazyPath, md4c: *std.Build.Step.Compile, c_flags: []const []const u8) void {
    const lib_test = b.step("test", "Run unit tests");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    var unit_tests = b.addTest(.{ .root_module = test_mod });
    unit_tests.addIncludePath(lexbor_src);
    unit_tests.addIncludePath(md4c_src);
    unit_tests.addCSourceFiles(.{ .files = &.{ "src/c/css_shim.c", "src/c/minimal.c" }, .flags = c_flags });
    unit_tests.linkLibrary(lexbor);
    unit_tests.linkLibrary(md4c);
    unit_tests.linkLibC();
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.skip_foreign_checks = true;
    lib_test.dependOn(&run_unit_tests.step);
}

fn buildWasm(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    // wasm32-wasi: Zig bundles wasi-libc, so Lexbor's malloc/free just work.
    // The resulting .wasm imports from wasi_snapshot_preview1; provide a tiny
    // polyfill in your browser JS (stub fd_write, proc_exit, environ_get, etc.).
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const wasm_optimize = if (optimize == .Debug) std.builtin.OptimizeMode.ReleaseSmall else optimize;

    const lexbor_wasm = buildLexbor(b, wasm_target, wasm_optimize);

    const md4c_src = b.path("vendor/md4c/src");
    const md4c_wasm = b.addLibrary(.{
        .name = "md4c_wasm",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = wasm_target, .optimize = wasm_optimize }),
    });
    md4c_wasm.addCSourceFiles(.{
        .root = md4c_src,
        .files = &.{ "md4c.c", "md4c-html.c", "entity.c" },
        .flags = &.{"-O2"},
    });
    md4c_wasm.addIncludePath(md4c_src);
    md4c_wasm.linkLibC();

    const wasm = b.addExecutable(.{
        .name = "zanitize",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.addIncludePath(b.path("vendor/lexbor_src_master/source"));
    wasm.addIncludePath(md4c_src);
    wasm.addCSourceFiles(.{
        .files = &.{ "src/c/css_shim.c", "src/c/minimal.c" },
        .flags = &.{ "-std=c99", "-DLEXBOR_STATIC" },
    });
    wasm.linkLibrary(lexbor_wasm);
    wasm.linkLibrary(md4c_wasm);
    // Do NOT call wasm.linkLibC() here: linking the WASI libc startup code
    // against an entry-less executable pulls in __main_void which requires main.
    // libc (malloc/free) is already transitively available via lexbor_wasm.

    const install_wasm = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "../wasm-out" } } });
    b.step("wasm", "Build zanitize.wasm (wasm32-wasi; use a WASI polyfill in the browser)").dependOn(&install_wasm.step);
}

fn buildDocs(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, lexbor: *std.Build.Step.Compile, lexbor_src: std.Build.LazyPath, md4c_src: std.Build.LazyPath, md4c: *std.Build.Step.Compile, c_flags: []const []const u8) void {
    const docs_obj = b.addObject(.{
        .name = "zanitize_docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    docs_obj.addIncludePath(lexbor_src);
    docs_obj.addIncludePath(md4c_src);
    docs_obj.addCSourceFiles(.{ .files = &.{ "src/c/css_shim.c", "src/c/minimal.c" }, .flags = c_flags });
    docs_obj.linkLibrary(lexbor);
    docs_obj.linkLibrary(md4c);
    docs_obj.linkLibC();
    const docs = docs_obj.getEmittedDocs();
    b.step("docs", "Build docs").dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}
