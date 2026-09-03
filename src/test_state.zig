const std = @import("std");
const nilebank = @import("nilebank");
const proto = nilebank.protocols.compositor;
const State = @import("State.zig");

var test_alloc: std.mem.Allocator = undefined;
var test_switch_workspace_id: ?u64 = null;
var test_focus_window_id: ?u64 = null;
var test_close_window_id: ?u64 = null;
var test_poll_count: usize = 0;

fn fakeCompositorCallback(msg: nilebank.Message) anyerror!nilebank.Message {
    const alloc = test_alloc;
    const req = try nilebank.decodeCompositorRequest(alloc, msg);
    defer req.deinit(alloc);

    const resp: proto.Event = switch (req) {
        .list_workspaces => blk: {
            if (test_poll_count > 0) {
                break :blk .{ .workspaces = .{ .items = &.{} } };
            }
            const ws = try alloc.alloc(proto.Workspace, 2);
            ws[0] = .{
                .id = 10,
                .number = 1,
                .name = try alloc.dupe(u8, "main"),
                .active = true,
                .current = true,
                .urgent = false,
                .output = 1,
            };
            ws[1] = .{
                .id = 20,
                .number = 2,
                .name = try alloc.dupe(u8, "code"),
                .active = false,
                .current = false,
                .urgent = true,
                .output = 1,
            };
            break :blk .{ .workspaces = .{ .items = ws } };
        },
        .list_windows => blk: {
            if (test_poll_count > 0) {
                break :blk .{ .windows = .{ .items = &.{} } };
            }
            const wins = try alloc.alloc(proto.Window, 1);
            wins[0] = .{
                .id = 100,
                .title = try alloc.dupe(u8, "main.zig - nvim"),
                .app_id = try alloc.dupe(u8, "nvim"),
                .workspace = 10,
                .output = 1,
                .pid = 12345,
                .rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
                .floating = false,
                .fullscreen = false,
                .focused = true,
                .urgent = false,
            };
            break :blk .{ .windows = .{ .items = wins } };
        },
        .list_outputs => blk: {
            if (test_poll_count > 0) {
                break :blk .{ .outputs = .{ .items = &.{} } };
            }
            const outs = try alloc.alloc(proto.Output, 1);
            outs[0] = .{
                .id = 1,
                .name = try alloc.dupe(u8, "eDP-1"),
                .make = try alloc.dupe(u8, "LG"),
                .model = try alloc.dupe(u8, "Display"),
                .x = 0,
                .y = 0,
                .mode = .{ .width = 2560, .height = 1440, .refresh = 60000 },
                .scale = 1000,
                .enabled = true,
            };
            break :blk .{ .outputs = .{ .items = outs } };
        },
        .switch_workspace => |v| blk: {
            test_switch_workspace_id = v.id;
            break :blk .{ .pong = .{} };
        },
        .focus_window => |v| blk: {
            test_focus_window_id = v.id;
            break :blk .{ .pong = .{} };
        },
        .close_window => |v| blk: {
            test_close_window_id = v.id;
            break :blk .{ .pong = .{} };
        },
        else => .{ .error_msg = .{ .code = 1, .message = try alloc.dupe(u8, "unsupported") } },
    };

    var ev_copy = resp;
    defer ev_copy.deinit(alloc);
    const enc: nilebank.CompositorEncoding = switch (resp) {
        .windows, .workspaces, .outputs, .windows_snapshot, .workspaces_snapshot, .outputs_snapshot => .deflate,
        else => .raw,
    };
    return try nilebank.encodeCompositorEvent(alloc, ev_copy, enc);
}

