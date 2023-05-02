const std = @import("std");
const clap = @import("clap");
const stderr = std.io.getStdErr().writer();
const linux = std.os.linux;

const params = clap.parseParamsComptime(
    \\-f, --force            Force unmount even if busy (NFS only)
    \\-l, --lazy             Perform lazy unmounting
    \\-h, --help             Show this help screen and exit
    \\-V, --version          Show version information and exit
    \\<MOUNTPOINT>
);

fn usage() !void {
    try stderr.writeAll("Usage: aa-umount [OPTIONS...] MOUNTPOINT\n");
}

pub fn main() !void {
    const args = clap.parse(clap.Help, &params, &.{
        .MOUNTPOINT = clap.parsers.string,
    }, .{}) catch {
        try usage();
        return;
    };

    if (args.args.version != 0) {
        try stderr.writeAll("aa-umount version 0.z.1\n");
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

    if (args.positionals.len != 1) {
        try usage();
        return;
    }

    const flags: u32 = if (args.args.lazy != 0)
        linux.MNT.DETACH
    else if (args.args.force != 0)
        linux.MNT.FORCE
    else
        0;

    const rc = linux.umount2(@ptrCast([*:0]const u8, args.positionals[0].ptr), flags);
    switch (linux.getErrno(rc)) {
        .SUCCESS => {},
        .BUSY => return error.FileBusy,
        .INVAL => return error.InvalidArgument,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.DirNotFound,
        .NOMEM => return error.SystemResources,
        .PERM => return error.PermissionDenied,
        else => unreachable,
    }
}
