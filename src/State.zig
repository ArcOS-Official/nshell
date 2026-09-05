const std = @import("std");
const dvui = @import("dvui");
const nilebank = @import("nilebank");
const proto = nilebank.protocols.compositor;

const State = @This();

// Request/response socket served by ../nile (`Bank.socket_id = "compositor"`).
// The same connection doubles as the push channel: the server broadcasts
// unsolicited events (`Header.push_id`) over it, and nilebank's reader fiber
// routes those to our event listener instead of an outstanding `request`
// (see ../nile/doc/nile-api.md "Shell event push").
const socket_path = "/tmp/arcos/compositor.sock";

// Freshness/coalescing window for windowImage(): a cached capture younger
// than this is served without compositor traffic, and re-requests for the
// same id are coalesced to at most one per window.
const image_ttl_ms: i64 = 2000;
// Native resolution; the GPU scales thumbnails down at draw time.
const image_capture_scale: u32 = 1000;

const reconnect_ms: i64 = 1500;
const loop_sleep_ms: u64 = 25;

// UI -> worker requests. Plain data: the worker sends them with
// `requestCompositor` on its own connection. Mutations (switch/focus/close)
// are acked with `pong`; the outcome arrives later as a broadcast push.
const Action = union(enum) {
    switch_workspace: u64,
    focus_window: u64,
    capture_window: CaptureWindow,
    get_window: u64,

    pub const CaptureWindow = struct {
        id: u64,
        scale: u32,
    };

    fn deinit(self: *Action, alloc: std.mem.Allocator) void {
        // No heap today (all payloads are u64s); kept for symmetry with
        // proto.Request so drops stay leak-free if that changes.
        _ = self;
        _ = alloc;
    }
};

// Mutex-guarded queue. Push/pop take the mutex only for a few instructions,
// never across network I/O. Items are owned: failed appends deinit the item.
fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        mu: std.Io.Mutex = .init,
        items: std.ArrayList(T) = .empty,

        fn push(self: *Self, alloc: std.mem.Allocator, io: std.Io, v: T) void {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            self.items.append(alloc, v) catch {
                var tmp = v;
                tmp.deinit(alloc);
            };
        }

        fn popAll(self: *Self, io: std.Io, out: *std.ArrayList(T)) void {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            std.mem.swap(std.ArrayList(T), &self.items, out);
        }

        fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            for (self.items.items) |*it| it.deinit(alloc);
            self.items.deinit(alloc);
            self.items = .empty;
        }
    };
}

// UI-thread window thumbnail cache entry. Only touched by the UI thread:
// windowImage() reads/enqueues, update() adopts worker captures.
const ImageEntry = struct {
    rgba: []u8 = &.{}, // owned packed RGBA; empty until the first capture lands
    width: u32 = 0,
    height: u32 = 0,
    fetched_ms: i64 = 0, // last successful capture; 0 = none yet
    requested_ms: i64 = 0, // last capture request; 0 = never

    fn deinit(self: *ImageEntry, alloc: std.mem.Allocator) void {
        if (self.rgba.len > 0) alloc.free(self.rgba);
        self.* = .{};
    }

    fn imageSource(self: *const ImageEntry) dvui.ImageSource {
        return .{ .pixels = .{ .rgba = self.rgba, .width = self.width, .height = self.height } };
    }
};

const ImageMap = std.AutoHashMap(u64, ImageEntry);

alloc: std.mem.Allocator = undefined,
io: std.Io = undefined,

// UI-thread model. Only touched by the UI thread: update() applies queued
// broadcasts here between frames; frame code reads directly. Broadcasts
// always win: full-list pushes replace, incremental pushes merge.
workspaces: []proto.Workspace = &.{},
windows: []proto.Window = &.{},

// UI-thread thumbnail cache (see ImageEntry).
images: ImageMap = undefined,

/// UI -> worker outbox. Pushed by the UI thread, drained by worker().
req_q: Queue(Action) = .{},
/// Listener/worker -> UI commit queue. Pushed by the connection reader fiber
/// (event listener) and by the worker (query replies, fills, captures);
/// drained by update(). Guarded insert: once `closed` is set, items are
/// dropped instead of queued, so a late push racing deinit can't touch
/// freed storage.
commit_q: Queue(proto.Event) = .{},

