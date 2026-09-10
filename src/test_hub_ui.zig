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
        } else if (std.mem.eql(u8, t, "render")) {
            // Frame-level mode redirects from hubFrame's render switch.
            switch (h.hubmode) {
                .search => h.switchMode(.launcher, &state),
                .wifi => h.switchMode(.clock, &state),
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
