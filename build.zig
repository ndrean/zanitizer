const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lexbor_static_lib_path = b.path("vendor/lexbor_src_master/build/liblexbor_static.a");
    const lexbor_src_path = b.path("vendor/lexbor_src_master/source/");
    const quickjs_src_path = b.path("vendor/quickjs-ng");
    const qjs_flags = &.{
        "-std=gnu99",
        "-D_GNU_SOURCE",
        "-Dasm=__asm__",
        "-DCONFIG_VERSION=\"2025-09-13\"", // Use actual version
        "-DCONFIG_BIGNUM",
        "-std=c99",
        "-fno-sanitize=undefined", // Optional: QJS sometimes triggers UBSAN
    };

    const qjs_lib = b.addLibrary(.{
        .name = "quickjs",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    qjs_lib.linkLibC();
    qjs_lib.addCSourceFiles(.{
        .root = quickjs_src_path,
        .files = &.{
            "quickjs.c",
            "libregexp.c",
            "libunicode.c",
            "cutils.c",
            "dtoa.c",
        },
        .flags = qjs_flags,
    });

    // const quickjs_dep = b.dependency("quickjs", .{ .target = target, .optimize = optimize });

    // const mailbox = b.dependency("mailbox", .{
    //     .target = target,
    //     .optimize = optimize,
    // });

    const dep_curl = b.dependency("curl", .{ .target = target, .optimize = optimize });
    const curl_module = dep_curl.module("curl");

    const zexplorer_lib = b.addLibrary(.{
        .name = "zexplorer",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    const c_flags = &.{ "-std=c99", "-DLEXBOR_STATIC" };
    zexplorer_lib.addCSourceFile(.{
        .file = b.path("src/minimal.c"),
        .flags = c_flags,
    });
    zexplorer_lib.addIncludePath(lexbor_src_path);
    // zexplorer_lib.addObjectFile(lexbor_static_lib_path);
    zexplorer_lib.linkLibrary(qjs_lib);
    zexplorer_lib.linkLibC();

    const zexplorer_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "curl", .module = curl_module },
        },
    });

    // Link the module to the wrapper library: get C dependencies
    zexplorer_module.linkLibrary(zexplorer_lib);
    zexplorer_module.linkLibrary(qjs_lib);
    zexplorer_module.addIncludePath(quickjs_src_path);
    zexplorer_module.addIncludePath(lexbor_src_path);

    // Link curl's C library to the module so it can find curl.h
    // The curl module depends on libcurl which needs to be linked
    zexplorer_module.link_libc = true;

    b.installArtifact(zexplorer_lib);

    // Examples executable
    const exe = b.addExecutable(.{
        .name = "zhtml-examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhtml-examples", .module = zexplorer_module },
                .{ .name = "curl", .module = curl_module },
            },
        }),
    });
    exe.addObjectFile(lexbor_static_lib_path);
    exe.addIncludePath(lexbor_src_path);
    exe.addIncludePath(quickjs_src_path);
    exe.linkLibC();
    exe.linkLibrary(zexplorer_lib);
    exe.linkLibrary(qjs_lib);
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);

    // Code generator for QuickJS bindings
    const gen_bindings = b.addExecutable(.{
        .name = "gen_bindings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_bindings.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const gen_bindings_run = b.addRunArtifact(gen_bindings);
    gen_bindings_run.addArg("src/bindings_generated.zig");

    const gen_bindings_step = b.step("gen-bindings", "Generate QuickJS bindings code");
    gen_bindings_step.dependOn(&gen_bindings_run.step);

    // Code generator for Async QuickJS bindings
    const gen_async_bindings = b.addExecutable(.{
        .name = "gen_async_bindings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_async_bindings.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const gen_async_bindings_run = b.addRunArtifact(gen_async_bindings);
    gen_async_bindings_run.addArg("src/async_bindings_generated.zig");
    const gen_async_bindings_step = b.step("gen-async-bindings", "Generate Async QuickJS bindings code");
    gen_async_bindings_step.dependOn(&gen_async_bindings_run.step);

    // SINGLE TEST TARGET - this runs ALL tests from all modules
    const lib_test = b.step("test", "Run units tests");

    // const coverage = b.option(bool, "test-coverage", "Generate test coverage") orelse false;

    var unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "curl", .module = curl_module },
            },
        }),
    });

    unit_tests.addIncludePath(quickjs_src_path);
    unit_tests.linkLibrary(qjs_lib);
    unit_tests.linkLibC();

    // Add dependencies to test
    unit_tests.addCSourceFile(.{
        .file = b.path("src/minimal.c"),
        .flags = &.{"-std=c99"},
    });
    unit_tests.addIncludePath(lexbor_src_path);
    unit_tests.addObjectFile(lexbor_static_lib_path);
    unit_tests.linkLibrary(zexplorer_lib);
    unit_tests.linkLibC();

    // if (coverage) {
    //     // with kcov
    //     unit_tests.setExecCmd(&[_]?[]const u8{
    //         "kcov",
    //         "--clean",
    //         "--include-path=src/modules/",
    //         "--exclude-path=lexbor_src_master/,lexbor_master_dist/,src/misc-files/",
    //         "kcov-output", // output dir for kcov
    //         null, // to get zig to use the --test-cmd-bin flag
    //     });
    // }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.skip_foreign_checks = true;
    lib_test.dependOn(&run_unit_tests.step);

    // ==================== EXAMPLES ====================
    // Run with: zig build example -Dname=<example_name>
    // e.g.: zig build example -Dname=extract_script_from_html
    // List available: zig build example

    const example_step = b.step("example", "Run an example from src/examples/");

    // Register examples as check targets for ZLS analysis
    // ZLS discovers modules attached to build artifacts
    const check_step = b.step("check", "Check examples compile (for ZLS)");
    const example_files = [_][]const u8{
        "src/examples/extract_script_from_html.zig",
        "src/examples/return_data_from_JS_into_zig.zig",
    };
    for (example_files) |example_file| {
        const check_exe = b.addExecutable(.{
            .name = "check-example",
            .root_module = b.createModule(.{
                .root_source_file = b.path(example_file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "curl", .module = curl_module },
                    .{ .name = "zexplorer", .module = zexplorer_module },
                },
            }),
        });
        check_exe.addObjectFile(lexbor_static_lib_path);
        check_exe.addIncludePath(lexbor_src_path);
        check_exe.addIncludePath(quickjs_src_path);
        check_exe.linkLibC();
        check_exe.linkLibrary(zexplorer_lib);
        check_exe.linkLibrary(qjs_lib);
        check_step.dependOn(&check_exe.step);
    }

    // Get example name from args
    const example_name = b.option([]const u8, "name", "Example name (without .zig extension)");

    if (example_name) |name| {
        // Build the specific example
        // Examples use @import("zexplorer") - all needed types exported from root.zig
        const example_path = b.fmt("src/examples/{s}.zig", .{name});

        const example_exe = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(example_path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "curl", .module = curl_module },
                    .{ .name = "zexplorer", .module = zexplorer_module },
                },
            }),
        });

        // Link all required libraries
        example_exe.addObjectFile(lexbor_static_lib_path);
        example_exe.addIncludePath(lexbor_src_path);
        example_exe.addIncludePath(quickjs_src_path);
        example_exe.linkLibC();
        example_exe.linkLibrary(zexplorer_lib);
        example_exe.linkLibrary(qjs_lib);

        b.installArtifact(example_exe);

        const run_example = b.addRunArtifact(example_exe);
        run_example.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_example.addArgs(args);

        example_step.dependOn(&run_example.step);
    } else {
        // No example specified - show available examples
        const list_examples = b.addSystemCommand(&.{ "sh", "-c", "echo 'Available examples:' && ls -1 src/examples/*.zig 2>/dev/null | sed 's|src/examples/||;s|\\.zig$||' | sed 's/^/  /' || echo '  (none found)'" });
        example_step.dependOn(&list_examples.step);
    }

    // Documentation
    const docs_step = b.step("docs", "Build zexplorer library docs");
    const docs_obj = b.addObject(.{
        .name = "zexplorer_docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const docs = docs_obj.getEmittedDocs();
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}
