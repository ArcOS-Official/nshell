const std = @import("std");
const dvui = @import("dvui");
const nilebank = @import("nilebank");
const proto = nilebank.protocols.compositor;
const State = @import("State.zig");

// Headless tests for the 2-way nilebank API (see ../nilebank, ../nile Bank.zig):
// one connection carries requests and server broadcasts; the reader fiber
// feeds the commit queue, update() applies, worker sends.

const Ctx = struct {
    alloc: std.mem.Allocator,
    switch_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    focus_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    capture_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    // Set when the worker declares the hub namespace after (re)connect.
    shell_registered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Fail the first capture for window 102, succeed after: proves a
    // transient error backs off and retries instead of disabling
    // thumbnails forever.
    cap102_calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn fakeHandler(ctx: ?*anyopaque, msg: nilebank.Message) anyerror!nilebank.Message {
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    const alloc = c.alloc;
    const req = try nilebank.decodeCompositorRequest(alloc, msg);
    defer req.deinit(alloc);

    const resp: proto.Event = switch (req) {
        .list_workspaces => blk: {
            const ws = try alloc.alloc(proto.Workspace, 2);
            ws[0] = .{ .id = 10, .number = 1, .name = try alloc.dupe(u8, "main"), .active = true, .current = true, .output = 1 };
            ws[1] = .{ .id = 20, .number = 2, .name = try alloc.dupe(u8, "code"), .active = false, .current = false, .urgent = true, .output = 1 };
            break :blk .{ .workspaces = .{ .items = ws } };
        },
        .list_windows => blk: {
            const wins = try alloc.alloc(proto.Window, 1);
            wins[0] = .{
                .id = 100,
                .title = try alloc.dupe(u8, "main.zig - nvim"),
                .app_id = try alloc.dupe(u8, "nvim"),
                .workspace = 10,
                .output = 1,
                .focused = true,
            };
            break :blk .{ .windows = .{ .items = wins } };
        },
        .switch_workspace => |v| blk: {
            c.switch_id.store(v.id, .seq_cst);
            break :blk .{ .pong = .{ .nonce = v.id } };
        },
        .shell_register => |v| blk: {
            if (std.mem.eql(u8, v.namespace, State.shell_namespace))
                c.shell_registered.store(true, .seq_cst);
            break :blk .{ .pong = .{ .nonce = 0 } };
        },
        .focus_window => |v| blk: {
            c.focus_id.store(v.id, .seq_cst);
            break :blk .{ .pong = .{ .nonce = v.id } };
        },
        .get_window => |v| blk: {
            // Unknown id: window is gone; lets the client prune its stub.
            if (v.id == 999) {
                break :blk .{ .error_msg = .{ .code = 2, .message = try alloc.dupe(u8, "window not found") } };
            }
            const wins = try alloc.alloc(proto.Window, 1);
            wins[0] = .{
                .id = v.id,
                .title = try alloc.dupe(u8, "filled"),
                .app_id = try alloc.dupe(u8, "filled-app"),
                .workspace = 10,
                .output = 1,
            };
            break :blk .{ .windows = .{ .items = wins } };
        },
        .capture_window => |v| blk: {
            _ = c.capture_count.fetchAdd(1, .seq_cst);
            if (v.window_id == 102 and c.cap102_calls.fetchAdd(1, .seq_cst) == 0) {
                break :blk .{ .error_msg = .{ .code = 3, .message = try alloc.dupe(u8, "busy") } };
            }
            if (v.window_id == 101) {
                const data = try alloc.dupe(u8, &[_]u8{ 0, 0, 255, 255 });
                break :blk .{ .window_image = .{ .window_id = v.window_id, .image = .{
                    .width = 1,
                    .height = 1,
                    .stride = 4,
                    .format = .bgra8,
                    .data = data,
                } } };
            }
            const data = try alloc.alloc(u8, 12);
            @memcpy(data[0..8], &[_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 });
            @memset(data[8..], 0);
            break :blk .{ .window_image = .{ .window_id = v.window_id, .image = .{
                .width = 2,
                .height = 1,
                .stride = 12,
                .format = .rgba8,
                .data = data,
            } } };
        },
        else => .{ .error_msg = .{ .code = 1, .message = try alloc.dupe(u8, "unsupported") } },
    };
    var ev_copy = resp;
    defer ev_copy.deinit(alloc);
    return try nilebank.encodeCompositorEventDefault(alloc, ev_copy);
}

test "state: query, broadcast override, actions, images via 2-way connection" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;

    const path = "/tmp/nshell-state2-test.sock";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    var ctx = Ctx{ .alloc = alloc };
    const server = try nilebank.servePath(alloc, io, path, fakeHandler, &ctx);
    defer server.deinit();

    var state = State{};
    state.socket_path_override = path;
    try state.init(alloc, io);
    const wt = try std.Thread.spawn(.{}, State.worker, .{ &state, io });
    // Teardown via defer (deinit first, then join) so a failing assertion
    // can't leak the worker into freed state and segfault the binary.
    defer wt.join();
    defer state.deinit();

    // Initial query populates the model.
    var tries: usize = 0;
    while (tries < 1000) : (tries += 1) {
        state.update();
        if (state.workspaces.len == 2 and state.windows.len == 1) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 2), state.workspaces.len);
    try t.expectEqual(@as(usize, 1), state.windows.len);
    try t.expectEqualStrings("main", state.workspaces[0].name);
    try t.expectEqualStrings("main.zig - nvim", state.windows[0].title);

    // Shell registration: the worker declares the hub namespace on
    // (re)connect so the compositor can focus it on MOD press.
    tries = 0;
    while (!ctx.shell_registered.load(.seq_cst) and tries < 500) : (tries += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(ctx.shell_registered.load(.seq_cst));

    // Launcher pushes (compositor MOD tap) are for the app launcher,
    // not the window switcher — State intentionally ignores them for
    // switcher; hubFrame would own a simple local hub_* var if needed.
    // Verify they are harmless and don't affect switcher state.
    {
        var ev: proto.Event = .{ .launcher_opened = {} };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    {
        var ev: proto.Event = .{ .launcher_closed = {} };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    // Drain them; no launcher_open field to check — just ensure update
    // doesn't crash and model stays intact.
    tries = 0;
    while (tries < 20) : (tries += 1) {
        state.update();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 1), state.windows.len);

    // Compositor-driven hub focus: the worker stores `shell_focus_changed`
    // pushes straight into the bound HubUi flag (no commit-queue round
    // trip), so the UI thread observes the edge on its next frame.
    {
        var hub_focused = std.atomic.Value(bool).init(true);
        state.bindHubFocus(&hub_focused);
        {
            var ev: proto.Event = .{ .shell_focus_changed = .{ .focused = false } };
            defer ev.deinit(alloc);
            try server.broadcastCompositorEventDefault(ev);
        }
        tries = 0;
        while (hub_focused.load(.seq_cst) and tries < 500) : (tries += 1) {
            io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
        try t.expect(!hub_focused.load(.seq_cst));
        {
            var ev: proto.Event = .{ .shell_focus_changed = .{ .focused = true } };
            defer ev.deinit(alloc);
            try server.broadcastCompositorEventDefault(ev);
        }
        tries = 0;
        while (!hub_focused.load(.seq_cst) and tries < 500) : (tries += 1) {
            io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
        try t.expect(hub_focused.load(.seq_cst));
        // Focus pushes carry no model state: the windows list is untouched
        // and no commit was queued for update() to apply.
        state.update();
        try t.expectEqual(@as(usize, 1), state.windows.len);
    }

    // Broadcast overrides current state without any new request.
    {
        var ev: proto.Event = .{ .window_title_changed = .{ .id = 100, .title = try alloc.dupe(u8, "hello") } };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    tries = 0;
    while (tries < 500) : (tries += 1) {
        state.update();
        if (state.windows.len == 1 and std.mem.eql(u8, state.windows[0].title, "hello")) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqualStrings("hello", state.windows[0].title);

    // Unknown window converges via get_window fill WITHOUT wiping the
    // existing list (regression: fills used to replace the whole model,
    // so the switcher showed only one window).
    {
        var ev: proto.Event = .{ .new_window = .{ .id = 101, .title = try alloc.dupe(u8, "fresh") } };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    tries = 0;
    while (tries < 500) : (tries += 1) {
        state.update();
        var filled = false;
        for (state.windows) |*w| {
            if (w.id == 101 and std.mem.eql(u8, w.app_id, "filled-app")) filled = true;
        }
        if (filled) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    {
        var found = false;
        for (state.windows) |*w| {
            if (w.id != 101) continue;
            found = true;
            try t.expectEqualStrings("filled", w.title);
        }
        try t.expect(found);
        // The pre-existing window must survive the fill.
        try t.expectEqual(@as(usize, 2), state.windows.len);
        try t.expectEqualStrings("hello", state.windows[0].title);
    }

    // Focus order: a window_focused push moves the row to the front (MRU)
    // so the switcher lists index 0 = currently focused.
    {
        var ev: proto.Event = .{ .window_focused = .{ .id = 101, .old_id = 100 } };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    tries = 0;
    while (tries < 500) : (tries += 1) {
        state.update();
        if (state.windows.len == 2 and state.windows[0].id == 101) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(u64, 101), state.windows[0].id);
    try t.expectEqual(@as(u64, 100), state.windows[1].id);
    try t.expect(state.windows[0].focused);
    try t.expect(!state.windows[1].focused);

    // Full-list pushes (e.g. the server's MRU re-push on focus change)
    // replace in the transmitted order.
    {
        const items = try alloc.alloc(proto.Window, 2);
        items[0] = .{ .id = 100, .title = try alloc.dupe(u8, "hello"), .focused = true };
        items[1] = .{ .id = 101, .title = try alloc.dupe(u8, "filled"), .focused = false };
        var ev: proto.Event = .{ .windows = .{ .items = items } };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    tries = 0;
    while (tries < 500) : (tries += 1) {
        state.update();
        if (state.windows.len == 2 and state.windows[0].id == 100 and state.windows[0].focused) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(u64, 100), state.windows[0].id);
    try t.expectEqual(@as(u64, 101), state.windows[1].id);

    // Gone window: a get_window error prunes the stub instead of leaving a
    // blank switcher entry.
    {
        var ev: proto.Event = .{ .new_window = .{ .id = 999, .title = try alloc.dupe(u8, "ghost") } };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    var saw_ghost = false;
    tries = 0;
    while (tries < 1000) : (tries += 1) {
        state.update();
        var ghost = false;
        for (state.windows) |*w| {
            if (w.id == 999) ghost = true;
        }
        if (ghost) saw_ghost = true;
        // Wait until the stub appears AND is then pruned by the error fill.
        if (saw_ghost and !ghost) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(saw_ghost);
    for (state.windows) |*w| try t.expect(w.id != 999);
    try t.expectEqual(@as(usize, 2), state.windows.len);

    // Actions reach the server.
    state.switchWorkspace(42);
    tries = 0;
    while (ctx.switch_id.load(.seq_cst) != 42 and tries < 500) : (tries += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(u64, 42), ctx.switch_id.load(.seq_cst));

    state.focusWindow(99);
    tries = 0;
    while (ctx.focus_id.load(.seq_cst) != 99 and tries < 500) : (tries += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(u64, 99), ctx.focus_id.load(.seq_cst));

    // Images: miss enqueues one capture; pixels land in the map; repeats
    // are served from cache with no new traffic.
    try t.expect(state.windowImage(100) == null);
    var j: usize = 0;
    while (j < 10) : (j += 1) _ = state.windowImage(100);
    tries = 0;
    while (ctx.capture_count.load(.seq_cst) != 1 and tries < 1000) : (tries += 1) {
        state.update();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 1), ctx.capture_count.load(.seq_cst));
    var img: ?dvui.ImageSource = null;
    tries = 0;
    while (tries < 1000) : (tries += 1) {
        state.update();
        img = state.windowImage(100);
        if (img != null) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(img != null);
    try t.expectEqual(@as(u32, 2), img.?.pixels.width);
    try t.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 }, img.?.pixels.rgba);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const again = state.windowImage(100);
        try t.expect(again != null);
    }
    try t.expectEqual(@as(usize, 1), ctx.capture_count.load(.seq_cst));

    // bgra8 source is normalized to RGBA (blue -> red).
    _ = state.windowImage(101);
    var img101: ?dvui.ImageSource = null;
    tries = 0;
    while (tries < 1000) : (tries += 1) {
        state.update();
        img101 = state.windowImage(101);
        if (img101 != null) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(img101 != null);
    try t.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, img101.?.pixels.rgba);

    // Transient capture error backs off and retries: the first request for
    // 102 fails with code 3, but the thumbnail must still arrive instead of
    // being disabled forever.
    _ = state.windowImage(102);
    var img102: ?dvui.ImageSource = null;
    tries = 0;
    while (tries < 1500) : (tries += 1) {
        state.update();
        img102 = state.windowImage(102);
        if (img102 != null) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(img102 != null);
    try t.expectEqual(@as(u32, 2), img102.?.pixels.width);
    try t.expect(ctx.cap102_calls.load(.seq_cst) >= 2);

    // Prefetch coalescing: back-to-back prefetches issue no duplicate
    // traffic. Drain the first prefetch, snapshot, then prefetch again —
    // everything is freshly requested/fetched, so the second adds nothing.
    // (Sleeps stay well under the 2s image TTL so refetch can't kick in.)
    state.prefetchWindowImages();
    var drain: usize = 0;
    while (drain < 60) : (drain += 1) {
        state.update();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    const after_first_prefetch = ctx.capture_count.load(.seq_cst);
    state.prefetchWindowImages();
    var spins: usize = 0;
    while (spins < 60) : (spins += 1) {
        state.update();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(after_first_prefetch, ctx.capture_count.load(.seq_cst));

    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}
