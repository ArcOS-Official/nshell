const std = @import("std");
const dvui = @import("dvui");
const ls = @import("layershell");
const State = @import("State.zig");

pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

const Ui = struct {
    hubmode: HubMode = .clock,
    last_hubmode: HubMode = .clock,
    anim_id: dvui.Id = undefined,
    hub_was_hovered: bool = false,
    // Set when the switcher opens; hubFrame hands keyboard focus to the
    // selected button once so Tab/Enter work without a first Tab press.
    windows_need_focus: bool = false,
    launcher_need_focus: bool = false,

    pub const HubMode = enum {
        clock,
        wifi,
        windows,
        launcher,
        search,
    };

    pub fn init() Ui {
        return .{
            .anim_id = .extendId(null, @src(), 0),
        };
    }

    pub fn switchMode(self: *Ui, mode: HubMode) void {
        if (mode == .windows) {
            if (state.windows.len == 0)
                return;
            // Warm every thumbnail in one round trip so the switcher fills
            // together instead of one capture per frame.
            state.prefetchWindowImages();
            if (self.hubmode != .windows) {
                // Fresh open: start at the MRU head (index 0 is the focused
                // window; State keeps the list in MRU order) and hand it
                // keyboard focus so Tab/Enter work immediately.
                selected = 0;
                self.windows_need_focus = true;
            }
        }
        if (mode == .launcher) {
            if (self.hubmode != .launcher) {
                self.launcher_need_focus = true;
                self.last_hubmode = self.hubmode;
            }
        }
        // Remember where we came from so Esc/launcher close returns.
        if (mode != .launcher and mode != .windows and self.hubmode == .launcher) {
            // leaving launcher keeps last_hubmode as is
        } else if (mode != .windows and mode != .launcher) {
            self.last_hubmode = mode;
        }
        self.hubmode = mode;
        setTarget(switch (mode) {
            .windows => .{ .w = 600, .h = 120 },
            .launcher => .{ .w = 520, .h = 360 },
            .clock => .{ .w = 150, .h = 50 },
            else => .{ .w = 480, .h = 180 },
        });
    }
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
        // dvui's SDL backend consumes FOCUS_GAINED/LOST for accesskit only
        // and never surfaces them as dvui events, so track the hub's OS
        // keyboard (input) focus ourselves for the switcher dismiss check.
        if (ev.type == C.SDL_EVENT_WINDOW_FOCUS_GAINED or ev.type == C.SDL_EVENT_WINDOW_FOCUS_LOST) {
            if (C.SDL_GetWindowFromEvent(&ev) == backend_hub.window) {
                hub_keyboard_focused = ev.type == C.SDL_EVENT_WINDOW_FOCUS_GAINED;
            }
        }
        const t_ = C.SDL_GetWindowFromEvent(&ev);
        if (t_ == null or t_ == backend_bar.window) {
            _ = try backend_bar.addEvent(win_bar, ev);
        } else if (t_ == backend_hub.window) {
            _ = try backend_hub.addEvent(win_hub, ev);
        } else {
            _ = try backend_bar.addEvent(win_bar, ev);
        }
    }
}

const LayerShellWindow = @typeInfo(@TypeOf(ls.initWindow)).@"fn".return_type.?;

