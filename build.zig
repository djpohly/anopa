const std = @import("std");

const version = blk: {
    const info = @embedFile("package/info");
    var lines = std.mem.split(u8, info, "\n");
    while (lines.next()) |line| {
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..eq_idx], "version")) {
            break :blk line[eq_idx + 1 ..];
        }
    }
    @compileError("Could not find version in package/info file");
};

const libanopa_files = .{
    "src/libanopa/copy_file.c",
    "src/libanopa/die_usage.c",
    "src/libanopa/die_version.c",
    "src/libanopa/enable_service.c",
    "src/libanopa/errmsg.c",
    "src/libanopa/eventmsg.c",
    "src/libanopa/exec_longrun.c",
    "src/libanopa/exec_oneshot.c",
    "src/libanopa/ga_list.c",
    "src/libanopa/init_repo.c",
    "src/libanopa/output.c",
    "src/libanopa/progress.c",
    "src/libanopa/sa_sources.c",
    "src/libanopa/service.c",
    "src/libanopa/service_name.c",
    "src/libanopa/service_start.c",
    "src/libanopa/service_stop.c",
    "src/libanopa/services.c",
    "src/libanopa/service_status.c",
    "src/libanopa/scan_dir.c",
    "src/libanopa/stats.c",
};

const aa_ctools = .{
    "aa-enable",
    "aa-reset",
    "aa-start",
    "aa-status",
    "aa-stop",
};

const aa_utils = .{
    "aa-chroot",
    "aa-ctty",
    "aa-echo",
    "aa-incmdline",
    "aa-kill",
    "aa-mount",
    "aa-pivot",
    "aa-reboot",
    "aa-service",
    "aa-setready",
    "aa-sync",
    "aa-terminate",
    "aa-test",
    "aa-tty",
    "aa-umount",
};

const aa_scripts = .{
    "aa-command",
    "aa-shutdown",
};

const aa_initscripts = .{
    "aa-stage0",
    "aa-stage1",
    "aa-stage2",
    "aa-stage3",
    "aa-stage4",
};

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const config = b.addConfigHeader(.{
        .include_path = "anopa/config.h",
    }, .{
        .ANOPA_VERSION = version,
    });

    const libanopa_shared = b.addSharedLibrary(.{
        .name = "anopa",
        .version = try std.builtin.Version.parse(version),
        .target = target,
        .optimize = optimize,
    });
    libanopa_shared.addConfigHeader(config);
    libanopa_shared.addIncludePath("src/include");
    libanopa_shared.addCSourceFiles(&libanopa_files, &.{});
    libanopa_shared.linkLibC();
    libanopa_shared.strip = true;
    libanopa_shared.install();

    const libanopa_static = b.addStaticLibrary(.{
        .name = "anopa",
        .version = try std.builtin.Version.parse(version),
        .target = target,
        .optimize = optimize,
    });
    libanopa_static.addConfigHeader(config);
    libanopa_static.addIncludePath("src/include");
    libanopa_static.addCSourceFiles(&libanopa_files, &.{});
    libanopa_static.linkLibC();
    libanopa_static.strip = true;
    libanopa_static.install();

    inline for (aa_ctools) |tool| {
        const exe = b.addExecutable(.{
            .name = tool,
            // In this case the main source file is merely a path, however, in more
            // complicated build scripts, this could be a generated file.
            .target = target,
            .optimize = optimize,
        });
        exe.addConfigHeader(config);
        exe.addIncludePath("src/include");
        exe.addCSourceFile("src/anopa/" ++ tool ++ ".c", &.{});
        exe.addCSourceFile("src/anopa/util.c", &.{});
        exe.addCSourceFile("src/anopa/start-stop.c", &.{});
        exe.linkSystemLibrary("s6");
        exe.linkSystemLibrary("skarnet");
        exe.linkLibrary(libanopa_static);
        exe.linkLibC();
        exe.strip = true;

        // This declares intent for the executable to be installed into the
        // standard location when the user invokes the "install" step (the default
        // step when running `zig build`).
        exe.install();
    }

    inline for (aa_utils) |util| {
        const exe = b.addExecutable(.{
            .name = util,
            // In this case the main source file is merely a path, however, in more
            // complicated build scripts, this could be a generated file.
            .target = target,
            .optimize = optimize,
        });
        exe.addIncludePath("src/include");
        exe.addCSourceFile("src/utils/" ++ util ++ ".c", &.{});
        exe.linkSystemLibrary("s6");
        exe.linkSystemLibrary("execline");
        exe.linkSystemLibrary("skarnet");
        exe.linkLibrary(libanopa_static);
        exe.linkLibC();
        exe.strip = true;

        // This declares intent for the executable to be installed into the
        // standard location when the user invokes the "install" step (the default
        // step when running `zig build`).
        exe.install();
    }

    inline for (aa_scripts) |script| {
        b.installBinFile("src/scripts/" ++ script, script);
    }

    inline for (aa_initscripts) |script| {
        b.installFile("src/scripts/" ++ script, "etc/anopa/" ++ script);
    }

    // Creates a step for unit testing.
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
