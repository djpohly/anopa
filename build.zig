const std = @import("std");

// Set this to true to link to libanopa statically
const link_to_static_libanopa = false;

// Version will be retrieved from the package/info file
const version = blk: {
    // Each line in this file is "key=value"
    const info = @embedFile("package/info");
    var lines = std.mem.split(u8, info, "\n");
    while (lines.next()) |line| {
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..eq_idx], "version")) {
            break :blk line[eq_idx + 1 ..];
        }
    }
    // Since this code runs at comptime, this line will not be processed if the
    // version is found.  I couldn't make this work when the block was written
    // as a separate function.
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

pub fn build(b: *std.Build) !void {
    // Use standard target/optimize options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Generate a config.h header to replace ./configure.  The only value
    // actually used in the C files is ANOPA_VERSION.
    const config = b.addConfigHeader(.{
        .include_path = "anopa/config.h",
    }, .{
        .ANOPA_VERSION = version,
    });

    // Build libanopa both shared and static
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
    libanopa_static.install();

    const libanopa = if (link_to_static_libanopa)
        libanopa_static
    else
        libanopa_shared;

    inline for (aa_ctools) |tool| {
        const exe = b.addExecutable(.{
            .name = tool,
            .target = target,
            .optimize = optimize,
            // No Zig source file for these
        });
        exe.addConfigHeader(config);
        exe.addIncludePath("src/include");
        exe.addCSourceFile("src/anopa/" ++ tool ++ ".c", &.{});

        // Various tools depend on these modules; anything the tool doesn't use
        // will be removed by either optimization or stripping.
        exe.addCSourceFile("src/anopa/util.c", &.{});
        exe.addCSourceFile("src/anopa/start-stop.c", &.{});

        // Needed libraries
        exe.linkSystemLibrary("s6");
        exe.linkSystemLibrary("skarnet");
        exe.linkLibrary(libanopa);
        exe.linkLibC();

        // Install these to the standard executable path
        exe.install();
    }

    inline for (aa_utils) |util| {
        const exe = b.addExecutable(.{
            .name = util,
            .target = target,
            .optimize = optimize,
            // No Zig source file for these
        });
        exe.addIncludePath("src/include");
        exe.addCSourceFile("src/utils/" ++ util ++ ".c", &.{});

        // Needed libraries
        exe.linkSystemLibrary("s6");
        exe.linkSystemLibrary("execline");
        exe.linkSystemLibrary("skarnet");
        exe.linkLibrary(libanopa);
        exe.linkLibC();

        // Install these to the standard executable path
        exe.install();
    }

    // Other files to include that don't need to be compiled
    inline for (aa_scripts) |script| {
        b.installBinFile("src/scripts/" ++ script, script);
    }
    inline for (aa_initscripts) |script| {
        b.installFile("src/scripts/" ++ script, "etc/anopa/" ++ script);
    }
}
