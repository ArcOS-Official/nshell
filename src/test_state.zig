const std = @import("std");
const nilebank = @import("nilebank");
const proto = nilebank.protocols.compositor;
const State = @import("State.zig");

var test_alloc: std.mem.Allocator = undefined;
var test_switch_workspace_id: ?u64 = null;
var test_focus_window_id: ?u64 = null;
var test_close_window_id: ?u64 = null;
var test_poll_count: usize = 0;
var test_fetch_count: usize = 0;

fn fakeCompositorCallback(msg: nilebank.Message) anyerror!nilebank.Message {
    const alloc = test_alloc;
    const req = try nilebank.decodeCompositorRequest(alloc, msg);
    defer req.deinit(alloc);

    const resp: proto.Event = switch (req) {
        .list_workspaces => blk: {
            test_fetch_count += 1;
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

fn probeCallback(msg: nilebank.Message) anyerror!nilebank.Message {
    const alloc = test_alloc;
    const req = try nilebank.decodeCompositorRequest(alloc, msg);
    defer req.deinit(alloc);
    const resp: proto.Event = switch (req) {
        .ping => .{ .pong = .{ .nonce = 0x4E494C45 } },
        else => .{ .error_msg = .{ .code = 1, .message = try alloc.dupe(u8, "unsupported") } },
    };
    var ev_copy = resp;
    defer ev_copy.deinit(alloc);
    return try nilebank.encodeCompositorEvent(alloc, ev_copy, .raw);
}

test "nilebank: id-based init resolves the compositor socket dir" {
    // Guards the /tmp/arcos vs /run/arcos regression: nshell's worker
    // connects by id (`Connection.init("compositor")`), so the pinned
    // nilebank must resolve the same path the compositor serves
    // (`/tmp/arcos/<id>.sock`, see ../nile/nile/Bank.zig).
    // Uses a probe id to avoid clashing with a live compositor.
    // NOTE: id-based `serve()` itself doesn't compile on Zig 0.16
    // (`std.fs.cwd()` removed), so the server side uses an explicit path.
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    test_alloc = alloc;

    std.Io.Dir.createDirAbsolute(io, "/tmp/arcos", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const server = try nilebank.servePath(alloc, io, "/tmp/arcos/nshell-probe.sock", probeCallback);
    defer server.deinit();

    var conn = try nilebank.Connection.init(alloc, io, "nshell-probe");
    defer conn.close();

    const req = proto.Request{ .ping = {} };
    const ev = try req.send(&conn, .{ .encoding = .raw });
    defer ev.deinit(alloc);
    switch (ev) {
        .pong => |p| try t.expectEqual(@as(u64, 0x4E494C45), p.nonce),
        else => return error.TestUnexpectedResult,
    }
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

    const server = try nilebank.servePath(alloc, io, path, fakeCompositorCallback);
    defer {
        server.deinit();
    }

    var state = State{};
    // Hermetic: no event stream here, exercise the polling fallback.
    state.stream_path_override = "/tmp/nshell-no-stream.sock";
    try state.init();
    defer state.deinit();

    state.connectTo(path);

    // Worker is async: wait for the first snapshot (connect + fetch).
    var tries: usize = 0;
    while (tries < 1000) : (tries += 1) {
        state.poll();
        if (state.connected and state.workspaces.len == 2 and state.windows.len == 1 and state.outputs.len == 1) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(state.connected);
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

    // Actions are queued to the worker: wait for the fake compositor to see them.
    state.switchWorkspace(42);
    tries = 0;
    while (test_switch_workspace_id != 42 and tries < 500) : (tries += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(test_switch_workspace_id != null);
    try t.expectEqual(@as(u64, 42), test_switch_workspace_id.?);

    // Test focusWindow action
    state.focusWindow(99);
    tries = 0;
    while (test_focus_window_id != 99 and tries < 500) : (tries += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(test_focus_window_id != null);
    try t.expectEqual(@as(u64, 99), test_focus_window_id.?);

    // Test closeWindow action
    state.closeWindow(77);
    tries = 0;
    while (test_close_window_id != 77 and tries < 500) : (tries += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(test_close_window_id != null);
    try t.expectEqual(@as(u64, 77), test_close_window_id.?);

    // Second phase: compositor returns empty lists — state should clear.
    test_poll_count = 1;
    tries = 0;
    while (tries < 1000) : (tries += 1) {
        state.poll();
        if (state.workspaces.len == 0 and state.windows.len == 0 and state.outputs.len == 0) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 0), state.workspaces.len);
    try t.expectEqual(@as(usize, 0), state.windows.len);
    try t.expectEqual(@as(usize, 0), state.outputs.len);
    try t.expect(state.focused_id == null);
    try t.expect(state.focusedWindow() == null);
}

// ---------------------------------------------------------------------------
// Event-stream integration: fake push server + fetch counting.
// ---------------------------------------------------------------------------

const stream_test_path = "/tmp/nshell-stream-test.sock";

var stream_accepted = std.atomic.Value(bool).init(false);
var stream_phase = std.atomic.Value(u32).init(0); // 0 hold, 1 send event, 2 sent, 3 close

fn sendStreamEvent(stream: std.Io.net.Stream, io: std.Io, ev: proto.Event) !void {
    const alloc = test_alloc;
    var m = ev;
    defer m.deinit(alloc);
    const enc = proto.encodingForEvent(@as(proto.EventTag, m));
    const msg = try nilebank.encodeCompositorEvent(alloc, m, enc);
    defer if (msg.data.len > 0) alloc.free(@constCast(msg.data));
    const hdr = nilebank.Header{
        .kind = msg.kind,
        .encoding = msg.encoding,
        .length = @as(u16, @intCast(msg.data.len)),
    };
    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(&hdr.toBytes());
    try w.interface.writeAll(msg.data);
    try w.interface.flush();
}

fn streamAcceptorMain(io: std.Io, path: []const u8) void {
    const addr = std.Io.net.UnixAddress.init(path) catch return;
    var server = addr.listen(io, .{}) catch return;
    defer server.deinit(io);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    var client = server.accept(io) catch return;
    defer client.close(io);
    stream_accepted.store(true, .seq_cst);
    // Catch-up snapshots, like the real Bank sends on connect.
    sendStreamEvent(client, io, .{ .windows_snapshot = .{ .items = &.{} } }) catch return;
    sendStreamEvent(client, io, .{ .workspaces_snapshot = .{ .items = &.{} } }) catch return;
    sendStreamEvent(client, io, .{ .outputs_snapshot = .{ .items = &.{} } }) catch return;
    while (stream_phase.load(.seq_cst) < 1) {
        io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    sendStreamEvent(client, io, .{ .workspace_activated = .{ .id = 10 } }) catch return;
    stream_phase.store(2, .seq_cst);
    while (stream_phase.load(.seq_cst) < 3) {
        io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
}

test "state: event stream drives refetch, fallback when down" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    test_alloc = alloc;
    test_poll_count = 0;
    test_fetch_count = 0;
    stream_accepted.store(false, .seq_cst);
    stream_phase.store(0, .seq_cst);

    // Request/response fake (also counts fetches).
    const path = "/tmp/nshell-stream-req-test.sock";
    const server = try nilebank.servePath(alloc, io, path, fakeCompositorCallback);
    defer server.deinit();

    // Push fake on an override path so a live compositor can't interfere.
    std.Io.Dir.deleteFileAbsolute(io, stream_test_path) catch {};

    const acceptor = try std.Thread.spawn(.{}, streamAcceptorMain, .{ io, stream_test_path });
    defer acceptor.join();
    // Unblock the acceptor on any early failure so join() can't hang.
    defer stream_phase.store(3, .seq_cst);

    var state = State{};
    state.stream_path_override = stream_test_path;
    try state.init();
    defer state.deinit();

    state.connectTo(path);

    // Wait for the stream accept and the first synced snapshot.
    var tries: usize = 0;
    while ((!stream_accepted.load(.seq_cst) or state.workspaces.len != 2) and tries < 1000) : (tries += 1) {
        state.poll();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(stream_accepted.load(.seq_cst));
    try t.expectEqual(@as(usize, 2), state.workspaces.len);

    // Settle, then assert the worker is idle while the stream is quiet:
    // no periodic polling means no new fetches.
    tries = 0;
    while (tries < 30) : (tries += 1) {
        state.poll();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    const c0 = test_fetch_count;
    tries = 0;
    while (tries < 70) : (tries += 1) {
        state.poll();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(c0, test_fetch_count);

    // Push one event: the worker must re-query promptly.
    stream_phase.store(1, .seq_cst);
    tries = 0;
    while (test_fetch_count == c0 and tries < 500) : (tries += 1) {
        state.poll();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(test_fetch_count > c0);
    try t.expectEqual(@as(usize, 2), state.workspaces.len);

    // Drop the stream: fallback polling must resume.
    const c1 = test_fetch_count;
    stream_phase.store(3, .seq_cst);
    tries = 0;
    while (test_fetch_count < c1 + 2 and tries < 500) : (tries += 1) {
        state.poll();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(test_fetch_count >= c1 + 2);
}
