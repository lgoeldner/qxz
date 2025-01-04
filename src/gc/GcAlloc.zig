const std = @import("std");
const BumpAlloc = @import("BumpAlloc.zig");
const trace = @import("trace.zig");
const assert = std.debug.assert;
const Self = @This();
const NURSERY_SIZE = 5 * 1024;
const builtin = @import("builtin");

const ObjectSet = std.ArrayHashMap(usize, struct {}, struct {
    pub fn hash(_: *const @This(), key: usize) u32 {
        return @intCast(key);
    }

    pub fn eql(_: *const @This(), a: usize, b: usize, _: usize) bool {
        return a == b;
    }
}, false);

pub const Error = BumpAlloc.Error;
pub const Tracer = trace.Tracer;

threadlocal var thread_stack_base: usize = undefined;

active_nursery: BumpAlloc,
copyto_nursery: BumpAlloc,

headers: ObjectSet,

pub fn init(ally: std.mem.Allocator) !Self {
    const stack_start: *anyopaque = switch (builtin.os.tag) {
        .windows => std.os.windows.teb().NtTib.StackBase,
        else => brk: {
            const s = std.c.pthread_self();
            const c = struct {
                pub extern "c" fn pthread_attr_getstack(
                    attr: *std.c.pthread_attr_t,
                    stackaddr: **anyopaque,
                    stacksize: *usize,
                ) std.c.E;

                pub extern "c" fn pthread_getattr_np(
                    thread: std.c.pthread_t,
                    attr: *std.c.pthread_attr_t,
                ) std.c.E;
            };
            var attr: std.c.pthread_attr_t = undefined;
            var stackaddr: *anyopaque = undefined;
            var stacksize: usize = undefined;

            if (c.pthread_getattr_np(s, &attr) != .SUCCESS)
                return error.PthreadGetAttrFailed;

            if (c.pthread_attr_getstack(&attr, &stackaddr, &stacksize) != .SUCCESS)
                return error.PThreadGetStackFailed;

            std.debug.print("pthread_self={}, stackaddr={}, stacksize={}\n", .{ @intFromPtr(s), stackaddr, stacksize });
            break :brk @ptrFromInt(@intFromPtr(stackaddr) + stacksize);
        },
    };

    thread_stack_base = @intFromPtr(stack_start);
    std.debug.print("stack base at {x}\n", .{thread_stack_base});

    return Self{
        .active_nursery = try BumpAlloc.init(ally, NURSERY_SIZE),
        .headers = ObjectSet.init(ally),
    };
}

pub fn deinit(self: *Self) void {
    self.active_nursery.deinit();
    self.headers.deinit();
}

pub const ReflectData = struct {
    format: *const fn (self: *anyopaque, writer: std.io.AnyWriter) anyerror!void,
    trace: *const fn (self: *anyopaque, tracer: *trace.Tracer) Tracer.Error!void,
    typename: []const u8,
    size: u32,

    fn format(
        self: *@This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        try writer.print("ReflectData{ typename={s} }", self.typename);
    }
};

const ObjTy = enum(u1) {
    DynamicSize,
    StaticSize,
};

const ObjHeader = packed struct {
    // wether the object is dynamically sized
    size_class: ObjTy,
    gc_marker: trace.MarkState = .NotVisited,
    // how many generations the object has survived in the current region
    generation_count: u8 = 0,
    size: u32,
    reflect: *const ReflectData,
};

const _ = std.debug.assert(@alignOf(ObjHeader) == @alignOf(usize) and @sizeOf(ObjHeader) == 2 * @sizeOf(usize));

fn getReflectData(comptime T: type) *const ReflectData {
    const Data = struct {
        fn do_format(opaqueself: *anyopaque, writer: std.io.AnyWriter) anyerror!void {
            const self = @as(*T, @ptrCast(@alignCast(opaqueself)));
            return writer.print("{}", .{self});
        }

        fn do_trace(opaqueself: *anyopaque, tracer: *trace.Tracer) !void {
            const self: *T = @ptrCast(@alignCast(opaqueself));
            if (std.meta.hasMethod(T, "gcTrace")) {
                try self.gcTrace(tracer);
            } else {
                @compileError(@typeName(T) ++ " does not implement gcTrace!");
            }
        }

        var data = ReflectData{
            .format = do_format,
            .typename = @typeName(T),
            .trace = do_trace,
            .size = @sizeOf(T),
        };
    };

    return &Data.data;
}

