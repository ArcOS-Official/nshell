const std = @import("std");
const dvui = @import("dvui");
const ls = @import("layershell");
const State = @import("State.zig");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 0, .h = 500.0 },
            .title = "nshell - Nile bar",
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
    .exclusive_zone = 50.0,
    .padding = .{ 4, 6, 6, 8 },
    .namespace = "nshell",
    .layer = .top,
};

pub const main = ls.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

var state: State = undefined;

// Worker -> GUI wakeup: runs on the worker thread every time a snapshot is
// pushed into the inbox. Forwards to dvui.refresh(window), which pushes an
// SDL user event that interrupts the backend's waitEventTimeout so the next
// frame (which drains the inbox in frame()) happens immediately instead of
// waiting for the next input event.
fn requestDvuiRefresh(ctx: ?*anyopaque) void {
    if (ctx) |c| {
        const win: *dvui.Window = @ptrCast(@alignCast(c));
        dvui.refresh(win, @src(), null);
    }
}

fn init(win: *dvui.Window) !void {
    try state.initWithWakeup(win, &requestDvuiRefresh);

    dvui.toggleDebugWindow();
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

    var t = &dvui.currentWindow().theme;

    var outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = false,
    });
    defer outer.deinit();

    {
        var left = dvui.box(
            @src(),
            .{ .dir = .horizontal, .equal_space = true },
            .{
                .background = true,
                .color_fill = t.color(.content, .fill),
                .color_border = t.color(.content, .text).opacity(0.15),
                .border = .all(1),
                .corners = .all(10),
                .min_size_content = .{ .h = 48.0, .w = (32*9)+(6*7) },
                .padding = .fromSize(.{ .w = 4 }),
                .gravity_y = 0.5,
            },
        );
        defer left.deinit();

        for (state.workspaces, 0..) |w, i| {
            var btn: dvui.ButtonWidget = undefined;
            btn.init(@src(), .{}, .{
                .background = true,
                .color_fill =
                if (w.current)
                    t.color(.highlight, .fill)
                else
                    t.color(.content, .fill).lighten(10),
                .color_fill_hover =
                if (w.current)
                    t.color(.highlight, .fill).lighten(-5)
                else
                    t.color(.content, .fill).lighten(5),
                .gravity_y = 0.5,
                .corners = .all(10),
                .padding = .all(0),
                .id_extra = i,
                .min_size_content = .{ .w = 32, .h = 32 },
                .max_size_content = .{ .w = 32, .h = 32 },
            });
            defer btn.deinit();
            btn.drawBackground();
            btn.processEvents();
            if (btn.clicked()) {
                state.switchWorkspace(w.id);
            }
            dvui.labelNoFmt(@src(), &.{'0'+w.number}, .{
                .align_x = 0.5,
                .align_y = 0.55,
            }, .{
                .font = t.font_mono.withWeight(.bold).withSize(11.0),
                .gravity_y = 0.5,
                .gravity_x = 0.5,
                .expand = .both,
                .padding = .all(0),
            });
        }
    }

    _ = dvui.spacer(@src(), .{
        .expand = .horizontal,
    });

    {
        var right = dvui.box(
            @src(),
            .{ .dir = .horizontal, .equal_space = true },
            .{
                .background = true,
                .color_fill = t.color(.content, .fill),
                .color_border = t.color(.content, .text).opacity(0.15),
                .border = .all(1),
                .corners = .all(10),
                .min_size_content = .{ .h = 48.0, .w = (32*9)+(6*7) },
                .padding = .fromSize(.{ .w = 4 }),
                .gravity_y = 0.5,
            },
        );
        defer right.deinit();
    }

    return .ok;
}
