const std = @import("std");
const dvui = @import("dvui");
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

const HubUi = @This();

pub const HubMode = enum {
    clock,
    wifi,
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
    if (mode != .launcher and mode != .windows and self.hubmode == .launcher) {
        // leaving launcher keeps last_hubmode as is
    } else if (mode != .windows and mode != .launcher) {
        self.last_hubmode = mode;
    }
    self.hubmode = mode;
    self.setTarget(switch (mode) {
        .windows => .{ .w = 600, .h = 120 },
        .launcher => .{ .w = 520, .h = 360 },
        .clock => .{ .w = 150, .h = 50 },
        else => .{ .w = 480, .h = 180 },
    });
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
        if (code == .slash or code == .space) {
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
    return self.hubmode;
}

pub fn hubFrame(self: *HubUi, state: *State, _io: std.Io, ctx_hub_g: anytype, _win_hub: anytype) !dvui.App.Result {
    _ = _io;
    _ = _win_hub;
    var t = &dvui.currentWindow().theme;
    const base = t.color(.content, .fill);

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
                                _ = dvui.icon(@src(), "app", dvui.entypo.image, .{}, .{
                                    .expand = .none,
                                    .min_size_content = .{ .w = 28, .h = 28 },
                                    .gravity_x = 0.5,
                                    .gravity_y = 0.5,
                                });
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
        .search => self.switchMode(.launcher, state),
        .wifi => self.switchMode(.clock, state),
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