// Worker-owned connection. Only the worker (re)connects; deinit closes.
// Stored as a heap pointer: nilebank's Connection owns a reader fiber and
// frees itself on close().
conn: ?*nilebank.Connection = null,
conn_mu: std.Io.Mutex = .init,

inited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
worker_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

// Capture support probe. The server answers capture_* with error code 3
// ("capture not implemented", see ../nile/nile/Bank.zig); while set,
// windowImage() skips compositor traffic and serves cache-or-null.
capture_unsupported: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

// Test override for the socket path (live code always uses the canonical
// ../nile paths above).
socket_path_override: ?[]const u8 = null,

// Wakeup hook: invoked every time commits land so the GUI redraws promptly.
// main.zig wires it to dvui.refresh.
wakeup_ctx: ?*anyopaque = null,
wakeup_fn: ?WakeupFn = null,

pub const WakeupFn = *const fn (?*anyopaque) void;

fn requestRefresh(self: *State) void {
    if (self.wakeup_fn) |f| f(self.wakeup_ctx);
}

fn nowMs(self: *State) i64 {
    return std.Io.Clock.boot.now(self.io).toMilliseconds();
}

pub fn init(self: *State, alloc: std.mem.Allocator, io: std.Io) !void {
    try self.initWithWakeup(alloc, io, null, null);
}

pub fn initWithWakeup(
    self: *State,
    alloc: std.mem.Allocator,
    io: std.Io,
    wakeup_ctx: ?*anyopaque,
    wakeup_fn: ?WakeupFn,
) !void {
    self.alloc = alloc;
    self.io = io;
    self.workspaces = &.{};
    self.windows = &.{};
    self.images = ImageMap.init(alloc);
    self.req_q = .{};
    self.commit_q = .{};
    self.conn = null;
    self.conn_mu = .init;
    self.inited = std.atomic.Value(bool).init(false);
    self.stop = std.atomic.Value(bool).init(false);
    self.worker_done = std.atomic.Value(bool).init(false);
    self.closed = std.atomic.Value(bool).init(false);
    self.capture_unsupported = std.atomic.Value(bool).init(false);
    self.wakeup_ctx = wakeup_ctx;
    self.wakeup_fn = wakeup_fn;
    self.inited.store(true, .seq_cst);
}

pub fn deinit(self: *State) void {
    self.stop.store(true, .seq_cst);
    self.closed.store(true, .seq_cst);
    self.dropConn();
    // The worker exits promptly: closing the connection fails any in-flight
    // request, and the loop checks `stop` every tick. Bounded wait so a
    // wedged peer can't hang shutdown forever.
    const t0 = self.nowMs();
    while (!self.worker_done.load(.seq_cst)) {
        if (self.nowMs() - t0 > 3000) break;
        std.Thread.yield() catch {};
    }
    self.wakeup_fn = null;
    self.wakeup_ctx = null;
    self.freeModel();
    var it = self.images.iterator();
    while (it.next()) |kv| kv.value_ptr.deinit(self.alloc);
    self.images.deinit();
    self.images = ImageMap.init(self.alloc);
    self.req_q.deinit(self.alloc);
    // Drain commits under the queue mutex: a late listener push racing us
    // blocks on the mutex, then sees `closed` and drops its item instead
    // of touching freed storage.
    self.commit_q.mu.lockUncancelable(self.io);
    defer self.commit_q.mu.unlock(self.io);
    self.commit_q.deinit(self.alloc);
}

// UI -> worker: just enqueue; the worker sends on its own connection.
// Staying connected is the subscription mechanism (subscribe is a no-op
// ack on the server); outcomes arrive as broadcast pushes.
pub fn switchWorkspace(self: *State, id: u64) void {
    self.req_q.push(self.alloc, self.io, .{ .switch_workspace = id });
}

pub fn focusWindow(self: *State, id: u64) void {
    self.req_q.push(self.alloc, self.io, .{ .focus_window = id });
}

