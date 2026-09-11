const std = @import("std");
const Net = @import("Net.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var net: Net = .{};
    net.init(alloc, io);
    defer net.deinit();

    const ms = struct {
        fn dt(t0: anytype, t1: anytype) f64 {
            const ns = t0.durationTo(t1).toNanoseconds();
            return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
        }
    }.dt;

    var t0 = std.Io.Clock.boot.now(io);
    const first = net.tick() catch false;
    var t1 = std.Io.Clock.boot.now(io);
    var st = net.status();
    std.debug.print("bus open + first poll: {d:.2} ms present={s} changed={s}\n", .{ ms(t0, t1), if (st.present) "yes" else "no", if (first) "yes" else "no" });
    if (!st.present) {
        std.debug.print("no system bus; live timings skipped\n", .{});
        return;
    }

    var polls: usize = 0;
    var poll_ms: f64 = 0;
    var max_ms: f64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        io.sleep(.fromMilliseconds(500), .awake) catch break;
        t0 = std.Io.Clock.boot.now(io);
        const changed = net.tick() catch false;
        t1 = std.Io.Clock.boot.now(io);
        if (changed) {
            const d = ms(t0, t1);
            polls += 1;
            poll_ms += d;
            if (d > max_ms) max_ms = d;
        }
    }
    st = net.status();
    std.debug.print("core polls: {d} avg {d:.2} ms max {d:.2} ms down={d:.0}bps up={d:.0}bps\n", .{
        polls,
        if (polls > 0) poll_ms / @as(f64, @floatFromInt(polls)) else 0,
        max_ms,
        st.down_bps,
        st.up_bps,
    });

    const refresh_req = net.refresh();
    t0 = std.Io.Clock.boot.now(io);
    _ = net.tick() catch false;
    t1 = std.Io.Clock.boot.now(io);
    var snap = net.snapshotCopy(alloc);
    defer snap.deinit(alloc);
    std.debug.print("ap+bt refresh: {d:.2} ms devices={d} aps={d} bt={s} req={s}\n", .{
        ms(t0, t1),
        snap.devices.len,
        snap.aps.len,
        if (snap.bt_present) (if (snap.bt_powered) "on" else "off") else "absent",
        @tagName(refresh_req.poll(&net)),
    });
    for (snap.aps[0..@min(5, snap.aps.len)]) |*ap| {
        std.debug.print("  ap {d}% {s} {s}\n", .{ ap.strength, ap.ssid, if (ap.secured) "locked" else "open" });
    }

    t0 = std.Io.Clock.boot.now(io);
    const scan_req = net.scan();
    const scanned = net.tick() catch false;
    t1 = std.Io.Clock.boot.now(io);
    std.debug.print("scan request: {d:.2} ms ok={s} req={s}\n", .{ ms(t0, t1), if (scanned) "yes" else "no", @tagName(scan_req.poll(&net)) });
    std.debug.print("\nbench done\n", .{});
}
