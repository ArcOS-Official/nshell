const std = @import("std");
const dvui = @import("dvui");
const nilebank = @import("nilebank");
const proto = nilebank.protocols.compositor;

const State = @This();

alloc: std.mem.Allocator = undefined,
threaded: std.Io.Threaded = undefined,
io: std.Io = undefined,
inited: bool = false,

conn: ?nilebank.Connection = null,
connected: bool = false,
next_reconnect_ms: i64 = 0,
last_fetch_ms: i64 = 0,

workspaces: []proto.Workspace = &.{},
windows: []proto.Window = &.{},
outputs: []proto.Output = &.{},

focused_id: ?u64 = null,

// clock cache
clock_text: [64]u8 = undefined,
clock_len: usize = 0,
last_clock_ms: i64 = 0,

// connection diagnostics
status_text: []const u8 = "disconnected",
use_mock: bool = true, // until we prove real compositor exists
mock_t: usize = 0,

fn nowMs(_: *State) i64 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    if (rc != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn realtimeSec() i64 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
    if (rc != 0) return 0;
    return @as(i64, ts.sec);
}

pub fn init(self: *State) !void {
    self.alloc = std.heap.smp_allocator;
    self.threaded = std.Io.Threaded.init(self.alloc, .{});
    self.io = self.threaded.io();
    self.inited = true;
    self.next_reconnect_ms = 0;
    // initial mock data so bar looks alive even before first poll
    try self.applyMock();
    self.updateClock();
}

pub fn deinit(self: *State) void {
    if (self.conn) |*c| {
        c.close();
        self.conn = null;
    }
    self.freeWorkspaces();
    self.freeWindows();
    self.freeOutputs();
    if (self.inited) {
        self.threaded.deinit();
        self.inited = false;
    }
}

fn freeWorkspaces(self: *State) void {
    for (self.workspaces) |*ws| ws.deinit(self.alloc);
    if (self.workspaces.len > 0) self.alloc.free(self.workspaces);
    self.workspaces = &.{};
}

fn freeWindows(self: *State) void {
    for (self.windows) |*w| w.deinit(self.alloc);
    if (self.windows.len > 0) self.alloc.free(self.windows);
    self.windows = &.{};
}

fn freeOutputs(self: *State) void {
    for (self.outputs) |*o| o.deinit(self.alloc);
    if (self.outputs.len > 0) self.alloc.free(self.outputs);
    self.outputs = &.{};
}

fn cloneWorkspace(self: *State, ws: proto.Workspace) !proto.Workspace {
    return proto.Workspace{
        .id = ws.id,
        .number = ws.number,
        .name = if (ws.name.len > 0) try self.alloc.dupe(u8, ws.name) else "",
        .active = ws.active,
        .current = ws.current,
        .urgent = ws.urgent,
        .output = ws.output,
    };
}

fn cloneWindow(self: *State, w: proto.Window) !proto.Window {
    return proto.Window{
        .id = w.id,
        .title = if (w.title.len > 0) try self.alloc.dupe(u8, w.title) else "",
        .app_id = if (w.app_id.len > 0) try self.alloc.dupe(u8, w.app_id) else "",
        .workspace = w.workspace,
        .output = w.output,
        .pid = w.pid,
        .rect = w.rect,
        .floating = w.floating,
        .fullscreen = w.fullscreen,
        .focused = w.focused,
        .urgent = w.urgent,
    };
}

fn cloneOutput(self: *State, o: proto.Output) !proto.Output {
    return proto.Output{
        .id = o.id,
        .name = if (o.name.len > 0) try self.alloc.dupe(u8, o.name) else "",
        .make = if (o.make.len > 0) try self.alloc.dupe(u8, o.make) else "",
        .model = if (o.model.len > 0) try self.alloc.dupe(u8, o.model) else "",
        .x = o.x,
        .y = o.y,
        .mode = o.mode,
        .scale = o.scale,
        .enabled = o.enabled,
    };
}

fn tryConnect(self: *State) void {
    if (self.conn != null) return;
    const now = self.nowMs();
    if (now < self.next_reconnect_ms) return;

    // Env override takes precedence – explicit path via NILE_SOCKET
    if (std.c.getenv("NILE_SOCKET")) |cstr| {
        const p = std.mem.span(cstr);
        if (nilebank.Connection.initPath(self.alloc, self.io, p)) |c| {
            self.conn = c;
            self.connected = true;
            self.status_text = "connected";
            self.use_mock = false;
            return;
        } else |_| {}
    }

    // Canonical compositor socket – id "compositor" → /run/arcos/compositor.sock
    // per compositor protocol spec this id is always "compositor"
    if (nilebank.Connection.init(self.alloc, self.io, "compositor")) |c| {
        self.conn = c;
        self.connected = true;
        self.status_text = "connected";
        self.use_mock = false;
        return;
    } else |_| {}

    // still offline
    self.connected = false;
    self.status_text = "offline · mock";
    self.next_reconnect_ms = now + 1500;
}

