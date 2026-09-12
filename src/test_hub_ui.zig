const std = @import("std");
const dvui = @import("dvui");
const nilebank = @import("nilebank");
const proto = nilebank.protocols.compositor;
const State = @import("State.zig");
const Launcher = @import("Launcher.zig");
const HubUi = @import("HubUi.zig");
const json = std.json;
const testing = std.testing;

const TestDir = struct {
    dir: std.Io.Dir,
    io: std.Io,

    fn close(self: *TestDir) void {
        self.dir.close(self.io);
    }
};

/// Locate the repo's test/ directory: try cwd first, then walk up parents
/// (zig build runs tests with cwd set to the build root, but a direct
/// `zig test` invocation uses whatever cwd the user is in).
/// Libc-free: probes relative candidates so the link stays light.
fn openTestDir(io: std.Io) !TestDir {
    var buf: [64]u8 = undefined;
    for (0..8) |depth| {
        var len: usize = 0;
        for (0..depth) |_| {
            buf[len..][0..3].* = "../".*;
            len += 3;
        }
        @memcpy(buf[len..][0..4], "test");
        len += 4;
        const cand = buf[0..len];
        if (std.Io.Dir.cwd().openDir(io, cand, .{ .iterate = true })) |d| {
            return .{ .dir = d, .io = io };
        } else |_| {}
    }
    return error.TestDirNotFound;
}

const switcher_delay_ms: u64 = 180;

const Case = struct {
    name: []const u8,
    file: []const u8,
    windows_count: usize,
    hub_keyboard_focused: bool,
    inputs: []const json.Value,
    exp_hubmode: ?HubUi.HubMode,
    exp_selected: ?usize,
    exp_switcher_pending: ?bool,
    exp_launch_need_focus: ?bool,
    exp_windows_need_focus: ?bool,
    exp_last_hubmode: ?HubUi.HubMode,
    exp_hub_target: ?dvui.Size,
    exp_hub_cur: ?dvui.Size,
    exp_kb_focused: ?bool,
};

fn parseMode(s_in: []const u8) ?HubUi.HubMode {
    const s = std.mem.trim(u8, s_in, " .");
    return std.meta.stringToEnum(HubUi.HubMode, s);
}

fn parseKey(name: []const u8) ?dvui.enums.Key {
    return std.meta.stringToEnum(dvui.enums.Key, std.mem.trim(u8, name, " ."));
}

fn parseSize(v: json.Value) dvui.Size {
    const o = v.object;
    return .{
        .w = @floatFromInt(o.get("w").?.integer),
        .h = @floatFromInt(o.get("h").?.integer),
    };
}

fn addWindows(state: *State, count: usize) !void {
    if (count == 0) return;
    const wins = try state.alloc.alloc(proto.Window, count);
    for (wins, 0..) |*w, i| {
        w.* = .{
            .id = 100 + i,
            .title = try state.alloc.dupe(u8, "win"),
            .app_id = "",
            .focused = i == 0,
        };
    }
    state.windows = wins;
}

