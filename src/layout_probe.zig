const std = @import("std");
const dvui = @import("dvui");
const HubUi = @import("HubUi.zig");
const State = @import("State.zig");

// Headless layout probe for the network panel (build step
// `layout-probe`). Drives the REAL hubFrame — including the AlignedEntry
// password field and the Connect button — against a Net model populated
// directly (no D-Bus, no worker thread), on dvui's testing backend.
// Prints the measured geometry of the tagged widgets so layout
// regressions can be diagnosed from numbers instead of screenshots.
//
// Drives Window.begin/end directly (not dvui.testing) so we don't drag
// test-only std internals into a normal executable.

var g_state: State = undefined;
var g_hub: HubUi = undefined;

// Layer-shell stand-in: hubFrame's only ctx calls are setSize (probe
// windows are already the right size) and setKeyboardInteractivity
// (no compositor here). Both are no-ops.
const FakeCtx = struct {
    pub const KeyboardInteractivity = enum { none, exclusive, on_demand };

    pub fn setSize(_: @This(), _: u32, _: u32) void {}
    pub fn setKeyboardInteractivity(_: @This(), _: KeyboardInteractivity) void {}
};

fn frame() !dvui.App.Result {
    return g_hub.hubFrame(&g_state, g_state.io, FakeCtx{}, undefined) catch .ok;
}

fn dumpTags(label: []const u8) void {
    std.debug.print("{s}:\n", .{label});
    const names = [_][]const u8{ "ap_row", "pw_row", "pw_entry", "connect_btn" };
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

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    try g_state.init(alloc, io);
    defer g_state.deinit();
    g_hub = HubUi.init();

    // Populate the Net model directly: hubFrame reads snapshots, and the
    // worker never runs here, so this is the whole world.
    {
        const net = &g_state.net;
        net.init(alloc, io);
        net.mu.lockUncancelable(io);
        defer net.mu.unlock(io);
        try net.devices.append(alloc, .{
            .path = try alloc.dupe(u8, "/dev/1"),
            .iface = try alloc.dupe(u8, "wlan0"),
            .kind = .wifi,
            .state = 100,
        });
        net.wifi_on = true;
        try net.aps.append(alloc, .{
            .path = try alloc.dupe(u8, "/ap/1"),
            .ssid = try alloc.dupe(u8, "HomeNet"),
            .strength = 80,
            .secured = true,
            .freq_mhz = 5180,
            .id = 1,
        });
        net.active_ap_path = "";
        // A saved NM profile for a second SSID exercises the grayed
        // "Password saved" entry state.
        try net.saved.append(alloc, .{
            .path = try alloc.dupe(u8, "/org/freedesktop/NetworkManager/Settings/1"),
            .ssid = try alloc.dupe(u8, "SavedNet"),
        });
        try net.aps.append(alloc, .{
            .path = try alloc.dupe(u8, "/ap/2"),
            .ssid = try alloc.dupe(u8, "SavedNet"),
            .strength = 60,
            .secured = true,
            .freq_mhz = 5180,
            .id = 2,
        });
    }

    var backend = dvui.backend.init(.{
        .allocator = alloc,
        .size = .{ .w = 520, .h = 420 },
        .size_pixels = .{ .w = 1040, .h = 840 },
    });
    var win = try dvui.Window.init(@src(), alloc, backend.backend(), .{
        .color_scheme = .light,
    });
    // Note: no win/backend deinit — dvui's testing backend double-frees the
    // shared font atlas on teardown (textureDestroy during Font.deinit
    // after the same bytes were already released). The probe is a
    // run-once diagnostic; the OS reclaims everything at exit.

    var frames: usize = 0;
    while (frames < 34) : (frames += 1) {
        const t_ns = @as(i128, @intCast(frames)) * 16 * std.time.ns_per_ms;
        try win.begin(t_ns);
        if (frames == 2) {
            // Open the panel with the secured row expanded, like a click.
            // Inside the frame: switchMode registers a dvui animation.
            g_hub.switchMode(.network, &g_state);
            g_hub.net_sel = 1;
            g_hub.net_sel_open = true;
        }
        if (frames == 14) {
            // Switch to the saved-profile row (grayed entry state).
            g_hub.net_sel = 2;
            g_hub.net_sel_open = true;
        }
        if (frames == 20) {
            // Simulate a wrong-password reject on the open row: stamp the
            // reject clock against the REAL clock hubFrame uses (not the
            // synthetic frame time) and watch the entry wiggle.
            g_hub.net_reject_since = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
            g_hub.net_reject_ap = 2;
        }
        if (frames == 26) {
            // Simulate focus: the reject outline draws only when focused.
            // The probe has no events, so fake it by checking geometry only
            // (offset movement is visible without focus; the red stroke
            // needs entry_focused, verified in the live app instead).
        }
        _ = try frame();
        if (frames >= 20 and frames < 24) {
            std.debug.print("reject: since={d} ap={d} sel={?d} now={d}\n", .{
                g_hub.net_reject_since, g_hub.net_reject_ap, g_hub.net_sel,
                @as(u64, @intCast(std.Io.Clock.real.now(io).toMilliseconds())),
            });
            // Wiggle window: entry x should oscillate around its slot.
            dumpTags("wiggle");
        } else if (frames == 19 or frames == 33) {
            dumpTags("settled");
        }
        _ = try win.end(.{});
    }
    std.debug.print("probe done\n", .{});
    std.process.exit(0);
}