pub fn newDynamic(self: *Self, header: anytype, data: []const u8) Error!*@TypeOf(header) {
    const H = @TypeOf(header);
    comptime std.debug.assert(@alignOf(H) <= @alignOf(ObjHeader));
    comptime if (@alignOf(H) != @alignOf(usize) or (@sizeOf(H) % @sizeOf(usize)) != 0) {
        @compileError(
            \\The Header type 
        ++ @typeName(H) ++
            \\must be aligned to the machine word,
            \\and must have a size that's a multiple of the machine word!
        );
    };

    const size = @sizeOf(ObjHeader) + @sizeOf(H) + data.len;
    const ptr = try self.active_nursery.bump(size);
    const headerptr = @as([*]ObjHeader, @ptrCast(@alignCast(ptr)));
    const reflect_data = getReflectData(H);
    headerptr[0] = ObjHeader{
        .size_class = ObjTy.DynamicSize,
        .size = @intCast(@sizeOf(H) + data.len),
        .reflect = reflect_data,
    };

    const objheaderptr: *H = @ptrCast(&headerptr[1]);
    objheaderptr.* = header;
    const dataptr = @as([*]u8, @ptrCast(@as([*]H, @ptrCast(objheaderptr)) + 1))[0..data.len];
    @memcpy(dataptr, data);

    if (!self.headers.contains(@intFromPtr(reflect_data))) {
        try self.headers.putNoClobber(@intFromPtr(reflect_data), .{});
    }

    return objheaderptr;
}

pub fn new(self: *Self, obj: anytype) !*@TypeOf(obj) {
    const T = @TypeOf(obj);
    const ptr = try self.newRaw(T);
    ptr.* = obj;
    return ptr;
}

pub fn newRaw(self: *Self, comptime T: type) !*T {
    comptime std.debug.assert(@alignOf(T) <= @alignOf(ObjHeader));
    const size = @sizeOf(ObjHeader) + @sizeOf(T);
    const ptr = try self.active_nursery.bump(size);
    const headerptr = @as([*]ObjHeader, @ptrCast(@alignCast(ptr)));

    const reflect_data = getReflectData(T);
    headerptr[0] = ObjHeader{
        .size_class = ObjTy.StaticSize,
        .size = @sizeOf(T),
        .reflect = reflect_data,
    };

    const objptr = &headerptr[1];

    if (!self.headers.contains(@intFromPtr(reflect_data))) {
        try self.headers.putNoClobber(@intFromPtr(reflect_data), .{});
    }

    std.debug.print("allocated @ {} {s}\n", .{ @as(*anyopaque, headerptr + 1), headerptr[0].reflect.typename });
    return @ptrCast(objptr);
}

pub fn isGcPtr(self: *Self, ptr: *anyopaque) bool {
    return std.mem.isAligned(@intFromPtr(ptr), @alignOf(usize)) //
    and self.active_nursery.contains_ptr(ptr) //
    and brk: {
        const header = @as([*]const ObjHeader, @ptrCast(@alignCast(ptr))) - 1;
        const reflectptr = header[0].reflect;
        break :brk self.headers.contains(@intFromPtr(reflectptr));
    };
}

pub const AnyReflect = struct {
    obj: *anyopaque,
    typename: []const u8,
    fmtptr: *const fn (self: *anyopaque, writer: std.io.AnyWriter) anyerror!void,

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        try writer.print("GcPtr@{x}='", .{@intFromPtr(self.obj)});
        try self.fmtptr(self.obj, writer);
        try writer.print("'", .{});
    }
};

pub fn getObjHeader(self: *Self, anyptr: *anyopaque) *const ObjHeader {
    assert(self.isGcPtr(anyptr));

    const header = @as([*]const ObjHeader, @ptrCast(@alignCast(anyptr))) - 1;
    return @ptrCast(header);
}

pub fn reflect(self: *Self, anyptr: *anyopaque) AnyReflect {
    const reflectdata = self.getObjHeader(anyptr).reflect;

    return AnyReflect{
        .obj = anyptr,
        .typename = reflectdata.typename,
        .fmtptr = reflectdata.format,
    };
}

inline fn initStackTop() void {
    if (thread_stack_base == null)
        thread_stack_base = get_rsp();
}

inline fn get_rsp() usize {
    return asm volatile (""
        : [ret] "={rsp}" (-> usize),
    );
}

inline fn castSlice(T: type, slice: []u8) []T {
    std.debug.assert(std.mem.isAligned(@intFromPtr(slice.ptr), @alignOf(T)));
    const new_len = slice.len / @sizeOf(T);
    return @as([*]T, @alignCast(@ptrCast(slice.ptr)))[0..new_len];
}

fn traceRoots(tracer: *trace.Tracer) !void {
    const stack_bottom = get_rsp();

    const stack_size = thread_stack_base - stack_bottom;

    const stack_slice = castSlice(*anyopaque, @as([*]u8, @ptrFromInt(stack_bottom))[0..stack_size]);
    try tracer.traceRootRegion(stack_slice);
}

pub fn fullCollect(self: *Self) !void {
    var tracer = Tracer.init(self.active_nursery.alloc, self);
    defer tracer.deinit();

    // trace roots
    // first, the stack can contain root pointers
    try traceRoots(&tracer);
    std.debug.print("entering dfs!\n", .{});

    try tracer.doDfs();
}