fn runCase(alloc: std.mem.Allocator, io: std.Io, c: Case) !void {
    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();
    try addWindows(&state, c.windows_count);

    var h = HubUi.init();
    h.hub_keyboard_focused = c.hub_keyboard_focused;
    h.hub_prev_keyboard_focused = c.hub_keyboard_focused;

    var now: u64 = 1000;

    for (c.inputs) |*iv| {
        const obj = iv.object;
        const t = obj.get("type").?.string;
        if (std.mem.eql(u8, t, "init") or std.mem.eql(u8, t, "click")) {
            // no-op for state machine
        } else if (std.mem.eql(u8, t, "switchMode")) {
            const mode = parseMode(obj.get("mode").?.string) orelse return error.BadMode;
            h.switchMode(mode, &state);
        } else if (std.mem.eql(u8, t, "toggleNetwork")) {
            h.toggleNetworkMenu(&state);
        } else if (std.mem.eql(u8, t, "render")) {
            // Frame-level mode redirects from hubFrame's render switch.
            switch (h.hubmode) {
                .search => h.switchMode(.launcher, &state),
                else => {},
            }
        } else if (std.mem.eql(u8, t, "advance")) {
            now += @intCast(obj.get("ms").?.integer);
            _ = h.updateSwitcher(now, &state);
            h.hub_prev_keyboard_focused = h.hub_keyboard_focused;
        } else if (std.mem.eql(u8, t, "hover")) {
            h.hub_was_hovered = obj.get("hovered").?.bool;
        } else if (std.mem.eql(u8, t, "type")) {
            h.launcher_query = obj.get("text").?.string;
        } else if (std.mem.eql(u8, t, "focus")) {
            // Simulate an OS focus change on the hub surface (pumpEvents
            // writes this in production). updateSwitcher (called at the
            // next step boundary, mirroring hubFrame) sees the transition.
            h.hub_keyboard_focused = obj.get("focused").?.bool;
        } else if (std.mem.eql(u8, t, "key")) {
            const code = parseKey(obj.get("code").?.string) orelse return error.BadKey;
            const act_str = obj.get("action").?.string;
            const act: HubUi.KeyAction = if (std.mem.eql(u8, act_str, "down")) .down else if (std.mem.eql(u8, act_str, "up")) .up else .repeat;
            const shift = if (obj.get("shift")) |s| s.bool else false;

            const consumed = switch (h.hubmode) {
                .windows => h.handleWindowsKey(code, act, &state) or h.handleGlobalKey(code, act, shift, now, &state),
                .launcher => h.handleLauncherKey(code, act, &state) or h.handleGlobalKey(code, act, shift, now, &state),
                .network => h.handleNetworkKey(code, act, &state) or h.handleGlobalKey(code, act, shift, now, &state),
                else => h.handleGlobalKey(code, act, shift, now, &state),
            };
            _ = consumed;
            // Each key step is a frame: run the delayed-popup / focus-lost
            // logic exactly like hubFrame does between events. 50ms per step
            // (a few frames) keeps quick multi-tab sequences under the 180ms
            // switcher delay.
            now += 50;
            _ = h.updateSwitcher(now, &state);
            // hubFrame defers this at frame end: prev tracks the last frame.
            h.hub_prev_keyboard_focused = h.hub_keyboard_focused;
        } else {
            std.debug.print("case '{s}' ({s}): unknown input type '{s}'\n", .{ c.name, c.file, t });
            return error.BadInputType;
        }
    }

    // Verify expectations.
    const ctx = struct {
        fn chk(comptime label: []const u8, case_: Case, ok: bool) !void {
            if (!ok) {
                std.debug.print("case '{s}' ({s}): {s} mismatch\n", .{ case_.name, case_.file, label });
                return error.TestExpectedEqual;
            }
        }
    };
    if (c.exp_hubmode) |want| try ctx.chk("hubmode", c, want == h.hubmode);
    if (c.exp_selected) |sel| try ctx.chk("selected", c, sel == h.selected);
    if (c.exp_switcher_pending) |sp| try ctx.chk("switcher_pending", c, sp == h.switcher_pending);
    if (c.exp_launch_need_focus) |lf| try ctx.chk("launcher_need_focus", c, lf == h.launcher_need_focus);
    if (c.exp_windows_need_focus) |wf| try ctx.chk("windows_need_focus", c, wf == h.windows_need_focus);
    if (c.exp_last_hubmode) |lm| try ctx.chk("last_hubmode", c, lm == h.last_hubmode);
    if (c.exp_kb_focused) |kf| try ctx.chk("hub_keyboard_focused", c, kf == h.hub_keyboard_focused);
    if (c.exp_hub_target) |want| {
        if (h.hub_target) |got| {
            try ctx.chk("hub_target.w", c, want.w == got.w);
            try ctx.chk("hub_target.h", c, want.h == got.h);
        } else {
            std.debug.print("case '{s}' ({s}): hub_target null, want {d}x{d}\n", .{ c.name, c.file, want.w, want.h });
            return error.MissingTarget;
        }
    }
    if (c.exp_hub_cur) |want| {
        try ctx.chk("hub_cur.w", c, want.w == h.hub_cur.w);
        try ctx.chk("hub_cur.h", c, want.h == h.hub_cur.h);
    }
}

