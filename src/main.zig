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

    {
        var left = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .vertical,
            .background = true,
            .style = .window,
            .corners = .all(16),
            .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
            .border = dvui.Rect.all(1),
            .min_size_content = .{ .h = 40 },
        });
        defer left.deinit();

        if (dvui.buttonIcon(@src(), "launcher", dvui.entypo.book, .{}, .{}, .{
            .style = .highlight,
            .corners = .all(10),
            .padding = dvui.Rect.all(8),
            .font = dvui.Font.theme(.title).withSize(16),
            .margin = dvui.Rect.all(2),
            .expand = .vertical,
            .min_size_content = .{ .w = 25 },
        })) {
            if (state.conn != null) {
                // could trigger launcher popup in future
            }
        }

        _ = dvui.separator(@src(), .{
            .expand = .vertical,
            .min_size_content = .{ .w = 1 },
            .margin = .fromSize(.{ .w = 2, .h = 4 }),
            .color_fill = dvui.Color{ .r = 0x3a, .g = 0x3a, .b = 0x44, .a = 0xff },
        });

        for (state.workspaces, 0..) |ws, i| {
            const is_active = ws.active or ws.current;
            const is_urgent = ws.urgent;

            var buf: [32]u8 = undefined;
            const label = if (ws.name.len > 0)
                std.fmt.bufPrint(&buf, "{d} {s}", .{ ws.number, ws.name }) catch "?"
            else
                std.fmt.bufPrint(&buf, "{d}", .{ws.number}) catch "?";

            const opts: dvui.Options = .{
                .style = if (is_active) .highlight else .control,
                .expand = .vertical,
                .background = true,
                .corners = .all(10),
                .padding = .fromSize(.{ .w = 2, .h = 0 }),
                .margin = .fromSize(.{ .w = 2, .h = 4 }),
                .font = if (is_active) dvui.Font.theme(.heading).withSize(13) else dvui.Font.theme(.body).withSize(13),
                .border = .all(1),
                .color_border = if (is_urgent) dvui.Color{ .r = 0xff, .g = 0x55, .b = 0x55, .a = 0xff } else null,
                .id_extra = i,
            };

            if (dvui.button(@src(), label, .{}, opts)) {
                state.switchWorkspace(ws.id);
            }
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .min_size_content = .{ .w = 12 } });

    {
        var center = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .vertical,
            .background = true,
            .style = .window,
            .corners = .all(16),
            .padding = .all(2),
            .border = dvui.Rect.all(1),
            .min_size_content = .{ .h = 40 },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
        defer center.deinit();

        if (state.focusedWindow()) |fw| {
            // app_id pill
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false, .gravity_x = 0.5 });
            defer row.deinit();
            dvui.label(@src(), "{s}", .{fw.app_id}, .{
                .font = dvui.Font.theme(.body).withSize(11),
                .color_text = dvui.Color{ .r = 0x9a, .g = 0x9a, .b = 0xa8, .a = 0xff },
                .gravity_y = 0.5,
            });
            dvui.label(@src(), " - ", .{}, .{ .color_text = dvui.Color{ .r = 0x5a, .g = 0x5a, .b = 0x66, .a = 0xff }, .gravity_y = 0.5 });
            // title truncated
            const t = truncateTitle(fw.title, 36);
            dvui.labelNoFmt(@src(), t, .{}, .{
                .font = dvui.Font.theme(.heading).withSize(11),
                .gravity_y = 0.5,
            });
        } else {
            dvui.label(@src(), "Desktop", .{}, .{
                .font = dvui.Font.theme(.heading).withSize(11),
                .color_text = dvui.Color{ .r = 0x9a, .g = 0x9a, .b = 0xa8, .a = 0xff },
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    {
        var right = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .vertical,
            .background = true,
            .style = .window,
            .corners = .all(16),
            .padding = .all(2),
            .border = dvui.Rect.all(1),
            .min_size_content = .{ .h = 40 },
            .gravity_y = 0.5,
        });
        defer right.deinit();

        if (state.outputs.len > 0) {
            const o = state.outputs[0];
            var obuf: [64]u8 = undefined;
            const olabel = std.fmt.bufPrint(&obuf, "{s} {d}×{d}@{d}", .{
                o.name,
                o.mode.width,
                o.mode.height,
                o.mode.refresh / 1000,
            }) catch o.name;
            dvui.labelNoFmt(@src(), olabel, .{}, .{
                .font = dvui.Font.theme(.body).withSize(11),
                .color_text = dvui.Color{ .r = 0x9a, .g = 0x9a, .b = 0xa8, .a = 0xff },
                .margin = dvui.Rect.all(6),
            });
            _ = dvui.separator(@src(), .{
                .expand = .vertical,
                .min_size_content = .{ .w = 1, .h = 24 },
                .margin = dvui.Rect.all(6),
                .color_fill = dvui.Color{
                    .r = 0x3a,
                    .g = 0x3a,
                    .b = 0x44,
                    .a = 0xff,
                },
            });
        }

        dvui.label(@src(), "V  78%  B  42%  W", .{}, .{
            .font = dvui.Font.theme(.body).withSize(12),
            .color_text = dvui.Color{ .r = 0xb8, .g = 0xb8, .b = 0xc8, .a = 0xff },
            .margin = dvui.Rect.all(6),
            .gravity_y = 0.5,
        });

        _ = dvui.separator(@src(), .{ .expand = .vertical, .min_size_content = .{ .w = 1, .h = 24 }, .margin = dvui.Rect.all(6), .color_fill = dvui.Color{ .r = 0x3a, .g = 0x3a, .b = 0x44, .a = 0xff } });

        dvui.labelNoFmt(@src(), state.clockSlice(), .{}, .{
            .font = dvui.Font.theme(.body).withSize(12),
            .margin = dvui.Rect.all(4),
        });

        if (state.focusedWindow() != null) {
            if (dvui.button(@src(), " ✕ ", .{}, .{
                .style = .control,
                .corners = .all(8),
                .padding = dvui.Rect.all(4),
                .margin = dvui.Rect.all(2),
                .font = dvui.Font.theme(.body).withSize(12),
            })) {
                if (state.focused_id) |fid| state.closeWindow(fid);
            }
        }
    }

    return .ok;
}
