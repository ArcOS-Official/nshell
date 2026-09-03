const std = @import("std");
const nilebank = @import("nilebank");
const proto = nilebank.protocols.compositor;

const State = @This();

// Worker -> UI snapshot. Ownership of the slices moves through the inbox;
// the UI thread frees its old arrays and takes these.
const Snapshot = struct {
    workspaces: []proto.Workspace = &.{},
    windows: []proto.Window = &.{},
    outputs: []proto.Output = &.{},
    connected: bool = false,

    fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        for (self.workspaces) |*ws| ws.deinit(alloc);
        if (self.workspaces.len > 0) alloc.free(self.workspaces);
        for (self.windows) |*w| w.deinit(alloc);
        if (self.windows.len > 0) alloc.free(self.windows);
        for (self.outputs) |*o| o.deinit(alloc);
        if (self.outputs.len > 0) alloc.free(self.outputs);
        self.* = .{};
    }
};

// UI -> worker requests.
const Action = union(enum) {
    connect_path: []u8,
    switch_workspace: u64,
    focus_window: u64,
    close_window: u64,

    fn deinit(self: *Action, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .connect_path => |p| alloc.free(p),
            else => {},
        }
    }
};

// MPSC queue with deferred submission: push/pop try the main mutex without
// blocking; if it is locked, the item goes to a pending list instead, and
// the pending list is flushed (executed) on the next successful lock, i.e.
// as part of unlock. The pending mutex is only ever held for a few
// instructions, never across network I/O.
fn DeferredQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator = undefined,
        io: std.Io = undefined,
        mu: std.Io.Mutex = .init,
        qmu: std.Io.Mutex = .init,
        items: std.ArrayList(T) = .empty,
        pending: std.ArrayList(T) = .empty,

        fn init(alloc: std.mem.Allocator, io: std.Io) Self {
            return .{ .alloc = alloc, .io = io };
        }

        fn deinit(self: *Self) void {
            for (self.items.items) |*it| it.deinit(self.alloc);
            self.items.deinit(self.alloc);
            for (self.pending.items) |*it| it.deinit(self.alloc);
            self.pending.deinit(self.alloc);
        }

        fn drainPendingLocked(self: *Self) void {
            self.qmu.lockUncancelable(self.io);
            defer self.qmu.unlock(self.io);
            if (self.pending.items.len == 0) return;
            self.items.appendSlice(self.alloc, self.pending.items) catch return;
            self.pending.clearRetainingCapacity();
        }

        fn drop(self: *Self, v: T) void {
            var tmp = v;
            tmp.deinit(self.alloc);
        }

        pub fn push(self: *Self, v: T) void {
            if (self.mu.tryLock()) {
                defer self.mu.unlock(self.io);
                self.drainPendingLocked();
                self.items.append(self.alloc, v) catch self.drop(v);
            } else {
                self.qmu.lockUncancelable(self.io);
                defer self.qmu.unlock(self.io);
                self.pending.append(self.alloc, v) catch self.drop(v);
            }
        }

        // Non-blocking drain for the UI thread. Returns false if the queue
        // is currently locked; the caller retries on its next tick, at which
        // point the unlock path has already flushed pending items.
        pub fn popAll(self: *Self, out: *std.ArrayList(T)) bool {
            if (!self.mu.tryLock()) return false;
            defer self.mu.unlock(self.io);
            self.drainPendingLocked();
            std.mem.swap(std.ArrayList(T), &self.items, out);
            return true;
        }

        // Blocking drain for the worker thread (microsecond critical section).
        pub fn popAllBlocking(self: *Self, out: *std.ArrayList(T)) void {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            self.drainPendingLocked();
            std.mem.swap(std.ArrayList(T), &self.items, out);
        }
    };
}

// Event stream (push) — see ../nile/doc/nile-api.md "Shell event stream".
// The worker subscribes to the compositor's push socket; every state change
// arrives as an event and triggers a re-query, so no polling is needed while
// the stream is up. Periodic polling remains only as fallback while down.
const stream_path = "/tmp/arcos/compositor-events.sock";
const stream_cooldown_ms: i64 = 50;
const stream_backoff_ms: i64 = 1500;
// Safety re-sync while the stream is up: bounds staleness if the server
// ever mutates state without broadcasting (or a message is dropped).
const stream_resync_ms: i64 = 2000;
const stream_max_frame: usize = 16 * 1024 * 1024;