test "hub_ui: JSON-driven state machine cases" {
    const alloc = testing.allocator;
    const io = testing.io;

    var td = try openTestDir(io);
    defer td.close();

    var cases: usize = 0;
    var it = td.dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const content = try td.dir.readFileAlloc(io, entry.name, alloc, .unlimited);
        defer alloc.free(content);

        var parsed = try json.parseFromSlice(json.Value, alloc, content, .{});
        defer parsed.deinit();
        const root_obj = parsed.value.object;

        // Structure validation for every file.
        try testing.expect(root_obj.get("name") != null);
        try testing.expect(root_obj.get("description") != null);
        try testing.expect(root_obj.get("initial_state") != null);
        try testing.expect(root_obj.get("inputs") != null);
        try testing.expect(root_obj.get("expected") != null);
        try testing.expect(root_obj.get("setup") != null);

        var c = Case{
            .name = root_obj.get("name").?.string,
            .file = entry.name,
            .windows_count = 0,
            .hub_keyboard_focused = true,
            .inputs = root_obj.get("inputs").?.array.items,
            .exp_hubmode = null,
            .exp_selected = null,
            .exp_switcher_pending = null,
            .exp_launch_need_focus = null,
            .exp_windows_need_focus = null,
            .exp_last_hubmode = null,
            .exp_hub_target = null,
            .exp_hub_cur = null,
            .exp_kb_focused = null,
        };

        if (root_obj.get("setup")) |s| {
            if (s.object.get("windows_count")) |v| c.windows_count = @intCast(v.integer);
            if (s.object.get("hub_keyboard_focused")) |v| c.hub_keyboard_focused = v.bool;
        }
        const exp = root_obj.get("expected").?.object;
        if (exp.get("hubmode")) |v| {
            c.exp_hubmode = parseMode(v.string) orelse {
                std.debug.print("case '{s}': unknown hubmode '{s}'\n", .{ c.name, v.string });
                return error.BadMode;
            };
        }
        if (exp.get("selected")) |v| c.exp_selected = @intCast(v.integer);
        if (exp.get("switcher_pending")) |v| c.exp_switcher_pending = v.bool;
        if (exp.get("launcher_need_focus")) |v| c.exp_launch_need_focus = v.bool;
        if (exp.get("windows_need_focus")) |v| c.exp_windows_need_focus = v.bool;
        if (exp.get("last_hubmode")) |v| {
            c.exp_last_hubmode = parseMode(v.string) orelse {
                std.debug.print("case '{s}' ({s}): unknown last_hubmode '{s}'\n", .{ c.name, entry.name, v.string });
                return error.BadMode;
            };
        }
        if (exp.get("hub_keyboard_focused")) |v| c.exp_kb_focused = v.bool;
        if (exp.get("hub_target")) |v| c.exp_hub_target = parseSize(v);
        if (exp.get("hub_cur")) |v| c.exp_hub_cur = parseSize(v);

        try runCase(alloc, io, c);
        cases += 1;
    }
    try testing.expect(cases >= 16);
}

test "hub_ui: selectIndex wrap and clamp" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();
    try addWindows(&state, 3);

    var h = HubUi.init();

    h.selectIndex(&state, 0);
    try testing.expectEqual(@as(usize, 0), h.selected);
    h.selectIndex(&state, 5);
    try testing.expectEqual(@as(usize, 2), h.selected);
    h.selectPrev(&state);
    try testing.expectEqual(@as(usize, 1), h.selected);
    h.selectNext(&state);
    try testing.expectEqual(@as(usize, 2), h.selected);
    h.selectNext(&state);
    try testing.expectEqual(@as(usize, 0), h.selected);
    h.selectPrev(&state);
    try testing.expectEqual(@as(usize, 2), h.selected);
    h.selectIndex(&state, 999);
    try testing.expectEqual(@as(usize, 0), h.selected);
}

test "hub_ui: switchMode windows needs windows" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();

    var h = HubUi.init();

    // No windows: switchMode(.windows) is a no-op.
    h.switchMode(.windows, &state);
    try testing.expectEqual(HubUi.HubMode.clock, h.hubmode);
    try testing.expect(h.hub_target == null);

    try addWindows(&state, 2);

    h.switchMode(.windows, &state);
    try testing.expectEqual(HubUi.HubMode.windows, h.hubmode);
    const ta = h.hub_target orelse return error.MissingTarget;
    try testing.expectEqual(@as(f32, 600), ta.w);
    try testing.expectEqual(@as(f32, 120), ta.h);
    try testing.expect(h.windows_need_focus);
}