// UI thread only. Returns the cached capture for `id` as a dvui.ImageSource
// (packed RGBA rows, borrowing cache memory: use within the frame).
// Fetch-on-call: a miss enqueues an async capture and returns null (or stale
// pixels while refreshing); the listener/worker wakes the GUI when pixels
// land via the commit queue. Never blocks on IPC.
pub fn windowImage(self: *State, id: u64) ?dvui.ImageSource {
    const now = self.nowMs();
    if (self.images.getPtr(id)) |e| {
        if (e.fetched_ms != 0 and now - e.fetched_ms < image_ttl_ms) {
            return e.imageSource();
        }
        if (self.capture_unsupported.load(.seq_cst)) {
            if (e.fetched_ms == 0) return null;
            return e.imageSource();
        }
        if (now - e.requested_ms < image_ttl_ms) {
            if (e.fetched_ms == 0) return null;
            return e.imageSource();
        }
        e.requested_ms = now;
        self.req_q.push(self.alloc, self.io, .{ .capture_window = .{ .id = id, .scale = image_capture_scale } });
        if (e.fetched_ms == 0) return null;
        return e.imageSource();
    }
    if (self.capture_unsupported.load(.seq_cst)) return null;
    self.images.put(id, .{ .requested_ms = now }) catch return null;
    self.req_q.push(self.alloc, self.io, .{ .capture_window = .{ .id = id, .scale = image_capture_scale } });
    return null;
}

// UI thread only. Applies all queued broadcasts/captures to the model.
// Broadcasts override current state: full-list pushes replace the slices,
// incremental pushes merge. Runs between frames; never blocks on IPC.
pub fn update(self: *State) void {
    var batch: std.ArrayList(proto.Event) = .empty;
    defer batch.deinit(self.alloc);
    self.commit_q.popAll(self.io, &batch);
    for (batch.items) |*ev| {
        self.applyEvent(ev);
        ev.deinit(self.alloc);
    }
}

// Worker entry point. Owns the connection: (re)connects with backoff,
// runs the initial query after every (re)connect, and drains the request
// queue sequentially (the connection allows only one outstanding request).
// Never touches the UI model or image map directly: replies that carry
// state (lists, fills, captures) are forwarded as owned events into the
// commit queue for update() to apply — the worker can add commits whenever
// needed without ever waiting on the UI thread.
pub fn worker(self: *State, io: std.Io) void {
    defer self.worker_done.store(true, .seq_cst);
    while (!self.inited.load(.seq_cst)) {
        if (self.stop.load(.seq_cst)) return;
        io.sleep(.fromMilliseconds(5), .awake) catch return;
    }
    var synced = false;
    var next_connect_ms: i64 = 0;
    while (!self.stop.load(.seq_cst)) {
        const conn = self.ensureConn(io, &next_connect_ms) orelse {
            io.sleep(.fromMilliseconds(200), .awake) catch return;
            continue;
        };
        if (!synced) {
            self.initialQuery(conn);
            synced = true;
        }
        var batch: std.ArrayList(Action) = .empty;
        defer batch.deinit(self.alloc);
        self.req_q.popAll(self.io, &batch);
        if (batch.items.len == 0) {
            io.sleep(.fromMilliseconds(loop_sleep_ms), .awake) catch return;
            continue;
        }
        for (batch.items) |*a| {
            self.handleAction(conn, a) catch {
                // Disconnected mid-batch: drop the connection so the next
                // tick reconnects; the remaining actions stay queued.
                synced = false;
                break;
            };
            a.deinit(self.alloc);
            if (self.stop.load(.seq_cst)) return;
        }
    }
}

// ---------------------------------------------------------------------------
// Listener: the dedicated listening path. Runs on nilebank's connection
// reader fiber (one per connection, spawned by initPath) — i.e. its own
// thread for as long as we stay connected. It only decodes the push into an
// owned event and appends it to the commit queue under the queue mutex, so
// update() can apply it later and the worker can add commits the same way.
// Never blocks: no IPC, no waiting, borrowed `msg.data` is duped by decode.
// ---------------------------------------------------------------------------
fn onEvent(ctx: ?*anyopaque, msg: nilebank.Message) void {
    const self: *State = @ptrCast(@alignCast(ctx orelse return));
    const ev = proto.Event.decodeAllocWith(self.alloc, msg.kind, msg.data, msg.encoding) catch return;
    self.commitEvent(ev);
    self.requestRefresh();
}

