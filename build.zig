const std = @import("std");

/// All include paths needed by artifacts linking against the zexplorer stack
const Paths = struct {
    lexbor_static_lib: std.Build.LazyPath,
    lexbor_src: std.Build.LazyPath,
    quickjs_src: std.Build.LazyPath,
    stb_image_src: std.Build.LazyPath,
    nanosvg_src: std.Build.LazyPath,
    libwebp_src: std.Build.LazyPath,
    thorvg_src: std.Build.LazyPath,
    yoga_src: std.Build.LazyPath,
    miniz_src: std.Build.LazyPath,
    libharu_include: std.Build.LazyPath,
    fake_zlib: std.Build.LazyPath,
};

/// All C libraries needed by the project
const Libraries = struct {
    qjs: *std.Build.Step.Compile,
    webp: *std.Build.Step.Compile,
    thorvg: *std.Build.Step.Compile,
    yoga: *std.Build.Step.Compile,
    miniz: *std.Build.Step.Compile,
    haru: *std.Build.Step.Compile,
    zexplorer: *std.Build.Step.Compile,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const paths = Paths{
        .lexbor_static_lib = b.path("vendor/lexbor_src_master/build/liblexbor_static.a"),
        .lexbor_src = b.path("vendor/lexbor_src_master/source/"),
        .quickjs_src = b.path("vendor/quickjs-ng"),
        .stb_image_src = b.path("src/c"),
        .nanosvg_src = b.path("src/c"),
        .libwebp_src = b.path("vendor/libwebp/src"),
        .thorvg_src = b.path("vendor/thorvg"),
        .yoga_src = b.path("vendor/yoga"),
        .miniz_src = b.path("vendor/miniz"),
        .libharu_include = b.path("vendor/libharu/include"),
        .fake_zlib = b.path("vendor/fake_zlib"),
    };

    // Build all C libraries
    const libs = Libraries{
        .qjs = buildQuickJS(b, target, optimize, paths),
        .webp = buildLibWebP(b, target, optimize, paths),
        .thorvg = buildThorVG(b, target, optimize, paths),
        .yoga = buildYoga(b, target, optimize, paths),
        .miniz = buildMiniz(b, target, optimize, paths),
        .haru = buildLibHaru(b, target, optimize, paths),
        .zexplorer = buildZexplorerLib(b, target, optimize, paths),
    };

    // Link zexplorer_lib against its C dependencies
    libs.zexplorer.linkLibrary(libs.qjs);
    libs.zexplorer.linkLibrary(libs.webp);
    libs.zexplorer.linkLibrary(libs.thorvg);
    libs.zexplorer.linkLibrary(libs.yoga);
    libs.zexplorer.linkLibrary(libs.miniz);
    libs.zexplorer.linkLibrary(libs.haru);

    // Curl dependency
    const dep_curl = b.dependency("curl", .{ .target = target, .optimize = optimize });
    const curl_module = dep_curl.module("curl");

    // Zexplorer Zig module (root.zig + all C deps)
    const zexplorer_module = buildZexplorerModule(b, target, optimize, paths, libs, curl_module);

    b.installArtifact(libs.zexplorer);

    // CLI executable
    buildMainExe(b, target, optimize, paths, libs, zexplorer_module, curl_module);

    // Code generators
    buildCodeGenerators(b, target, optimize, paths, libs);

    // Tests
    buildTests(b, target, optimize, paths, libs, curl_module);

    // Examples
    buildExamples(b, target, optimize, paths, libs, zexplorer_module, curl_module);

    // Documentation
    buildDocs(b, target, optimize);
}

// =============================================================================
// C Library Builders
// =============================================================================

fn buildMiniz(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, paths: Paths) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "miniz",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    lib.addCSourceFiles(.{ .root = paths.miniz_src, .files = &.{"miniz.c"}, .flags = &.{"-O3"} });
    lib.linkLibC();
    return lib;
}

