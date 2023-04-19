const std = @import("std");
const clap = @import("clap");
const linux = std.os.linux;
const stderr = std.io.getStdErr().writer();

const params = clap.parseParamsComptime(
    \\-D, --double-output    Enable double-output mode
    \\-h, --help             Show this help screen and exit
    \\-V, --version          Show version information and exit
    \\<NEWROOT>
    \\<OLDROOT>
);

const parsers = .{
    .NEWROOT = clap.parsers.string,
    .OLDROOT = clap.parsers.string,
};

pub fn main() !void {
    const args = try clap.parse(clap.Help, &params, &parsers, .{});

    if (args.args.version != 0) {
        try stderr.writeAll("aa-pivot version 0.z.1\n");
        return;
    }

    if (args.positionals.len != 2 or args.args.help != 0) {
        try stderr.writeAll("Usage: aa-pivot [-DhV] NEWROOT OLDROOT\n");
        return;
    }

    const rc = linux.syscall2(linux.SYS.pivot_root,
            @ptrToInt(args.positionals[0].ptr),
            @ptrToInt(args.positionals[1].ptr));
    switch (linux.getErrno(rc)) {
        .SUCCESS => {},
        .INVAL => return error.InvalidArgument,
        .BUSY => return error.FileBusy,
        .NOTDIR => return error.NotDir,
        .PERM => return error.PermissionDenied,
        else => unreachable,
    }
}
