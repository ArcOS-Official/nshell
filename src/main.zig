const std = @import("std");
const dvui = @import("dvui");
const ls = @import("layershell");
const State = @import("State.zig");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = -1, .h = 68.0 },
            .title = "nshell — Nile bar",
            .window_init_options = .{
                .theme = dvui.Theme.builtin.adwaita_dark,
            },
            .min_size = .{ .w = 800.0, .h = 68.0 },
            .max_size = .{ .w = 8192.0, .h = 68.0 },
            .transparent = true,
        },
    },
    .frameFn = frame,
    .initFn = init,
    .deinitFn = deinit,
};

pub const layer_shell_opts: ls.LayerShellOpts = .{
    .anchors = .{ .top, .left, .right, null },
    .size = .{ .w = -1, .h = 68.0 },
    .exclusive_zone = 68.0,
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

    // Root: transparent, just holds the island
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .padding = dvui.Rect.all(6),
    });
    defer outer.deinit();

    // Island — the actual bar
    var island = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .style = .window,
        .corners = .all(16),
        .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
        .border = dvui.Rect.all(1),
        .min_size_content = .{ .h = 40 },
    });
    defer island.deinit();

    // LEFT — launcher + workspaces
    {
        var left = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .background = false,
            .padding = .{ .x = 2, .y = 0, .w = 4, .h = 0 },
        });
        defer left.deinit();

        // launcher
        if (dvui.button(@src(), "  ◈  ", .{}, .{
            .style = .highlight,
            .corners = .all(10),
            .padding = dvui.Rect.all(8),
            .font = dvui.Font.theme(.title).withSize(16),
            .margin = dvui.Rect.all(2),
        })) {
            // quick ping to test connection liveness
            if (state.conn != null) {
                // could trigger launcher popup in future
            }
        }

        // divider
        _ = dvui.separator(@src(), .{ .expand = .vertical, .min_size_content = .{ .w = 1, .h = 24 }, .margin = dvui.Rect.all(6), .color_fill = dvui.Color{ .r = 0x3a, .g = 0x3a, .b = 0x44, .a = 0xff } });

        // workspaces
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
                .background = true,
                .corners = .all(10),
                .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
                .margin = dvui.Rect.all(3),
                .font = if (is_active) dvui.Font.theme(.title).withSize(8) else dvui.Font.theme(.body).withSize(8),
                .border = dvui.Rect.all(1),
                .color_border = if (is_urgent) dvui.Color{ .r = 0xff, .g = 0x55, .b = 0x55, .a = 0xff } else null,
                .id_extra = i,
            };

            // urgent dot via extra label if needed – we color border instead plus dot in label
            var label_with_dot: []const u8 = label;
            var dot_buf: [40]u8 = undefined;
            if (is_urgent and !is_active) {
                label_with_dot = std.fmt.bufPrint(&dot_buf, "{s} ●", .{label}) catch label;
            }

            if (dvui.button(@src(), label_with_dot, .{}, opts)) {
                state.switchWorkspace(ws.id);
            }
        }

        // windows on active workspace as tiny chips (task strip)
        // show up to 4 windows from active ws
        var active_ws_id: ?u64 = null;
        for (state.workspaces) |ws| if (ws.active or ws.current) {
            active_ws_id = ws.id;
            break;
        };
        if (active_ws_id) |wsid| {
            var shown: usize = 0;
            for (state.windows, 0..) |*w, i| {
                if (w.workspace != wsid) continue;
                if (shown >= 3) break;
                shown += 1;
                const focused = w.focused;
                const chip_opts: dvui.Options = .{
                    .style = if (focused) .highlight else .control,
                    .background = true,
                    .corners = .all(9),
                    .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
                    .margin = dvui.Rect.all(3),
                    .font = dvui.Font.theme(.body).withSize(12),
                    .id_extra = i,
                };
                // truncate title to 18 chars
                const t = if (w.title.len > 22) w.title[0..21] else w.title;
                var cbuf: [48]u8 = undefined;
                const clabel = std.fmt.bufPrint(&cbuf, "{s}", .{t}) catch t;
                if (dvui.button(@src(), clabel, .{}, chip_opts)) {
                    state.focusWindow(w.id);
                }
            }
        }
    }

    // SPACER left-center
    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .min_size_content = .{ .w = 12 } });

    // CENTER — focused window
    {
        var center = dvui.box(@src(), .{ .dir = .vertical }, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .background = false,
            .padding = dvui.Rect.all(2),
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
            dvui.label(@src(), "  —  ", .{}, .{ .color_text = dvui.Color{ .r = 0x5a, .g = 0x5a, .b = 0x66, .a = 0xff }, .gravity_y = 0.5 });
            // title truncated
            const t = truncateTitle(fw.title, 36);
            dvui.labelNoFmt(@src(), t, .{}, .{
                .font = dvui.Font.theme(.heading).withSize(13),
                .gravity_y = 0.5,
            });
        } else {
            dvui.label(@src(), "Desktop", .{}, .{
                .font = dvui.Font.theme(.heading).withSize(13),
                .color_text = dvui.Color{ .r = 0x9a, .g = 0x9a, .b = 0xa8, .a = 0xff },
                .gravity_x = 0.5,
            });
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .min_size_content = .{ .w = 12 } });

    // RIGHT — outputs, clock, status, system
    {
        var right = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .background = false,
            .padding = .{ .x = 4, .y = 0, .w = 2, .h = 0 },
        });
        defer right.deinit();

        // outputs
        if (state.outputs.len > 0) {
            const o = state.outputs[0];
            var obuf: [64]u8 = undefined;
            const olabel = std.fmt.bufPrint(&obuf, "{s} {d}×{d}@{d}", .{ o.name, o.mode.width, o.mode.height, o.mode.refresh / 1000 }) catch o.name;
            dvui.labelNoFmt(@src(), olabel, .{}, .{
                .font = dvui.Font.theme(.body).withSize(11),
                .color_text = dvui.Color{ .r = 0x9a, .g = 0x9a, .b = 0xa8, .a = 0xff },
                .margin = dvui.Rect.all(6),
            });
            _ = dvui.separator(@src(), .{ .expand = .vertical, .min_size_content = .{ .w = 1, .h = 24 }, .margin = dvui.Rect.all(6), .color_fill = dvui.Color{ .r = 0x3a, .g = 0x3a, .b = 0x44, .a = 0xff } });
        }

        // simple system indicators (mock)
        dvui.label(@src(), "󰕾  78%  󰂀  42%  󰖩", .{}, .{
            .font = dvui.Font.theme(.body).withSize(12),
            .color_text = dvui.Color{ .r = 0xb8, .g = 0xb8, .b = 0xc8, .a = 0xff },
            .margin = dvui.Rect.all(6),
        });

        _ = dvui.separator(@src(), .{ .expand = .vertical, .min_size_content = .{ .w = 1, .h = 24 }, .margin = dvui.Rect.all(6), .color_fill = dvui.Color{ .r = 0x3a, .g = 0x3a, .b = 0x44, .a = 0xff } });

        // clock
        dvui.labelNoFmt(@src(), state.clockSlice(), .{}, .{
            .font = dvui.Font.theme(.body).withSize(12),
            .margin = dvui.Rect.all(4),
        });

        // connection dot + status
        const dot_color: dvui.Color = if (state.connected) dvui.Color{ .r = 0x3d, .g = 0xd6, .b = 0x88, .a = 0xff } else dvui.Color{ .r = 0xe8, .g = 0x57, .b = 0x57, .a = 0xff };
        const dot_char: []const u8 = if (state.connected) "●" else "○";
        dvui.label(@src(), "{s}", .{dot_char}, .{ .color_text = dot_color, .font = dvui.Font.theme(.body).withSize(13), .margin = dvui.Rect.all(4) });

        // power / close indicator (click to close focused window as demo)
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
