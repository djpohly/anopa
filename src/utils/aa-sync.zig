const std = @import("std");
const clap = @import("clap");
const stderr = std.io.getStdErr().writer();
const linux = std.os.linux;

const params = clap.parseParamsComptime(
    \\-h, --help             Show this help screen and exit
    \\-V, --version          Show version information and exit
);

fn usage() !void {
    try stderr.writeAll("Usage: aa-sync [OPTION]\n");
}

pub fn main() !void {
    const args = clap.parse(clap.Help, &params, &clap.parsers.default, .{}) catch {
        try usage();
        return;
    };

    if (args.args.version != 0) {
        try stderr.writeAll("aa-sync version 0.z.1\n");
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

    if (args.positionals.len != 0) {
        try usage();
        return;
    }

    linux.sync();
}