const StreamMsg = union(enum) {
    event: proto.Event,
    disconnected,

    fn deinit(self: *StreamMsg, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .event => |*ev| ev.deinit(alloc),
            .disconnected => {},
        }
    }
};

alloc: std.mem.Allocator = undefined,
threaded: std.Io.Threaded = undefined,
io: std.Io = undefined,
inited: bool = false,

// Background worker owns the compositor connection exclusively. The UI
// thread never connects, reconnects, or blocks on IPC: it only exchanges
// snapshots/actions through the queues.
thread: ?std.Thread = null,
stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
inbox: DeferredQueue(Snapshot) = .{},
outbox: DeferredQueue(Action) = .{},

// Event-stream reader state. `reader` is only touched by the worker;
// `stream_conn` is shared with the reader thread for shutdown and guarded
// by `stream_mu`. `next_stream_ms` is worker-only backoff.
// `stream_path_override` is init-time config (set before init): the worker
// reads it after spawn, so there is no race as long as it is not mutated
// once the worker runs.
streamQ: DeferredQueue(StreamMsg) = .{},
reader: ?std.Thread = null,
stream_mu: std.Io.Mutex = .init,
stream_conn: ?nilebank.Connection = null,
next_stream_ms: i64 = 0,
stream_path_override: ?[]const u8 = null,

// UI-thread copies. Only touched by the UI thread: published by the worker
// via inbox snapshots applied in poll(), read directly by the frame.
workspaces: []proto.Workspace = &.{},
windows: []proto.Window = &.{},
outputs: []proto.Output = &.{},

connected: bool = false,
focused_id: ?u64 = null,
drain_pending: bool = false,

// clock cache
clock_text: [64]u8 = undefined,
clock_len: usize = 0,
last_clock_ms: i64 = 0,

// connection diagnostics — Nile compositor is required, no mock fallback
status_text: []const u8 = "disconnected",

const fetch_every_ms: i64 = 220;
const loop_sleep_ms: u64 = 25;

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
    self.inbox = DeferredQueue(Snapshot).init(self.alloc, self.io);
    self.outbox = DeferredQueue(Action).init(self.alloc, self.io);
    self.streamQ = DeferredQueue(StreamMsg).init(self.alloc, self.io);
    self.stop = std.atomic.Value(bool).init(false);
    self.drain_pending = false;
    // Explicit: callers may declare `var state: State = undefined`.
    self.workspaces = &.{};
    self.windows = &.{};
    self.outputs = &.{};
    self.connected = false;
    self.focused_id = null;
    self.status_text = "disconnected";
    self.thread = null;
    self.reader = null;
    self.stream_conn = null;
    self.next_stream_ms = 0;
    self.inited = true;
    self.updateClock();
    errdefer {
        self.inbox.deinit();
        self.outbox.deinit();
        self.streamQ.deinit();
        self.threaded.deinit();
        self.inited = false;
    }
    self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
}

