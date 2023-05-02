const std = @import("std");
const clap = @import("clap");
const util = @import("util.zig");
const stderr = std.io.getStdErr().writer();
const linux = std.os.linux;

const params = clap.parseParamsComptime(
    \\-v, --verbose          Show what was done
    \\-q, --quiet            No warnings for what's left
    \\-l, --lazy-umounts     Try lazy umount as last resort
    \\-a, --apis             Umount /run, /sys, /proc & /dev too
    \\-h, --help             Show this help screen and exit
    \\-V, --version          Show version information and exit
);

fn usage() !void {
    try stderr.writeAll("Usage: aa-terminate [OPTION...]\n");
}

pub fn main() !void {
    const args = clap.parse(clap.Help, &params, &clap.parsers.default, .{}) catch {
        try usage();
        return;
    };

    if (args.args.version != 0) {
        try stderr.writeAll("aa-terminate version 0.z.1\n");
        return;
    }

    if (args.args.help != 0) {
        try usage();
        try stderr.writeByte('\n');
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

    // Get list of swaps from /proc
    var swaps = try util.openslurpclose("/proc/swaps");

    // Discard the header line and parse the rest
    var lines = std.mem.tokenize(u8, swaps, "\n");
    _ = lines.next();
    while (lines.next()) |line| {
        // TODO: spaces and special characters are octal-escaped \ooo
        var swap = std.mem.sliceTo(line, ' ');
        try stderr.writeAll(swap);
        try stderr.writeByte('\n');
    }
}
