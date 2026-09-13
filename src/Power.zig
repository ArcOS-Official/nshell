const std = @import("std");
const Dbus = @import("Dbus.zig");

// Laptop battery state polled from UPower's composite DisplayDevice over
// the system bus. Mirrors Net.zig's shape (worker-owned bus + cached
// model, cheap status reads for the UI) minus the action queue: the
// battery is read-only, so there is nothing to send.
//
// No battery (desktop, IsPresent == false) is normal: status() reports
// present == false and the bar hides the whole cluster.

pub const refresh_ms: u64 = 5000;
const retry_ms: i64 = 5000;

const upower_dest = "org.freedesktop.UPower";
const display_path = "/org/freedesktop/UPower/devices/DisplayDevice";
const device_iface = "org.freedesktop.UPower.Device";
const props_iface = "org.freedesktop.DBus.Properties";

// UPower Device.State (daemon/src/up-device.h): only charging vs
// discharging matters here; everything else reads as idle.
pub const state_charging: u32 = 1;
pub const state_fully_charged: u32 = 4;

pub const Status = struct {
    present: bool = false,
    percent: u8 = 0, // 0-100, clamped
    charging: bool = false,
    full: bool = false,
};

mu: std.Io.Mutex = .init,
alloc: std.mem.Allocator = undefined,
io: std.Io = undefined,
inited: bool = false,

bus: ?*Dbus.Bus = null,
retry_at_ms: i64 = 0,
next_poll_ms: i64 = 0,
gen: u64 = 0,

present: bool = false,
percent: u8 = 0,
charging: bool = false,
full: bool = false,

const Power = @This();

pub fn init(self: *Power, alloc: std.mem.Allocator, io: std.Io) void {
    self.alloc = alloc;
    self.io = io;
    self.inited = true;
}

pub fn deinit(self: *Power) void {
    if (self.bus) |b| {
        Dbus.closeBus(b);
        self.bus = null;
    }
    self.* = .{};
}

fn nowMs(self: *Power) i64 {
    return std.Io.Clock.boot.now(self.io).toMilliseconds();
}

fn bump(self: *Power) void {
    self.gen +%= 1;
}

/// Cheap UI read (bar battery cluster). No allocation.
pub fn status(self: *Power) Status {
    if (!self.inited) return .{};
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    return .{
        .present = self.present,
        .percent = self.percent,
        .charging = self.charging,
        .full = self.full,
    };
}

fn getProp(self: *Power, bus: *Dbus.Bus, prop: [*:0]const u8) ?Dbus.Reply {
    _ = self;
    var m = Dbus.Method.init(bus, .{
        .destination = upower_dest,
        .path = display_path,
        .interface = props_iface,
        .member = "Get",
    }, .{ device_iface, prop }) orelse return null;
    defer m.deinit();
    var r = m.send(bus) orelse return null;
    const pk = r.peek() orelse {
        r.deinit();
        return null;
    };
    if (pk.t != 'v') {
        r.deinit();
        return null;
    }
    // enterRaw needs a sentinel signature: copy it like Net.enterVariant.
    var buf: [32]u8 = undefined;
    if (pk.contents.len == 0 or pk.contents.len + 1 > buf.len) {
        r.deinit();
        return null;
    }
    @memcpy(buf[0..pk.contents.len], pk.contents);
    buf[pk.contents.len] = 0;
    if (r.enterRaw('v', buf[0..pk.contents.len :0]) <= 0) {
        r.deinit();
        return null;
    }
    return r;
}

/// Worker tick (see State.worker): connects lazily, polls the
/// DisplayDevice every refresh_ms. Returns true when the model changed.
pub fn tick(self: *Power) !bool {
    if (!self.inited) return false;
    if (self.bus == null) {
        const now = self.nowMs();
        if (now < self.retry_at_ms) return false;
        self.retry_at_ms = now + retry_ms;
        if (Dbus.openSystem()) |b| {
            self.mu.lockUncancelable(self.io);
            self.bus = b;
            self.next_poll_ms = 0;
            self.mu.unlock(self.io);
            self.bump();
            return true;
        }
        return false;
    }
    const now = self.nowMs();
    if (now < self.next_poll_ms) return false;
    self.next_poll_ms = now + @as(i64, @intCast(refresh_ms));
    return self.poll();
}

fn poll(self: *Power) bool {
    const bus = self.bus orelse return false;
    var present = false;
    var percent: u8 = 0;
    var charging = false;
    var full = false;
    var r_present = self.getProp(bus, "IsPresent") orelse return false;
    defer r_present.deinit();
    present = r_present.readBool() orelse false;
    if (!present) {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.present) {
            self.present = false;
            self.bump();
            return true;
        }
        return false;
    }
    var r_pct = self.getProp(bus, "Percentage") orelse return false;
    defer r_pct.deinit();
    {
        const p = r_pct.readF64() orelse -1;
        if (p < 0) return false;
        percent = @intCast(@min(@max(@as(i64, @intFromFloat(p)), 0), 100));
    }
    var r_state = self.getProp(bus, "State") orelse return false;
    defer r_state.deinit();
    {
        const st = r_state.readU32() orelse 0;
        charging = st == state_charging;
        full = st == state_fully_charged;
    }
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.present and self.percent == percent and self.charging == charging and self.full == full)
        return false;
    self.present = true;
    self.percent = percent;
    self.charging = charging;
    self.full = full;
    self.bump();
    return true;
}

test "power: uninit status is absent" {
    var p: Power = .{};
    const st = p.status();
    try std.testing.expect(!st.present);
}
