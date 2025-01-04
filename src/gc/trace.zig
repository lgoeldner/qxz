const std = @import("std");
const Gc = @import("GcAlloc.zig");

/// Holds pointers to reachable GC Objects to be traced.
/// Used for traversing the object tree.
pub const Tracer = struct {
    pub const Error = error{OutOfMemory};
    const Self = @This();

    ally: std.mem.Allocator,
    gc: *Gc,
    unvisited_ptrs: std.ArrayList(*anyopaque),

    pub fn init(alloc: std.mem.Allocator, gc: *Gc) Self {
        return Self{
            .ally = alloc,
            .gc = gc,
            .unvisited_ptrs = std.ArrayList(*anyopaque).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.unvisited_ptrs.deinit();
    }

    pub fn addPtr(self: *Tracer, source: **anyopaque, gc_ptr: *anyopaque) Error!void {
        _ = source;

        std.debug.assert(self.gc.isGcPtr(gc_ptr));
        // const r = self.gc.reflect(gc_ptr);
        // std.debug.print("found GC pointer! {x} is {}\n", .{ gc_ptr, r });

        try self.unvisited_ptrs.append(gc_ptr);
    }

    pub fn traceRootRegion(self: *Self, region: []*anyopaque) Error!void {
        std.debug.print("tracing {} potential pointers\n", .{region.len});

        for (region) |*ptr| {
            if (self.gc.isGcPtr(ptr.*)) {
                try self.addPtr(ptr, ptr.*);
            }
        }
    }

    /// Traverses the object Tree after all Roots are added to the tracer
    pub fn doDfs(self: *Self) Error!void {
        while (self.unvisited_ptrs.popOrNull()) |ptr| {
            const header = self.gc.getObjHeader(ptr);
            try header.reflect.trace(ptr, self);
        }
    }
};

pub const MarkState = enum(u2) {
    NotVisited,
    Dead,
    Marked,
};
