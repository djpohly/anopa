const std = @import("std");
const clap = @import("clap");
const stderr = std.io.getStdErr().writer();
const linux = std.os.linux;

const params = clap.parseParamsComptime(
    \\-h, --help             Show this help screen and exit
    \\-V, --version          Show version information and exit
);

pub fn main() !void {
    const args = clap.parse(clap.Help, &params, &clap.parsers.default, .{}) catch {
        try stderr.writeAll("Usage: aa-sync [OPTION]\n");
        return;
    };

    if (args.args.version != 0) {
        try stderr.writeAll("aa-sync version 0.z.1\n");
        return;
    }

    if (args.positionals.len != 0 or args.args.help != 0) {
        try stderr.writeAll("Usage: aa-sync [OPTION]\n");
        return;
    }

    linux.sync();
}