test "state: poll and actions via fake compositor" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    test_alloc = alloc;
    test_poll_count = 0;
    test_switch_workspace_id = null;
    test_focus_window_id = null;
    test_close_window_id = null;

    const path = "/tmp/nshell-state-test.sock";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    const server = try nilebank.servePath(alloc, io, path, fakeCompositorCallback);
    defer {
        server.deinit();
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }

    var state = State{};
    try state.init();
    defer state.deinit();

    state.connectTo(path);
    try t.expect(state.connected);
    try t.expect(state.conn != null);

    // First poll: should populate state
    state.last_fetch_ms = 0;
    state.poll();
    try t.expectEqual(@as(usize, 2), state.workspaces.len);
    try t.expectEqual(@as(usize, 1), state.windows.len);
    try t.expectEqual(@as(usize, 1), state.outputs.len);

    // Verify workspace fields
    {
        const ws0 = state.workspaces[0];
        try t.expectEqual(@as(u64, 10), ws0.id);
        try t.expectEqual(@as(u8, 1), ws0.number);
        try t.expectEqualStrings("main", ws0.name);
        try t.expectEqual(true, ws0.active);
        try t.expectEqual(true, ws0.current);
        try t.expectEqual(false, ws0.urgent);
        try t.expectEqual(@as(u64, 1), ws0.output);
    }
    {
        const ws1 = state.workspaces[1];
        try t.expectEqual(@as(u64, 20), ws1.id);
        try t.expectEqual(@as(u8, 2), ws1.number);
        try t.expectEqualStrings("code", ws1.name);
        try t.expectEqual(false, ws1.active);
        try t.expectEqual(false, ws1.current);
        try t.expectEqual(true, ws1.urgent);
    }

    // Verify window fields
    {
        const w0 = state.windows[0];
        try t.expectEqual(@as(u64, 100), w0.id);
        try t.expectEqualStrings("main.zig - nvim", w0.title);
        try t.expectEqualStrings("nvim", w0.app_id);
        try t.expectEqual(@as(u64, 10), w0.workspace);
        try t.expectEqual(@as(u64, 1), w0.output);
        try t.expectEqual(@as(u32, 12345), w0.pid);
        try t.expectEqual(true, w0.focused);
        try t.expectEqual(false, w0.floating);
        try t.expectEqual(false, w0.fullscreen);
        try t.expectEqual(false, w0.urgent);
    }

    // Verify output fields
    {
        const o0 = state.outputs[0];
        try t.expectEqual(@as(u64, 1), o0.id);
        try t.expectEqualStrings("eDP-1", o0.name);
        try t.expectEqualStrings("LG", o0.make);
        try t.expectEqualStrings("Display", o0.model);
        try t.expectEqual(@as(u32, 2560), o0.mode.width);
        try t.expectEqual(@as(u32, 1440), o0.mode.height);
        try t.expectEqual(@as(u32, 60000), o0.mode.refresh);
        try t.expectEqual(@as(u32, 1000), o0.scale);
        try t.expectEqual(true, o0.enabled);
    }

    // Verify focused_id derivation
    try t.expect(state.focused_id != null);
    try t.expectEqual(@as(u64, 100), state.focused_id.?);

    // Test focusedWindow helper
    {
        const fw = state.focusedWindow();
        try t.expect(fw != null);
        try t.expectEqualStrings("nvim", fw.?.app_id);
    }

    // Test switchWorkspace action
    state.switchWorkspace(42);
    try t.expect(test_switch_workspace_id != null);
    try t.expectEqual(@as(u64, 42), test_switch_workspace_id.?);

    // Test focusWindow action
    state.focusWindow(99);
    try t.expect(test_focus_window_id != null);
    try t.expectEqual(@as(u64, 99), test_focus_window_id.?);

    // Test closeWindow action
    state.closeWindow(77);
    try t.expect(test_close_window_id != null);
    try t.expectEqual(@as(u64, 77), test_close_window_id.?);

    // Second poll: compositor returns empty lists — state should clear
    test_poll_count = 1;
    state.last_fetch_ms = 0;
    state.poll();
    try t.expectEqual(@as(usize, 0), state.workspaces.len);
    try t.expectEqual(@as(usize, 0), state.windows.len);
    try t.expectEqual(@as(usize, 0), state.outputs.len);
    try t.expect(state.focused_id == null);
    try t.expect(state.focusedWindow() == null);
}
