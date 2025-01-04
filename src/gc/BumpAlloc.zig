const std = @import("std");
const math = std.math;
const Self = @This();
pub const Error = std.mem.Allocator.Error || error{Overflow};

buf: []align(ALIGN) u8,
/// Teg bottom of the heap of allocated values
ptr: *align(ALIGN) u8,
obj_count: u64 = 0,
alloc: std.mem.Allocator,

pub inline fn init(alloc: std.mem.Allocator, size: usize) Error!Self {
    const start = try alloc.alignedAlloc(u8, @alignOf(usize), size);

    const top = @as(*u8, @ptrCast(start.ptr + start.len));

    return Self{
        .buf = start,
        .ptr = @alignCast(top),
        .alloc = alloc,
    };
}

pub fn heapSize(self: *Self) usize {
    return @intFromPtr(self.ptr) - @intFromPtr(self.buf);
}

pub fn deinit(self: *Self) void {
    self.alloc.free(self.buf);
}

const ALIGN = @alignOf(usize);

pub inline fn bump(self: *Self, size: usize) error{OutOfMemory}![]align(ALIGN) u8 {
    const new_unaligned = math.sub(usize, @intFromPtr(self.ptr), size) catch return error.OutOfMemory;

    const new_aligned = @as([*]u8, @ptrFromInt(std.mem.alignBackward(usize, new_unaligned, ALIGN)));
    const new_aligned_slice: []u8 = new_aligned[0..size];

    if (@as(usize, @intFromPtr(new_aligned_slice.ptr)) < @as(usize, @intFromPtr(self.buf.ptr))) return error.OutOfMemory;
    self.ptr = @alignCast(@ptrCast(new_aligned_slice.ptr));
    self.obj_count += 1;

    std.debug.print("bumped {}B at {x}\n", .{ size, @intFromPtr(new_aligned_slice.ptr) });
    return @alignCast(new_aligned_slice);
}

pub fn contains_ptr(self: *Self, ptr: *anyopaque) bool {
    const addr = @intFromPtr(ptr);
    const topint = @intFromPtr(self.buf.ptr + self.buf.len);
    const botint = @intFromPtr(self.ptr);

    return addr <= topint and addr >= botint;
}
