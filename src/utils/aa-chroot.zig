const std = @import("std");
const clap = @import("clap");
const linux = std.os.linux;
const stderr = std.io.getStdErr().writer();

const params = clap.parseParamsComptime(
    \\-D, --double-output    Enable double-output mode
    \\-h, --help             Show this help screen and exit
    \\-V, --version          Show version information and exit
    \\<NEWROOT>
    \\<COMMAND>
    \\[<ARG>...]
);

const parsers = .{
    .NEWROOT = clap.parsers.string,
    .COMMAND = clap.parsers.string,
    .ARG = clap.parsers.string,
};

fn usage() !void {
    try stderr.writeAll("Usage: aa-chroot [OPTION] NEWROOT COMMAND [ARG...]\n");
}

pub fn main() !void {
    const args = clap.parse(clap.Help, &params, &parsers, .{}) catch {
        try usage();
        return;
    };

    if (args.args.version != 0) {
        try stderr.writeAll("aa-chroot version 0.z.1\n");
        return;
    }

    if (args.args.help != 0) {
        try usage();
        try stderr.writeAll("\n");
        try clap.help(stderr, clap.Help, &params, .{
            .indent = 1,
            .description_indent = 10,
            .description_on_new_line = false,
            .spacing_between_parameters = 0,
        });
        return;
    }

    if (args.positionals.len < 2 or args.args.help != 0) {
        try stderr.writeAll("Usage: aa-chroot [-DhV] NEWROOT COMMAND [ARG...]\n");
        return;
    }

    {
        var newroot = try std.fs.cwd().openDir(args.positionals[0], .{});
        defer newroot.close();
        try newroot.setAsCwd();
    }

    const rc = linux.chroot(".");
    switch (linux.getErrno(rc)) {
        .SUCCESS => {},
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .IO => return error.InputOutput,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.PathNotFound,
        .NOMEM => return error.SystemResources,
        .NOTDIR => return error.NotDir,
        else => unreachable,
    }

    {
        var newroot = try std.fs.openDirAbsolute("/", .{});
        defer newroot.close();
        try newroot.setAsCwd();
    }

    return std.process.execv(std.heap.page_allocator, args.positionals[1..]);
}