pub fn deinit(self: *State) void {
    if (self.thread) |t| {
        self.stop.store(true, .seq_cst);
        t.join();
        self.thread = null;
    }
    self.inbox.deinit();
    self.outbox.deinit();
    self.streamQ.deinit();
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

fn cloneWorkspace(alloc: std.mem.Allocator, ws: proto.Workspace) !proto.Workspace {
    return proto.Workspace{
        .id = ws.id,
        .number = ws.number,
        .name = if (ws.name.len > 0) try alloc.dupe(u8, ws.name) else "",
        .active = ws.active,
        .current = ws.current,
        .urgent = ws.urgent,
        .output = ws.output,
    };
}

fn cloneWindow(alloc: std.mem.Allocator, w: proto.Window) !proto.Window {
    return proto.Window{
        .id = w.id,
        .title = if (w.title.len > 0) try alloc.dupe(u8, w.title) else "",
        .app_id = if (w.app_id.len > 0) try alloc.dupe(u8, w.app_id) else "",
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

fn cloneOutput(alloc: std.mem.Allocator, o: proto.Output) !proto.Output {
    return proto.Output{
        .id = o.id,
        .name = if (o.name.len > 0) try alloc.dupe(u8, o.name) else "",
        .make = if (o.make.len > 0) try alloc.dupe(u8, o.make) else "",
        .model = if (o.model.len > 0) try alloc.dupe(u8, o.model) else "",
        .x = o.x,
        .y = o.y,
        .mode = o.mode,
        .scale = o.scale,
        .enabled = o.enabled,
    };
}

fn cloneItems(
    comptime T: type,
    comptime cloneOne: fn (std.mem.Allocator, T) anyerror!T,
    alloc: std.mem.Allocator,
    items: []const T,
) ![]T {
    if (items.len == 0) return &.{};
    var out = try alloc.alloc(T, items.len);
    errdefer alloc.free(out);
    for (items, 0..) |it, i| {
        out[i] = try cloneOne(alloc, it);
    }
    return out;
}

// Explicit socket path override. Async: the worker picks it up and
// reconnects; never touches the connection from the UI thread.
pub fn connectTo(self: *State, path: []const u8) void {
    const owned = self.alloc.dupe(u8, path) catch return;
    self.outbox.push(.{ .connect_path = owned });
}

fn getEnv(key: []const u8) ?[]const u8 {
    const env_path: [*:0]const u8 = "/proc/self/environ";
    const fd_i = std.os.linux.openat(std.os.linux.AT.FDCWD, env_path, .{}, 0);
    if (@as(isize, @bitCast(fd_i)) < 0) return null;
    const fd: i32 = @intCast(fd_i);
    defer _ = std.os.linux.close(fd);
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.os.linux.read(fd, &buf, buf.len - total);
        if (@as(isize, @bitCast(n)) <= 0) break;
        total += n;
    }
    var start: usize = 0;
    while (start < total) {
        var end = start;
        while (end < total and buf[end] != 0) end += 1;
        const entry = buf[start..end];
        if (std.mem.startsWith(u8, entry, key) and entry.len > key.len and entry[key.len] == '=') {
            return entry[key.len + 1 ..];
        }
        start = end + 1;
    }
    return null;
}

// UI thread: never connects or blocks on IPC. Drains published snapshots
// (non-blocking) and updates the local clock.
pub fn poll(self: *State) void {
    const now = self.nowMs();
    // throttle to ~4Hz plus clock at 1Hz
    if (now - self.last_clock_ms > 900) self.updateClock();

    var tmp: std.ArrayList(Snapshot) = .empty;
    defer tmp.deinit(self.alloc);
    if (!self.inbox.popAll(&tmp)) {
        self.drain_pending = true;
        return;
    }
    self.drain_pending = false;
    for (tmp.items) |s| {
        self.freeWorkspaces();
        self.freeWindows();
        self.freeOutputs();
        self.workspaces = s.workspaces;
        self.windows = s.windows;
        self.outputs = s.outputs;
        self.connected = s.connected;
        self.status_text = if (s.connected) "connected" else "disconnected";
    }
    if (tmp.items.len == 0) return;
    // derive focused id
    self.focused_id = null;
    for (self.windows) |w| if (w.focused) {
        self.focused_id = w.id;
        break;
    };
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

// Actions just enqueue; the worker sends them on its own connection.
pub fn switchWorkspace(self: *State, id: u64) void {
    self.outbox.push(.{ .switch_workspace = id });
}

pub fn focusWindow(self: *State, id: u64) void {
    self.outbox.push(.{ .focus_window = id });
}

pub fn closeWindow(self: *State, id: u64) void {
    self.outbox.push(.{ .close_window = id });
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

// ---------------------------------------------------------------------------
// Background worker below. Owns the connection; only it does IPC.
// ---------------------------------------------------------------------------

const Worker = struct {
    st: *State,
    conn: ?nilebank.Connection = null,
    override_path: ?[]u8 = null,
    next_reconnect_ms: i64 = 0,
    last_fetch_ms: i64 = 0,

    fn deinit(self: *Worker) void {
        if (self.conn) |*c| {
            c.close();
            self.conn = null;
        }
        if (self.override_path) |p| {
            self.st.alloc.free(p);
            self.override_path = null;
        }
    }

    fn sendOnConn(self: *Worker, req: proto.Request) void {
        const c = if (self.conn) |*c| c else return;
        const ev = req.send(c, .{ .encoding = .raw }) catch {
            c.close();
            self.conn = null;
            self.next_reconnect_ms = self.st.nowMs() + 800;
            return;
        };
        defer ev.deinit(self.st.alloc);
    }

    fn drainActions(self: *Worker) void {
        var tmp: std.ArrayList(Action) = .empty;
        defer tmp.deinit(self.st.alloc);
        self.st.outbox.popAllBlocking(&tmp);
        for (tmp.items) |*a| {
            switch (a.*) {
                .connect_path => |p| {
                    if (self.override_path) |old| self.st.alloc.free(old);
                    self.override_path = self.st.alloc.dupe(u8, p) catch null;
                    // reconnect to the new path immediately
                    if (self.conn) |*c| {
                        c.close();
                        self.conn = null;
                    }
                    self.next_reconnect_ms = 0;
                },
                .switch_workspace => |id| self.sendOnConn(.{ .switch_workspace = .{ .id = id } }),
                .focus_window => |id| self.sendOnConn(.{ .focus_window = .{ .id = id } }),
                .close_window => |id| self.sendOnConn(.{ .close_window = .{ .id = id } }),
            }
            a.deinit(self.st.alloc);
        }
    }

    fn tryConnect(self: *Worker, now: i64) void {
        if (self.conn != null) return;
        if (now < self.next_reconnect_ms) return;

        // Explicit override first, then env, then canonical compositor socket.
        if (self.override_path) |p| {
            if (nilebank.Connection.initPath(self.st.alloc, self.st.io, p)) |c| {
                self.conn = c;
                return;
            } else |_| {}
        }
        if (getEnv("NILE_SOCKET")) |p| {
            if (nilebank.Connection.initPath(self.st.alloc, self.st.io, p)) |c| {
                self.conn = c;
                return;
            } else |_| {}
        }
        if (nilebank.Connection.init(self.st.alloc, self.st.io, "compositor")) |c| {
            self.conn = c;
            return;
        } else |_| {}

        self.next_reconnect_ms = now + 1500;
    }

    fn requestTyped(self: *Worker, req: proto.Request, enc: proto.Encoding) ?proto.Event {
        const c = if (self.conn) |*c| c else return null;
        const ev = req.send(c, .{ .encoding = enc }) catch |err| {
            std.log.debug("nile request {s} failed: {}", .{ @tagName(req), err });
            c.close();
            self.conn = null;
            self.next_reconnect_ms = self.st.nowMs() + 800;
            return null;
        };
        return ev;
    }

    fn fetchSnapshot(self: *Worker) Snapshot {
        const alloc = self.st.alloc;
        var snap = Snapshot{ .connected = true };

        if (self.requestTyped(.{ .list_workspaces = {} }, .raw)) |ev| {
            defer ev.deinit(alloc);
            switch (ev) {
                .workspaces => |lst| snap.workspaces = cloneItems(proto.Workspace, cloneWorkspace, alloc, lst.items) catch &.{},
                .workspaces_snapshot => |lst| snap.workspaces = cloneItems(proto.Workspace, cloneWorkspace, alloc, lst.items) catch &.{},
                else => {},
            }
        }
        if (self.conn == null) {
            snap.deinit(alloc);
            return .{ .connected = false };
        }
        if (self.requestTyped(.{ .list_windows = {} }, .raw)) |ev| {
            defer ev.deinit(alloc);
            switch (ev) {
                .windows => |lst| snap.windows = cloneItems(proto.Window, cloneWindow, alloc, lst.items) catch &.{},
                .windows_snapshot => |lst| snap.windows = cloneItems(proto.Window, cloneWindow, alloc, lst.items) catch &.{},
                else => {},
            }
        }
        if (self.conn == null) {
            snap.deinit(alloc);
            return .{ .connected = false };
        }
        if (self.requestTyped(.{ .list_outputs = {} }, .raw)) |ev| {
            defer ev.deinit(alloc);
            switch (ev) {
                .outputs => |lst| snap.outputs = cloneItems(proto.Output, cloneOutput, alloc, lst.items) catch &.{},
                .outputs_snapshot => |lst| snap.outputs = cloneItems(proto.Output, cloneOutput, alloc, lst.items) catch &.{},
                else => {},
            }
        }
        if (self.conn == null) {
            snap.deinit(alloc);
            return .{ .connected = false };
        }
        return snap;
    }
};

fn closeStreamConn(st: *State) void {
    st.stream_mu.lockUncancelable(st.io);
    defer st.stream_mu.unlock(st.io);
    if (st.stream_conn) |*c| {
        // shutdown() first: plain close() does not reliably wake a thread
        // blocked in recv(), which would hang the reader join below.
        c.conn.shutdown(st.io, .both) catch {};
        c.close();
        st.stream_conn = null;
    }
}

// Push-channel reader: connects to the compositor event stream, forwards
// each decoded event to the worker, and reports exactly one `disconnected`
// on exit (connect failure, EOF, decode framing error, or shutdown).
fn streamReaderMain(st: *State) void {
    const path = st.stream_path_override orelse stream_path;
    var conn: nilebank.Connection = nilebank.Connection.initPath(st.alloc, st.io, path) catch {
        st.streamQ.push(.disconnected);
        return;
    };
    st.stream_mu.lockUncancelable(st.io);
    if (st.stop.load(.seq_cst)) {
        st.stream_mu.unlock(st.io);
        conn.close();
        st.streamQ.push(.disconnected);
        return;
    }
    st.stream_conn = conn;
    st.stream_mu.unlock(st.io);

    defer {
        st.stream_mu.lockUncancelable(st.io);
        if (st.stream_conn != null) {
            st.stream_conn.?.close();
            st.stream_conn = null;
        }
        st.stream_mu.unlock(st.io);
        st.streamQ.push(.disconnected);
    }

    var read_buf: [4096]u8 = undefined;
    var r = conn.conn.reader(st.io, &read_buf);
    const reader = &r.interface;
    while (true) {
        var hdr_buf: [nilebank.Header.size]u8 = undefined;
        reader.readSliceAll(&hdr_buf) catch {
            break;
        };
        var h: nilebank.Header = undefined;
        h.fromBytes(hdr_buf);
        if (h.length > stream_max_frame) {
            break;
        }
        const payload = st.alloc.alloc(u8, h.length) catch {
            break;
        };
        if (h.length > 0) {
            reader.readSliceAll(payload) catch {
                st.alloc.free(payload);
                break;
            };
        }
        const ev = proto.Event.decodeAllocWith(st.alloc, h.kind, payload, h.encoding) catch {
            st.alloc.free(payload);
            continue;
        };
        st.alloc.free(payload);
        st.streamQ.push(.{ .event = ev });
    }
}

fn workerMain(st: *State) void {
    var w = Worker{ .st = st };
    defer w.deinit();
    var dirty = false;
    while (!st.stop.load(.seq_cst)) {
        w.drainActions();
        const now = st.nowMs();
        w.tryConnect(now);
        // Event stream: keep one reader; drain pushed events.
        if (st.reader == null and now >= st.next_stream_ms) {
            if (std.Thread.spawn(.{}, streamReaderMain, .{st})) |t| {
                st.reader = t;
            } else |_| {
                st.next_stream_ms = now + stream_backoff_ms;
            }
        }
        {
            var sq: std.ArrayList(StreamMsg) = .empty;
            defer sq.deinit(st.alloc);
            if (st.streamQ.popAll(&sq)) {
                for (sq.items) |*m| {
                    switch (m.*) {
                        .event => dirty = true,
                        .disconnected => {
                            if (st.reader) |t| {
                                t.join();
                                st.reader = null;
                            }
                            st.next_stream_ms = now + stream_backoff_ms;
                        },
                    }
                    m.deinit(st.alloc);
                }
            }
        }
        // Push-driven while the stream is up (coalesce bursts), with a slow
        // safety re-sync; periodic polling only as fallback while down.
        const interval: i64 = if (st.reader != null)
            (if (dirty) stream_cooldown_ms else stream_resync_ms)
        else
            fetch_every_ms;
        const want_fetch = dirty or st.reader == null or now - w.last_fetch_ms >= stream_resync_ms;
        if (w.conn != null and want_fetch and now - w.last_fetch_ms >= interval) {
            w.last_fetch_ms = now;
            dirty = false;
            st.inbox.push(w.fetchSnapshot());
        } else if (w.conn == null and now - w.last_fetch_ms >= fetch_every_ms) {
            w.last_fetch_ms = now;
            st.inbox.push(.{ .connected = false });
        }
        st.io.sleep(.fromMilliseconds(loop_sleep_ms), .awake) catch {};
    }
    // Shutdown: unblock a reader stuck in read, then join it.
    closeStreamConn(st);
    if (st.reader) |t| {
        t.join();
        st.reader = null;
    }
}
