const std = @import("std");
const Gc = @import("GcAlloc.zig");

/// Holds pointers to reachable GC Objects to be traced.
/// Used for traversing the object tree.
pub const Tracer = struct {
    pub const Error = error{OutOfMemory};
    const Self = @This();
    const PairPtr = struct { src: **anyopaque, dest: *anyopaque };

    ally: std.mem.Allocator,
    gc: *Gc,
    unvisited_ptrs: std.ArrayList(PairPtr),

    pub fn init(alloc: std.mem.Allocator, gc: *Gc) Self {
        return Self{
            .ally = alloc,
            .gc = gc,
            .unvisited_ptrs = std.ArrayList(PairPtr).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.unvisited_ptrs.deinit();
    }

    pub fn addPtr(self: *Tracer, source: **anyopaque, gc_ptr: *anyopaque) Error!void {
        std.debug.assert(self.gc.isGcPtr(gc_ptr));

        try self.unvisited_ptrs.append(.{ .src = source, .dest = gc_ptr });
    }

    pub fn traceRootRegion(self: *Self, region: []*anyopaque) !void {
        std.debug.print("tracing {} potential pointers\n", .{region.len});

        for (region) |*ptr| {
            if (self.gc.isGcPtr(ptr.*)) {
                try self.addPtr(ptr, ptr.*);
            }
        }
    }

    /// Traverses the object Tree after all Roots are added to the tracer
    pub fn doDfs(self: *Self) !void {
        while (self.unvisited_ptrs.popOrNull()) |pair| {
            const ptr = pair.dest;

            var header = self.gc.getObjHeader(ptr);

            if (header.gc_marker == .NotVisited) {
                header.generation_count += 1;

                std.debug.print("moving a {s} of size: {} ", .{ header.reflect.typename, header.size });

                // copy the object and replace it with a broken heart
                // pointing at the new object in the copyto nursery.

                const new_obj: *anyopaque = try self.gc.copyObjToToSpace(ptr);

                // mark the old object as a broken heart
                header.gc_marker = .BrokenHeart;
                // add the redirection pointer to the new object
                @as(**anyopaque, @alignCast(@ptrCast(self.gc.getObjPtr(header)))).* = new_obj;

                // now, trace the potential pointers in the new object
                const new_header = self.gc.getObjHeader(new_obj);
                try new_header.reflect.trace(new_obj, self);
            }

            // update the pointer
            const new_obj_ptr: **anyopaque = @alignCast(@ptrCast(ptr));
            std.debug.print("moved {} to {}\n", .{ pair, new_obj_ptr.* });

            std.debug.assert(self.gc.isGcPtr(new_obj_ptr.*));
            pair.src.* = new_obj_ptr.*;
        }
    }
};

pub const MarkState = enum(u2) {
    NotVisited,
    BrokenHeart,
};
