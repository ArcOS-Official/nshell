const std = @import("std");
const dvui = @import("dvui");
const ls = @import("layershell");
const State = @import("State.zig");

pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

const Ui = struct {
    hubmode: HubMode = .clock,

    pub const HubMode = enum {
        clock,
        wifi,
        windows,
        launcher,
        search,
    };
};

var state: State = undefined;
var ui: Ui = undefined;

// Worker -> GUI wakeup: runs on the worker thread every time a snapshot is
// pushed into the inbox. Forwards to dvui.refresh(window), which pushes an
// SDL user event that interrupts the backend's waitEventTimeout so the next
// frame (which drains the inbox in frame()) happens immediately instead of
// waiting for the next input event. Waking either window is enough: one loop
// iteration redraws both.
fn requestDvuiRefresh(ctx: ?*anyopaque) void {
    if (ctx) |c| {
        const win: *dvui.Window = @ptrCast(@alignCast(c));
        dvui.refresh(win, @src(), null);
    }
}

// Single shared pump for both layer-shell windows. SDL owns one process-wide
// event queue, so one pump must serve all windows: dispatch by target window.
// App-level quit has no target: mirror it to both windows so they share one
// lifetime (otherwise only the bar would close and the hub surface would
// linger with its last frame). Other target-less events (e.g. the refresh
// wakeup) go to the bar, matching the backend's "global events are managed
// by the primary window" convention.
fn pumpEvents(backend_bar: anytype, win_bar: anytype, backend_hub: anytype, win_hub: anytype) !void {
    // Backends arrive as pointers; decl access needs the struct type.
    const C = @TypeOf(backend_bar.*).c;
    var ev: C.SDL_Event = undefined;
    while (C.SDL_PollEvent(&ev)) {
        if (ev.type == C.SDL_EVENT_QUIT) {
            _ = try backend_bar.addEvent(win_bar, ev);
            _ = try backend_hub.addEvent(win_hub, ev);
            continue;
        }
        const target = C.SDL_GetWindowFromEvent(&ev);
        if (target == null or target == backend_bar.window) {
            _ = try backend_bar.addEvent(win_bar, ev);
        } else if (target == backend_hub.window) {
            _ = try backend_hub.addEvent(win_hub, ev);
        } else {
            _ = try backend_bar.addEvent(win_bar, ev);
        }
    }
}