// Guarded commit-queue insert shared by the listener and the worker.
fn commitEvent(self: *State, ev: proto.Event) void {
    self.commit_q.mu.lockUncancelable(self.io);
    defer self.commit_q.mu.unlock(self.io);
    if (self.closed.load(.seq_cst)) {
        var drop = ev;
        drop.deinit(self.alloc);
        return;
    }
    self.commit_q.items.append(self.alloc, ev) catch {
        var drop = ev;
        drop.deinit(self.alloc);
    };
}

fn reqSocketPath(self: *State) []const u8 {
    return self.socket_path_override orelse socket_path;
}

// Worker-only. Returns the live connection, connecting (with backoff) if
// needed. The listener is attached at connect time, so pushes flow from
// the first byte.
fn ensureConn(self: *State, io: std.Io, next_connect_ms: *i64) ?*nilebank.Connection {
    self.conn_mu.lockUncancelable(self.io);
    const existing = self.conn;
    self.conn_mu.unlock(self.io);
    if (existing) |c| return c;

    const now = self.nowMs();
    if (now < next_connect_ms.*) return null;
    const conn = nilebank.Connection.initPath(self.alloc, io, self.reqSocketPath(), onEvent, self) catch {
        next_connect_ms.* = now + reconnect_ms;
        return null;
    };
    self.conn_mu.lockUncancelable(self.io);
    self.conn = conn;
    self.conn_mu.unlock(self.io);
    // A fresh server re-probes capture support; a late deinit closes us.
    self.capture_unsupported.store(false, .seq_cst);
    self.requestRefresh();
    if (self.stop.load(.seq_cst) or self.closed.load(.seq_cst)) {
        self.dropConn();
        return null;
    }
    return conn;
}

fn dropConn(self: *State) void {
    self.conn_mu.lockUncancelable(self.io);
    const c = self.conn;
    self.conn = null;
    self.conn_mu.unlock(self.io);
    if (c) |conn| conn.close();
}

// Worker-only. Initial state after every (re)connect: the server answers
// with full lists, which update() adopts. Later broadcasts override them.
fn initialQuery(self: *State, conn: *nilebank.Connection) void {
    const queries = [_]proto.Request{
        .{ .list_windows = {} },
        .{ .list_workspaces = {} },
    };
    for (queries) |req| {
        const ev = conn.requestCompositor(req, .raw) catch return;
        self.commitEvent(ev);
    }
    self.requestRefresh();
}

// Worker-only. Sends one queued action; state-carrying replies are
// forwarded into the commit queue. Returns error on disconnect.
fn handleAction(self: *State, conn: *nilebank.Connection, a: *Action) !void {
    switch (a.*) {
        .switch_workspace => |id| {
            var ev = try conn.requestCompositor(.{ .switch_workspace = .{ .id = id } }, .raw);
            defer ev.deinit(self.alloc);
        },
        .focus_window => |id| {
            var ev = try conn.requestCompositor(.{ .focus_window = .{ .id = id } }, .raw);
            defer ev.deinit(self.alloc);
        },
        .get_window => |id| {
            var ev = try conn.requestCompositor(.{ .get_window = .{ .id = id } }, .raw);
            if (ev == .windows) {
                self.commitEvent(ev);
                self.requestRefresh();
            } else {
                ev.deinit(self.alloc);
            }
        },
        .capture_window => |c| {
            if (self.capture_unsupported.load(.seq_cst)) return;
            var ev = try conn.requestCompositor(
                .{ .capture_window = .{ .window_id = c.id, .scale = c.scale } },
                .raw,
            );
            var consumed = false;
            switch (ev) {
                .window_image => |*v| {
                    if (v.window_id == c.id) {
                        if (normalizeWindowImage(self.alloc, v.image)) |norm| {
                            if (v.image.data.len > 0) self.alloc.free(v.image.data);
                            v.image = .{
                                .width = norm.width,
                                .height = norm.height,
                                .stride = norm.width * 4,
                                .format = .rgba8,
                                .data = norm.rgba,
                            };
                            self.commitEvent(ev);
                            self.requestRefresh();
                            consumed = true;
                        } else |_| {}
                    }
                },
                .error_msg => |e| {
                    if (e.code == 3) {
                        if (!self.capture_unsupported.swap(true, .seq_cst)) {
                            std.log.info("capture unsupported by compositor, thumbnails disabled", .{});
                        }
                    }
                },
                else => {},
            }
            if (!consumed) ev.deinit(self.alloc);
        },
    }
}

