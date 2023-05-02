const std = @import("std");
const clap = @import("clap");
const util = @import("util.zig");
const linux = std.os.linux;
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

const KVPair = struct {
    key: []const u8,
    value: ?[]const u8 = null,
};

const CmdlineIterator = struct {
    const separators = " \t\n\x00";

    data: []const u8,

    pub fn init(str: []const u8) CmdlineIterator {
        return .{ .data = str };
    }

    pub fn next(self: *CmdlineIterator) ?KVPair {
        // Skip over separator charactors
        self.data = std.mem.trimLeft(u8, self.data, separators);

        // No options left
        if (self.data.len == 0)
            return null;

        // Parse key
        const key_end = std.mem.indexOfAny(u8, self.data, separators ++ "=") orelse self.data.len;
        const key = self.data[0..key_end];
        if (key_end == self.data.len or self.data[key_end] != '=') {
            // No value was provided - key only
            self.data = self.data[key_end..];
            return .{ .key = key };
        }

        // Parse value
        const value = self.data[key_end + 1 ..];
        if (value.len == 0 or value[0] != '"') {
            // Unquoted value
            const value_end = std.mem.indexOfAny(u8, value, separators) orelse value.len;
            self.data = value[value_end..];
            return .{ .key = key, .value = value[0..value_end] };
        }

        // Quoted value
        const quote_or_end = std.mem.indexOfScalarPos(u8, value, 1, '"');
        if (quote_or_end) |quote| {
            // Properly terminated
            self.data = value[quote + 1 ..];
            return .{ .key = key, .value = value[1..quote] };
        } else {
            // Unterminated
            self.data = value[value.len..];
            return .{ .key = key, .value = value[1..] };
        }
    }
};

// NOTE incompatibility: -s requires a parameter
const params = clap.parseParamsComptime(
    \\-f, --file <FILE>      Use FD as terminal (Default: 0)
    \\-q, --quiet            Don't write value (if any) to stdout
    \\-s, --safe <C>         Ignore argument if value contain C (default: '/')
    \\-r, --required         Ignore argument if no value specified
    \\-h, --help             Show this help screen and exit
    \\-V, --version          Show version information and exit
    \\<NAME>
);

fn parseChar(arg: []const u8) !u8 {
    if (arg.len != 1)
        return error.NotSingleChar;
    return arg[0];
}

const parsers = .{
    .FILE = clap.parsers.string,
    .NAME = clap.parsers.string,
    .C = parseChar,
};

fn usage() !void {
    try stderr.writeAll("Usage: aa-incmdline [OPTION...] PROG...\n");
}

pub fn main() !u8 {
    const args = clap.parse(clap.Help, &params, &parsers, .{}) catch {
        try usage();
        return 1;
    };

    if (args.args.version != 0) {
        try stderr.writeAll("aa-incmdline version 0.z.1\n");
        return 0;
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
        return 0;
    }

    if (args.positionals.len != 1 or args.args.help != 0) {
        try usage();
        return 1;
    }

    const key = args.positionals[0];
    const rawdata = util.openslurpclose(args.args.file orelse "/proc/cmdline") catch return 2;
    const data = std.mem.trimRight(u8, rawdata, "\r\n");

    var it = CmdlineIterator.init(data);
    while (it.next()) |item| {
        if (!std.mem.eql(u8, key, item.key))
            continue;
        if (item.value) |value| {
            // Return 3 if safe char is specified and appears in value
            if (args.args.safe) |safe|
                if (std.mem.indexOfScalar(u8, value, safe) != null)
                    return 3;

            if (args.args.quiet == 0) {
                try stdout.writeAll(value);
                try stdout.writeByte('\n');
            }
        } else if (args.args.required != 0) {
            // Value required, but none was given
            return 3;
        }
        return 0;
    }

    return 3;
}
