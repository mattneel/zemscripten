// ALTERED FOR ZIG++: https://github.com/mattneel/zemscripten is a fork of
// https://github.com/zig-gamedev/zemscripten whose build script is ported to
// Zig++'s (https://github.com/mattneel/zigpp) `std.Build` API: `LazyPath.getPath`
// is gone, so emsdk paths and resources are propagated as `std.Build.LazyPath`
// values instead of strings.
const builtin = @import("builtin");
const std = @import("std");

pub const emsdk_ver_major = "4";
pub const emsdk_ver_minor = "0";
pub const emsdk_ver_tiny = "19";
pub const emsdk_version = emsdk_ver_major ++ "." ++ emsdk_ver_minor ++ "." ++ emsdk_ver_tiny;

pub fn build(b: *std.Build) void {
    _ = b.addModule("root", .{ .root_source_file = b.path("src/zemscripten.zig") });
}

/// Returns a lazy path to a path within the `emsdk` dependency.
fn emsdkPath(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
    return b.dependency("emsdk", .{}).path("").path(b, sub_path);
}

pub fn emccPath(b: *std.Build) std.Build.LazyPath {
    return emsdkPath(b, "upstream/emscripten/emcc.py");
}

pub fn emrunPath(b: *std.Build) std.Build.LazyPath {
    return emsdkPath(b, switch (builtin.target.os.tag) {
        .windows => "upstream/emscripten/emrun.bat",
        else => "upstream/emscripten/emrun",
    });
}

pub fn htmlPath(b: *std.Build) std.Build.LazyPath {
    return emsdkPath(b, "upstream/emscripten/src/shell.html");
}

/// Runs a system command whose argv[0] is `program` (an emsdk script inside the
/// `emsdk` dependency), followed by `args`.
fn addEmsdkCommand(b: *std.Build, program: std.Build.LazyPath, args: []const []const u8) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, b.fmt("emsdk {s}", .{args[0]}));
    run.addFileArg(program);
    run.addArgs(args);
    return run;
}

pub fn activateEmsdkStep(b: *std.Build) *std.Build.Step {
    const emsdk_script_path = emsdkPath(b, switch (builtin.target.os.tag) {
        .windows => "emsdk.bat",
        else => "emsdk",
    });

    const emsdk_update = addEmsdkCommand(b, emsdk_script_path, &.{"update"});

    const emsdk_install = addEmsdkCommand(b, emsdk_script_path, &.{ "install", emsdk_version });
    emsdk_install.step.dependOn(&emsdk_update.step);

    switch (builtin.target.os.tag) {
        .linux, .macos => {
            const chmod_emsdk = b.addSystemCommand(&.{ "chmod", "a+x" });
            chmod_emsdk.addFileArg(emsdk_script_path);
            emsdk_install.step.dependOn(&chmod_emsdk.step);
        },
        .windows => {
            const takeown_emsdk = b.addSystemCommand(&.{ "takeown", "/f" });
            takeown_emsdk.addFileArg(emsdk_script_path);
            emsdk_install.step.dependOn(&takeown_emsdk.step);
        },
        else => {},
    }

    const emsdk_activate = addEmsdkCommand(b, emsdk_script_path, &.{ "activate", emsdk_version });
    emsdk_activate.step.dependOn(&emsdk_install.step);

    // A no-op aggregator step; the Zig++ build API has no user-defined step
    // callbacks, so use the same `top_level` step type the install/uninstall
    // steps use.
    const step = b.allocator.create(std.Build.Step.TopLevel) catch @panic("OOM");
    step.* = .{
        .step = std.Build.Step.init(.{
            .tag = .top_level,
            .name = "Activate EMSDK",
            .owner = b,
        }),
        .description = "Activate EMSDK",
    };

    switch (builtin.target.os.tag) {
        .linux, .macos => {
            const chmod_emcc = b.addSystemCommand(&.{ "chmod", "a+x" });
            chmod_emcc.addFileArg(emccPath(b));
            chmod_emcc.step.dependOn(&emsdk_activate.step);
            step.step.dependOn(&chmod_emcc.step);

            const chmod_emrun = b.addSystemCommand(&.{ "chmod", "a+x" });
            chmod_emrun.addFileArg(emrunPath(b));
            chmod_emrun.step.dependOn(&emsdk_activate.step);
            step.step.dependOn(&chmod_emrun.step);
        },
        .windows => {
            const takeown_emcc = b.addSystemCommand(&.{ "takeown", "/f" });
            takeown_emcc.addFileArg(emccPath(b));
            takeown_emcc.step.dependOn(&emsdk_activate.step);
            step.step.dependOn(&takeown_emcc.step);

            const takeown_emrun = b.addSystemCommand(&.{ "takeown", "/f" });
            takeown_emrun.addFileArg(emrunPath(b));
            takeown_emrun.step.dependOn(&emsdk_activate.step);
            step.step.dependOn(&takeown_emrun.step);
        },
        else => {},
    }

    return &step.step;
}

pub const EmccFlags = std.StringHashMap(void);

pub const EmccDefaultFlagsOverrides = struct {
    optimize: std.builtin.OptimizeMode,
    fsanitize: bool,
};

