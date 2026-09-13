const std = @import("std");

// Unread notification count. A stub for now: there is no notification
// daemon in nshell yet, so nothing produces events — the count starts at
// zero and only moves via these calls. UI-thread only (no producer thread
// exists yet); add a mutex when a daemon feed lands.
//
// Read by the bar bell indicator; cleared from the control center.
const Notif = @This();

unread: u32 = 0,

pub fn count(self: *const Notif) u32 {
    return self.unread;
}

/// Record one incoming notification (saturates instead of wrapping).
pub fn push(self: *Notif) void {
    self.unread +|= 1;
}

pub fn clear(self: *Notif) void {
    self.unread = 0;
}

test "notif: push saturates, clear resets" {
    var n: Notif = .{};
    try std.testing.expectEqual(@as(u32, 0), n.count());
    n.push();
    n.push();
    try std.testing.expectEqual(@as(u32, 2), n.count());
    n.clear();
    try std.testing.expectEqual(@as(u32, 0), n.count());
    n.unread = std.math.maxInt(u32);
    n.push();
    try std.testing.expectEqual(std.math.maxInt(u32), n.count());
}
