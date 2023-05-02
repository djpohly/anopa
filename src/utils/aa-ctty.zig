const std = @import("std");
const clap = @import("clap");
const linux = std.os.linux;
const stderr = std.io.getStdErr().writer();

const TIOC = struct {
    const SCTTY = 0x540E;
};

const params = clap.parseParamsComptime(
    \\-f, --fd <FD>          Use FD as terminal (Default: 0)\n"
    \\-s, --steal            Steal terminal from other session if needed\n"
    \\-h, --help             Show this help screen and exit
    \\-V, --version          Show version information and exit
    \\<PROG>...
);

const parsers = .{
    .FD = clap.parsers.int(std.os.fd_t, 10),
    .PROG = clap.parsers.string,
};

fn usage() !void {
    try stderr.writeAll("Usage: aa-ctty [OPTION...] PROG...\n");
}

pub fn main() !void {
    const args = clap.parse(clap.Help, &params, &parsers, .{}) catch {
        try usage();
        return;
    };

    if (args.args.version != 0) {
        try stderr.writeAll("aa-ctty version 0.z.1\n");
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

    if (args.positionals.len < 1 or args.args.help != 0) {
        try usage();
        return;
    }

    const rc = linux.ioctl(
            args.args.fd orelse 0,
            TIOC.SCTTY,
            if (args.args.steal != 0) 1 else 0,
    );
    switch (linux.getErrno(rc)) {
        .SUCCESS => {},
        .BADF => return error.InvalidFileDescriptor,
        .NOTTY => return error.NotATerminal,
        .PERM => return error.PermissionDenied,
        else => unreachable,
    }

    return std.process.execv(std.heap.page_allocator, args.positionals[1..]);
}
