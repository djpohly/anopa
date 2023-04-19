const std = @import("std");
const clap = @import("clap");
const stdout = std.io.getStdOut().writer();
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

    var file: []const u8 = undefined;
    var file_buf: [256]u8 = undefined;
    {
        const fd = try std.fs.openFileAbsolute("/sys/class/tty/console/active", .{});
        defer fd.close();

        const b = try fd.readAll(&file_buf);
        file = std.mem.trimRight(u8, file_buf[0..b], "\r\n");
    }
    while (true) {
        var fname_buf: [256]u8 = undefined;
        const fname = try std.fmt.bufPrint(&fname_buf, "/sys/class/tty/{s}/active", .{file});

        const fd = std.fs.openFileAbsolute(fname, .{}) catch |err| switch (err) {
            error.FileNotFound => break,
            else => return err,
        };
        defer fd.close();

        const b = try fd.readAll(&file_buf);
        file = std.mem.trimRight(u8, file_buf[0..b], "\r\n");
    }

    try stdout.writeAll("/dev/");
    try stdout.writeAll(file);
    try stdout.writeAll("\n");
}