// Normalize any compositor pixel format to tightly packed RGBA bytes the UI
// can hand straight to `dvui.ImageSource{ .pixels = ... }`. Honors the
// source stride (row padding) by packing rows. Returns owned `rgba`.
fn normalizeWindowImage(alloc: std.mem.Allocator, src: proto.Image) !struct {
    width: u32,
    height: u32,
    rgba: []u8,
} {
    const w = src.width;
    const h = src.height;
    if (w == 0 or h == 0 or w > 16384 or h > 16384) return error.InvalidImage;
    const bpp: usize = switch (src.format) {
        .rgba8, .bgra8, .rgbx8, .bgrx8 => 4,
        .rgb8 => 3,
        .r8 => 1,
    };
    const row_bytes = @as(usize, w) * bpp;
    const stride: usize = if (src.stride == 0) row_bytes else src.stride;
    if (stride < row_bytes) return error.InvalidImage;
    if (src.data.len < stride * (@as(usize, h) - 1) + row_bytes) return error.InvalidImage;

    const out_len = std.math.mul(usize, @as(usize, w) * @as(usize, h), 4) catch return error.InvalidImage;
    const out = try alloc.alloc(u8, out_len);
    errdefer alloc.free(out);

    for (0..h) |y| {
        const srow = src.data[y * stride ..][0..row_bytes];
        const drow = out[y * @as(usize, w) * 4 ..][0..@as(usize, w) * 4];
        switch (src.format) {
            .rgba8 => @memcpy(drow, srow),
            .bgra8 => {
                var x: usize = 0;
                while (x < row_bytes) : (x += 4) {
                    drow[x] = srow[x + 2];
                    drow[x + 1] = srow[x + 1];
                    drow[x + 2] = srow[x];
                    drow[x + 3] = srow[x + 3];
                }
            },
            .rgbx8, .bgrx8 => {
                const swap_rb = (src.format == .bgrx8);
                var x: usize = 0;
                while (x < row_bytes) : (x += 4) {
                    drow[x] = if (swap_rb) srow[x + 2] else srow[x];
                    drow[x + 1] = srow[x + 1];
                    drow[x + 2] = if (swap_rb) srow[x] else srow[x + 2];
                    drow[x + 3] = 255;
                }
            },
            .rgb8 => {
                var p: usize = 0;
                var x: usize = 0;
                while (x < row_bytes) : ({
                    x += 3;
                    p += 4;
                }) {
                    drow[p] = srow[x];
                    drow[p + 1] = srow[x + 1];
                    drow[p + 2] = srow[x + 2];
                    drow[p + 3] = 255;
                }
            },
            .r8 => {
                var p: usize = 0;
                for (srow) |v| {
                    drow[p] = v;
                    drow[p + 1] = v;
                    drow[p + 2] = v;
                    drow[p + 3] = 255;
                    p += 4;
                }
            },
        }
    }
    return .{ .width = w, .height = h, .rgba = out };
}

// ---------------------------------------------------------------------------
// UI-side model. Applied only in update() — never while dvui is drawing, so
// no locking is needed beyond the commit-queue handoff.
// ---------------------------------------------------------------------------

fn freeModel(self: *State) void {
    for (self.workspaces) |w| w.deinit(self.alloc);
    if (self.workspaces.len > 0) self.alloc.free(self.workspaces);
    self.workspaces = &.{};
    for (self.windows) |*w| w.deinit(self.alloc);
    if (self.windows.len > 0) self.alloc.free(self.windows);
    self.windows = &.{};
}

fn findWindow(self: *State, id: u64) ?*proto.Window {
    for (self.windows) |*w| if (w.id == id) return w;
    return null;
}