test "hub_ui: setTarget idempotent and animation starts" {
    var h = HubUi.init();
    h.setTarget(.{ .w = 150, .h = 50 });
    try testing.expect(h.hub_target == null);
    h.setTarget(.{ .w = 520, .h = 360 });
    try testing.expect(h.hub_target != null);
    const first = h.hub_target.?;
    h.setTarget(.{ .w = 520, .h = 360 });
    try testing.expectEqual(first.w, h.hub_target.?.w);
    // Shim animation recorded for the anim_id "hubsize" key.
    try testing.expect(dvui.animationGet(h.anim_id, "hubsize") != null);
}

test "hub_ui: delayed switcher popup fires after 180ms" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();
    try addWindows(&state, 3);

    var h = HubUi.init();

    // Quick tab: arms the switcher, stays clock under the delay.
    _ = h.handleGlobalKey(.tab, .down, false, 1000, &state);
    try testing.expect(h.switcher_pending);
    try testing.expectEqual(HubUi.HubMode.clock, h.hubmode);
    _ = h.updateSwitcher(1100, &state);
    try testing.expectEqual(HubUi.HubMode.clock, h.hubmode);

    // After the delay it flips to windows.
    _ = h.updateSwitcher(1200, &state);
    try testing.expectEqual(HubUi.HubMode.windows, h.hubmode);
    try testing.expect(!h.switcher_pending or h.hubmode == .windows);
}

test "hub_ui: toggleNetworkMenu flips mode and targets" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();

    var h = HubUi.init();

    h.toggleNetworkMenu(&state);
    try testing.expectEqual(HubUi.HubMode.network, h.hubmode);
    const open_ta = h.hub_target orelse return error.MissingTarget;
    try testing.expectEqual(@as(f32, 520), open_ta.w);
    try testing.expectEqual(@as(f32, 420), open_ta.h);

    h.toggleNetworkMenu(&state);
    try testing.expectEqual(HubUi.HubMode.clock, h.hubmode);
    const shut_ta = h.hub_target orelse return error.MissingTarget;
    try testing.expectEqual(@as(f32, 150), shut_ta.w);
    try testing.expectEqual(@as(f32, 50), shut_ta.h);
}

test "hub_ui: targetFor matches switchMode targets" {
    try testing.expectEqual(dvui.Size{ .w = 600, .h = 120 }, HubUi.targetFor(.windows));
    try testing.expectEqual(dvui.Size{ .w = 520, .h = 360 }, HubUi.targetFor(.launcher));
    try testing.expectEqual(dvui.Size{ .w = 520, .h = 420 }, HubUi.targetFor(.network));
    try testing.expectEqual(dvui.Size{ .w = 150, .h = 50 }, HubUi.targetFor(.clock));
    try testing.expectEqual(dvui.Size{ .w = 520, .h = 360 }, HubUi.targetFor(.controls));
}

test "hub_ui: openNetworkFaded defers the mode commit" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();

    var h = HubUi.init();
    h.switchMode(.controls, &state);
    try testing.expectEqual(HubUi.HubMode.controls, h.hubmode);

    // From controls: resize kicks off but the mode stays until the
    // hubFrame midpoint commit. The wifi toggle selects the wifi tab
    // and records the controls origin for the back button.
    h.openNetworkFaded(&state, .wifi);
    try testing.expect(h.controls_fade_start != null);
    try testing.expectEqual(HubUi.HubMode.controls, h.hubmode);
    try testing.expectEqual(HubUi.NetTab.wifi, h.net_tab);
    try testing.expectEqual(HubUi.HubMode.controls, h.net_return.?);
    const ta = h.hub_target orelse return error.MissingTarget;
    try testing.expectEqual(@as(f32, 520), ta.w);
    try testing.expectEqual(@as(f32, 420), ta.h);

    // Re-entry mid-fade converges at once: a second tap commits the
    // open immediately instead of lingering in controls.
    h.openNetworkFaded(&state, .bluetooth);
    try testing.expectEqual(HubUi.HubMode.network, h.hubmode);
    // ...but the tab hint still applies.
    try testing.expectEqual(HubUi.NetTab.bluetooth, h.net_tab);

    // Bar toggles are swallowed while a fade is in flight (the fade
    // converges on open): fresh fade, then a toggle must not disturb it.
    // (hubFrame clears controls_fade_start when the fade settles; headless
    // there are no frames, so retire the previous fade by hand.)
    h.controls_fade_start = null;
    h.switchMode(.controls, &state);
    h.openNetworkFaded(&state, null);
    // Null tab keeps the current one.
    try testing.expectEqual(HubUi.NetTab.bluetooth, h.net_tab);
    h.toggleNetworkMenu(&state);
    try testing.expectEqual(HubUi.HubMode.controls, h.hubmode);
    try testing.expect(h.controls_fade_start != null);
}

