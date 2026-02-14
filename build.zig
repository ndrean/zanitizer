const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lexbor_static_lib_path = b.path("vendor/lexbor_src_master/build/liblexbor_static.a");
    const lexbor_src_path = b.path("vendor/lexbor_src_master/source/");
    const libwebp_src_path = b.path("vendor/libwebp/src");
    const stb_image_src_path = b.path("src/c");
    const nanosvg_src_path = b.path("src/c");
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
    const libwebp = b.addLibrary(.{
        .name = "webp_decoder",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    libwebp.linkLibC();
    libwebp.addIncludePath(libwebp_src_path);
    libwebp.addIncludePath(b.path("vendor/libwebp"));
    libwebp.addCSourceFiles(.{
        .root = b.path("vendor/libwebp/src/dsp"),
        .files = &.{ "alpha_processing.c", "alpha_processing_mips_dsp_r2.c", "alpha_processing_neon.c", "alpha_processing_sse2.c", "alpha_processing_sse41.c", "cpu.c", "dec.c", "dec_clip_tables.c", "dec_mips32.c", "dec_mips_dsp_r2.c", "dec_msa.c", "dec_neon.c", "dec_sse2.c", "dec_sse41.c", "enc.c", "enc_mips32.c", "enc_mips_dsp_r2.c", "enc_msa.c", "enc_neon.c", "enc_sse2.c", "enc_sse41.c", "filters.c", "filters_mips_dsp_r2.c", "filters_msa.c", "filters_neon.c", "filters_sse2.c", "lossless.c", "lossless_mips_dsp_r2.c", "lossless_msa.c", "lossless_neon.c", "lossless_sse2.c", "lossless_sse41.c", "lossless_enc.c", "lossless_enc_mips32.c", "lossless_enc_mips_dsp_r2.c", "lossless_enc_msa.c", "lossless_enc_neon.c", "lossless_enc_sse2.c", "lossless_enc_sse41.c", "rescaler.c", "rescaler_mips32.c", "rescaler_mips_dsp_r2.c", "rescaler_msa.c", "rescaler_neon.c", "rescaler_sse2.c", "ssim.c", "ssim_sse2.c", "upsampling.c", "upsampling_mips_dsp_r2.c", "upsampling_msa.c", "upsampling_neon.c", "upsampling_sse2.c", "upsampling_sse41.c", "yuv.c", "yuv_mips32.c", "yuv_mips_dsp_r2.c", "yuv_neon.c", "yuv_sse2.c", "yuv_sse41.c", "cost.c", "cost_mips32.c", "cost_mips_dsp_r2.c", "cost_neon.c", "cost_sse2.c" },
        .flags = &.{"-O3"},
    });
    libwebp.addCSourceFiles(.{
        .root = b.path("vendor/libwebp/src/dec"),
        .files = &.{
            "alpha_dec.c", "buffer_dec.c", "frame_dec.c", "idec_dec.c",
            "io_dec.c",    "quant_dec.c",  "tree_dec.c",  "vp8_dec.c",
            "vp8l_dec.c",  "webp_dec.c",
        },
        .flags = &.{"-O3"},
    });
    libwebp.addCSourceFiles(.{
        .root = b.path("vendor/libwebp/src/enc"),
        .files = &.{ "alpha_enc.c", "analysis_enc.c", "backward_references_cost_enc.c", "backward_references_enc.c", "config_enc.c", "cost_enc.c", "filter_enc.c", "frame_enc.c", "histogram_enc.c", "iterator_enc.c", "near_lossless_enc.c", "picture_csp_enc.c", "picture_enc.c", "picture_psnr_enc.c", "picture_rescale_enc.c", "picture_tools_enc.c", "predictor_enc.c", "quant_enc.c", "syntax_enc.c", "token_enc.c", "tree_enc.c", "vp8l_enc.c", "webp_enc.c" },
        .flags = &.{"-O3"},
    });

    libwebp.addCSourceFiles(.{
        .root = b.path("vendor/libwebp/src/utils"),
        .files = &.{ "bit_reader_utils.c", "bit_writer_utils.c", "color_cache_utils.c", "filters_utils.c", "huffman_utils.c", "huffman_encode_utils.c", "palette.c", "quant_levels_dec_utils.c", "quant_levels_utils.c", "random_utils.c", "rescaler_utils.c", "thread_utils.c", "utils.c" },
        .flags = &.{"-O3"},
    });
    libwebp.addCSourceFiles(.{
        .root = b.path("vendor/libwebp/sharpyuv"),
        .files = &.{ "sharpyuv.c", "sharpyuv_cpu.c", "sharpyuv_csp.c", "sharpyuv_dsp.c", "sharpyuv_gamma.c", "sharpyuv_neon.c", "sharpyuv_sse2.c" },
        .flags = &.{"-O3"},
    });

    const dep_curl = b.dependency(
        "curl",
        .{ .target = target, .optimize = optimize },
    );
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
    zexplorer_lib.addCSourceFile(.{
        .file = b.path("src/c/stb_image.c"),
        .flags = &.{
            "-g",
            // "-std=c99",
            "-fno-sanitize=undefined",
        },
    });

    zexplorer_lib.addCSourceFile(.{
        .file = b.path("src/c/nanosvg.c"),
        .flags = &.{
            "-std=c99",
            "-fno-sanitize=undefined",
        },
    });

    zexplorer_lib.addCSourceFile(.{
        .file = b.path("src/css_shim.c"),
        .flags = c_flags,
    });
    zexplorer_lib.addIncludePath(lexbor_src_path);
    zexplorer_lib.addIncludePath(stb_image_src_path);
    zexplorer_lib.addIncludePath(nanosvg_src_path);
    zexplorer_lib.addIncludePath(libwebp_src_path);
    zexplorer_lib.linkLibrary(qjs_lib);
    zexplorer_lib.linkLibrary(libwebp);
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
    zexplorer_module.linkLibrary(libwebp);
    zexplorer_module.addIncludePath(quickjs_src_path);
    zexplorer_module.addIncludePath(lexbor_src_path);
    zexplorer_module.addIncludePath(stb_image_src_path);
    zexplorer_module.addIncludePath(nanosvg_src_path);
    zexplorer_module.addIncludePath(libwebp_src_path);

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
    exe.addCSourceFiles(
        .{
            .files = &[_][]const u8{"src/c/stb_image.c"},
            .flags = &.{"-g"},
        },
    );
    exe.addCSourceFiles(
        .{
            .files = &[_][]const u8{"src/c/nanosvg.c"},
            .flags = &.{"-std=c99"},
        },
    );
    // -g adds debug info, makes it easier to debug
    exe.addIncludePath(stb_image_src_path);
    exe.addObjectFile(lexbor_static_lib_path);
    exe.addIncludePath(lexbor_src_path);
    exe.addIncludePath(quickjs_src_path);
    exe.addIncludePath(nanosvg_src_path);
    exe.addIncludePath(libwebp_src_path);
    exe.linkLibC();
    exe.linkLibrary(zexplorer_lib);
    exe.linkLibrary(qjs_lib);
    exe.linkLibrary(libwebp);

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
            .root_source_file = b.path("tools/template_gen.zig"),
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

    // Bytecode generator for pre-compiling JavaScript
    const gen_bytecode = b.addExecutable(.{
        .name = "gen-bytecode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_bytecode.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gen_bytecode.addIncludePath(quickjs_src_path);
    gen_bytecode.linkLibrary(qjs_lib);
    gen_bytecode.linkLibC();
    b.installArtifact(gen_bytecode);

    const gen_bytecode_step = b.step("gen-bytecode", "Build bytecode compiler tool");
    gen_bytecode_step.dependOn(&gen_bytecode.step);

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
    unit_tests.addIncludePath(lexbor_src_path);
    unit_tests.addIncludePath(stb_image_src_path);
    unit_tests.addIncludePath(nanosvg_src_path);
    unit_tests.addIncludePath(libwebp_src_path);
    unit_tests.linkLibrary(qjs_lib);
    unit_tests.linkLibrary(libwebp);
    unit_tests.linkLibC();

    // Add dependencies to test
    const test_c_flags = &.{ "-std=c99", "-DLEXBOR_STATIC" };
    unit_tests.addCSourceFile(.{
        .file = b.path("src/minimal.c"),
        .flags = test_c_flags,
    });
    unit_tests.addCSourceFile(.{
        .file = b.path("src/css_shim.c"),
        .flags = test_c_flags,
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
        "src/examples/classlist.zig",
        "src/examples/text_encoding.zig",
        "src/examples/readable_stream_demo.zig",
        "src/examples/formdata_upload_demo.zig",
        "src/examples/disk_streaming_upload_demo.zig",
        "src/examples/fs_demo.zig",
        "src/examples/writable_stream_demo.zig",
        "src/examples/streaming_demo.zig",
        "src/examples/file_reader.zig",
        "src/examples/cdn_import.zig",
        "src/examples/js-bench-1.zig",
        "src/examples/js-bench-2.zig",
        "src/examples/js-bench-20.zig",
        "src/examples/js-bench-3.zig",
        "src/examples/js-bench-bau.zig",
        "src/examples/js-bench-vue.zig",
        "src/examples/js-bench-react-h.zig",
        "src/examples/js-bench-solid.zig",
        "src/examples/test-worker_zig.zig",
        "src/examples/dom_purify.zig",
        "src/examples/test_encoding.zig",
        "src/examples/jsdom_zexplorer_speed_test.zig",
        "src/examples/h5sc-test.zig",
        "src/examples/blob_url.zig",
        "src/examples/blob_object_url.zig",
        "src/examples/test_css_sanitization.zig",
        "src/examples/test_css_pipeline.zig",
        "src/examples/test_css_complete.zig",
        "src/examples/test_real.zig",
        "src/examples/test_all.zig",
        "src/examples/test_canvas.zig",
        "src/examples/test_example.zig",
        "src/examples/test_image1.zig",
        "src/examples/test_image2.zig",
        "src/examples/test_image3.zig",
        "src/examples/test_image4.zig",
        "src/examples/dompurify_tests.zig",
        "src/examples/test_svg_raster.zig",
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
        check_exe.linkLibrary(libwebp);
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
        example_exe.linkLibrary(libwebp);

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