var win_hub_g: *dvui.Window = undefined;
var ctx_hub_g: *ls.WaylandContextType = undefined;

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
        .namespace = State.shell_namespace,
        .center = .horizontal,
        .anchors = .{ .top, null, null, null },
        .padding = .{ 4, 0, 0, 0 },
    }, gpa);
    ctx_hub_g = ctx_hub.waylandCtx;
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
    ui = .init();

    try state.initWithWakeup(gpa, io, &win_bar, &requestDvuiRefresh);
    defer state.deinit();
    // Populate launcher list (uses arena alloc, non-fatal if dirs missing).
    state.launcher.loadList(init) catch |e| std.log.warn("launcher load: {s}", .{@errorName(e)});

    // Worker after init (it spins until `inited`), cancelled before deinit
    // frees the model: LIFO defers run cancel first.
    var a = io.async(State.worker, .{ &state, io });
    defer a.cancel(io);

    var ref = io.async(struct {
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
    state.update();

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

// Hub resize state. `hub_cur` animates `hub_from -> hub_target` and drives
// the content box; the layer-shell surface jumps exactly once per
// transition: pre-grow (room first, so growing content never clips) or
// post-shrink (content shrinks first, so the window never snaps smaller
// underneath it). Animation id is `ui.anim_id` (stable), not a widget id.
var hub_from: dvui.Size = .{ .w = 150, .h = 50 };
var hub_target: ?dvui.Size = null;
var hub_cur: dvui.Size = .{ .w = 150, .h = 50 };
var hub_surfaced: dvui.Size = .{ .w = 150, .h = 50 };
var selected: usize = 0;
// Whether the hub layer surface currently holds OS keyboard (input)
// focus. Updated in pumpEvents from raw SDL focus events. Defaults to
// true so the switcher doesn't instantly dismiss before the first focus
// event arrives (e.g. on compositors that never focus the overlay).
var hub_keyboard_focused: bool = true;
// Previous frame's state.launcher_open: hubFrame edge-detects on the
// compositor's launcher pushes to open/activate the switcher.
var launcher_was_open: bool = false;

fn setTarget(t: dvui.Size) void {
    // No-op if already there / already heading there (kills click-spam
    // restarts and mid-animation no-ops).
    if (hub_target) |ta| {
        if (ta.w == t.w and ta.h == t.h) return;
    } else if (hub_cur.w == t.w and hub_cur.h == t.h) {
        return;
    }
    hub_target = t;
    hub_from = hub_cur;
    dvui.animation(ui.anim_id, "hubsize", .{
        .easing = dvui.easing.outQuart,
        .end_time = 0.4 * std.time.us_per_s, // micros; dvui.Animation runs on microsecond time
    });
}

// Push a surface resize once; logical units (the backend forwards to both
// the layer surface and SDL, so no manual content-scale multiply here).
fn pushHubSurface(t: dvui.Size) void {
    if (hub_surfaced.w == t.w and hub_surfaced.h == t.h) return;
    hub_surfaced = t;
    ctx_hub_g.setSize(
        @as(u32, @intFromFloat(@round(t.w))),
        @as(u32, @intFromFloat(@round(t.h))),
    );
}

pub fn hubFrame() !dvui.App.Result {
    var t = &dvui.currentWindow().theme;
    const base = t.color(.content, .fill);

    // Advance the animated content size. Snaps on done/expiry so float
    // rounding can never stall one step away from the target.
    const hub_anim = dvui.animationGet(ui.anim_id, "hubsize");
    if (hub_target) |ta| {
        if (hub_anim) |a| {
            hub_cur.w = std.math.lerp(hub_from.w, ta.w, a.value());
            hub_cur.h = std.math.lerp(hub_from.h, ta.h, a.value());
            if (a.done()) hub_cur = ta;
        } else {
            hub_cur = ta;
        }
    }

    // Sync the surface once per transition.
    if (hub_target) |ta| {
        const expanding = ta.w > hub_from.w or ta.h > hub_from.h;
        const done = hub_anim == null or hub_anim.?.done();
        if (expanding) {
            pushHubSurface(ta); // pre-resize
            if (done) {
                hub_target = null;
                hub_from = ta;
            }
        } else if (done) {
            hub_cur = ta;
            pushHubSurface(ta); // post-resize
            hub_target = null;
            hub_from = ta;
        }
    }

    const outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = hub_cur,
        .max_size_content = .size(hub_cur),
        .background = true,
        .color_fill = base,
        .color_border = t.color(.content, .text).opacity(0.15),
        .border = .all(1),
        .corners = .all(10),
        .padding = .fromSize(.{ .w = 4 }),
        .gravity_y = 0.0,
        .gravity_x = 0.5,
    });
    defer outer.deinit();

    if (state.launcher_open and ui.hubmode != .windows) {
        // Compositor MOD press (nile focuses this surface and pushes
        // launcher_opened): open the switcher. nshell never learns which
        // key MOD is — this level is the only MOD-derived signal consumed.
        ui.switchMode(.windows);
    } else if (!state.launcher_open and launcher_was_open and ui.hubmode == .windows) {
        // Compositor MOD release: activate the selection, then dismiss.
        // Runs before the focus-loss dismiss below so the selection isn't
        // lost when focus snaps back to the window in the same iteration.
        if (selected < state.windows.len) state.focusWindow(state.windows[selected].id);
        ui.switchMode(ui.last_hubmode);
    }
    launcher_was_open = state.launcher_open;

    // Local Tab-to-open, matched by keycode with modifiers ignored (there
    // is no "tab" dvui bind, so matchBind can never fire for it): covers
    // testing without a compositor and any focused-hub Tab press. With MOD
    // held this still fires, so MOD+Tab opens without any MOD knowledge.
    // In-switcher Tab cycling needs nothing here — dvui moves widget focus
    // on Tab/Shift+Tab via next_widget/prev_widget, which ignore MOD.
    for (dvui.events()) |ev| {
        if (ev.evt == .key and ev.evt.key.code == .tab and ev.evt.key.action == .down) {
            if (ui.hubmode != .windows) {
                ui.switchMode(.windows);
                selected += 1;
            }
            break;
        }
        // Manual launcher trigger for demo (no compositor MOD needed):
        // '/' or Ctrl+P opens the app launcher that demos Launcher.search flow.
        if (ev.evt == .key and ev.evt.key.action == .down) {
            if (ev.evt.key.code == .slash or ev.evt.key.code == .p) {
                if (ui.hubmode != .launcher) {
                    ui.switchMode(.launcher);
                    break;
                }
            }
        }
    }

    switch (ui.hubmode) {
        .clock => {
            var hover = false;
            defer ui.hub_was_hovered = hover;
            const clicked = dvui.clicked(outer.data(), .{
                .hovered = &hover,
                .hover_cursor = .arrow,
            });
            if (hover and !ui.hub_was_hovered) {
                dvui.animation(outer.data().id, "hover", .{
                    .easing = dvui.easing.outExpo,
                    .end_time = @floor(std.time.us_per_s * 0.2),
                });
            }
            if (!hover and ui.hub_was_hovered) {
                dvui.animation(outer.data().id, "hover", .{
                    .easing = dvui.easing.outExpo,
                    .end_time = @floor(std.time.us_per_s * 0.2),
                    .start_val = 1.0,
                    .end_val = 0.0,
                });
            }

            if (dvui.animationGet(outer.data().id, "hover")) |a| {
                outer.data().options.color_fill = base.lighten(10 * a.value());
                outer.data().options.color_border = .transparent;
                outer.drawBackground();
            } else if (hover) {
                outer.data().options.color_fill = base.lighten(10);
                outer.data().options.color_border = .transparent;
                outer.drawBackground();
            }

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
                    .color_text = t.color(.highlight, .fill).lighten(5),
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
            // second click opens launcher demo
            if (clicked) {
                // Left click on clock cycles windows; right-click or extra button opens launcher
                ui.switchMode(.windows);
            }
            // Small launcher button below clock
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 0.5 });
                defer row.deinit();
                if (dvui.button(@src(), "Launcher  \u{2318}P / /", .{}, .{ .min_size_content = .{ .h = 18 } })) {
                    ui.switchMode(.launcher);
                }
            }
        },
        .windows => {
            const list = dvui.flexbox(
                @src(),
                .{ .justify_content = .center },
                .{
                    .background = false,
                    .expand = .both,
                },
            );
            defer list.deinit();

            // Dismiss the switcher when the hub surface loses OS keyboard
            // (input) focus to another surface.
            if (!hub_keyboard_focused) {
                state.focusWindow(state.windows[selected].id);
                ui.switchMode(ui.last_hubmode);
            }
            // Esc dismisses without activating.
            for (dvui.events()) |ev| {
                if (ev.evt == .key and ev.evt.key.code == .escape and ev.evt.key.action == .down) {
                    ui.switchMode(ui.last_hubmode);
                    break;
                }
            }
            if (selected >= state.windows.len) selected = 0;
            // Keyboard focus drives the selection; mouse hover is the
            // fallback for mouse-only use. dvui moves widget focus on
            // Tab/Shift+Tab via its built-in next_widget/prev_widget binds,
            // so no manual tab handling is needed here.
            var focused_idx: ?usize = null;
            var hovered_idx: ?usize = null;
            for (state.windows, 0..) |w, i| {
                const c = if (i == selected)
                    base.lighten(10.0)
                else if (w.focused)
                    t.color(.highlight, .fill).lighten(-15.0)
                else
                    base;
                var btn: dvui.ButtonWidget = undefined;
                btn.init(@src(), .{}, .{
                    .color_fill = c,
                    .expand = .ratio,
                    .max_size_content = .{ .w = 100, .h = 100 },
                    .min_size_content = .{ .w = 60, .h = 60 },
                    .id_extra = i,
                });
                btn.processEvents();
                btn.drawBackground();
                defer btn.deinit();
                if (btn.focused()) {
                    focused_idx = i;
                }
                if (btn.hovered()) {
                    hovered_idx = i;
                }
                if (ui.windows_need_focus and i == selected) {
                    dvui.focusWidget(btn.data().id, null, null);
                    focused_idx = i;
                }
                if (btn.clicked()) {
                    state.focusWindow(w.id);
                    ui.switchMode(ui.last_hubmode);
                }
                var box = dvui.box(
                    @src(),
                    .{ .dir = .vertical, .equal_space = true },
                    .{
                        .background = false,
                        .expand = .both,
                    },
                );
                defer box.deinit();
                // Thumbnail once the async capture lands; the generic icon
                // while it is still loading (windowImage returns null).
                if (state.windowImage(w.id)) |src| {
                    _ = dvui.image(@src(), .{
                        .shrink = .ratio,
                        .source = src,
                    }, .{
                        .expand = .both,
                        .padding = .{ .y = 10 },
                        .gravity_x = 0.5,
                    });
                } else {
                    _ = dvui.icon(@src(), "window", dvui.entypo.image, .{}, .{
                        .expand = .both,
                        .padding = .{ .y = 10 },
                        .gravity_x = 0.5,
                    });
                }
                dvui.labelNoFmt(@src(), w.title, .{
                    .align_x = 0.5,
                    .align_y = 0.5,
                }, .{
                    .font = t.font_title,
                    .expand = .horizontal,
                });
            }
            ui.windows_need_focus = false;
            if (focused_idx) |f| {
                selected = f;
            } else if (hovered_idx) |h| {
                selected = h;
            }
        },
        .launcher => {
            // Example launcher that demos the async search flow:
            // UI thread calls `state.launcher.search(term)` which returns
            // cached results immediately or null + enqueues term.
            // State worker's `launcher.tick()` materializes results
            // concurrently, then wakes the GUI.
            var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .both,
                .background = false,
                .padding = .all(4),
            });
            defer vbox.deinit();

            const q = blk: {
                var te = dvui.textEntry(@src(), .{
                    .placeholder = "Type app name… (name > description > category > command)",
                }, .{
                    .expand = .horizontal,
                });
                defer te.deinit();
                if (ui.launcher_need_focus) {
                    dvui.focusWidget(te.data().id, null, null);
                    ui.launcher_need_focus = false;
                }
                break :blk te.getText();
            };

            // Enqueue + fetch (null while pending).
            const results = state.launcher.search(q);

            // ESC dismisses launcher, Enter launches top hit
            for (dvui.events()) |ev| {
                if (ev.evt == .key and ev.evt.key.code == .escape and ev.evt.key.action == .down) {
                    ui.switchMode(ui.last_hubmode);
                    break;
                }
                if (ev.evt == .key and ev.evt.key.code == .enter and ev.evt.key.action == .down) {
                    if (results) |apps| {
                        if (apps.len > 0) {
                            var idx: usize = 0;
                            for (state.launcher.data.items, 0..) |*a, j| if (a == apps[0]) {
                                idx = j;
                                break;
                            };
                            state.launcher.run(idx);
                            ui.switchMode(ui.last_hubmode);
                        }
                    }
                }
            }

            var scroll = dvui.scrollArea(@src(), .{}, .{
                .expand = .both,
                .background = false,
                .padding = .all(2),
            });
            defer scroll.deinit();

            if (results) |apps| {
                if (apps.len == 0) {
                    if (q.len == 0) {
                        dvui.labelNoFmt(@src(), "No apps loaded", .{}, .{ .color_text = t.color(.content, .text).opacity(0.6) });
                    } else {
                        dvui.labelNoFmt(@src(), "No results", .{}, .{ .color_text = t.color(.content, .text).opacity(0.6) });
                    }
                } else {
                    for (apps, 0..) |app, i| {
                        var btn: dvui.ButtonWidget = undefined;
                        btn.init(@src(), .{}, .{
                            .expand = .horizontal,
                            .background = true,
                            .color_fill = base,
                            .color_fill_hover = base.lighten(5),
                            .border = .all(1),
                            .color_border = t.color(.content, .text).opacity(0.08),
                            .corners = .all(6),
                            .padding = .all(6),
                            .margin = .{ .y = 2, .x = 2 },
                            .id_extra = i,
                        });
                        btn.processEvents();
                        btn.drawBackground();
                        defer btn.deinit();
                        if (btn.clicked()) {
                            var idx: usize = 0;
                            for (state.launcher.data.items, 0..) |*a, j| if (a == app) {
                                idx = j;
                                break;
                            };
                            state.launcher.run(idx);
                            ui.switchMode(ui.last_hubmode);
                        }
                        var row2 = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false });
                        defer row2.deinit();
                        dvui.labelNoFmt(@src(), app.name, .{}, .{ .font = t.font_title.withSize(11) });
                        var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
                        defer meta.deinit();
                        if (app.comment) |c| {
                            dvui.labelNoFmt(@src(), c, .{}, .{ .font = t.font_body.withSize(9), .color_text = t.color(.content, .text).opacity(0.6) });
                        } else if (app.generic_name) |g| {
                            dvui.labelNoFmt(@src(), g, .{}, .{ .font = t.font_body.withSize(9), .color_text = t.color(.content, .text).opacity(0.6) });
                        }
                        if (app.categories) |cats| {
                            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 } });
                            dvui.labelNoFmt(@src(), cats, .{}, .{ .font = t.font_body.withSize(8), .color_text = t.color(.highlight, .fill) });
                        }
                        if (app.exec) |e| {
                            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 } });
                            dvui.labelNoFmt(@src(), e, .{}, .{ .font = t.font_mono.withSize(8), .color_text = t.color(.content, .text).opacity(0.45) });
                        }
                    }
                }
            } else {
                dvui.labelNoFmt(@src(), if (q.len == 0) "Type to search…" else "Searching…", .{}, .{ .color_text = t.color(.content, .text).opacity(0.6) });
            }
        },
        .search => ui.switchMode(.launcher),
        .wifi => ui.switchMode(.clock),
    }

    return .ok;
}