// Ensure a record exists for `id`, appending a blank stub if needed.
// Returns true when a new stub was created (caller enqueues a fill then).
fn ensureWindow(self: *State, id: u64) bool {
    if (self.findWindow(id) != null) return false;
    self.windows = self.alloc.realloc(self.windows, self.windows.len + 1) catch return false;
    self.windows[self.windows.len - 1] = .{ .id = id };
    return true;
}

// Order-preserving remove from a model list. The caller deinits the
// removed item first.
fn removeAt(comptime T: type, alloc: std.mem.Allocator, items: *[]T, i: usize) void {
    var s: []T = items.*;
    std.mem.copyForwards(T, s[i .. s.len - 1], s[i + 1 ..]);
    if (s.len - 1 == 0) {
        alloc.free(s);
        items.* = &.{};
    } else {
        items.* = alloc.realloc(s, s.len - 1) catch s[0 .. s.len - 1];
    }
}

fn removeWindow(self: *State, id: u64) void {
    for (self.windows, 0..) |*w, i| {
        if (w.id != id) continue;
        w.deinit(self.alloc);
        removeAt(proto.Window, self.alloc, &self.windows, i);
        return;
    }
}

fn removeWorkspace(self: *State, id: u64) void {
    for (self.workspaces, 0..) |*ws, i| {
        if (ws.id != id) continue;
        ws.deinit(self.alloc);
        removeAt(proto.Workspace, self.alloc, &self.workspaces, i);
        return;
    }
}

fn dupeNonEmpty(self: *State, s: []const u8) []const u8 {
    return if (s.len > 0) self.alloc.dupe(u8, s) catch "" else "";
}

fn upsertWorkspace(self: *State, ws: proto.Workspace) void {
    for (self.workspaces) |*cur| {
        if (cur.id != ws.id) continue;
        cur.deinit(self.alloc);
        cur.* = .{
            .id = ws.id,
            .number = ws.number,
            .name = self.dupeNonEmpty(ws.name),
            .active = ws.active,
            .current = ws.current,
            .urgent = ws.urgent,
            .output = ws.output,
        };
        return;
    }
    const old_len = self.workspaces.len;
    self.workspaces = self.alloc.realloc(self.workspaces, old_len + 1) catch return;
    self.workspaces[old_len] = .{
        .id = ws.id,
        .number = ws.number,
        .name = self.dupeNonEmpty(ws.name),
        .active = ws.active,
        .current = ws.current,
        .urgent = ws.urgent,
        .output = ws.output,
    };
}

// Steal one full window record into the model (a get_window reply). The
// caller must not use the source afterwards; its strings are neutralized so
// the message deinit stays safe.
fn adoptFillWindow(self: *State, f: *proto.Window) void {
    for (self.windows) |*cur| {
        if (cur.id != f.id) continue;
        cur.deinit(self.alloc);
        cur.* = f.*;
        f.title = "";
        f.app_id = "";
        return;
    }
    self.windows = self.alloc.realloc(self.windows, self.windows.len + 1) catch return;
    self.windows[self.windows.len - 1] = f.*;
    f.title = "";
    f.app_id = "";
}

// Adopt a worker capture into the image map, stealing ownership of the
// already-normalized RGBA buffer (the event aliases it but is neutralized,
// so exactly one side owns it afterwards).
fn adoptImage(self: *State, id: u64, img: *proto.Image) void {
    const entry = self.images.getPtr(id) orelse {
        self.images.put(id, .{}) catch {
            if (img.data.len > 0) self.alloc.free(img.data);
            img.data = "";
            return;
        };
        const e = self.images.getPtr(id) orelse return;
        // img.data is allocator-owned (worker-normalized); reclaim mutable.
        e.rgba = @constCast(img.data);
        e.width = img.width;
        e.height = img.height;
        e.fetched_ms = self.nowMs();
        e.requested_ms = e.fetched_ms;
        img.data = "";
        return;
    };
    if (entry.rgba.len > 0) self.alloc.free(entry.rgba);
    entry.rgba = @constCast(img.data);
    entry.width = img.width;
    entry.height = img.height;
    entry.fetched_ms = self.nowMs();
    entry.requested_ms = entry.fetched_ms;
    img.data = "";
}