fn buildLibHaru(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, paths: Paths) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "hpdf",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    lib.addIncludePath(paths.fake_zlib);
    lib.addIncludePath(paths.libharu_include);
    lib.addCSourceFiles(.{
        .root = b.path("vendor/libharu/src"),
        .files = &.{ "hpdf_3dmeasure.c", "hpdf_annotation.c", "hpdf_array.c", "hpdf_binary.c", "hpdf_boolean.c", "hpdf_catalog.c", "hpdf_destination.c", "hpdf_dict.c", "hpdf_direct.c", "hpdf_doc.c", "hpdf_doc_png.c", "hpdf_encoder.c", "hpdf_encoder_cns.c", "hpdf_encoder_cnt.c", "hpdf_encoder_jp.c", "hpdf_encoder_kr.c", "hpdf_encoder_utf.c", "hpdf_encrypt.c", "hpdf_encryptdict.c", "hpdf_error.c", "hpdf_exdata.c", "hpdf_ext_gstate.c", "hpdf_font.c", "hpdf_font_cid.c", "hpdf_font_tt.c", "hpdf_font_type1.c", "hpdf_fontdef.c", "hpdf_fontdef_base14.c", "hpdf_fontdef_cid.c", "hpdf_fontdef_cns.c", "hpdf_fontdef_cnt.c", "hpdf_fontdef_jp.c", "hpdf_fontdef_kr.c", "hpdf_fontdef_tt.c", "hpdf_fontdef_type1.c", "hpdf_gstate.c", "hpdf_image.c", "hpdf_image_ccitt.c", "hpdf_image_png.c", "hpdf_info.c", "hpdf_list.c", "hpdf_mmgr.c", "hpdf_name.c", "hpdf_namedict.c", "hpdf_null.c", "hpdf_number.c", "hpdf_objects.c", "hpdf_outline.c", "hpdf_page_label.c", "hpdf_page_operator.c", "hpdf_pages.c", "hpdf_pdfa.c", "hpdf_real.c", "hpdf_shading.c", "hpdf_streams.c", "hpdf_string.c", "hpdf_u3d.c", "hpdf_utils.c", "hpdf_xref.c" },
        .flags = &.{ "-O3", "-DHPDF_NOPNGLIB" },
    });
    return lib;
}

fn buildQuickJS(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, paths: Paths) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "quickjs",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    lib.linkLibC();
    lib.addCSourceFiles(.{
        .root = paths.quickjs_src,
        .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c" },
        .flags = &.{
            "-std=gnu99",
            "-D_GNU_SOURCE",
            "-Dasm=__asm__",
            "-DCONFIG_VERSION=\"2025-09-13\"",
            "-DCONFIG_BIGNUM",
            "-std=c99",
            "-fno-sanitize=undefined",
        },
    });
    return lib;
}