fn requestTyped(self: *State, req: proto.Request, enc: proto.Encoding) ?proto.Event {
    var c = self.conn orelse return null;
    const ev = req.send(&c, .{ .encoding = enc }) catch |err| {
        std.log.debug("nile request {s} failed: {}", .{ @tagName(req), err });
        // treat as disconnect
        c.close();
        self.conn = null;
        self.connected = false;
        self.status_text = "disconnected";
        self.next_reconnect_ms = self.nowMs() + 800;
        return null;
    };
    // we muted conn copy; write back if it was moved? request doesn't mutate conn, so keep self.conn
    _ = &c;
    return ev;
}

pub fn poll(self: *State) void {
    const now = self.nowMs();
    // throttle to ~4Hz plus clock at 1Hz
    if (now - self.last_clock_ms > 900) self.updateClock();
    if (now - self.last_fetch_ms < 220) return;
    self.last_fetch_ms = now;

    self.tryConnect();
    if (self.conn == null) {
        // animate mock a bit
        if (now - self.last_fetch_ms > 300) {
            self.mock_t +%= 1;
            if (self.mock_t % 8 == 0) {
                self.applyMock() catch {};
            }
        }
        return;
    }

    // connected path: fetch workspaces, windows, outputs
    // we do them sequentially; each is a round-trip. Keep it cheap.
    if (self.requestTyped(.{ .list_workspaces = {} }, .raw)) |ev| {
        defer ev.deinit(self.alloc);
        switch (ev) {
            .workspaces => |lst| self.replaceWorkspaces(lst.items) catch {},
            .workspaces_snapshot => |lst| self.replaceWorkspaces(lst.items) catch {},
            else => {},
        }
    }
    if (self.requestTyped(.{ .list_windows = {} }, .raw)) |ev| {
        defer ev.deinit(self.alloc);
        switch (ev) {
            .windows => |lst| self.replaceWindows(lst.items) catch {},
            .windows_snapshot => |lst| self.replaceWindows(lst.items) catch {},
            else => {},
        }
    }
    if (self.requestTyped(.{ .list_outputs = {} }, .raw)) |ev| {
        defer ev.deinit(self.alloc);
        switch (ev) {
            .outputs => |lst| self.replaceOutputs(lst.items) catch {},
            .outputs_snapshot => |lst| self.replaceOutputs(lst.items) catch {},
            else => {},
        }
    }
    // derive focused id
    self.focused_id = null;
    for (self.windows) |w| if (w.focused) {
        self.focused_id = w.id;
        break;
    };
    self.use_mock = false;
}

fn replaceWorkspaces(self: *State, items: []const proto.Workspace) !void {
    self.freeWorkspaces();
    if (items.len == 0) {
        self.workspaces = &.{};
        return;
    }
    var out = try self.alloc.alloc(proto.Workspace, items.len);
    errdefer self.alloc.free(out);
    for (items, 0..) |ws, i| {
        out[i] = try self.cloneWorkspace(ws);
    }
    self.workspaces = out;
}

fn replaceWindows(self: *State, items: []const proto.Window) !void {
    self.freeWindows();
    if (items.len == 0) {
        self.windows = &.{};
        return;
    }
    var out = try self.alloc.alloc(proto.Window, items.len);
    errdefer self.alloc.free(out);
    for (items, 0..) |w, i| {
        out[i] = try self.cloneWindow(w);
    }
    self.windows = out;
}

fn replaceOutputs(self: *State, items: []const proto.Output) !void {
    self.freeOutputs();
    if (items.len == 0) {
        self.outputs = &.{};
        return;
    }
    var out = try self.alloc.alloc(proto.Output, items.len);
    errdefer self.alloc.free(out);
    for (items, 0..) |o, i| {
        out[i] = try self.cloneOutput(o);
    }
    self.outputs = out;
}