pub fn emccDefaultFlags(allocator: std.mem.Allocator, options: EmccDefaultFlagsOverrides) EmccFlags {
    var args = EmccFlags.init(allocator);
    switch (options.optimize) {
        .Debug => {
            args.put("-O0", {}) catch unreachable;
            args.put("-gsource-map", {}) catch unreachable;
            if (options.fsanitize)
                args.put("-fsanitize=undefined", {}) catch unreachable;
        },
        .ReleaseSafe => {
            args.put("-O3", {}) catch unreachable;
            if (options.fsanitize) {
                args.put("-fsanitize=undefined", {}) catch unreachable;
                args.put("-fsanitize-minimal-runtime", {}) catch unreachable;
            }
        },
        .ReleaseFast => {
            args.put("-O3", {}) catch unreachable;
        },
        .ReleaseSmall => {
            args.put("-Oz", {}) catch unreachable;
        },
    }
    return args;
}

pub const EmccSettings = std.StringHashMap([]const u8);

pub const EmsdkAllocator = enum {
    none,
    dlmalloc,
    emmalloc,
    @"emmalloc-debug",
    @"emmalloc-memvalidate",
    @"emmalloc-verbose",
    mimalloc,
};

pub const EmccDefaultSettingsOverrides = struct {
    optimize: std.builtin.OptimizeMode,
    emsdk_allocator: EmsdkAllocator = .emmalloc,
};

pub fn emccDefaultSettings(allocator: std.mem.Allocator, options: EmccDefaultSettingsOverrides) EmccSettings {
    var settings = EmccSettings.init(allocator);
    switch (options.optimize) {
        .Debug, .ReleaseSafe => {
            settings.put("SAFE_HEAP", "1") catch unreachable;
            settings.put("STACK_OVERFLOW_CHECK", "1") catch unreachable;
            settings.put("ASSERTIONS", "1") catch unreachable;
        },
        else => {},
    }
    settings.put("MALLOC", @tagName(options.emsdk_allocator)) catch unreachable;
    return settings;
}

pub const ResourceFile = struct {
    src_path: std.Build.LazyPath,
    virtual_path: ?[]const u8 = null,
};

pub const StepOptions = struct {
    optimize: std.builtin.OptimizeMode,
    flags: EmccFlags,
    settings: EmccSettings,
    use_preload_plugins: bool = false,
    embed_paths: ?[]const ResourceFile = null,
    preload_paths: ?[]const ResourceFile = null,
    shell_file_path: ?std.Build.LazyPath = null,
    js_library_path: ?std.Build.LazyPath = null,
    out_file_name: []const u8,
    install_dir: std.Build.InstallDir,
};

pub fn emccStep(
    b: *std.Build,
    src_paths: []const std.Build.LazyPath,
    compile_steps: []const *std.Build.Step.Compile,
    options: StepOptions,
) *std.Build.Step {
    const emcc = std.Build.Step.Run.create(b, "emcc");
    emcc.addFileArg(emccPath(b));

    var iterFlags = options.flags.iterator();
    while (iterFlags.next()) |kvp| {
        emcc.addArg(kvp.key_ptr.*);
    }

    var iterSettings = options.settings.iterator();
    while (iterSettings.next()) |kvp| {
        emcc.addArg(std.fmt.allocPrint(
            b.allocator,
            "-s{s}={s}",
            .{ kvp.key_ptr.*, kvp.value_ptr.* },
        ) catch unreachable);
    }

    for (src_paths) |src_path| {
        emcc.addFileArg(src_path);
    }

    for (compile_steps) |compile_step| {
        emcc.addArtifactArg(compile_step);
        for (compile_step.root_module.getGraph().modules) |module| {
            for (module.link_objects.items) |link_object| {
                switch (link_object) {
                    .other_step => |linked_compile_step| {
                        switch (linked_compile_step.kind) {
                            .lib => {
                                emcc.addArtifactArg(linked_compile_step);
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            }
        }
    }

    emcc.addArg("-o");
    const out_file = emcc.addOutputFileArg(options.out_file_name);

    if (options.use_preload_plugins) {
        emcc.addArg("--use-preload-plugins");
    }

    if (options.embed_paths) |embed_paths| {
        for (embed_paths) |path| {
            emcc.addArg("--embed-file");
            addResourceFileArg(b, emcc, path);
        }
    }

    if (options.preload_paths) |preload_paths| {
        for (preload_paths) |path| {
            emcc.addArg("--preload-file");
            addResourceFileArg(b, emcc, path);
        }
    }

    if (options.shell_file_path) |shell_file_path| {
        emcc.addArg("--shell-file");
        emcc.addFileArg(shell_file_path);
    }

    if (options.js_library_path) |js_library_path| {
        emcc.addArg("--js-library");
        emcc.addFileArg(js_library_path);
    }

    const install_step = b.addInstallDirectory(.{
        .source_dir = out_file.dirname(),
        .install_dir = options.install_dir,
        .install_subdir = "",
    });
    install_step.step.dependOn(&emcc.step);

    return &install_step.step;
}

/// Passes `resource.src_path` as a command line argument, appending
/// `@<virtual_path>` when the resource names one (emcc's syntax for embedding
/// or preloading a file at a path inside the virtual file system).
fn addResourceFileArg(b: *std.Build, run: *std.Build.Step.Run, resource: ResourceFile) void {
    if (resource.virtual_path) |virtual_path| {
        run.addFileArg2(resource.src_path, .{ .suffix = b.fmt("@{s}", .{virtual_path}) });
    } else {
        run.addFileArg(resource.src_path);
    }
}

pub fn emrunStep(
    b: *std.Build,
    html_path: std.Build.LazyPath,
    extra_args: []const []const u8,
) *std.Build.Step {
    const emrun = std.Build.Step.Run.create(b, "emrun");
    emrun.addFileArg(emrunPath(b));
    emrun.addArgs(extra_args);
    emrun.addFileArg(html_path);
    // emrun.addArg("--");

    return &emrun.step;
}
