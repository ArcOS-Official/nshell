const std = @import("std");
const dvui = @import("dvui");
const ls = @import("layershell");
const State = @import("State.zig");
const HubUi = @import("HubUi.zig");
const Icons = @import("Icons.zig");

pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

var state: State = undefined;
var hub_ui: HubUi = undefined;

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

// Authoritative hub keyboard (input) focus now comes from the compositor:
// nile broadcasts `shell_focus_changed` on every focus edge (plus once
// after each `shell_register` so reconnects converge), and State's worker
// thread stores it straight into HubUi.hub_keyboard_focused via the
// bindHubFocus pointer below. No SDL polling here: dvui's SDL backend
// consumes FOCUS_GAINED/LOST for accesskit and never surfaces them as
// dvui events, and the window flag can race the compositor (focus granted
// after a panel-open request arrives a frame later, reading as a loss).

const LayerShellWindow = @typeInfo(@TypeOf(ls.initWindow)).@"fn".return_type.?;

var win_hub_g: *dvui.Window = undefined;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    // HubUi owns all hub state now (see HubUi.zig); main keeps only the
    // windows, backends, and shared pump.

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
    hub_ui = HubUi.init();

    try state.initWithWakeup(gpa, io, &win_bar, &requestDvuiRefresh);
    defer state.deinit();
    // Worker-driven focus: compositor pushes store straight into the hub
    // flag (see State.bindHubFocus). Must precede the worker spawn below.
    state.bindHubFocus(&hub_ui.hub_keyboard_focused);
    // Populate launcher list (uses arena alloc, non-fatal if dirs missing).
    state.launcher.loadList(init) catch |e| std.log.warn("launcher load: {s}", .{@errorName(e)});

    // Worker after init (it spins until `inited`), cancelled before deinit
    // frees the model: LIFO defers run cancel first.
    var a = io.async(State.worker, .{ &state, io });
    defer a.cancel(io);

    var ref = io.async(struct {
        pub fn refresh(io_: std.Io) void {
            while (true) {
                // Fallback wakeup on the shared Net cadence: worker pushes
                // already wake the loop on change, but snapshots also need
                // to flow (and spinners/animations need frames) when
                // nothing pushes. Matches HubUi's steady panel timer.
                io_.sleep(.fromMilliseconds(@intCast(State.Net.refresh_ms)), .awake) catch {
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
            _ = try hub_ui.hubFrame(&state, io, ctx_hub.waylandCtx, &win_hub);
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

// The bar button only arms the toggle; HubUi.toggleNetworkMenu runs at
// the top of the next hubFrame (hub window context) so the resize
// animation registers on the right window. See HubUi.net_toggle_pending.
fn toggleNetworkMenu() void {
    hub_ui.net_toggle_pending = true;
}

fn frame() !dvui.App.Result {
    state.update();

    var t = &dvui.currentWindow().theme;

    // Scale knob for the bar: workspace numbers set the type size, and icon
    // glyphs render at the same size (see icon_px below).
    const num_font = t.font_mono.withWeight(.bold).withSize(11.0);
    const icon_px: f32 = num_font.size*2;

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
                .font = num_font,
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

        const nst = state.net.status();
        // One comptime call per icon (not a runtime-selected enum): tabler
        // embeds only referenced icons, so the selection stays explicit.
        // Aliased 1-bit raster (see Icons): rasterize at the display size,
        // show 1:1 with nearest sampling.
        const net_crisp: ?Icons.Crisp = if (nst.eth_up)
            Icons.iconPx(.network, icon_px, .white) catch null
        else if (nst.wifi_on)
            Icons.iconPx(.wifi, icon_px, .white) catch null
        else
            Icons.iconPx(.wifi_off, icon_px, .white) catch null;

        // Manual button composition (mirrors dvui.buttonIcon): the 32px box
        // keeps the hit area, but the glyph renders at icon_px so it tracks
        // the workspace number size instead of filling the button.
        var nbtn: dvui.ButtonWidget = undefined;
        nbtn.init(@src(), .{
            .draw_focus = false,
        }, .{
            .color_fill = t.color(.content, .fill),
            .corners = .all(10),
            .padding = .all(0),
            .min_size_content = .{ .w = 32, .h = 32 },
            .max_size_content = .{ .w = 32, .h = 32 },
            .gravity_y = 0.5,
        });
        defer nbtn.deinit();
        nbtn.processEvents();
        nbtn.drawBackground();
        if (net_crisp) |c| {
            _ = dvui.image(@src(), Icons.pixelImage(c), .{
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = icon_px, .h = icon_px },
                .expand = .none,
            });
        }
        if (nbtn.clicked()) toggleNetworkMenu();
        nbtn.drawFocus();
    }

    return .ok;
}