fn applyMock(self: *State) !void {
    // only if we are in mock mode
    self.freeWorkspaces();
    self.freeWindows();
    self.freeOutputs();

    const ws_defs = [_]struct { id: u64, num: u8, name: []const u8, active: bool, urgent: bool }{
        .{ .id = 1, .num = 1, .name = "code", .active = true, .urgent = false },
        .{ .id = 2, .num = 2, .name = "web", .active = false, .urgent = false },
        .{ .id = 3, .num = 3, .name = "term", .active = false, .urgent = (self.mock_t % 16 == 0) },
        .{ .id = 4, .num = 4, .name = "chat", .active = false, .urgent = false },
        .{ .id = 5, .num = 5, .name = "media", .active = false, .urgent = false },
    };
    var ws = try self.alloc.alloc(proto.Workspace, ws_defs.len);
    for (ws_defs, 0..) |d, i| {
        ws[i] = .{
            .id = d.id,
            .number = d.num,
            .name = try self.alloc.dupe(u8, d.name),
            .active = d.active,
            .current = d.active,
            .urgent = d.urgent,
            .output = 1,
        };
    }
    self.workspaces = ws;

    const win_defs = [_]struct { id: u64, title: []const u8, app: []const u8, ws: u64, focused: bool }{
        .{ .id = 101, .title = "nshell — nile bar", .app = "nshell", .ws = 1, .focused = true },
        .{ .id = 102, .title = "neovim — State.zig", .app = "foot", .ws = 1, .focused = false },
        .{ .id = 103, .title = "Firefox — GitHub", .app = "firefox", .ws = 2, .focused = false },
    };
    var wins = try self.alloc.alloc(proto.Window, win_defs.len);
    for (win_defs, 0..) |d, i| {
        wins[i] = .{
            .id = d.id,
            .title = try self.alloc.dupe(u8, d.title),
            .app_id = try self.alloc.dupe(u8, d.app),
            .workspace = d.ws,
            .output = 1,
            .pid = 1000 + @as(u32, @intCast(d.id % 1000)),
            .rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
            .floating = false,
            .fullscreen = false,
            .focused = d.focused,
            .urgent = false,
        };
    }
    self.windows = wins;
    self.focused_id = 101;

    var outs = try self.alloc.alloc(proto.Output, 1);
    outs[0] = .{
        .id = 1,
        .name = try self.alloc.dupe(u8, "HDMI-1"),
        .make = try self.alloc.dupe(u8, "Iris"),
        .model = try self.alloc.dupe(u8, "Nile"),
        .x = 0,
        .y = 0,
        .mode = .{ .width = 2560, .height = 1440, .refresh = 60000 },
        .scale = 1000,
        .enabled = true,
    };
    self.outputs = outs;
    self.status_text = "offline · mock";
}

fn updateClock(self: *State) void {
    const ts = realtimeSec();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const h: u8 = @intCast(day_seconds.getHoursIntoDay());
    const m: u8 = @intCast(day_seconds.getMinutesIntoHour());
    const s: u8 = @intCast(day_seconds.getSecondsIntoMinute());
    // Jan 1 1970 + days
    const yd = epoch_seconds.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const hour12 = if (h % 12 == 0) 12 else h % 12;
    const ampm: []const u8 = if (h < 12) "AM" else "PM";
    const res = std.fmt.bufPrint(&self.clock_text, "{d:0>2}:{d:0>2}:{d:0>2} {s}  {d:0>2}/{d:0>2}/{d}", .{ hour12, m, s, ampm, @as(u16, md.month.numeric()), md.day_index + 1, yd.year }) catch {
        self.clock_len = 0;
        return;
    };
    self.clock_len = res.len;
    self.last_clock_ms = self.nowMs();
}

pub fn clockSlice(self: *State) []const u8 {
    return self.clock_text[0..self.clock_len];
}

pub fn focusedWindow(self: *State) ?*const proto.Window {
    const fid = self.focused_id orelse return null;
    for (self.windows) |*w| if (w.id == fid) return w;
    return null;
}

// Actions – fire-and-forget, best effort
pub fn switchWorkspace(self: *State, id: u64) void {
    if (self.conn == null) {
        // mock: just flip active
        for (self.workspaces) |*ws| {
            const was = ws.active;
            ws.active = ws.id == id;
            ws.current = ws.active;
            if (was != ws.active and ws.active) {
                // also move focused window conceptually?
            }
        }
        return;
    }
    var c = self.conn orelse return;
    const req: proto.Request = .{ .switch_workspace = .{ .id = id } };
    const ev = req.send(&c, .{ .encoding = .raw }) catch return;
    defer ev.deinit(self.alloc);
}

pub fn focusWindow(self: *State, id: u64) void {
    if (self.conn == null) {
        for (self.windows) |*w| w.focused = (w.id == id);
        self.focused_id = id;
        return;
    }
    var c = self.conn orelse return;
    const req: proto.Request = .{ .focus_window = .{ .id = id } };
    const ev = req.send(&c, .{ .encoding = .raw }) catch return;
    defer ev.deinit(self.alloc);
}

pub fn closeWindow(self: *State, id: u64) void {
    if (self.conn == null) {
        // mock remove
        var idx: ?usize = null;
        for (self.windows, 0..) |w, i| if (w.id == id) {
            idx = i;
            break;
        };
        if (idx) |i| {
            self.alloc.free(self.windows[i].title);
            self.alloc.free(self.windows[i].app_id);
            // shift
            for (i..self.windows.len - 1) |j| self.windows[j] = self.windows[j + 1];
            self.windows = self.alloc.realloc(self.windows, self.windows.len - 1) catch self.windows[0 .. self.windows.len - 1];
            if (self.focused_id == id) self.focused_id = null;
        }
        return;
    }
    var c = self.conn orelse return;
    const req: proto.Request = .{ .close_window = .{ .id = id } };
    const ev = req.send(&c, .{ .encoding = .raw }) catch return;
    defer ev.deinit(self.alloc);
}

pub fn workspaceWindows(self: *State, ws_id: u64, buf: []const *proto.Window) usize {
    var n: usize = 0;
    for (self.windows) |*w| {
        if (w.workspace == ws_id) {
            if (n < buf.len) {
                @constCast(&buf[n]).* = w;
                n += 1;
            }
        }
    }
    return n;
}
