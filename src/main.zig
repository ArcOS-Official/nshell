const std = @import("std");
const dvui = @import("dvui");
const ls = @import("layershell");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = -1, .h = 58.0 },
            .title = "Test window",
            .window_init_options = .{},
            .min_size = .{ .w = 250.0, .h = 58.0 },
            .transparent = true,
        }
    },
    .frameFn = appFrame,
};
pub const layer_shell_opts: ls.LayerShellOpts = .{
    .anchors = .{ .top, .left, .right, null },
    .size = .{ .w = -1, .h = 58.0 },
    .exclusive_zone = 58.0,
    .padding = .{ 8, 6, 0, 0 },
    .namespace = "arcos",
};
pub const main = ls.main;

fn appFrame() !dvui.App.Result {
    var exit = false;
    var box = dvui.flexbox(@src(), .{}, .{});
    defer box.deinit();
    for (0..10) |i| {
        if (dvui.button(@src(), "Hello", .{}, .{ .id_extra = i })) {
            if (exit)
                return .close;
            dvui.toggleDebugWindow();
            exit = true;
        }
    }
    return .ok;
}
