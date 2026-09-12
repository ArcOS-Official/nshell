const std = @import("std");
const builtin = @import("builtin");
const c = @import("sd_bus");

// Thin wrapper over the system sd-bus API (see src/sd_bus.h, wired via the
// translateC step in build.zig as `@import("sd_bus")`, linked as -lsystemd).
// Keeps Zig-side ergonomics (slices, optionals) at the boundary; Net.zig is
// the only consumer.

pub const Bus = c.sd_bus;
pub const Message = c.sd_bus_message;
pub const SdError = c.sd_bus_error;

const testing = builtin.is_test;

pub const call_timeout_us: u64 = 2_000_000;

pub fn openSystem() ?*Bus {
    if (testing) return null;
    var bus: ?*Bus = null;
    if (c.sd_bus_open_system(&bus) < 0) return null;
    return bus;
}

/// Session (user) bus: MPRIS players live here, not on the system bus.
/// Mirrors openSystem; null in headless tests so Media ticks harmlessly.
pub fn openSession() ?*Bus {
    if (testing) return null;
    var bus: ?*Bus = null;
    if (c.sd_bus_open_user(&bus) < 0) return null;
    return bus;
}

pub fn closeBus(bus: ?*Bus) void {
    if (testing) return;
    _ = c.sd_bus_unref(bus);
}

pub fn errorText(err: *const SdError) []const u8 {
    if (testing) return "";
    if (err.name) |n| return std.mem.span(n);
    if (err.message) |m| return std.mem.span(m);
    return "";
}

pub fn errorIsUnknownMethod(err: *const SdError) bool {
    if (testing) return false;
    const n = err.name orelse return false;
    return std.mem.eql(u8, std.mem.span(n), "org.freedesktop.DBus.Error.UnknownMethod");
}

pub fn errorFree(err: *SdError) void {
    if (testing) return;
    c.sd_bus_error_free(err);
    err.* = .{};
}

// One declarative spec per D-Bus call: who, where, what. Constructed inline
// at each call site instead of threading four positional string args.
pub const Target = struct {
    destination: [*:0]const u8,
    path: [*:0]const u8,
    interface: [*:0]const u8,
    member: [*:0]const u8,
};

// Marker for object-path args: 's' and 'o' share Zig's string type, so
// paths need an explicit wrapper to marshal as 'o'.
pub const Obj = struct { path: [*:0]const u8 };
pub fn obj(path: [*:0]const u8) Obj {
    return .{ .path = path };
}

// Comptime marshalling for Method.init args: maps Zig value types to D-Bus
// basic types on the fly (literals, sentinel slices/strings, bools, ints,
// f64). Anything else is a compile error naming the offending type.
fn appendValue(m: *Message, v: anytype) bool {
    const T = @TypeOf(v);
    if (T == Obj) return c.sd_bus_message_append_basic(m, 'o', v.path) >= 0;
    if (T == [*:0]const u8 or T == [*:0]u8) return c.sd_bus_message_append_basic(m, 's', v) >= 0;
    const ti = @typeInfo(T);
    if (ti == .pointer) {
        const P = ti.pointer;
        // *const [N:0]u8 (string literals) and [:0]u8 / [:0]const u8 slices.
        if (P.size == .one) {
            const C = @typeInfo(P.child);
            if (C == .array and C.array.child == u8 and C.array.sentinel() != null) {
                const s: [*:0]const u8 = v;
                return c.sd_bus_message_append_basic(m, 's', s) >= 0;
            }
        }
        if (P.size == .slice and P.child == u8 and P.sentinel() != null) {
            const s: [*:0]const u8 = @ptrCast(v.ptr);
            return c.sd_bus_message_append_basic(m, 's', s) >= 0;
        }
    }
    if (ti == .bool) return c.sd_bus_message_append_basic(m, 'b', &v) >= 0;
    if (ti == .int) {
        const ch: u8 = switch (ti.int.bits) {
            8 => 'y',
            16 => if (ti.int.signedness == .signed) 'n' else 'q',
            32 => if (ti.int.signedness == .signed) 'i' else 'u',
            64 => if (ti.int.signedness == .signed) 'x' else 't',
            else => @compileError("Dbus args: unsupported int width " ++ @typeName(T)),
        };
        return c.sd_bus_message_append_basic(m, ch, &v) >= 0;
    }
    if (ti == .float and ti.float.bits == 64) return c.sd_bus_message_append_basic(m, 'd', &v) >= 0;
    @compileError("Dbus args: unsupported type " ++ @typeName(T) ++ " (object paths need Dbus.obj(...))");
}