test "hub_ui: openNetworkFaded outside controls switches at once" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();

    var h = HubUi.init();
    h.openNetworkFaded(&state, null);
    try testing.expect(h.controls_fade_start == null);
    try testing.expectEqual(HubUi.HubMode.network, h.hubmode);
    // No tophub origin: no back button.
    try testing.expect(h.net_return == null);
}

test "hub_ui: saturatingAge never underflows" {
    try testing.expectEqual(@as(u64, 0), HubUi.saturatingAge(1000, 1000));
    try testing.expectEqual(@as(u64, 499), HubUi.saturatingAge(1499, 1000));
    // Fresh stamp newer than the frame clock (fade midpoint commit
    // racing the millisecond): saturates instead of panicking.
    try testing.expectEqual(@as(u64, 0), HubUi.saturatingAge(1000, 1001));
    try testing.expectEqual(@as(u64, 0), HubUi.saturatingAge(0, std.math.maxInt(u64)));
}

test "hub_ui: opening a menu from clock requests hub focus" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();

    const hubFocusRequests = struct {
        fn count(s: *State, a: std.mem.Allocator, io_: std.Io) !usize {
            var batch: std.ArrayList(State.Action) = .empty;
            defer batch.deinit(a);
            s.req_q.popAll(io_, &batch);
            var n: usize = 0;
            for (batch.items) |act| switch (act) {
                .request_keyboard_focus => n += 1,
                else => {},
            };
            return n;
        }
    }.count;

    var h = HubUi.init();
    h.switchMode(.launcher, &state);
    try testing.expectEqual(@as(usize, 1), try hubFocusRequests(&state, alloc, io));
    // Re-entering the same menu, moving between menus, or clock entry
    // itself requests nothing further.
    h.switchMode(.launcher, &state);
    h.switchMode(.network, &state);
    h.switchMode(.clock, &state);
    try testing.expectEqual(@as(usize, 0), try hubFocusRequests(&state, alloc, io));
}

test "hub_ui: leaving network retires the back-button origin" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();

    var h = HubUi.init();
    h.switchMode(.controls, &state);
    h.openNetworkFaded(&state, .bluetooth);
    try testing.expectEqual(HubUi.HubMode.controls, h.net_return.?);
    // The fade midpoint commit keeps the origin...
    h.switchMode(.network, &state);
    try testing.expectEqual(HubUi.HubMode.controls, h.net_return.?);
    // ...leaving the panel clears it.
    h.switchMode(.clock, &state);
    try testing.expect(h.net_return == null);
}

test "hub_ui: focus loss always lands in clock mode" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();
    try addWindows(&state, 1);

    // From the launcher, even when another menu was last.
    var h = HubUi.init();
    h.switchMode(.launcher, &state);
    h.last_hubmode = .network;
    h.hub_keyboard_focused = false;
    _ = h.updateSwitcher(2000, &state);
    try testing.expectEqual(HubUi.HubMode.clock, h.hubmode);

    // From the network panel: selection state is cleaned too.
    h.switchMode(.network, &state);
    h.net_sel = 7;
    h.net_sel_open = true;
    h.hub_keyboard_focused = true;
    h.hub_prev_keyboard_focused = true;
    h.hub_keyboard_focused = false;
    _ = h.updateSwitcher(2100, &state);
    try testing.expectEqual(HubUi.HubMode.clock, h.hubmode);
    try testing.expect(h.net_sel == null);
    try testing.expect(!h.net_sel_open);
}

test "hub_ui: network escape honors the tophub origin" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();

    // Opened from the control center: Escape goes back to it.
    var h = HubUi.init();
    h.switchMode(.controls, &state);
    h.openNetworkFaded(&state, .wifi);
    h.switchMode(.network, &state); // fade midpoint commit
    try testing.expect(h.handleNetworkKey(.escape, .down, &state));
    try testing.expectEqual(HubUi.HubMode.controls, h.hubmode);
    try testing.expect(h.net_return == null);

    // Opened from the bar: Escape goes to clock.
    h.switchMode(.network, &state);
    try testing.expect(h.handleNetworkKey(.escape, .down, &state));
    try testing.expectEqual(HubUi.HubMode.clock, h.hubmode);
}