var win_hub_g: *dvui.Window = undefined;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    ui = .{};

    // Bar surface. Values carried over from the old dvui_app/layer_shell_opts.
    var ctx_bar = try ls.initWindow(.{
        .io = io,
        .environ_map = init.environ_map,
        .size = .{ .w = 0, .h = 50.0 },
        .title = "nshell - Nile bar",
        .transparent = true,
        .vsync = true,
    }, .{
        .anchors = .{ .top, .left, .right, null },
        .padding = .{ 4, 6, 6, 8 },
        .layer = .top,
        .exclusive_zone = 50,
        .namespace = "nshell",
    }, gpa);
    var backend_bar = ctx_bar.backend;
    defer backend_bar.deinit();
    defer ctx_bar.waylandCtx.deinit(gpa);

    // Hub surface: centered overlay with its own namespace. Always open.
    var ctx_hub = try ls.initWindow(.{
        .io = io,
        .environ_map = init.environ_map,
        .size = .{ .w = 150, .h = 50.0 },
        .title = "hub",
        .transparent = true,
        .persist_window_geometry = false,
        .vsync = true,
    }, .{
        .layer = .overlay,
        .namespace = "nshell-hub",
        .center = .horizontal,
        .anchors = .{ .top, null, null, null },
        .padding = .{ 4, 0, 0, 0 },
    }, gpa);
    var backend_hub = ctx_hub.backend;
    // Only the bar backend quits SDL; the hub only destroys its own
    // window/renderer (same convention as secondary os windows).
    backend_hub.sdl_quit = false;
    defer backend_hub.deinit();
    defer ctx_hub.waylandCtx.deinit(gpa);

    const C = @TypeOf(backend_bar).c;
    _ = C.SDL_EnableScreenSaver();

    // Transparent panels: keep the window fill transparent so per-pixel alpha
    // isn't overdrawn (same handling as the library's App path).
    var theme = dvui.Theme.builtin.adwaita_dark;
    theme.window.fill = .transparent;

    var bar_open = true;
    var win_bar = try dvui.Window.init(@src(), gpa, backend_bar.backend(), .{
        .theme = theme,
    });
    win_bar.open_flag = &bar_open;
    defer win_bar.deinit();

    var hub_open = true;
    var win_hub = try dvui.Window.init(@src(), gpa, backend_hub.backend(), .{
        .theme = theme,
    });
    win_hub_g = &win_hub;
    win_hub.open_flag = &hub_open;
    defer win_hub.deinit();

    try state.initWithWakeup(&win_bar, &requestDvuiRefresh);
    defer state.deinit();

    var ref = io.async(struct{
        pub fn refresh(io_: std.Io) void {
            while (true) {
                io_.sleep(.fromSeconds(1), .awake) catch {
                    return;
                };
                dvui.refresh(win_hub_g, @src(), null);
            }
        }
    }.refresh, .{io});
    defer ref.cancel(io);

    var interrupted = false;
    // Single app lifetime: closing either window tears down both surfaces.
    // (Per-window lifetimes would leave the other layer surface mapped with
    // a frozen last frame after this function returns one window's defers.)
    while (bar_open and hub_open) {
        if (ctx_bar.waylandCtx.should_close or ctx_hub.waylandCtx.should_close) break;

        const t_bar = if (bar_open) win_bar.beginWait(interrupted) else 0;
        const t_hub = if (hub_open) win_hub.beginWait(interrupted) else 0;

        try pumpEvents(&backend_bar, &win_bar, &backend_hub, &win_hub);

        var end_bar: ?u32 = null;
        if (bar_open) {
            try win_bar.begin(t_bar);
            _ = try frame();
            end_bar = try win_bar.end(.{});
        }

        var end_hub: ?u32 = null;
        if (hub_open) {
            try win_hub.begin(t_hub);
            _ = try hubFrame();
            end_hub = try win_hub.end(.{});
        }

        if (!bar_open or !hub_open) break;

        const wait_bar = if (bar_open) win_bar.waitTime(end_bar) else std.math.maxInt(u32);
        const wait_hub = if (hub_open) win_hub.waitTime(end_hub) else std.math.maxInt(u32);
        interrupted = try backend_bar.waitEventTimeout(@min(wait_bar, wait_hub));
    }
    return 0;
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
                .min_size_content = .{ .h = 48.0, .w = (32 * 9) + (6 * 7) },
                .padding = .fromSize(.{ .w = 4 }),
                .gravity_y = 0.5,
            },
        );
        defer left.deinit();

        for (state.workspaces, 0..) |w, i| {
            var btn: dvui.ButtonWidget = undefined;
            btn.init(@src(), .{}, .{
                .background = true,
                .color_fill = if (w.current)
                    t.color(.highlight, .fill)
                else
                    t.color(.content, .fill).lighten(10),
                .color_fill_hover = if (w.current)
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
            dvui.labelNoFmt(@src(), &.{'0' + w.number}, .{
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
                .min_size_content = .{ .h = 48.0, .w = (32 * 9) + (6 * 7) },
                .padding = .fromSize(.{ .w = 4 }),
                .gravity_y = 0.5,
            },
        );
        defer right.deinit();
    }

    return .ok;
}

pub fn hubFrame() !dvui.App.Result {
    var t = &dvui.currentWindow().theme;
    const outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = t.color(.content, .fill),
        .color_border = t.color(.content, .text).opacity(0.15),
        .border = .all(1),
        .corners = .all(10),
        .padding = .fromSize(.{ .w = 4 }),
        .gravity_y = 0.0,
    });
    defer outer.deinit();

    switch (ui.hubmode) {
        .clock => {
            const ts = std.Io.Clock.real.now(state.io);
            const s = ts.toSeconds();
            const stamp = std.time.epoch.EpochSeconds{ .secs = @intCast(s) };
            const ds = stamp.getDaySeconds();
            const d = stamp.getEpochDay();
            const dy = d.calculateYearDay();
            const txt = try std.fmt.allocPrint(state.alloc, "{}:{}:{}", .{
                ds.getHoursIntoDay(),
                ds.getMinutesIntoHour(),
                ds.getSecondsIntoMinute(),
            });
            defer state.alloc.free(txt);
            dvui.labelNoFmt(
                @src(),
                txt,
                .{ .align_y = 0.5, .align_x = 0.5 },
                .{
                    .expand = .both,
                    .font = t.font_mono.withWeight(.bold).withSize(12.0),
                    .padding = .{ .y = 6 },
                },
            );
            const dw = [_][]const u8{
                "Thursday",
                "Wednesday",
                "Firday",
                "Saturday",
                "Sunday",
                "Monday",
            };
            const ms = [_][]const u8{
                "Jan",
                "Feb",
                "Mar",
                "Apr",
                "May",
                "Jun",
                "Jul",
                "Aug",
                "Sep",
                "Oct",
                "Nov",
                "Dec",
            };
            const dname = dw[@as(usize, @intCast(@divFloor(s, 86400))) % 7];
            const dm = dy.calculateMonthDay();
            const txt_ = try std.fmt.allocPrint(state.alloc, "{s}, {s} {}", .{
                dname,
                ms[dm.month.numeric()],
                dm.day_index,
            });
            defer state.alloc.free(txt_);
            dvui.labelNoFmt(
                @src(),
                txt_,
                .{ .align_y = 0.5, .align_x = 0.5 },
                .{
                    .expand = .both,
                    .font = t.font_mono.withSize(8.0),
                    .padding = .{ .h = 6 },
                },
            );
        },
        else => {},
    }

    return .ok;
}
