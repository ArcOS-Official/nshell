const std = @import("std");
const dvui = @import("dvui");
const Icons = @import("Icons.zig");
const AlignedEntry = @import("AlignedEntry.zig");
const State = @import("State.zig");

hubmode: HubMode = .clock,
last_hubmode: HubMode = .clock,
anim_id: dvui.Id = undefined,
hub_was_hovered: bool = false,
windows_need_focus: bool = false,
launcher_need_focus: bool = false,

hub_from: dvui.Size = .{ .w = 150, .h = 50 },
hub_target: ?dvui.Size = null,
hub_cur: dvui.Size = .{ .w = 150, .h = 50 },
hub_surfaced: dvui.Size = .{ .w = 150, .h = 50 },

switcher_pending: bool = false,
switcher_armed_ms: u64 = 0,
selected: usize = 0,

hub_keyboard_focused: bool = true,
hub_prev_keyboard_focused: bool = true,

launcher_query: []const u8 = "",

net_sel: ?u64 = null,
net_sel_open: bool = false,
net_need_focus: bool = false,
// In-flight connect/disconnect request + the AP row it belongs to (an
// ApView.id, 0 = none). The row shows "Connecting…" while pending and
// the daemon's last_error under that row on failure.
net_req: ?State.Net.Request = null,
net_req_ap: u64 = 0,
// Row resize animation: the AP that was displayed open when the latest
// toggle started (null = none) + start ms. Heights lerp 38<->72 on the
// hub curve at 75% of hub time (see net_anim_ms). Shared clock covers
// both the collapsing and the expanding row on a selection swap.
net_anim_open_ap: ?u64 = null,
net_anim_start: u64 = 0,
// MRU head window id when the network panel opened (0 = none/empty).
// If it changes, the user focused an app elsewhere: close the panel.
net_open_win: u64 = 0,
// Error display clock: frames since the current error appeared (drives
// the red flash schedule) + ms timestamp (drives the 5s auto-dismiss).
net_err_frame: u32 = 0,
net_err_since: u64 = 0,
// Wrong-password reject animation for the open row's password entry:
// start ms (0 = idle). While `now - start < net_reject_ms` the entry
// wiggles horizontally and its focus outline draws red; the entry also
// re-arms for typing (saved-password graying is bypassed until edited
// again). Stamped when a connect request on this row fails.
net_reject_since: u64 = 0,
net_reject_ap: u64 = 0,
// Last ms timestamp the open network panel asked the worker for fresh
// state (see the steady-timer block in hubFrame). Gates re-requests to
// the shared 750ms cadence even while fast-ticking for the spinner.
net_last_refresh: u64 = 0,
// Last applied keyboard-interactivity mode (null = never applied).
// hubFrame syncs it from hubmode, cached like pushHubSurface.
kb_exclusive: ?bool = null,
// Set alongside an explicit focusWindow so the clock-entry push below
// doesn't immediately override it with the (stale) MRU head.
suppress_clock_push: bool = false,

// Set by the bar window's network button; consumed at the top of the next
// hubFrame. switchMode must run in the hub window's context: dvui
// animations are stored per-window, so starting the resize from the bar
// frame registers it on the wrong window and the hub never sees it
// (clock -> network snapped instead of animating).
net_toggle_pending: bool = false,

off_start: u64 = 0,

const HubUi = @This();

pub const HubMode = enum {
    clock,
    network,
    windows,
    launcher,
    search,
};

pub const KeyAction = enum {
    down,
    repeat,
    up,
};

pub fn init() HubUi {
    return .{ .anim_id = .extendId(null, @src(), 0) };
}

pub fn switchMode(self: *HubUi, mode: HubMode, state: *State) void {
    self.off_start = @as(u64, @intCast(std.Io.Clock.real.now(state.io).toMilliseconds()));
    defer self.suppress_clock_push = false;
    if (mode == .clock and self.hubmode != .clock) {
        // Clock mode never holds keyboard focus: push it back to the
        // user's app. Windows stay in MRU focus order, so the head is
        // the last focused non-shell window (shell surfaces never enter
        // this list). Only when the hub actually holds focus — if focus
        // already moved elsewhere (click), there is nothing to push.
        // Skipped right after an explicit focusWindow (switcher), which
        // names its own target.
        if (!self.suppress_clock_push and self.hub_keyboard_focused and state.windows.len > 0) {
            state.focusWindow(state.windows[0].id);
        }
    }
    if (mode == .windows) {
        if (state.windows.len == 0)
            return;
        state.prefetchWindowImages();
        if (self.hubmode != .windows) {
            if (!self.switcher_pending) self.selectIndex(state, 0);
            self.windows_need_focus = true;
        }
    }
    if (mode == .launcher) {
        if (self.hubmode != .launcher) {
            self.launcher_need_focus = true;
            self.last_hubmode = self.hubmode;
        }
    }
    if (mode == .network) {
        if (self.hubmode != .network) {
            self.clearNetSel(state);
            self.net_need_focus = true;
            // Baseline for the focus-elsewhere detector: MRU head is the
            // focused app window (shell surfaces never enter the list).
            self.net_open_win = if (state.windows.len > 0) state.windows[0].id else 0;
            _ = state.net.refresh();
        }
    }
    if (mode != .launcher and mode != .windows and mode != .network and self.hubmode == .launcher) {
        // leaving launcher keeps last_hubmode as is
    } else if (mode != .windows and mode != .launcher and mode != .network) {
        self.last_hubmode = mode;
    }
    self.hubmode = mode;
    self.setTarget(switch (mode) {
        .windows => .{ .w = 600, .h = 120 },
        .launcher => .{ .w = 520, .h = 360 },
        .network => .{ .w = 520, .h = 420 },
        .clock => .{ .w = 150, .h = 50 },
        else => .{ .w = 480, .h = 180 },
    });
}

fn clearNetSel(self: *HubUi, state: *State) void {
    _ = state;
    self.net_sel = null;
    self.net_sel_open = false;
    self.net_req_ap = 0;
    self.net_reject_since = 0;
    self.net_reject_ap = 0;
}

pub fn handleNetworkKey(self: *HubUi, code: dvui.enums.Key, action: KeyAction, state: *State) bool {
    if (code == .escape and action == .down) {
        self.clearNetSel(state);
        self.switchMode(self.last_hubmode, state);
        return true;
    }
    return false;
}

// Frame-context key check: true when `code` went down in the current
// frame's event queue. Peeks without consuming, so widget handlers still
// see the event. For named keybinds prefer ke.matchBind; raw codes have
// no bind entries (dvui registers no "esc"/"escape" bind — escape must
// match by code, as handleNetworkKey does), hence this helper.
pub fn pressed(code: dvui.enums.Key) bool {
    for (dvui.events()) |ev| {
        if (ev.evt != .key) continue;
        const k = ev.evt.key;
        if (k.action == .down and k.code == code) return true;
    }
    return false;
}

