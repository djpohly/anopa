const std = @import("std");

// Set this to true to link to libanopa statically
const link_to_static_libanopa = false;

// Version will be retrieved from the package/info file
const pkginfo = KeyValueFileStruct("package/info"){};

/// Parses a key-value file and returns a struct type containing a field for
/// each key and default values given by the file.
fn KeyValueFileStruct(comptime filename: []const u8) type {
    var keys: []const []const u8 = &[_][]const u8{};
    var values: []const []const u8 = &[_][]const u8{};

    // Read lines from the given file.  Each line is formatted "key=value".
    {
        const kvdata = @embedFile(filename);
        var lines = std.mem.split(u8, kvdata, "\n");

        // Build parallel arrays of keys and values
        while (lines.next()) |line| {
            // Ignore lines with no equals sign
            const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;

            keys = keys ++ .{ line[0..eq_idx] };
            values = values ++ .{ line[eq_idx + 1 ..] };
        }
    }

    // Construct the array of struct fields
    var fields: [keys.len]std.builtin.Type.StructField = undefined;
    for (&fields, keys, values) |*field, key, value| {
        field.* = std.builtin.Type.StructField{
            .name = key,
            .type = [:0]const u8,
            .default_value = value,
            .alignment = 0,
            .is_comptime = false,
        };
    }

    // Return a corresponding type
    return @Type(std.builtin.Type{
        .Struct = std.builtin.Type.Struct{
            .layout = .Auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

// Version will be retrieved from the package/info file
const version = pkginfo.version;

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

const aa_cutils = .{
    "aa-ctty",
    "aa-echo",
    "aa-incmdline",
    "aa-kill",
    "aa-mount",
    "aa-reboot",
    "aa-service",
    "aa-setready",
    "aa-terminate",
    "aa-test",
    "aa-tty",
    "aa-umount",
};

const aa_utils = .{
    "aa-chroot",
    "aa-pivot",
    "aa-sync",
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

const man_pages = .{ "anopa" } ++
    aa_ctools ++
    aa_cutils ++
    aa_utils ++
    aa_scripts;

pub fn build(b: *std.Build) !void {
    // Use standard target/optimize options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig dependencies
    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    }).module("clap");

    // Generate a config.h header to replace ./configure.  The only value
    // actually used in the C files is ANOPA_VERSION.
    const config = b.addConfigHeader(.{
        .include_path = "anopa/config.h",
    }, .{
        .ANOPA_VERSION = version,
    });

    // Build libanopa both shared and static
    const libanopa_shared = b.addSharedLibrary(.{
        .name = pkginfo.package,
        .version = try std.builtin.Version.parse(version),
        .target = target,
        .optimize = optimize,
    });
    libanopa_shared.addConfigHeader(config);
    libanopa_shared.addIncludePath("src/include");
    libanopa_shared.addCSourceFiles(&libanopa_files, &.{});
    libanopa_shared.linkSystemLibrary("skarnet");
    libanopa_shared.linkSystemLibrary("s6");
    libanopa_shared.linkLibC();
    b.installArtifact(libanopa_shared);

    const libanopa_static = b.addStaticLibrary(.{
        .name = pkginfo.package,
        .version = try std.builtin.Version.parse(version),
        .target = target,
        .optimize = optimize,
    });
    libanopa_static.addConfigHeader(config);
    libanopa_static.addIncludePath("src/include");
    libanopa_static.addCSourceFiles(&libanopa_files, &.{});
    libanopa_static.linkSystemLibrary("skarnet");
    libanopa_static.linkSystemLibrary("s6");
    libanopa_static.linkLibC();
    b.installArtifact(libanopa_static);

    const libanopa = if (link_to_static_libanopa)
        libanopa_static
    else
        libanopa_shared;

    const util_obj = b.addObject(std.build.ObjectOptions{
        .name = "util",
        .root_source_file = .{ .path = "src/anopa/util.zig" },
        .target = target,
        .optimize = optimize,
    });
    // For now...
    util_obj.addIncludePath("src/anopa");
    util_obj.linkLibC();

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
        exe.addObject(util_obj);
        exe.addCSourceFile("src/anopa/start-stop.c", &.{});

        // Needed libraries
        exe.linkSystemLibrary("s6");
        exe.linkSystemLibrary("skarnet");
        exe.linkLibrary(libanopa);
        exe.linkLibC();

        // Install these to the standard executable path
        b.installArtifact(exe);
    }

    inline for (aa_cutils) |util| {
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
        b.installArtifact(exe);
    }

    inline for (aa_utils) |util| {
        const exe = b.addExecutable(.{
            .name = util,
            .target = target,
            .optimize = optimize,
            .root_source_file = .{ .path = "src/utils/" ++ util ++ ".zig" },
        });

        // Needed libraries
        exe.addModule("clap", clap);

        // Install these to the standard executable path
        b.installArtifact(exe);
    }

    // Other files to include that don't need to be compiled
    inline for (aa_scripts) |script| {
        b.installBinFile("src/scripts/" ++ script, script);
    }
    inline for (aa_initscripts) |script| {
        b.installLibFile("src/scripts/" ++ script, "anopa/" ++ script);
    }

    // Man pages
    inline for (man_pages) |page| {
        const doc = b.addSystemCommand(&.{
            "/bin/sh", "-c",
            "cat \"$1\" doc/footer.pod | pod2man --name=\"$2\" --center=\"$3\" --section=1 --release=\"$4\" > \"$5\"",
            "sh",
        });
        doc.addFileSourceArg(std.Build.FileSource{
            .path = "doc/" ++ page ++ ".pod"
        });
        doc.addArg(page);
        doc.addArg(pkginfo.package);
        doc.addArg(pkginfo.version);
        const outfile = doc.addOutputFileArg("doc/" ++ page ++ ".1");
        const man = b.addInstallFile(outfile, "man/" ++ page ++ ".1");
        b.getInstallStep().dependOn(&man.step);
    }
}
