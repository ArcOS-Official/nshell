const std = @import("std");
const dvui = @import("dvui");
const ls = @import("layershell");
const State = @import("State.zig");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = -1, .h = 58.0 },
            .title = "nshell — Nile bar",
            .window_init_options = .{
                .theme = dvui.Theme.builtin.adwaita_dark,
            },
            .transparent = true,
        },
    },
    .frameFn = frame,
    .initFn = init,
    .deinitFn = deinit,
};

pub const layer_shell_opts: ls.LayerShellOpts = .{
    .anchors = .{ .top, .left, .right, null },
    .exclusive_zone = 58.0,
    .padding = .{ 6, 8, 0, 8 },
    .namespace = "nshell",
    .layer = .top,
};

pub const main = ls.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

var state: State = undefined;

fn init(_: *dvui.Window) !void {
    try state.init();
}

fn deinit() void {
    state.deinit();
}

fn truncateTitle(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    // truncate at max, add ellipsis
    if (max < 3) return s[0..max];
    return s[0 .. max - 1];
}

fn frame() !dvui.App.Result {
    state.poll();

    var outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = false,
        .padding = dvui.Rect.all(6),
    });
    defer outer.deinit();

    return .ok;
}