fn buildLibWebP(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, paths: Paths) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "webp_decoder",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    lib.linkLibC();
    lib.addIncludePath(paths.libwebp_src);
    lib.addIncludePath(b.path("vendor/libwebp"));

    lib.addCSourceFiles(.{
        .root = b.path("vendor/libwebp/src/dsp"),
        .files = &.{ "alpha_processing.c", "alpha_processing_mips_dsp_r2.c", "alpha_processing_neon.c", "alpha_processing_sse2.c", "alpha_processing_sse41.c", "cpu.c", "dec.c", "dec_clip_tables.c", "dec_mips32.c", "dec_mips_dsp_r2.c", "dec_msa.c", "dec_neon.c", "dec_sse2.c", "dec_sse41.c", "enc.c", "enc_mips32.c", "enc_mips_dsp_r2.c", "enc_msa.c", "enc_neon.c", "enc_sse2.c", "enc_sse41.c", "filters.c", "filters_mips_dsp_r2.c", "filters_msa.c", "filters_neon.c", "filters_sse2.c", "lossless.c", "lossless_mips_dsp_r2.c", "lossless_msa.c", "lossless_neon.c", "lossless_sse2.c", "lossless_sse41.c", "lossless_enc.c", "lossless_enc_mips32.c", "lossless_enc_mips_dsp_r2.c", "lossless_enc_msa.c", "lossless_enc_neon.c", "lossless_enc_sse2.c", "lossless_enc_sse41.c", "rescaler.c", "rescaler_mips32.c", "rescaler_mips_dsp_r2.c", "rescaler_msa.c", "rescaler_neon.c", "rescaler_sse2.c", "ssim.c", "ssim_sse2.c", "upsampling.c", "upsampling_mips_dsp_r2.c", "upsampling_msa.c", "upsampling_neon.c", "upsampling_sse2.c", "upsampling_sse41.c", "yuv.c", "yuv_mips32.c", "yuv_mips_dsp_r2.c", "yuv_neon.c", "yuv_sse2.c", "yuv_sse41.c", "cost.c", "cost_mips32.c", "cost_mips_dsp_r2.c", "cost_neon.c", "cost_sse2.c" },
        .flags = &.{"-O3"},
    });
    lib.addCSourceFiles(.{
        .root = b.path("vendor/libwebp/src/dec"),
        .files = &.{ "alpha_dec.c", "buffer_dec.c", "frame_dec.c", "idec_dec.c", "io_dec.c", "quant_dec.c", "tree_dec.c", "vp8_dec.c", "vp8l_dec.c", "webp_dec.c" },
        .flags = &.{"-O3"},
    });
    lib.addCSourceFiles(.{
        .root = b.path("vendor/libwebp/src/enc"),
        .files = &.{ "alpha_enc.c", "analysis_enc.c", "backward_references_cost_enc.c", "backward_references_enc.c", "config_enc.c", "cost_enc.c", "filter_enc.c", "frame_enc.c", "histogram_enc.c", "iterator_enc.c", "near_lossless_enc.c", "picture_csp_enc.c", "picture_enc.c", "picture_psnr_enc.c", "picture_rescale_enc.c", "picture_tools_enc.c", "predictor_enc.c", "quant_enc.c", "syntax_enc.c", "token_enc.c", "tree_enc.c", "vp8l_enc.c", "webp_enc.c" },
        .flags = &.{"-O3"},
    });
    lib.addCSourceFiles(.{
        .root = b.path("vendor/libwebp/src/utils"),
        .files = &.{ "bit_reader_utils.c", "bit_writer_utils.c", "color_cache_utils.c", "filters_utils.c", "huffman_utils.c", "huffman_encode_utils.c", "palette.c", "quant_levels_dec_utils.c", "quant_levels_utils.c", "random_utils.c", "rescaler_utils.c", "thread_utils.c", "utils.c" },
        .flags = &.{"-O3"},
    });
    lib.addCSourceFiles(.{
        .root = b.path("vendor/libwebp/sharpyuv"),
        .files = &.{ "sharpyuv.c", "sharpyuv_cpu.c", "sharpyuv_csp.c", "sharpyuv_dsp.c", "sharpyuv_gamma.c", "sharpyuv_neon.c", "sharpyuv_sse2.c" },
        .flags = &.{"-O3"},
    });
    return lib;
}

fn buildYoga(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, paths: Paths) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "yoga",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    lib.linkLibC();
    lib.linkLibCpp();

    const yoga_flags = &.{
        "-xc++",
        "-std=c++20",
        "-fno-exceptions",
        "-fno-rtti",
        "-Wno-everything",
    };

    // Yoga headers are included as <yoga/Yoga.h> so we add the parent dir
    lib.addIncludePath(paths.yoga_src);

    const yoga_src_dirs = [_][]const u8{
        "vendor/yoga/yoga",
        "vendor/yoga/yoga/algorithm",
        "vendor/yoga/yoga/config",
        "vendor/yoga/yoga/debug",
        "vendor/yoga/yoga/event",
        "vendor/yoga/yoga/node",
    };

    for (yoga_src_dirs) |dir_path| {
        var dir = b.build_root.handle.openDir(dir_path, .{ .iterate = true }) catch |err| {
            std.debug.panic("Failed to open dir {s}: {}", .{ dir_path, err });
        };
        defer dir.close();
        var walker = dir.iterate();
        while (walker.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".cpp")) {
                lib.addCSourceFile(.{
                    .file = b.path(b.pathJoin(&.{ dir_path, entry.name })),
                    .flags = yoga_flags,
                });
            }
        }
    }
    return lib;
}

