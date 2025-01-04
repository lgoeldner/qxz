const std = @import("std");
const Gc = @import("gc/GcAlloc.zig");

pub const Cons = struct {
    car: Expr,
    cdr: Expr,

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        options: ?std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;

        try writer.print("(", .{});

        var c = self;
        while (true) {
            switch (c.cdr) {
                .Nil => {
                    try writer.print("{})", .{c.car});
                    break;
                },
                .Cons => {
                    try writer.print("{} ", .{c.car});
                    c = c.cdr.Cons;
                },
                else => {
                    try writer.print("{} . {})", .{ c.car, c.cdr });
                    break;
                },
            }
        }
    }

    pub fn gcTrace(self: *@This(), tracer: *Gc.Tracer) !void {
        try self.car.gcTrace(tracer);
        try self.cdr.gcTrace(tracer);
    }
};

pub const Str = struct {
    len: u64,

    pub fn format(
        self: *@This(),
        comptime fmt: []const u8,
        options: ?std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;

        const after_header = @as([*]u8, @ptrCast(@as([*]Str, @ptrCast(self)) + 1))[0..self.len];

        try writer.print("{s}", .{after_header});
    }

    pub fn gcTrace(self: *@This(), tracer: *Gc.Tracer) !void {
        _ = self;
        _ = tracer;
    }
};

pub const Expr = union(enum) {
    Int: i64,
    Cons: *Cons,
    Str: *Str,
    Nil,

    pub fn format(
        self: Expr,
        comptime fmt: []const u8,
        options: ?std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;

        switch (self) {
            .Int => try writer.print("{}", .{self.Int}),
            .Cons => try self.Cons.format(fmt, null, writer),
            .Nil => try writer.print("nil", .{}),
            .Str => try self.Str.format(fmt, null, writer),
        }
    }

    pub fn gcTrace(self: *@This(), tracer: *Gc.Tracer) Gc.Tracer.Error!void {
        switch (self.*) {
            .Int, .Nil => {},
            .Cons => try tracer.addPtr(@constCast(&@as(*anyopaque, self.Cons)), self.Cons),
            .Str => try tracer.addPtr(@constCast(&@as(*anyopaque, self.Str)), self.Str),
        }
    }
};