// Bar-button entry point (deferred via net_toggle_pending so the mode
// switch — and its resize animation — runs in hub context).
pub fn toggleNetworkMenu(self: *HubUi, state: *State) void {
    if (self.hubmode == .network) {
        self.clearNetSel(state);
        self.switchMode(self.last_hubmode, state);
    } else {
        self.switchMode(.network, state);
        // Opening from the bar can coincide with the hub losing OS focus
        // (click moves focus to the bar surface). Swallow that edge so
        // updateSwitcher's focus-loss dismissal doesn't close the panel
        // on the same frame it opened; later edges still dismiss.
        self.hub_prev_keyboard_focused = self.hub_keyboard_focused;
    }
}

pub fn selectIndex(self: *HubUi, state: *State, idx: usize) void {
    if (state.windows.len == 0) {
        self.selected = 0;
        return;
    }
    self.selected = idx % state.windows.len;
}

pub fn selectNext(self: *HubUi, state: *State) void {
    self.selectIndex(state, self.selected + 1);
}

pub fn selectPrev(self: *HubUi, state: *State) void {
    if (state.windows.len == 0) {
        self.selected = 0;
        return;
    }
    self.selected = (self.selected + state.windows.len - 1) % state.windows.len;
}

pub fn commitSwitcherSelection(self: *HubUi, state: *State) void {
    if (state.windows.len == 0) return;
    if (self.selected >= state.windows.len) self.selectIndex(state, self.selected);
    state.focusWindow(state.windows[self.selected].id);
    // Names its own focus target: a clock entry right after this must
    // not override it with the stale MRU head (see switchMode).
    self.suppress_clock_push = true;
}

// Queue a NetworkManager connect for `ap` (activating a new connection
// implicitly swaps out whatever is active on the device) and track the
// request so the row can report progress/errors.
pub fn connectToAp(self: *HubUi, state: *State, dev_path: []const u8, ap: State.Net.ApView, password: []const u8) void {
    self.net_reject_since = 0;
    self.net_reject_ap = 0;
    self.net_req = state.net.connect(dev_path, ap.path, ap.ssid, password);
    self.net_req_ap = ap.id;
}

// Activate the stored NM profile for this AP: NM supplies the saved
// secret, so no password round-trip. Used when the row is in the
// "saved" state and the user hasn't typed an override.
pub fn connectToApSaved(self: *HubUi, state: *State, dev_path: []const u8, ap: State.Net.ApView) void {
    self.net_reject_since = 0;
    self.net_reject_ap = 0;
    self.net_req = state.net.connectSaved(dev_path, ap.path, ap.saved_path);
    self.net_req_ap = ap.id;
}

pub fn disconnectAp(self: *HubUi, state: *State, ap: State.Net.ApView) void {
    self.net_req = state.net.disconnect();
    self.net_req_ap = ap.id;
}

// Error flash schedule: 10-frame periods (5 red, 5 transparent),
// twice, then steady transparent.
pub fn errFlashRed(frame: u32) bool {
    return frame < 20 and frame % 10 < 5;
}

// Row expand/collapse animation: same curve as the hub resize
// (outQuart) at 75% of hub time (180ms -> 135ms).
pub const net_anim_ms: u64 = 135;
// Wrong-password wiggle duration (also bounds the red focus outline).
pub const net_reject_ms: u64 = 500;
// Open = 12 padding + 32 header + 28 controls; shut = 12 + 32. These
// must equal the natural heights, or the animation pin starts/ends
// with a jump that reads as overshoot.
const net_row_open_h: f32 = 72;
const net_row_shut_h: f32 = 44;

// Eased 0..1 progress on the shared resize clock: the hub curve
// (outQuart) at 75% of hub time. Drives row heights and the color
// fades that ride along with them.
pub fn animFrac(start_ms: u64, now_ms: u64) f32 {
    const el = now_ms -% start_ms;
    if (el >= net_anim_ms) return 1;
    return dvui.easing.outQuart(@as(f32, @floatFromInt(el)) / @as(f32, @floatFromInt(net_anim_ms)));
}

// macOS-style activity spinner: 12 thick spokes around a circle, lit
// head with fading tail, ~1 rev/sec. Generic over rect/color so the
// headless test builds (which never instantiate hubFrame) skip dvui
// drawing entirely.
fn drawSpinner(rs: anytype, now_ms: u64, color: anytype) void {
    if (rs.r.empty()) return;
    const r = rs.r;
    const s = rs.s;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    const rad = @min(r.w, r.h) / 2;
    const phase: usize = @as(usize, @intCast(now_ms / 80)) % 12;
    var k: usize = 0;
    while (k < 12) : (k += 1) {
        const a = @as(f32, @floatFromInt(k)) * std.math.pi / 6.0;
        const dx = @cos(a);
        const dy = @sin(a);
        var path = dvui.Path.Builder.init(dvui.currentWindow().lifo());
        defer path.deinit();
        path.addPoint(.{ .x = cx + dx * rad * 0.55, .y = cy + dy * rad * 0.55 });
        path.addPoint(.{ .x = cx + dx * rad * 0.92, .y = cy + dy * rad * 0.92 });
        const age = (phase + 12 - k) % 12;
        const alpha = 1.0 - @as(f32, @floatFromInt(age)) * (0.85 / 11.0);
        path.build().stroke(.{
            .thickness = rad * 0.30 * s,
            .color = color.opacity(alpha),
            .endcap_style = .square,
        });
    }
}

// Displayed height for one AP row. Rows shown open at the last toggle
// start from the open height, all others from shut; both converge on
// their target, so a selection swap animates both sides at once.
pub fn netRowHeight(self: *HubUi, ap_id: u64, open: bool, now_ms: u64) f32 {
    const target: f32 = if (open) net_row_open_h else net_row_shut_h;
    if (now_ms -% self.net_anim_start >= net_anim_ms) return target;
    const from: f32 = if (self.net_anim_open_ap != null and ap_id == self.net_anim_open_ap.?)
        net_row_open_h
    else
        net_row_shut_h;
    if (from == target) return target;
    return std.math.lerp(from, target, animFrac(self.net_anim_start, now_ms));
}

pub fn setTarget(self: *HubUi, t: dvui.Size) void {
    if (self.hub_target) |ta| {
        if (ta.w == t.w and ta.h == t.h) return;
    } else if (self.hub_cur.w == t.w and self.hub_cur.h == t.h) {
        return;
    }
    self.hub_target = t;
    self.hub_from = self.hub_cur;
    dvui.animation(self.anim_id, "hubsize", .{
        .easing = dvui.easing.outQuart,
        .end_time = 0.18 * std.time.us_per_s,
    });
}