fn buildThorVG(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, paths: Paths) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "thorvg",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    lib.linkLibC();
    lib.linkLibCpp();

    const tvg_config = b.addConfigHeader(.{ .style = .blank, .include_path = "config.h" }, .{
        .THORVG_SW_RASTER_SUPPORT = 1,
        .THORVG_SVG_LOADER_SUPPORT = 1,
        .THORVG_TTF_LOADER_SUPPORT = 1,
        .THORVG_JPG_LOADER_SUPPORT = 1,
        .THORVG_PNG_LOADER_SUPPORT = 1,
        .THORVG_CAPI_BINDING_SUPPORT = 1,
        .THORVG_THREAD_SUPPORT = 1,
        .THORVG_VERSION_STRING = "0.15.2",
    });
    lib.addConfigHeader(tvg_config);

    const tvg_flags = &.{
        "-xc++",          "-std=c++14",
        "-fno-exceptions", "-fno-rtti",
        "-Wno-everything",
        "-DTHORVG_SW_RASTER_SUPPORT=1",
        "-DTHORVG_SVG_LOADER_SUPPORT=1",
        "-DTHORVG_TTF_LOADER_SUPPORT=1",
        "-DTHORVG_JPG_LOADER_SUPPORT=1",
        "-DTHORVG_PNG_LOADER_SUPPORT=1",
        "-DTHORVG_CAPI_BINDING_SUPPORT=1",
        "-DTHORVG_THREAD_SUPPORT=1",
    };

    const tvg_src_dirs = [_][]const u8{
        "vendor/thorvg/src/common",
        "vendor/thorvg/src/renderer",
        "vendor/thorvg/src/renderer/sw_engine",
        "vendor/thorvg/src/loaders/svg",
        "vendor/thorvg/src/loaders/ttf",
        "vendor/thorvg/src/bindings/capi",
        "vendor/thorvg/src/loaders/raw",
        "vendor/thorvg/src/loaders/jpg",
        "vendor/thorvg/src/loaders/png",
    };

    lib.addIncludePath(paths.thorvg_src);
    lib.addIncludePath(b.path("vendor/thorvg/inc"));
    lib.addIncludePath(b.path("vendor/thorvg/src/common"));
    for (tvg_src_dirs) |dir_path| {
        lib.addIncludePath(b.path(dir_path));
    }

    for (tvg_src_dirs) |dir_path| {
        var dir = b.build_root.handle.openDir(dir_path, .{ .iterate = true }) catch |err| {
            std.debug.panic("Failed to open dir {s}: {}", .{ dir_path, err });
            continue;
        };
        defer dir.close();
        var walker = dir.iterate();
        while (walker.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".cpp")) {
                lib.addCSourceFile(.{
                    .file = b.path(b.pathJoin(&.{ dir_path, entry.name })),
                    .flags = tvg_flags,
                });
            }
        }
    }
    return lib;
}