test "hub_ui: aborting the fade cleans the transition" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();

    var h = HubUi.init();
    h.switchMode(.controls, &state);
    h.openNetworkFaded(&state, .wifi);
    try testing.expect(h.controls_fade_start != null);
    // Focus loss mid-fade lands in clock with no stale transition.
    h.hub_keyboard_focused = false;
    _ = h.updateSwitcher(2000, &state);
    try testing.expectEqual(HubUi.HubMode.clock, h.hubmode);
    try testing.expect(h.controls_fade_start == null);
}

test "hub_ui: network dismisses on focus loss edge" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();

    var h = HubUi.init();
    h.switchMode(.network, &state);
    try testing.expectEqual(HubUi.HubMode.network, h.hubmode);

    // Edge (prev focused, now not): dismisses back to clock.
    h.hub_keyboard_focused = false;
    _ = h.updateSwitcher(2000, &state);
    try testing.expectEqual(HubUi.HubMode.clock, h.hubmode);
    h.hub_prev_keyboard_focused = h.hub_keyboard_focused;

    // Level (already unfocused, no new edge): a reopened panel stays.
    h.switchMode(.network, &state);
    _ = h.updateSwitcher(2100, &state);
    try testing.expectEqual(HubUi.HubMode.network, h.hubmode);
}

test "hub_ui: entering clock pushes focus to head window" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();
    try addWindows(&state, 2); // ids 100, 101; head is MRU

    var h = HubUi.init();
    h.hub_keyboard_focused = true;
    h.switchMode(.network, &state);
    h.switchMode(.clock, &state);

    var batch: std.ArrayList(State.Action) = .empty;
    defer batch.deinit(alloc);
    state.req_q.popAll(io, &batch);
    var focus_actions: usize = 0;
    for (batch.items) |a| switch (a) {
        .focus_window => |id| {
            focus_actions += 1;
            try testing.expectEqual(@as(u64, 100), id);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), focus_actions);
}

test "hub_ui: clock entry pushes no focus when unfocused or empty" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();
    try addWindows(&state, 1);

    var h = HubUi.init();
    // Hub doesn't hold focus: nothing to push away.
    h.hub_keyboard_focused = false;
    h.hub_prev_keyboard_focused = false;
    h.switchMode(.network, &state);
    h.switchMode(.clock, &state);

    var batch: std.ArrayList(State.Action) = .empty;
    defer batch.deinit(alloc);
    state.req_q.popAll(io, &batch);
    for (batch.items) |a| switch (a) {
        .focus_window => return error.UnexpectedFocus,
        else => {},
    };
}

test "hub_ui: switcher commit suppresses the clock push" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();
    try addWindows(&state, 3);

    var h = HubUi.init();
    h.hub_keyboard_focused = true;
    h.selectIndex(&state, 1);
    h.commitSwitcherSelection(&state); // focus_window 101
    h.switchMode(.clock, &state); // must not override with head (100)

    var batch: std.ArrayList(State.Action) = .empty;
    defer batch.deinit(alloc);
    state.req_q.popAll(io, &batch);
    var focus_actions: usize = 0;
    for (batch.items) |a| switch (a) {
        .focus_window => |id| {
            focus_actions += 1;
            try testing.expectEqual(@as(u64, 101), id);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), focus_actions);
}

test "hub_ui: connectToAp enqueues a tracked request" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();
    try state.net.devices.append(alloc, .{
        .path = try alloc.dupe(u8, "/dev/1"),
        .iface = try alloc.dupe(u8, "wlan0"),
        .kind = .wifi,
        .state = 100,
    });

    var h = HubUi.init();
    const ap = State.Net.ApView{
        .id = 7,
        .path = "/ap/1",
        .ssid = "Home",
        .strength = 80,
        .secured = true,
        .freq_mhz = 5180,
        .active = false,
    };
    h.connectToAp(&state, "/dev/1", ap, "secret");
    const req = h.net_req orelse return error.MissingRequest;
    try testing.expect(req.isQueued());
    try testing.expectEqual(@as(u64, 7), h.net_req_ap);
}