pub const Method = struct {
    m: *Message,
    err: SdError = .{},

    // Builds the method call and appends `args` (a tuple, possibly empty)
    // via comptime marshalling, so new calls never need new append helpers.
    // Pass .{} and build manually when the call needs containers.
    pub fn init(bus: *Bus, t: Target, args: anytype) ?Method {
        if (testing) return null;
        const is_tuple = comptime blk: {
            const ti = @typeInfo(@TypeOf(args));
            if (ti != .@"struct") break :blk false;
            break :blk ti.@"struct".is_tuple;
        };
        if (!is_tuple)
            @compileError("Dbus args must be a tuple, e.g. .{ arg1, arg2 } (or .{} for none)");
        var m: ?*Message = null;
        if (c.sd_bus_message_new_method_call(bus, &m, t.destination, t.path, t.interface, t.member) < 0) return null;
        const self = Method{ .m = m orelse return null };
        errdefer _ = c.sd_bus_message_unref(self.m);
        inline for (std.meta.fields(@TypeOf(args))) |f| {
            if (!appendValue(self.m, @field(args, f.name))) return null;
        }
        return self;
    }

    pub fn deinit(self: *Method) void {
        if (testing) return;
        _ = c.sd_bus_message_unref(self.m);
        errorFree(&self.err);
    }

    pub fn str(self: *Method, v: [*:0]const u8) bool {
        if (testing) return false;
        return c.sd_bus_message_append_basic(self.m, 's', v) >= 0;
    }

    pub fn obj(self: *Method, v: [*:0]const u8) bool {
        if (testing) return false;
        return c.sd_bus_message_append_basic(self.m, 'o', v) >= 0;
    }

    pub fn boolean(self: *Method, v: bool) bool {
        if (testing) return false;
        const b: c_int = if (v) 1 else 0;
        return c.sd_bus_message_append_basic(self.m, 'b', &b) >= 0;
    }

    pub fn byte(self: *Method, v: u8) bool {
        if (testing) return false;
        return c.sd_bus_message_append_basic(self.m, 'y', &v) >= 0;
    }

    pub fn open(self: *Method, t: u8, contents: [*:0]const u8) bool {
        if (testing) return false;
        return c.sd_bus_message_open_container(self.m, t, contents) >= 0;
    }

    pub fn close(self: *Method) bool {
        if (testing) return false;
        return c.sd_bus_message_close_container(self.m) >= 0;
    }

    pub fn send(self: *Method, bus: *Bus) ?Reply {
        if (testing) return null;
        var reply: ?*Message = null;
        if (c.sd_bus_call(bus, self.m, call_timeout_us, &self.err, &reply) < 0) return null;
        return .{ .m = reply orelse return null };
    }
};

pub const Reply = struct {
    m: *Message,

    pub fn deinit(self: *Reply) void {
        if (testing) return;
        _ = c.sd_bus_message_unref(self.m);
    }

    pub fn readStr(self: *Reply) ?[]const u8 {
        if (testing) return null;
        var p: ?[*:0]const u8 = null;
        if (c.sd_bus_message_read_basic(self.m, 's', @ptrCast(&p)) <= 0) return null;
        const s = p orelse return null;
        return std.mem.span(s);
    }

    pub fn readObj(self: *Reply) ?[]const u8 {
        if (testing) return null;
        var p: ?[*:0]const u8 = null;
        if (c.sd_bus_message_read_basic(self.m, 'o', @ptrCast(&p)) <= 0) return null;
        const s = p orelse return null;
        return std.mem.span(s);
    }

    pub fn readU32(self: *Reply) ?u32 {
        if (testing) return null;
        var v: u32 = 0;
        if (c.sd_bus_message_read_basic(self.m, 'u', &v) <= 0) return null;
        return v;
    }

    pub fn readU64(self: *Reply) ?u64 {
        if (testing) return null;
        var v: u64 = 0;
        if (c.sd_bus_message_read_basic(self.m, 't', &v) <= 0) return null;
        return v;
    }

    pub fn readU8(self: *Reply) ?u8 {
        if (testing) return null;
        var v: u8 = 0;
        if (c.sd_bus_message_read_basic(self.m, 'y', &v) <= 0) return null;
        return v;
    }

    pub fn readI64(self: *Reply) ?i64 {
        if (testing) return null;
        var v: i64 = 0;
        if (c.sd_bus_message_read_basic(self.m, 'x', &v) <= 0) return null;
        return v;
    }

    pub fn readI32(self: *Reply) ?i32 {
        if (testing) return null;
        var v: i32 = 0;
        if (c.sd_bus_message_read_basic(self.m, 'i', &v) <= 0) return null;
        return v;
    }

    pub fn readBool(self: *Reply) ?bool {
        if (testing) return null;
        var v: c_int = 0;
        if (c.sd_bus_message_read_basic(self.m, 'b', &v) <= 0) return null;
        return v != 0;
    }

    pub fn enterRaw(self: *Reply, t: u8, contents: [*:0]const u8) c_int {
        if (testing) return -1;
        return c.sd_bus_message_enter_container(self.m, t, contents);
    }

    pub fn exit(self: *Reply) bool {
        if (testing) return false;
        return c.sd_bus_message_exit_container(self.m) >= 0;
    }

    pub fn peek(self: *Reply) ?struct { t: u8, contents: []const u8 } {
        if (testing) return null;
        var t: u8 = 0;
        var raw: ?[*:0]const u8 = null;
        if (c.sd_bus_message_peek_type(self.m, &t, @ptrCast(&raw)) < 0) return null;
        const cs = raw orelse return null;
        return .{ .t = t, .contents = std.mem.span(cs) };
    }

    pub fn skip(self: *Reply, types: [*:0]const u8) bool {
        if (testing) return false;
        return c.sd_bus_message_skip(self.m, types) >= 0;
    }
};
