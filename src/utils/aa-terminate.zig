const std = @import("std");
const clap = @import("clap");
const util = @import("util.zig");
const stderr = std.io.getStdErr().writer();
const linux = std.os.linux;

const LOOP_GET_STATUS64 = 0x4C05;
const LO_NAME_SIZE = 64;
const LO_KEY_SIZE = 32;
const LoopInfo64 = extern struct {
    device: u64,
    inode: u64,
    rdevice: u64,
    offset: u64,
    sizelimit: u64,
    number: u32,
    encrypt_type: u32,
    encrypt_key_size: u32,
    flags: u32,
    file_name: [LO_NAME_SIZE]u8,
    crypt_name: [LO_NAME_SIZE]u8,
    encrypt_key: [LO_KEY_SIZE]u8,
    init: [2]u64,
};

const params = clap.parseParamsComptime(
    \\-v, --verbose          Show what was done
    \\-q, --quiet            No warnings for what's left
    \\-l, --lazy-umounts     Try lazy umount as last resort
    \\-a, --apis             Umount /run, /sys, /proc & /dev too
    \\-h, --help             Show this help screen and exit
    \\-V, --version          Show version information and exit
);

const alloc = std.heap.page_allocator;

fn usage() !void {
    try stderr.writeAll("Usage: aa-terminate [OPTION...]\n");
}

fn do_swapoff(path: []const u8) !void {
    try stderr.writeAll("swapoff ");
    try stderr.writeAll(path);
    try stderr.writeByte('\n');
}

fn do_umount(path: []const u8) !void {
    try stderr.writeAll("umount ");
    try stderr.writeAll(path);
    try stderr.writeByte('\n');
}

fn do_loop_close(path: []const u8) !void {
    try stderr.writeAll("loop_close ");
    try stderr.writeAll(path);
    try stderr.writeByte('\n');
}

fn do_dm_close(path: []const u8) !void {
    try stderr.writeAll("dm_close ");
    try stderr.writeAll(path);
    try stderr.writeByte('\n');
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

    var did_something = true;
    var unmounted_all = true;
    while (did_something) {
        did_something = false;

        var line_buf: [std.mem.page_size]u8 = undefined;
        {
            // Get list of swaps from /proc
            var swaps_file = try std.fs.openFileAbsolute("/proc/swaps", .{});
            defer swaps_file.close();

            const reader = swaps_file.reader();

            // Skip header line
            try reader.skipUntilDelimiterOrEof('\n');

            while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
                // TODO: spaces and special characters are octal-escaped \ooo
                var swap_name = std.mem.sliceTo(line, ' ');
                if (do_swapoff(swap_name)) {
                    did_something = true;
                } else |_| {}
            }
        }

        {
            // Get list of mounts from /proc
            var mounts_file = try std.fs.openFileAbsolute("/proc/mounts", .{});
            defer mounts_file.close();

            const reader = mounts_file.reader();

            // Skip header line
            try reader.skipUntilDelimiterOrEof('\n');

            while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
                // TODO: spaces and special characters are octal-escaped \ooo
                var fields = std.mem.tokenize(u8, line, " \t");

                // Skip the device name and get the mountpoint; if the line ends
                // early, skip the line rather than crashing.
                _ = fields.next() orelse continue;
                const mount_name = fields.next() orelse continue;

                if (do_umount(mount_name)) {
                    did_something = true;
                } else |_| {
                    unmounted_all = false;
                }
            }
        }

        {
            // Scan for /dev/loop* and /dev/dm-* to close
            var dev_dir = try std.fs.openIterableDirAbsolute("/dev", .{
                .access_sub_paths = true,
            });
            defer dev_dir.close();

            var dev_files = dev_dir.iterateAssumeFirstIteration();
            fileLoop: while (try dev_files.next()) |dev| {
                if (dev.kind != .BlockDevice)
                    continue;
                if (std.mem.startsWith(u8, dev.name, "loop")) {
                    {
                        const loop_file = try dev_dir.dir.openFile(dev.name, .{});
                        defer loop_file.close();

                        var info: LoopInfo64 = undefined;
                        switch (linux.getErrno(linux.ioctl(loop_file.handle, LOOP_GET_STATUS64, @ptrToInt(&info)))) {
                            .SUCCESS => {},
                            else => continue :fileLoop,
                        }
                    }

                    if (do_loop_close(dev.name)) {
                        did_something = true;
                    } else |_| {}
                } else if (std.mem.startsWith(u8, dev.name, "dm-")) {
                    if (do_dm_close(dev.name)) {
                        did_something = true;
                    } else |_| {}
                }
            }
        }
    }
}
