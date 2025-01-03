/// Holds pointers to reachable GC Objects to be traced.
/// Used for traversing the object tree.
pub const Tracer = struct {
    pub const Error = error{OutOfMemory};

    const Self = @This();

    pub fn init() Self {}

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn addPtr(self: *Tracer, source: **anyopaque, gc_ptr: *anyopaque) Error!void {
        _ = source;
        _ = gc_ptr;
        _ = self;
    }
};

pub const MarkState = enum(u2) {
    NotVisited,
    Dead,
    Marked,
};