pub fn pushHubSurface(self: *HubUi, t: dvui.Size, ctx_hub_g: anytype) void {
    if (self.hub_surfaced.w == t.w and self.hub_surfaced.h == t.h) return;
    self.hub_surfaced = t;
    ctx_hub_g.setSize(
        @as(u32, @intFromFloat(@round(t.w))),
        @as(u32, @intFromFloat(@round(t.h))),
    );
}

pub fn handleGlobalKey(self: *HubUi, code: dvui.enums.Key, action: KeyAction, shift: bool, now_ms: u64, state: *State) bool {
    const is_tab_down = code == .tab and action == .down;
    if (is_tab_down) {
        if (self.hubmode == .windows) {
            return false;
        }
        if (self.hub_keyboard_focused) {
            if (state.windows.len == 0) return false;
            if (shift) {
                self.selectPrev(state);
            } else {
                self.selectNext(state);
            }
            if (!self.switcher_pending) {
                self.switcher_pending = true;
                self.switcher_armed_ms = now_ms;
            }
            return true;
        }
    }
    if (action == .down) {
        if (code == .slash or code == .p) {
            if (self.hubmode != .launcher) {
                self.switchMode(.launcher, state);
                return true;
            }
        }
    }
    return false;
}

pub fn handleLauncherKey(self: *HubUi, code: dvui.enums.Key, action: KeyAction, state: *State) bool {
    if (code == .escape and action == .down) {
        self.switchMode(self.last_hubmode, state);
        return true;
    }
    if (code == .enter and action == .down) {
        if (state.launcher.search(self.launcher_query)) |apps| {
            if (apps.len > 0) {
                var idx: usize = 0;
                for (state.launcher.data.items, 0..) |*a, j| if (a == apps[0]) {
                    idx = j;
                    break;
                };
                state.launcher.run(idx);
                self.switchMode(self.last_hubmode, state);
                return true;
            }
        }
    }
    return false;
}

pub fn handleWindowsKey(self: *HubUi, code: dvui.enums.Key, action: KeyAction, state: *State) bool {
    if (code == .escape and action == .down) {
        self.switcher_pending = false;
        self.selectIndex(state, 0);
        self.switchMode(self.last_hubmode, state);
        return true;
    }
    return false;
}

pub fn updateSwitcher(self: *HubUi, now_ms: u64, state: *State) HubMode {
    if (self.switcher_pending and self.hubmode != .windows and now_ms -% self.switcher_armed_ms >= 180) {
        self.switchMode(.windows, state);
    }
    const focus_lost = !self.hub_keyboard_focused and self.hub_prev_keyboard_focused;
    if (focus_lost) {
        if (self.switcher_pending or self.hubmode == .windows) {
            if (state.windows.len > 0) self.commitSwitcherSelection(state);
            if (self.hubmode == .windows) self.switchMode(self.last_hubmode, state);
            self.switcher_pending = false;
            self.selectIndex(state, 0);
        } else {
            self.switcher_pending = false;
        }
    }
    if (focus_lost and self.hubmode == .launcher) {
        self.switchMode(self.last_hubmode, state);
    }
    if (focus_lost and self.hubmode == .network) {
        self.clearNetSel(state);
        self.switchMode(self.last_hubmode, state);
    }
    return self.hubmode;
}

