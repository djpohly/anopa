const std = @import("std");
const stdin = std.io.getStdIn().reader();

// From util.h
const names_cb = ?*const fn ([*c]const u8, ?*anyopaque) callconv(.C) void;

export fn process_names_from_stdin(
        process_name: names_cb, data: *anyopaque) c_int {
    while (true) {
        var buf: [1024]u8 = undefined;
        const used = stdin.readUntilDelimiterOrEof(&buf, '\n') catch return -1;
        process_name.?(used.?.ptr, data);
    }
}

pub fn unslash_slice(s: []u8) []u8 {
    if (s.len <= 1)
        return s;
    const last = s.len - 1;
    if (s[last] == '/')
        return s[0 .. last];
}

export fn unslash(s: [*:0]u8) void {
    var slice = std.mem.span(s);
    if (slice.len <= 1)
        return;
    const last = slice.len - 1;
    if (slice[last] == '/')
        slice[last] = 0;
}
