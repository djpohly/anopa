const std = @import("std");
const clap = @import("clap");
const stderr = std.io.getStdErr().writer();
const linux = std.os.linux;

const params = clap.parseParamsComptime(
    \\-f, --fd <FD>          Use FD as terminal (Default: 0)
    \\-s, --steal            Steal terminal from other session if needed
    \\-h, --help             Show this help screen and exit
    \\-V, --version          Show version information and exit
    \\<PROG>...
);

fn usage() !void {
    try stderr.writeAll("Usage: aa-ctty [OPTION...] PROG...\n");
}

pub fn main() !void {
    const args = clap.parse(clap.Help, &params, &.{
        .FD = clap.parsers.int(u31, 10),
        .PROG = clap.parsers.string,
    }, .{}) catch {
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

    const fd = args.args.fd orelse 0;
    const steal = args.args.steal != 0;

    if (args.positionals.len < 1) {
        try usage();
        return;
    }

    const TIOCSCTTY = 0x540E;
    const rc = linux.ioctl(fd, TIOCSCTTY, if (steal) 1 else 0);
    switch (linux.getErrno(rc)) {
        .SUCCESS => {},
        .BADF => try stderr.writeAll("aa-ctty: warning: unable to set controlling terminal: Bad file descriptor\n"),
        .PERM => try stderr.writeAll("aa-ctty: warning: unable to set controlling terminal: Operation not permitted\n"),
        else => unreachable,
    }

    return std.process.execv(std.heap.page_allocator, args.positionals);
}
