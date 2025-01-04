const std = @import("std");
const GcAlloc = @import("gc/GcAlloc.zig");
const lib = @import("root.zig");

pub fn main() !void {
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = alloc.deinit();

    var gc = try GcAlloc.init(alloc.allocator());
    defer gc.deinit();

    const sym: []const u8 = "print";
    const str = lib.Str{ .len = sym.len };

    const hello: []const u8 = "hello";
    const hstr = lib.Str{ .len = hello.len };
    const next = lib.Expr{ .Cons = try gc.new(lib.Cons{
        .car = .{ .Str = try gc.newDynamic(hstr, hello) },
        .cdr = .{ .Cons = try gc.new(lib.Cons{
            .car = .{ .Int = 42 },
            .cdr = .Nil,
        }) },
    }) };

    _ = &next;

    const cons = try gc.new(lib.Cons{
        .car = .{ .Str = try gc.newDynamic(str, sym) },
        .cdr = next,
    });

    try gc.fullCollect();

    const r = gc.reflect(cons);
    std.debug.print("{}\n", .{r});
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
