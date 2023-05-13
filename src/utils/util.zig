const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn openslurpclose(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    return file.readToEndAlloc(alloc, std.mem.page_size);
}
