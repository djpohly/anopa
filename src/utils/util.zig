const std = @import("std");

pub fn openslurpclose(path: []const u8) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    return file.readToEndAlloc(std.heap.page_allocator, std.mem.page_size);
}
