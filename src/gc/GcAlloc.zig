const std = @import("std");
const BumpAlloc = @import("BumpAlloc.zig");
const trace = @import("trace.zig");
const assert = std.debug.assert;
const Self = @This();

pub const Error = BumpAlloc.Error;
pub const Tracer = trace.Tracer;

const NURSERY_SIZE = 5 * 1024;
nursery: BumpAlloc,

pub fn init(ally: std.mem.Allocator) Error!Self {
    return Self{
        .nursery = try BumpAlloc.init(ally, NURSERY_SIZE),
    };
}

pub fn deinit(self: *Self) void {
    self.nursery.deinit();
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
    reflect: ?*const ReflectData,
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

        // var for static
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
    const ptr = try self.nursery.bump(size);
    const headerptr = @as([*]ObjHeader, @ptrCast(@alignCast(ptr)));
    headerptr[0] = ObjHeader{
        .size_class = ObjTy.DynamicSize,
        .size = @intCast(@sizeOf(H) + data.len),
        .reflect = getReflectData(H),
    };

    const objheaderptr: *H = @ptrCast(&headerptr[1]);
    objheaderptr.* = header;
    const dataptr = @as([*]u8, @ptrCast(@as([*]H, @ptrCast(objheaderptr)) + 1))[0..data.len];
    @memcpy(dataptr, data);

    return objheaderptr;
}

pub fn new(self: *Self, obj: anytype) Error!*@TypeOf(obj) {
    const T = @TypeOf(obj);
    const ptr = try self.newRaw(T);
    ptr.* = obj;
    return ptr;
}

pub fn newRaw(self: *Self, comptime T: type) Error!*T {
    comptime std.debug.assert(@alignOf(T) <= @alignOf(ObjHeader));
    const size = @sizeOf(ObjHeader) + @sizeOf(T);
    const ptr = try self.nursery.bump(size);
    const headerptr = @as([*]ObjHeader, @ptrCast(@alignCast(ptr)));

    headerptr[0] = ObjHeader{
        .size_class = ObjTy.StaticSize,
        .size = @sizeOf(T),
        .reflect = getReflectData(T),
    };

    const objptr = &headerptr[1];
    std.debug.print("header={} {s}\n", .{ @as(*anyopaque, headerptr), headerptr[0].reflect.?.typename });
    return @ptrCast(objptr);
}

pub fn isGcPtr(self: *Self, ptr: *anyopaque) bool {
    return self.nursery.contains_ptr(ptr);
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

pub fn reflect(self: *Self, anyptr: *anyopaque) ?AnyReflect {
    assert(self.isGcPtr(anyptr));

    const header = @as([*]const ObjHeader, @ptrCast(@alignCast(anyptr))) - 1;

    if (header[0].reflect) |reflectdata| {
        return AnyReflect{
            .obj = anyptr,
            .typename = reflectdata.typename,
            .fmtptr = reflectdata.format,
        };
    }

    return null;
}