test "hub_ui: errFlashRed flashes twice then stops" {
    // 10-frame periods (5 red, 5 transparent), twice.
    for (0..5) |f| try testing.expect(HubUi.errFlashRed(@intCast(f)));
    for (5..10) |f| try testing.expect(!HubUi.errFlashRed(@intCast(f)));
    for (10..15) |f| try testing.expect(HubUi.errFlashRed(@intCast(f)));
    for (15..20) |f| try testing.expect(!HubUi.errFlashRed(@intCast(f)));
    // Then steady transparent.
    try testing.expect(!HubUi.errFlashRed(20));
    try testing.expect(!HubUi.errFlashRed(1000));
}

test "hub_ui: animFrac eases 0 to 1 on the shared clock" {
    try testing.expectEqual(@as(f32, 0), HubUi.animFrac(1000, 1000));
    const mid = HubUi.animFrac(1000, 1000 + 67);
    try testing.expect(mid > 0 and mid < 1);
    try testing.expectEqual(@as(f32, 1), HubUi.animFrac(1000, 1000 + HubUi.net_anim_ms));
    try testing.expectEqual(@as(f32, 1), HubUi.animFrac(1000, 1000 + 10000));
}

test "hub_ui: netRowHeight animates on the hub curve" {
    var h = HubUi.init();

    // Idle: exact targets (shut = 32 header + 12 padding).
    try testing.expectEqual(@as(f32, 44), h.netRowHeight(7, false, 1000));
    try testing.expectEqual(@as(f32, 72), h.netRowHeight(7, true, 1000));

    // Opening from shut: mid-flight strictly between, settled exact.
    h.net_anim_open_ap = null;
    h.net_anim_start = 1000;
    const mid_open = h.netRowHeight(7, true, 1000 + 67);
    try testing.expect(mid_open > 44 and mid_open < 72);
    try testing.expectEqual(@as(f32, 72), h.netRowHeight(7, true, 1000 + HubUi.net_anim_ms));
    try testing.expectEqual(@as(f32, 72), h.netRowHeight(7, true, 1000 + 10000));

    // Closing from open; a shut row is untouched mid-flight, while a
    // newly opened row animates up from shut on the same clock.
    h.net_anim_open_ap = 7;
    h.net_anim_start = 2000;
    const mid_shut = h.netRowHeight(7, false, 2000 + 67);
    try testing.expect(mid_shut > 44 and mid_shut < 72);
    try testing.expectEqual(@as(f32, 44), h.netRowHeight(9, false, 2000 + 30));
    const mid_open2 = h.netRowHeight(9, true, 2000 + 30);
    try testing.expect(mid_open2 > 44 and mid_open2 < 72);
    try testing.expectEqual(@as(f32, 72), h.netRowHeight(9, true, 2000 + 10000));
}

test "hub_ui: pressed sees no keys headless" {
    // No frame events exist outside a live window; the scan must simply
    // report false instead of failing to compile against the shim.
    try testing.expect(!HubUi.pressed(.escape));
    try testing.expect(!HubUi.pressed(.enter));
}

test "hub_ui: focus lost commits selection and resets" {
    const alloc = testing.allocator;
    const io = testing.io;

    var state = State{};
    state.socket_path_override = "/tmp/nshell-hubui-unused.sock";
    try state.init(alloc, io);
    defer state.deinit();
    try addWindows(&state, 3);

    var h = HubUi.init();

    _ = h.handleGlobalKey(.tab, .down, false, 1000, &state);
    h.hub_keyboard_focused = false; // MOD released
    _ = h.updateSwitcher(1050, &state);
    try testing.expectEqual(HubUi.HubMode.clock, h.hubmode);
    try testing.expect(!h.switcher_pending);
    try testing.expectEqual(@as(usize, 0), h.selected);

    // The committed selection must have enqueued exactly one focus_window
    // for the window the tab advanced to (index 1 => id 101).
    var batch: std.ArrayList(State.Action) = .empty;
    defer batch.deinit(alloc);
    state.req_q.popAll(io, &batch);
    var focus_actions: usize = 0;
    for (batch.items) |a| switch (a) {
        .focus_window => |id| {
            focus_actions += 1;
            try testing.expectEqual(@as(u64, 101), id);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), focus_actions);
}