fn buildZexplorerLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, paths: Paths) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "zexplorer",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    const c_flags = &.{ "-std=c99", "-DLEXBOR_STATIC" };
    lib.addCSourceFile(.{ .file = b.path("src/minimal.c"), .flags = c_flags });
    lib.addCSourceFile(.{ .file = b.path("src/c/stb_image.c"), .flags = &.{ "-g", "-fno-sanitize=undefined" } });
    // Legacy: nanosvg replaced by ThorVG for SVG rasterization
    // lib.addCSourceFile(.{ .file = b.path("src/c/nanosvg.c"), .flags = &.{ "-std=c99", "-fno-sanitize=undefined" } });
    lib.addCSourceFile(.{ .file = b.path("src/css_shim.c"), .flags = c_flags });

    lib.addIncludePath(paths.lexbor_src);
    lib.addIncludePath(paths.stb_image_src);
    lib.addIncludePath(paths.nanosvg_src);
    lib.addIncludePath(paths.libwebp_src);
    lib.addIncludePath(paths.thorvg_src);
    lib.addIncludePath(paths.miniz_src);
    lib.addIncludePath(paths.libharu_include);
    lib.addIncludePath(paths.fake_zlib);
    lib.addIncludePath(b.path("vendor/libharu/include"));
    lib.linkLibC();
    lib.linkLibCpp();
    return lib;
}

// =============================================================================
// Zig Module & Targets
// =============================================================================

fn buildZexplorerModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    paths: Paths,
    libs: Libraries,
    curl_module: *std.Build.Module,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "curl", .module = curl_module }},
    });

    mod.linkLibrary(libs.zexplorer);
    mod.linkLibrary(libs.qjs);
    mod.linkLibrary(libs.webp);
    mod.linkLibrary(libs.thorvg);
    mod.linkLibrary(libs.yoga);
    mod.linkLibrary(libs.miniz);
    mod.linkLibrary(libs.haru);
    mod.addIncludePath(paths.quickjs_src);
    mod.addIncludePath(paths.lexbor_src);
    mod.addIncludePath(paths.stb_image_src);
    mod.addIncludePath(paths.nanosvg_src);
    mod.addIncludePath(paths.libwebp_src);
    mod.addIncludePath(paths.thorvg_src);
    mod.addIncludePath(paths.yoga_src);
    mod.addIncludePath(paths.miniz_src);
    mod.addIncludePath(paths.libharu_include);
    mod.addIncludePath(paths.fake_zlib);
    mod.addIncludePath(b.path("vendor/libharu/include"));
    mod.link_libc = true;
    mod.link_libcpp = true;
    return mod;
}

/// Link all C libraries and include paths to an executable or test artifact
fn linkAllLibs(artifact: *std.Build.Step.Compile, paths: Paths, libs: Libraries) void {
    artifact.addObjectFile(paths.lexbor_static_lib);
    artifact.addIncludePath(paths.lexbor_src);
    artifact.addIncludePath(paths.quickjs_src);
    artifact.addIncludePath(paths.stb_image_src);
    artifact.addIncludePath(paths.nanosvg_src);
    artifact.addIncludePath(paths.libwebp_src);
    artifact.addIncludePath(paths.thorvg_src);
    artifact.addIncludePath(paths.yoga_src);
    artifact.addIncludePath(paths.libharu_include);
    artifact.addIncludePath(paths.miniz_src);
    artifact.addIncludePath(paths.fake_zlib);
    artifact.linkLibC();
    artifact.linkLibCpp();
    artifact.linkLibrary(libs.zexplorer);
    artifact.linkLibrary(libs.qjs);
    artifact.linkLibrary(libs.webp);
    artifact.linkLibrary(libs.thorvg);
    artifact.linkLibrary(libs.yoga);
    artifact.linkLibrary(libs.miniz);
    artifact.linkLibrary(libs.haru);
}

fn buildMainExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    paths: Paths,
    libs: Libraries,
    zexplorer_module: *std.Build.Module,
    curl_module: *std.Build.Module,
) void {
    const exe = b.addExecutable(.{
        .name = "zxp-ex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zxp", .module = zexplorer_module },
                .{ .name = "curl", .module = curl_module },
            },
        }),
    });
    exe.addCSourceFiles(.{ .files = &.{"src/c/stb_image.c"}, .flags = &.{"-g"} });
    // Legacy: nanosvg replaced by ThorVG
    // exe.addCSourceFiles(.{ .files = &.{"src/c/nanosvg.c"}, .flags = &.{"-std=c99"} });
    linkAllLibs(exe, paths, libs);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the example").dependOn(&run_cmd.step);
}