// Apply one queued broadcast to the model. Full-list pushes replace (they
// are the server's current truth); incremental ones merge. Unknown ids get
// a stub plus a get_window fill request so a missed new_window still
// converges once the worker answers.
fn applyEvent(self: *State, ev: *proto.Event) void {
    switch (ev.*) {
        .windows_snapshot, .windows => {
            for (self.windows) |*w| w.deinit(self.alloc);
            if (self.windows.len > 0) self.alloc.free(self.windows);
            if (ev.* == .windows_snapshot) {
                self.windows = ev.windows_snapshot.items;
                ev.windows_snapshot.items = &.{};
            } else {
                self.windows = ev.windows.items;
                ev.windows.items = &.{};
            }
        },
        .workspaces_snapshot, .workspaces => {
            for (self.workspaces) |*ws| ws.deinit(self.alloc);
            if (self.workspaces.len > 0) self.alloc.free(self.workspaces);
            if (ev.* == .workspaces_snapshot) {
                self.workspaces = ev.workspaces_snapshot.items;
                ev.workspaces_snapshot.items = &.{};
            } else {
                self.workspaces = ev.workspaces.items;
                ev.workspaces.items = &.{};
            }
        },
        .new_window => |v| {
            const created = self.ensureWindow(v.id);
            const rec = self.findWindow(v.id) orelse return;
            if (v.title.len > 0) {
                if (rec.title.len > 0) self.alloc.free(rec.title);
                rec.title = self.dupeNonEmpty(v.title);
            }
            if (created) self.req_q.push(self.alloc, self.io, .{ .get_window = v.id });
        },
        .window_closed => |v| self.removeWindow(v.id),
        .window_focused => |v| {
            for (self.windows) |*w| w.focused = (w.id == v.id);
        },
        .window_title_changed => |v| {
            const created = self.ensureWindow(v.id);
            const rec = self.findWindow(v.id) orelse return;
            if (rec.title.len > 0) self.alloc.free(rec.title);
            rec.title = self.dupeNonEmpty(v.title);
            if (created) self.req_q.push(self.alloc, self.io, .{ .get_window = v.id });
        },
        .window_app_id_changed => |v| {
            const created = self.ensureWindow(v.id);
            const rec = self.findWindow(v.id) orelse return;
            if (rec.app_id.len > 0) self.alloc.free(rec.app_id);
            rec.app_id = self.dupeNonEmpty(v.app_id);
            if (created) self.req_q.push(self.alloc, self.io, .{ .get_window = v.id });
        },
        .window_state_changed => |v| {
            const created = self.ensureWindow(v.id);
            const rec = self.findWindow(v.id) orelse return;
            rec.floating = v.floating;
            rec.fullscreen = v.fullscreen;
            rec.urgent = v.urgent;
            rec.focused = v.focused;
            if (created) self.req_q.push(self.alloc, self.io, .{ .get_window = v.id });
        },
        .window_workspace_changed => |v| {
            const created = self.ensureWindow(v.id);
            const rec = self.findWindow(v.id) orelse return;
            rec.workspace = v.new_workspace;
            if (created) self.req_q.push(self.alloc, self.io, .{ .get_window = v.id });
        },
        .window_moved, .window_resized => |v| {
            const created = self.ensureWindow(v.id);
            const rec = self.findWindow(v.id) orelse return;
            rec.rect = v.rect;
            if (created) self.req_q.push(self.alloc, self.io, .{ .get_window = v.id });
        },
        .window_image => |*v| self.adoptImage(v.window_id, &v.image),
        .workspace_created => |v| self.upsertWorkspace(v),
        .workspace_removed => |v| self.removeWorkspace(v.id),
        .workspace_activated => |v| {
            for (self.workspaces) |*ws| ws.current = (ws.id == v.id);
        },
        .workspace_deactivated => |v| {
            for (self.workspaces) |*ws| if (ws.id == v.id) {
                ws.current = false;
                return;
            };
        },
        .switch_workspace => |v| {
            for (self.workspaces) |*ws| ws.current = (ws.number == v.index);
        },
        else => {},
    }
}