pub fn hubFrame(self: *HubUi, state: *State, _io: std.Io, ctx_hub_g: anytype, _win_hub: anytype) !dvui.App.Result {
    _ = _io;
    _ = _win_hub;
    var t = &dvui.currentWindow().theme;
    const base = t.color(.content, .fill);

    // Bar-window requests run here so switchMode (and its resize
    // animation) executes in hub context. See net_toggle_pending.
    if (self.net_toggle_pending) {
        self.net_toggle_pending = false;
        self.toggleNetworkMenu(state);
    }

    // Keyboard focus follows the panel: exclusive asks the compositor
    // to focus the hub surface while a panel is open (typing lands in
    // the search/password entries); clock releases it — focus itself
    // goes back to the app via switchMode. Cached on change, like
    // pushHubSurface, so the protocol call doesn't fire every frame.
    {
        const want_excl = self.hubmode != .clock;
        if (self.kb_exclusive == null or self.kb_exclusive.? != want_excl) {
            self.kb_exclusive = want_excl;
            ctx_hub_g.setKeyboardInteractivity(if (want_excl) .exclusive else .on_demand);
        }
    }

    const hub_anim = dvui.animationGet(self.anim_id, "hubsize");
    if (self.hub_target) |ta| {
        if (hub_anim) |a| {
            self.hub_cur.w = std.math.lerp(self.hub_from.w, ta.w, a.value());
            self.hub_cur.h = std.math.lerp(self.hub_from.h, ta.h, a.value());
            if (a.done()) self.hub_cur = ta;
        } else {
            self.hub_cur = ta;
        }
    }

    if (self.hub_target) |ta| {
        const expanding = ta.w > self.hub_from.w or ta.h > self.hub_from.h;
        const done = hub_anim == null or hub_anim.?.done();
        if (expanding) {
            self.pushHubSurface(ta, ctx_hub_g);
            if (done) {
                self.hub_target = null;
                self.hub_from = ta;
            }
        } else if (done) {
            self.hub_cur = ta;
            self.pushHubSurface(ta, ctx_hub_g);
            self.hub_target = null;
            self.hub_from = ta;
        }
    }

    const outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = self.hub_cur,
        .max_size_content = .size(self.hub_cur),
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

    const now = @as(u64, @intCast(std.Io.Clock.real.now(state.io).toMilliseconds()));

    const focus_gained = self.hub_keyboard_focused and !self.hub_prev_keyboard_focused;
    _ = focus_gained;
    defer self.hub_prev_keyboard_focused = self.hub_keyboard_focused;

    for (dvui.events()) |ev| {
        if (ev.evt != .key) continue;
        const k = ev.evt.key;
        const action: KeyAction = switch (k.action) {
            .down => .down,
            .up => .up,
            else => .repeat,
        };
        // Same helpers the headless JSON harness drives, so tested
        // behavior is the wired behavior.
        if (self.handleGlobalKey(k.code, action, k.mod.shift(), now, state)) break;
    }

    _ = self.updateSwitcher(now, state);

    switch (self.hubmode) {
        .clock => {
            var hover = false;
            defer self.hub_was_hovered = hover;
            const clicked = dvui.clicked(outer.data(), .{
                .hovered = &hover,
                .hover_cursor = .arrow,
            });
            if (hover and !self.hub_was_hovered) {
                dvui.animation(outer.data().id, "hover", .{
                    .easing = dvui.easing.outExpo,
                    .end_time = @floor(std.time.us_per_s * 0.2),
                });
            }
            if (!hover and self.hub_was_hovered) {
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
                "Thursday", "Friday",  "Saturday",  "Sunday",
                "Monday",   "Tuesday", "Wednesday",
            };
            const ms = [_][]const u8{
                "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
            };
            const dname = dw[@as(usize, @intCast(@divFloor(s, 86400))) % dw.len];
            const dm = dy.calculateMonthDay();
            const txt_ = try std.fmt.allocPrint(state.alloc, "{s}, {s} {}", .{
                dname,
                ms[dm.month.numeric() - 1],
                dm.day_index + 1,
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
            if (clicked) self.handleClockClick(state);
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 0.5 });
                defer row.deinit();
                if (dvui.button(@src(), "Launcher  \u{2318}P / /", .{}, .{ .min_size_content = .{ .h = 18 } })) {
                    self.switchMode(.launcher, state);
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

            for (dvui.events()) |ev| {
                if (ev.evt != .key) continue;
                const k = ev.evt.key;
                const action: KeyAction = switch (k.action) {
                    .down => .down,
                    .up => .up,
                    else => .repeat,
                };
                if (self.handleWindowsKey(k.code, action, state)) break;
            }
            if (self.selected >= state.windows.len) self.selectIndex(state, self.selected);

            var focused_idx: ?usize = null;
            var hovered_idx: ?usize = null;
            for (state.windows, 0..) |w, i| {
                const c = if (i == self.selected)
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
                if (self.windows_need_focus and i == self.selected) {
                    dvui.focusWidget(btn.data().id, null, null);
                    focused_idx = i;
                }
                if (btn.clicked()) {
                    self.switcher_pending = false;
                    state.focusWindow(w.id);
                    // Names its own focus target (see switchMode).
                    self.suppress_clock_push = true;
                    self.switchMode(self.last_hubmode, state);
                    self.selectIndex(state, 0);
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
                    // Aliased placeholder: 1-bit raster shown 1:1.
                    if (Icons.iconPx(.photo, 64, .white) catch null) |crisp| {
                        _ = dvui.image(@src(), Icons.pixelImage(crisp), .{
                            .expand = .both,
                            .padding = .{ .y = 10 },
                            .gravity_x = 0.5,
                        });
                    }
                }
                dvui.labelNoFmt(@src(), w.title, .{
                    .align_x = 0.5,
                    .align_y = 0.5,
                }, .{
                    .font = t.font_title,
                    .expand = .horizontal,
                });
            }
            self.windows_need_focus = false;
            if (focused_idx) |f| {
                self.selectIndex(state, f);
            } else if (hovered_idx) |h| {
                self.selectIndex(state, h);
            }
        },
        .launcher => {
            var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .both,
                .background = false,
                .padding = .all(4),
            });
            defer vbox.deinit();

            const q = blk: {
                var te = dvui.textEntry(@src(), .{
                    .placeholder = "Search...",
                }, .{
                    .expand = .horizontal,
                    .margin = .all(2),
                    .padding = .{ .w = 4, .h = 6, .y = 6, .x = 4 },
                });
                defer te.deinit();
                if (self.launcher_need_focus and self.hub_keyboard_focused) {
                    dvui.focusWidget(te.data().id, null, null);
                    self.launcher_need_focus = false;
                }
                break :blk te.getText();
            };
            self.launcher_query = q;

            const results = state.launcher.search(q);

            for (dvui.events()) |ev| {
                if (ev.evt != .key) continue;
                const k = ev.evt.key;
                const action: KeyAction = switch (k.action) {
                    .down => .down,
                    .up => .up,
                    else => .repeat,
                };
                if (self.handleLauncherKey(k.code, action, state)) break;
            }

            var scroll = dvui.scrollArea(@src(), .{}, .{
                .expand = .both,
                .background = false,
                .padding = .all(2),
                .margin = .{ .y = 6 },
            });
            defer scroll.deinit();

            if (results) |apps| {
                if (apps.len == 0) {
                    if (q.len == 0) {
                        dvui.labelNoFmt(@src(), "No apps loaded", .{
                            .align_x = 0.5,
                            .align_y = 0.5,
                        }, .{
                            .color_text = t.color(.content, .text).opacity(0.6),
                            .expand = .horizontal,
                            .margin = .{ .y = 26 },
                        });
                    } else {
                        dvui.labelNoFmt(@src(), "No results", .{
                            .align_x = 0.5,
                            .align_y = 0.5,
                        }, .{
                            .color_text = t.color(.content, .text).opacity(0.6),
                            .expand = .horizontal,
                            .margin = .{ .y = 26 },
                        });
                    }
                } else {
                    for (apps, 0..) |app, i| {
                        var btn: dvui.ButtonWidget = undefined;
                        btn.init(@src(), .{}, .{
                            .expand = .horizontal,
                            .background = true,
                            .color_fill = if (i == 0) base.lighten(5) else base,
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
                        }
                        if (btn.clicked() or !self.hub_keyboard_focused)
                            self.switchMode(self.last_hubmode, state);
                        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .expand = .horizontal,
                            .background = false,
                            .min_size_content = .{ .h = 36, .w = 0 },
                            .max_size_content = .height(36),
                        });
                        defer hbox.deinit();
                        {
                            var slot = dvui.box(@src(), .{}, .{
                                .expand = .none,
                                .min_size_content = .{ .w = 32, .h = 32 },
                                .max_size_content = .{ .w = 32, .h = 32 },
                                .gravity_y = 0.5,
                                .padding = .all(2),
                            });
                            defer slot.deinit();
                            const prev_clip = dvui.clip(slot.data().rectScale().r);
                            defer dvui.clipSet(prev_clip);
                            if (app.iconTvg(&state.launcher)) |tvg| {
                                _ = dvui.icon(@src(), "app", tvg, .{}, .{
                                    .expand = .none,
                                    .min_size_content = .{ .w = 28, .h = 28 },
                                    .max_size_content = .{ .w = 28, .h = 28 },
                                    .gravity_x = 0.5,
                                    .gravity_y = 0.5,
                                });
                            } else if (app.iconImage(&state.launcher)) |src| {
                                _ = dvui.image(@src(), .{ .source = src, .shrink = .ratio }, .{
                                    .expand = .none,
                                    .min_size_content = .{ .w = 28, .h = 28 },
                                    .max_size_content = .{ .w = 28, .h = 28 },
                                    .gravity_x = 0.5,
                                    .gravity_y = 0.5,
                                });
                            } else {
                                // Aliased fallback: chunky pixels (raster
                                // 14, shown 28 with nearest sampling).
                                if (Icons.iconChunkyPx(.photo, 28, .white) catch null) |crisp| {
                                    _ = dvui.image(@src(), Icons.pixelImage(crisp), .{
                                        .expand = .none,
                                        .min_size_content = .{ .w = 28, .h = 28 },
                                        .gravity_x = 0.5,
                                        .gravity_y = 0.5,
                                    });
                                }
                            }
                        }
                        var row2 = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .gravity_y = 0.5, .padding = .{ .x = 6 } });
                        defer row2.deinit();
                        dvui.labelNoFmt(@src(), app.name, .{}, .{ .font = t.font_title.withSize(12) });
                        var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
                        defer meta.deinit();
                        if (app.comment) |c| {
                            dvui.labelNoFmt(@src(), c, .{}, .{ .font = t.font_body.withSize(10), .color_text = t.color(.content, .text).opacity(0.6) });
                        } else if (app.generic_name) |g| {
                            dvui.labelNoFmt(@src(), g, .{}, .{ .font = t.font_body.withSize(10), .color_text = t.color(.content, .text).opacity(0.6) });
                        }
                        if (app.categories) |cats| {
                            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 } });
                            dvui.labelNoFmt(@src(), cats, .{}, .{ .font = t.font_body.withSize(9), .color_text = t.color(.highlight, .fill) });
                        }
                        if (app.exec) |e| {
                            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 } });
                            dvui.labelNoFmt(@src(), e, .{}, .{ .font = t.font_mono.withSize(9), .color_text = t.color(.content, .text).opacity(0.45) });
                        }
                    }
                }
            } else {
                dvui.labelNoFmt(@src(), "No results found", .{
                    .align_x = 0.5,
                    .align_y = 0.5,
                }, .{
                    .color_text = t.color(.content, .text).opacity(0.6),
                    .margin = .{ .y = 26 },
                    .expand = .horizontal,
                });
            }
        },
        .network => {
            var snap = state.net.snapshotCopy(state.alloc);
            // Per-frame copy on the GPA: must free before leaving the
            // branch or the open panel leaks every frame.
            defer snap.deinit(state.alloc);
            // Wifi device path for connect calls (owned, one fetch per
            // frame shared by all rows).
            const wifi_dev = state.net.wifiDevicePath();
            defer if (wifi_dev) |d| state.alloc.free(d);
            // Settle any in-flight connect/disconnect: success collapses
            // the row, failure leaves the daemon's last_error under the
            // targeted row (net_req_ap survives for that).
            if (self.net_req) |req| {
                switch (req.poll(&state.net)) {
                    .pending => {},
                    .ok => {
                        self.net_req = null;
                        self.net_req_ap = 0;
                        self.net_sel_open = false;
                    },
                    .failed => {
                        const failed_ap = self.net_req_ap;
                        self.net_req = null;
                        // Fresh error: restart the flash + 5s dismiss clock.
                        self.net_err_frame = 0;
                        self.net_err_since = now;
                        // Wrong password (or saved-profile auth reject):
                        // wiggle + red outline on the failed row's entry.
                        self.net_reject_since = now;
                        self.net_reject_ap = failed_ap;
                    },
                }
            }
            // Last frame's typing state fed a row2 highlight that is gone
            // (focus now shows only via the entry's own focus border);
            // net_typing/net_typing_since retired with it.
            {
                var row = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .expand = .both,
                    .padding = .all(6),
                });
                defer row.deinit();
                var q: []const u8 = undefined;
                {
                    var global = dvui.box(@src(), .{
                        .dir = .horizontal,
                    }, .{
                        .expand = .horizontal,
                        .margin = .{ .h = 6 },
                    });
                    defer global.deinit();
                    const fill_wifi =
                        if (snap.wifi_on)
                            t.color(.highlight, .fill)
                        else
                            t.color(.content, .fill).lighten(10);
                    // Derived control sizing (no magic numbers): the search
                    // entry below sizes itself naturally from font +
                    // padding and drives the row height; the wifi button
                    // follows it via expand-ratio + a measured glyph.
                    // Manual button composition (mirrors dvui.buttonIcon,
                    // which only accepts TVG bytes).
                    var wbtn: dvui.ButtonWidget = undefined;
                    wbtn.init(@src(), .{
                        .draw_focus = false,
                        .grayed = !snap.wifi_supported,
                    }, .{
                        // Square floor with 1:1 ratio: `expand = .ratio`
                        // stretches the button to the full row height
                        // (the entry's natural height) without taking
                        // horizontal expand weight from the entry.
                        .min_size_content = .{ .w = 28, .h = 28 },
                        .expand = .ratio,
                        // Zero chrome: padding/margin would add onto the
                        // stretched rect and break the height match with
                        // the entry (margin kept horizontal-only, same as
                        // the entry, so neither adds row height).
                        .padding = .all(0),
                        .margin = .{ .w = 2 },
                        .color_fill = fill_wifi,
                        .color_fill_hover = fill_wifi.lighten(5.0),
                        .color_fill_press = fill_wifi.lighten(5.0),
                    });
                    wbtn.processEvents();
                    wbtn.drawBackground();
                    // Custom alignment: the glyph derives from the
                    // button's measured content box (full row height, so
                    // this equals the entry height) minus a breathing
                    // inset, centered via gravity. Rounded for
                    // raster-cache stability: a fractional size would
                    // miss the cache every frame.
                    const icon_px: f32 = @max(8, @round(wbtn.data().contentRect().h - 8));
                    if (Icons.iconPx(.wifi, icon_px, .white) catch null) |crisp| {
                        _ = dvui.image(@src(), Icons.pixelImage(crisp), .{
                            .gravity_x = 0.5,
                            .gravity_y = 0.5,
                            .min_size_content = .{ .w = icon_px, .h = icon_px },
                            .expand = .none,
                        });
                    }
                    if (wbtn.clicked()) {
                        _ = state.net.setWifiEnabled(!snap.wifi_on);
                    }
                    wbtn.drawFocus();
                    wbtn.deinit();
                    q = blk: {
                        // Centered search text via our TextEntry copy
                        // (stock dvui entries are always left/top aligned).
                        const qbox = AlignedEntry.textEntry(@src(), .{
                            .placeholder = "Search...",
                            .align_y = 0.5,
                        }, .{
                            .expand = .horizontal,
                            // Natural height (font + padding + border):
                            // this drives the row, and the wifi button
                            // above stretches to match it.
                            .min_size_content = .{ .h = 28 },
                            .gravity_y = 0.5,
                            .margin = .{ .x = 6 },
                            .font = t.font_body.withSize(11.0),
                        });
                        defer qbox.deinit();
                        if (self.net_need_focus and self.hub_keyboard_focused) {
                            dvui.focusWidget(qbox.data().id, null, null);
                            self.net_need_focus = false;
                        }
                        break :blk qbox.getText();
                    };
                    state.net.setSearch(q);
                }
                // Live filter: the worker applies this to snap.aps on every
                // snapshot; empty clears the filter. setSearch is a no-op
                // when the query is unchanged, so calling it per frame is
                // free.
                if (snap.aps.len == 0) {
                    dvui.labelNoFmt(@src(), if (q.len == 0) "No networks found" else "No networks match", .{
                        .align_x = 0.5,
                        .align_y = 0.5,
                    }, .{
                        .color_text = t.color(.content, .text).opacity(0.6),
                        .expand = .horizontal,
                        .gravity_y = 0.5,
                        .margin = .{ .y = 26 },
                    });
                }
                {
                    var scroll = dvui.scrollArea(@src(), .{
                        .vertical = .auto,
                        .vertical_bar = .auto,
                        .horizontal = .none,
                    }, .{
                        // Fill the panel: without this the content sizes
                        // to the widest row and nothing spans the viewport.
                        .expand = .both,
                    });
                    defer scroll.deinit();
                    // Steady-timer inputs, accumulated across rows below:
                    // a spinner needs fast frames to turn, a visible error
                    // needs them to flash; otherwise the 750ms state cadence
                    // is enough.
                    var net_busy = false;
                    var net_err_visible = false;
                    for (snap.aps) |conn| {
                        const selected = if (self.net_sel) |s|
                            (s == conn.id)
                        else
                            (snap.connected == conn.id);
                        const open = selected and self.net_sel_open;
                        // Highlight marks the joined network only, dimmed
                        // 10%; everything else is the plain content fill
                        // with standard hover/press offsets.
                        const is_connected = snap.connected != 0 and snap.connected == conn.id;
                        const base_fill = if (is_connected)
                            t.color(.highlight, .fill).lighten(-10)
                        else
                            t.color(.content, .fill);
                        // In-flight request for this row (drives spinner,
                        // button state; settled at the branch top).
                        const connecting = self.net_req != null and self.net_req_ap == conn.id and
                            self.net_req.?.isPending(&state.net);
                        // The row auto-sizes around its content. While the
                        // resize animation runs for this row, pin to the
                        // animated height instead (height only: pinning the
                        // width blows out the scroll content extents and the
                        // rows jump horizontally for the whole animation).
                        // The error banner below lives inside this box and
                        // adds a line past the 72px open budget, so an
                        // erroring row is never pinned (it would clip).
                        const show_err = open and self.net_req == null and self.net_req_ap == conn.id and
                            snap.last_error.len > 0 and now -% self.net_err_since < 5000;
                        net_busy = net_busy or connecting;
                        net_err_visible = net_err_visible or show_err;
                        const anim_live = now -% self.net_anim_start < net_anim_ms;
                        const anim_mine = anim_live and !show_err and (if (open)
                            self.net_anim_open_ap == null or conn.id != self.net_anim_open_ap.?
                        else
                            self.net_anim_open_ap != null and conn.id == self.net_anim_open_ap.?);
                        var bopts: dvui.Options = .{
                            .background = true,
                            .color_fill = base_fill,
                            .color_fill_hover = base_fill.lighten(10),
                            .color_fill_press = base_fill.lighten(-5),
                            .corners = .all(10),
                            .expand = .horizontal,
                            // Rect fields are left/top/right/bottom.
                            .padding = .{ .x = 4, .y = 6, .w = 4, .h = 6 },
                            // Stable per-connection id (not the loop index):
                            // the list re-sorts as strengths change, and
                            // index-keyed widget ids make per-widget data
                            // (including the password buffer) jump rows.
                            .id_extra = @as(usize, @truncate(conn.id)),
                        };
                        if (anim_mine) {
                            const ah = self.netRowHeight(conn.id, open, now);
                            bopts.min_size_content = .{ .h = ah };
                            bopts.max_size_content = dvui.Options.MaxSize.height(ah);
                        }
                        const box = dvui.box(@src(), .{ .dir = .vertical }, bopts);
                        defer box.deinit();
                        // Header: wifi + text lined up on the left, lock hard
                        // right. Identical in both states so expanding never
                        // moves it. The signal glyph sits on the bottom edge
                        // (row1 is taller than the glyphs) so weaker signals
                        // read as lower, not just smaller.
                        {
                            var row1 = dvui.box(@src(), .{ .dir = .horizontal }, .{
                                .expand = .horizontal,
                                .background = false,
                                .min_size_content = .{ .h = 32 },
                                .id_extra = @as(usize, @truncate(conn.id)),
                            });
                            defer row1.deinit();
                            // One comptime call per icon (tabler embeds only
                            // referenced icons). Aliased 1-bit raster, shown 1:1.
                            const sig_crisp: ?Icons.Crisp = switch (State.Net.barsForStrength(conn.strength)) {
                                0 => Icons.iconPx(.wifi_off, 24, .white) catch null,
                                1 => Icons.iconPx(.wifi_0, 24, .white) catch null,
                                2 => Icons.iconPx(.wifi_1, 24, .white) catch null,
                                3 => Icons.iconPx(.wifi_2, 24, .white) catch null,
                                else => Icons.iconPx(.wifi, 24, .white) catch null,
                            };
                            if (sig_crisp) |crisp| {
                                _ = dvui.image(@src(), Icons.pixelImage(crisp), .{
                                    .padding = .all(2),
                                    .gravity_y = 1.0,
                                });
                            }
                            // NOTE: no align_y — single-line labels render at
                            // the top of their content rect (LabelWidget
                            // places only horizontally), so vertical
                            // centering comes from the widget's own gravity
                            // + symmetric padding. Horizontal-only expand
                            // keeps the content box text-sized (and pushes
                            // the lock right); .both would stretch it full
                            // height and strand the text at the top.
                            dvui.labelNoFmt(@src(), conn.ssid, .{}, .{
                                .expand = .horizontal,
                                .padding = .all(4),
                                .gravity_y = 0.5,
                            });
                            //macOS-style activity spinner while this row has
                            // a request in flight. Drawn manually (dvui's
                            // stock spinner is an arc, not spokes).
                            if (connecting) {
                                var slot = dvui.box(@src(), .{}, .{
                                    .background = false,
                                    .min_size_content = .{ .w = 24, .h = 24 },
                                    .max_size_content = .{ .w = 24, .h = 24 },
                                    .padding = .all(2),
                                    .gravity_y = 0.5,
                                    .id_extra = @as(usize, @truncate(conn.id)),
                                });
                                defer slot.deinit();
                                drawSpinner(slot.data().contentRectScale(), now, t.color(.content, .text));
                            }
                            // Same 2px padding as the signal icon so the
                            // text sits equidistant from both glyphs.
                            if (conn.secured) {
                                if (Icons.iconPxFilled(.lock, 24, .white) catch null) |crisp| {
                                    _ = dvui.image(@src(), Icons.pixelImage(crisp), .{
                                        .padding = .all(2),
                                        .gravity_y = 0.5,
                                    });
                                }
                            } else {
                                if (Icons.iconPx(.lock_cancel, 24, .white) catch null) |crisp| {
                                    _ = dvui.image(@src(), Icons.pixelImage(crisp), .{
                                        .padding = .all(2),
                                        .gravity_y = 0.5,
                                    });
                                }
                            }
                        }
                        // Interactive child rects, for the whole-row toggle
                        // veto below. Physical units, matching the click
                        // position. Captured before their widgets deinit.
                        // The button vetoes via its own click state.
                        var veto_entry: ?dvui.Rect.Physical = null;
                        var veto_err: ?dvui.Rect.Physical = null;
                        var btn_clicked = false;
                        if (open) {
                            // Joined to this network: offer Disconnect.
                            // Otherwise Connect — activating a new
                            // connection swaps out whatever is active on
                            // the device, no manual disconnect needed.
                            const joined_here = is_connected;
                            // Controls row. No background wash while typing:
                            // the entry's own focus outline is the only
                            // focus indicator (the old highlight fill made
                            // the whole row turn the theme highlight color).
                            var row2 = dvui.box(@src(), .{ .dir = .horizontal }, .{
                                .expand = .horizontal,
                                .background = false,
                                .id_extra = @as(usize, @truncate(conn.id)),
                                .tag = "pw_row",
                            });
                            defer row2.deinit();
                            // Entry outlives the row: its buffer backs `pw`
                            // through the Connect click below.
                            var pw: []const u8 = "";
                            // Saved-profile state: a stored NM password
                            // exists and the user hasn't typed an
                            // override. Entry grays out ("Password saved
                            // — click Connect"); Connect activates the
                            // stored profile. Any typed text overrides.
                            const reject_ap = self.net_reject_ap;
                            const reject_live = reject_ap == conn.id and
                                now -% self.net_reject_since < net_reject_ms and
                                self.net_reject_since != 0;
                            if (reject_live) std.debug.print("reject_live row {d} el={d}\n", .{ conn.id, now -% self.net_reject_since });
                            if (conn.secured and !joined_here) {
                                const use_saved = conn.saved;
                                var eopts: dvui.Options = .{
                                    .expand = .horizontal,
                                    .gravity_y = 0.5,
                                    .font = t.font_body.withSize(11.0),
                                    // Uncap the single-line width clamp
                                    // (min 14 M-widths) so the entry truly
                                    // fills its flex share. min h 14 lands
                                    // the entry on the 28px control budget
                                    // (14 content + 12 padding + 2 border),
                                    // matching the button below so the open
                                    // row measures exactly net_row_open_h.
                                    // No vertical margin: the default all(4)
                                    // would pad the row height; 8px right
                                    // keeps it off the button.
                                    .min_size_content = .{ .h = 14 },
                                    .max_size_content = .{ .w = 100000, .h = 14 },
                                    .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
                                    .id_extra = @as(usize, @truncate(conn.id)),
                                    .tag = "pw_entry",
                                };
                                if (use_saved) {
                                    // Grayed look: dimmed chrome and text.
                                    // Still interactive — typing an
                                    // override switches the row back to
                                    // the typed-password connect path.
                                    eopts = eopts.override(.{
                                        .color_fill = t.color(.content, .fill).opacity(0.45),
                                        .color_border = t.color(.content, .text).opacity(0.2),
                                        .color_text = t.color(.content, .text).opacity(0.55),
                                    });
                                }
                                if (reject_live) {
                                    // Wrong-password wiggle: the left
                                    // margin follows a decaying sine
                                    // (always >= 0: box margins can't go
                                    // negative), so entry+button glide
                                    // together within the row's own width
                                    // and the flex share is preserved.
                                    const el = @as(f32, @floatFromInt(now -% self.net_reject_since));
                                    const frac = el / @as(f32, @floatFromInt(net_reject_ms));
                                    const decay = 1.0 - frac;
                                    const dx = (@sin(frac * std.math.pi * 6.0) + 1.0) * 5.0 * decay;
                                    eopts = eopts.override(.{
                                        .margin = .{ .x = dx, .y = 0, .w = 8, .h = 0 },
                                    });
                                }
                                const e = dvui.textEntry(@src(), .{
                                    .placeholder = if (use_saved)
                                        "Password saved — click Connect"
                                    else
                                        "Password",
                                    .password_char = "*",
                                }, eopts);
                                pw = e.getText();
                                veto_entry = e.data().borderRectScale().r;
                                // Enter submits like the button. The flag
                                // latches until read, so always clear it.
                                const enter_go = e.enter_pressed;
                                e.enter_pressed = false;
                                // Deinit BEFORE creating the Connect button:
                                // the entry's init leaves dvui's current
                                // parent at its internal textLayout, so any
                                // widget created before deinit becomes a
                                // child of the entry and renders on top of
                                // the password text (the "goofy" overlap).
                                // getText's buffer stays valid after
                                // deinit; pw was already copied above.
                                const pw_owned = pw;
                                const entry_rect = e.data().borderRectScale();
                                const entry_focused = dvui.focusedWidgetId() == e.data().id;
                                e.deinit();
                                pw = pw_owned;
                                // Reject window: draw the red focus outline
                                // over the stock one (same 2px), tied to
                                // focus like the stock border so it reads
                                // as the entry's outline, not a decal.
                                if (reject_live and entry_focused) {
                                    entry_rect.r.stroke(dvui.CornerRect.Physical.all(4 * entry_rect.s), .{
                                        .thickness = 2 * entry_rect.s,
                                        .color = .{ .r = 0xcc, .g = 0x2e, .b = 0x2e, .a = 255 },
                                        .after = true,
                                    });
                                }
                                if (enter_go and !connecting) {
                                    if (pw.len > 0) {
                                        if (wifi_dev) |dev| self.connectToAp(state, dev, conn, pw);
                                    } else if (use_saved) {
                                        if (wifi_dev) |dev| self.connectToApSaved(state, dev, conn);
                                    }
                                }
                            } else {
                                _ = dvui.spacer(@src(), .{ .expand = .horizontal });
                            }
                            // While the request is in flight the button
                            // itself reports it: grayed "Connecting…".
                            // Standard button at the row end (right).
                            const btn_label = if (connecting) "Connecting…" else if (joined_here) "Disconnect" else "Connect";
                            // A secured network needs a passphrase unless
                            // one is already stored (saved-profile path).
                            const need_pw = conn.secured and !joined_here and pw.len == 0 and !conn.saved;
                            btn_clicked = dvui.button(@src(), btn_label, .{ .grayed = need_pw or connecting }, .{
                                .gravity_y = 0.5,
                                // 24 content + 4 padding = the 28px control
                                // budget (see the password entry above): the
                                // open row then measures exactly
                                // net_row_open_h and the resize pin neither
                                // clips nor jumps at either end.
                                .min_size_content = .{ .h = 24 },
                                // Zero vertical chrome: the defaults
                                // (margin + padding all(4..6)) stack onto
                                // the label and bloat the row with dead
                                // space below the button.
                                .margin = .all(0),
                                .padding = .all(2),
                                .font = t.font_body.withSize(11.0),
                                .id_extra = @as(usize, @truncate(conn.id)),
                                .tag = "connect_btn",
                            });
                            // grayed is visual only: guard the in-flight
                            // double-submit explicitly.
                            if (btn_clicked and !connecting) {
                                if (joined_here) {
                                    self.disconnectAp(state, conn);
                                } else if (pw.len > 0) {
                                    // Typed text always overrides the
                                    // stored secret.
                                    if (wifi_dev) |dev| self.connectToAp(state, dev, conn, pw);
                                } else if (conn.saved) {
                                    // Nothing typed + stored profile: let
                                    // NM supply the saved password.
                                    if (wifi_dev) |dev| self.connectToApSaved(state, dev, conn);
                                }
                            }
                        }
                        // Error for this row's failed request, on its own
                        // line below the controls. Flashes red twice (10
                        // frame periods: 5 red, 5 transparent), then goes
                        // unadorned; vanishes 5s after the failure unless
                        // hovered (hover restarts the 5s), or at once on
                        // click. Clicking it must not toggle the row.
                        if (show_err) {
                            self.net_err_frame += 1;
                            var errbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                                .expand = .horizontal,
                                .background = true,
                                .color_fill = if (errFlashRed(self.net_err_frame))
                                    dvui.Color{ .r = 0xcc, .g = 0x2e, .b = 0x2e, .a = 255 }
                                else
                                    .transparent,
                                .corners = .all(4),
                                .padding = .all(4),
                                .id_extra = @as(usize, @truncate(conn.id)),
                            });
                            defer errbox.deinit();
                            var err_hover = false;
                            const err_clicked = dvui.clicked(errbox.data(), .{ .hovered = &err_hover });
                            if (err_hover) self.net_err_since = now;
                            if (err_clicked) {
                                self.net_req_ap = 0;
                            } else {
                                dvui.labelNoFmt(@src(), snap.last_error, .{}, .{
                                    .expand = .horizontal,
                                    .color_text = t.color(.content, .text).opacity(0.85),
                                    .font = t.font_body.withSize(10.0),
                                });
                            }
                            veto_err = errbox.data().borderRectScale().r;
                        }
                        // The whole row toggles — except clicks the button
                        // took, and releases landing on the password entry
                        // or error box, which belong to those widgets.
                        // Keyboard activation carries no position and
                        // always toggles.
                        if (dvui.clickedEx(box.data(), .{})) |cev| {
                            const on_child = btn_clicked or switch (cev) {
                                .mouse => |me| blk: {
                                    if (veto_entry) |r| {
                                        if (r.contains(me.p)) break :blk true;
                                    }
                                    if (veto_err) |r| {
                                        if (r.contains(me.p)) break :blk true;
                                    }
                                    break :blk false;
                                },
                                else => false,
                            };
                            if (!on_child) {
                                // Restart the resize animation from the row
                                // currently displayed open (if any), then
                                // flip this row's state.
                                self.net_anim_open_ap = if (self.net_sel_open) blk: {
                                    if (self.net_sel) |s| break :blk s;
                                    break :blk if (snap.connected != 0) snap.connected else null;
                                } else null;
                                self.net_anim_start = now;
                                // Drive frames for the manual height lerp:
                                // without a live dvui animation the loop
                                // sleeps through the 135ms and both rows
                                // snap instead of resizing.
                                dvui.animation(self.anim_id, "netrow", .{
                                    .easing = dvui.easing.outQuart,
                                    .end_time = net_anim_ms * 1000,
                                });
                                // Select the connection (expand its row);
                                // clicking the selected row collapses it.
                                if (self.net_sel == conn.id) {
                                    self.net_sel_open = !self.net_sel_open;
                                } else {
                                    self.net_sel = conn.id;
                                    self.net_sel_open = true;
                                }
                                self.net_req_ap = 0;
                    }
                }
            }
            // Steady state cadence while the panel is open: re-ask the
            // worker for fresh state every State.Net.refresh_ms so the
            // rows track the daemon even with no input. The timer is what
            // wakes the loop (worker pushes also wake it, for immediacy).
            // A spinner or a flashing error needs faster frames than the
            // state cadence, so those tick hot — but re-requests stay
            // gated on net_last_refresh so fast ticks never turn into a
            // D-Bus storm.
            {
                const tick_us: i32 = if (net_busy or net_err_visible) 80_000 else @intCast(State.Net.refresh_ms * 1000);
                if (dvui.timerDone(self.anim_id)) {
                    if (now -% self.net_last_refresh >= State.Net.refresh_ms) {
                        self.net_last_refresh = now;
                        _ = state.net.refresh();
                    }
                    dvui.timer(self.anim_id, tick_us);
                } else if (dvui.timerGet(self.anim_id) == null) {
                    dvui.timer(self.anim_id, tick_us);
                }
            }
                }
            }
            // Dismiss when the hub loses keyboard focus, on Escape, or
            // when the focused app window moves elsewhere (MRU head
            // change vs the open baseline — covers clicks the hub never
            // sees as SDL focus events).
            const focused_elsewhere = state.windows.len > 0 and self.net_open_win != 0 and
                state.windows[0].id != self.net_open_win;
            if (now - self.off_start > 500 and
                (!self.hub_keyboard_focused or pressed(.escape) or focused_elsewhere))
            {
                self.clearNetSel(state);
                self.switchMode(self.last_hubmode, state);
            }
        },
        .search => self.switchMode(.launcher, state),
    }

    return .ok;
}

pub fn handleClockClick(self: *HubUi, state: *State) void {
    self.switchMode(.windows, state);
}

pub fn handleLauncherEnter(self: *HubUi, state: *State) void {
    if (state.launcher.search(self.launcher_query)) |apps| {
        if (apps.len > 0) {
            var idx: usize = 0;
            for (state.launcher.data.items, 0..) |*a, j| if (a == apps[0]) {
                idx = j;
                break;
            };
            state.launcher.run(idx);
            self.switchMode(self.last_hubmode, state);
        }
    }
}
