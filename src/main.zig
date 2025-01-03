const std = @import("std");
const GcAlloc = @import("gc/GcAlloc.zig");
const lib = @import("root.zig");

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    var gc = try GcAlloc.init(alloc.allocator());
    defer gc.deinit();

    const sym: []const u8 = "print";
    const str = lib.Str{ .len = sym.len };

    const hello: []const u8 = "hello";
    const hstr = lib.Str{ .len = hello.len };

    var cons = try gc.new(lib.Cons{
        .car = .{ .Str = try gc.newDynamic(str, sym) },
        .cdr = .{ .Cons = try gc.new(lib.Cons{
            .car = .{ .Str = try gc.newDynamic(hstr, hello) },
            .cdr = .{ .Cons = try gc.new(lib.Cons{
                .car = .{ .Int = 42 },
                .cdr = .Nil,
            }) },
        }) },
    });

    std.debug.print("cons={}\n", .{gc.reflect(cons).?});
    _ = &cons;
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
