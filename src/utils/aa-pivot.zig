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

fn usage() !void {
    try stderr.writeAll("Usage: aa-pivot [OPTION] NEWROOT OLDROOT\n");
}

pub fn main() !void {
    const args = try clap.parse(clap.Help, &params, &parsers, .{});

    if (args.args.version != 0) {
        try stderr.writeAll("aa-pivot version 0.z.1\n");
        return;
    }

    if (args.args.help != 0) {
        try usage();
        try stderr.writeAll("\n");
        const opts = clap.HelpOptions{
            .indent = 1,
            .description_indent = 10,
            .description_on_new_line = false,
            .spacing_between_parameters = 0,
        };
        try clap.help(stderr, clap.Help, &params, opts);
        return;
    }

    if (args.positionals.len != 2 or args.args.help != 0) {
        try usage();
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