// =============================================================================
// Code Generators
// =============================================================================

fn buildCodeGenerators(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    paths: Paths,
    libs: Libraries,
) void {
    // QuickJS bindings generator
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
    b.step("gen-bindings", "Generate QuickJS bindings code").dependOn(&gen_bindings_run.step);

    // Async bindings generator
    const gen_async = b.addExecutable(.{
        .name = "gen_async_bindings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_async_bindings.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const gen_async_run = b.addRunArtifact(gen_async);
    gen_async_run.addArg("src/async_bindings_generated.zig");
    b.step("gen-async-bindings", "Generate Async QuickJS bindings code").dependOn(&gen_async_run.step);

    // Bytecode generator
    const gen_bytecode = b.addExecutable(.{
        .name = "gen-bytecode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_bytecode.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gen_bytecode.addIncludePath(paths.quickjs_src);
    gen_bytecode.linkLibrary(libs.qjs);
    gen_bytecode.linkLibC();
    b.installArtifact(gen_bytecode);
    b.step("gen-bytecode", "Build bytecode compiler tool").dependOn(&gen_bytecode.step);
}

// =============================================================================
// Tests
// =============================================================================

fn buildTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    paths: Paths,
    libs: Libraries,
    curl_module: *std.Build.Module,
) void {
    const lib_test = b.step("test", "Run unit tests");

    var unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "curl", .module = curl_module }},
        }),
    });

    linkAllLibs(unit_tests, paths, libs);

    const c_flags = &.{ "-std=c99", "-DLEXBOR_STATIC" };
    unit_tests.addCSourceFile(.{ .file = b.path("src/minimal.c"), .flags = c_flags });
    unit_tests.addCSourceFile(.{ .file = b.path("src/css_shim.c"), .flags = c_flags });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.skip_foreign_checks = true;
    lib_test.dependOn(&run_unit_tests.step);
}

// =============================================================================
// Examples
// =============================================================================

fn buildExamples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    paths: Paths,
    libs: Libraries,
    zexplorer_module: *std.Build.Module,
    curl_module: *std.Build.Module,
) void {
    const example_step = b.step("example", "Run an example from src/examples/");
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
        "src/examples/js-bench-preact.zig",
        "src/examples/js-bench-svelte.zig",
        "src/examples/js-bench-solid.zig",
        "src/examples/test-worker_zig.zig",
        "src/examples/dom_purify.zig",
        "src/examples/text_encoding.zig",
        "src/examples/jsdom_zexplorer_speed_test.zig",
        "src/examples/h5sc-test.zig",
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
        "src/examples/test_og_generator.zig",
        "src/examples/test_og_generator_v3.zig",
        "src/examples/test_invoice_generator.zig",
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
        linkAllLibs(check_exe, paths, libs);
        b.installArtifact(check_exe);
        check_step.dependOn(&check_exe.step);
    }

    const example_name = b.option([]const u8, "name", "Example name (without .zig extension)");

    if (example_name) |name| {
        const example_exe = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "curl", .module = curl_module },
                    .{ .name = "zexplorer", .module = zexplorer_module },
                },
            }),
        });
        linkAllLibs(example_exe, paths, libs);
        b.installArtifact(example_exe);

        const run_example = b.addRunArtifact(example_exe);
        run_example.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_example.addArgs(args);
        example_step.dependOn(&run_example.step);
    } else {
        const list_examples = b.addSystemCommand(&.{ "sh", "-c", "echo 'Available examples:' && ls -1 src/examples/*.zig 2>/dev/null | sed 's|src/examples/||;s|\\.zig$||' | sed 's/^/  /' || echo '  (none found)'" });
        example_step.dependOn(&list_examples.step);
    }
}

// =============================================================================
// Documentation
// =============================================================================

fn buildDocs(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const docs_obj = b.addObject(.{
        .name = "zexplorer_docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const docs = docs_obj.getEmittedDocs();
    b.step("docs", "Build zexplorer library docs").dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}
