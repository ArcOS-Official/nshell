const std = @import("std");
const dvui = @import("dvui");
const HubUi = @import("HubUi.zig");
const State = @import("State.zig");

// Headless layout probe for the clock media player (build step
// `media-probe`). Drives the REAL hubFrame against dvui's testing backend
// with a Media model populated directly (no D-Bus, no worker thread).
// Prints hub size + tagged widget geometry so the expanded clock and the
// control-center card can be sized from numbers instead of screenshots.

var g_state: State = undefined;
var g_hub: HubUi = undefined;

const FakeCtx = struct {
    pub const KeyboardInteractivity = enum { none, exclusive, on_demand };

    pub fn setSize(_: @This(), _: u32, _: u32) void {}
    pub fn setKeyboardInteractivity(_: @This(), _: KeyboardInteractivity) void {}
};

fn frame() !dvui.App.Result {
    return g_hub.hubFrame(&g_state, g_state.io, FakeCtx{}, undefined) catch .ok;
}

fn dumpHub(label: []const u8) void {
    std.debug.print("{s}: hub_cur={d:.0}x{d:.0} target={?d:.0}x{?d:.0} mode={s}\n", .{
        label,
        g_hub.hub_cur.w,
        g_hub.hub_cur.h,
        if (g_hub.hub_target) |ta| ta.w else null,
        if (g_hub.hub_target) |ta| ta.h else null,
        @tagName(g_hub.hubmode),
    });
    const names = [_][]const u8{ "tophub", "tophub_clock", "launcher_row", "player_row" };
    for (names) |n| {
        const td = dvui.tagGet(n) orelse {
            std.debug.print("  {s}: (not present this frame)\n", .{n});
            continue;
        };
        const r = td.rect;
        std.debug.print("  {s}: x={d:.1} y={d:.1} w={d:.1} h={d:.1} visible={}\n", .{
            n, r.x, r.y, r.w, r.h, td.visible,
        });
    }
}

fn injectTrack(io: std.Io, alloc: std.mem.Allocator) !void {
    const m = &g_state.media;
    m.mu.lockUncancelable(io);
    defer m.mu.unlock(io);
    m.player = try alloc.dupe(u8, "org.mpris.MediaPlayer2.vlc");
    m.title = try alloc.dupe(u8, "Midnight City");
    m.artist = try alloc.dupe(u8, "M83");
    m.trackid = try alloc.dupe(u8, "/org/mpris/MediaPlayer2/Track/1");
    m.status = .playing;
    m.position_us = 65_000_000;
    m.position_ms = std.Io.Clock.boot.now(io).toMilliseconds();
    m.length_us = 240_000_000;
    m.present = true;
    m.gen +%= 1;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    try g_state.init(alloc, io);
    defer g_state.deinit();
    g_hub = HubUi.init();

    var backend = dvui.backend.init(.{
        .allocator = alloc,
        .size = .{ .w = 640, .h = 600 },
        .size_pixels = .{ .w = 1280, .h = 1200 },
    });
    var win = try dvui.Window.init(@src(), alloc, backend.backend(), .{
        .color_scheme = .light,
    });

    // Phase 1: idle clock baseline (no media).
    {
        var f: usize = 0;
        while (f < 6) : (f += 1) {
            try win.begin(@as(i128, @intCast(f)) * 16 * std.time.ns_per_ms);
            _ = try frame();
            // tagGet needs an open frame: dump before end().
            if (f == 5) dumpHub("idle clock");
            _ = try win.end(.{});
        }
    }

    // Phase 2: track appears; let the expand animation settle.
    try injectTrack(io, alloc);
    {
        var f: usize = 0;
        while (f < 30) : (f += 1) {
            try win.begin(@as(i128, @intCast(100 + f)) * 16 * std.time.ns_per_ms);
            _ = try frame();
            if (f == 29) dumpHub("clock + player");
            _ = try win.end(.{});
        }
    }

    // Phase 3: control center with the pinned card.
    {
        var f: usize = 0;
        while (f < 30) : (f += 1) {
            try win.begin(@as(i128, @intCast(200 + f)) * 16 * std.time.ns_per_ms);
            // switchMode registers a dvui animation: needs an open frame.
            if (f == 0) g_hub.switchMode(.controls, &g_state);
            _ = try frame();
            if (f == 29) dumpHub("controls + card");
            _ = try win.end(.{});
        }
    }

    std.debug.print("probe done\n", .{});
    std.process.exit(0);
}
