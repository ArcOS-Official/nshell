const std = @import("std");
const dvui = @import("dvui");
const nilebank = @import("nilebank");
const proto = nilebank.protocols.compositor;
const Launcher = @import("Launcher.zig");
pub const Net = @import("Net.zig");

const State = @This();

// Namespace of the interactive hub layer surface (see main.zig initWindow).
// Declared to the compositor via shell_register so it can focus this
// surface on MOD press without nshell ever learning which key MOD is.
pub const shell_namespace = "nshell-hub";

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
// Thumbnail resolution (1000 = native). The switcher draws at most ~100px,
// so a small scale keeps the reply far under the 64KiB transport frame
// while staying sharp on HiDPI; the GPU scales down at draw time.
const image_capture_scale: u32 = 200;
// Pause after a capture error before trying again. Matches the freshness
// window so a struggling server is retried about as often as a stale image
// would refresh anyway — slow streams keep flowing instead of stalling.
const image_error_backoff_ms: i64 = 2000;

const reconnect_ms: i64 = 1500;
const loop_sleep_ms: u64 = 25;

// UI -> worker requests. Plain data: the worker sends them with
// `requestCompositor` on its own connection. Mutations (switch/focus/close
// and floating/tiling) are acked with `pong`; the outcome arrives later as
// a broadcast push.
// Pub so headless tests can inspect the queued requests.
pub const Action = union(enum) {
    switch_workspace: u64,
    focus_window: u64,
    capture_window: CaptureWindow,
    get_window: u64,
    set_window_floating: SetWindowFloating,
    set_workspace_mode: SetWorkspaceMode,
    set_focus_config: SetFocusConfig,

    pub const CaptureWindow = struct {
        id: u64,
        scale: u32,
    };
    pub const SetWindowFloating = struct { id: u64, floating: bool };
    pub const SetWorkspaceMode = struct { id: u64, mode: proto.WorkspaceMode };
    pub const SetFocusConfig = struct { switch_workspace_on_focus: bool };

    fn deinit(self: *Action, alloc: std.mem.Allocator) void {
        // No heap today (all payloads are plain data); kept for symmetry
        // with proto.Request so drops stay leak-free if that changes.
        _ = self;
        _ = alloc;
    }
};

// Mutex-guarded queue. Push/pop take the mutex only for a few instructions,
// never across network I/O. Items are owned: failed appends deinit the item.
// Methods are pub so headless tests can drive/inspect the queues.
fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        mu: std.Io.Mutex = .init,
        items: std.ArrayList(T) = .empty,

        pub fn push(self: *Self, alloc: std.mem.Allocator, io: std.Io, v: T) void {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            self.items.append(alloc, v) catch {
                var tmp = v;
                tmp.deinit(alloc);
            };
        }

        pub fn popAll(self: *Self, io: std.Io, out: *std.ArrayList(T)) void {
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

// (launcher_opened/launcher_closed are compositor MOD-tap gestures for
// the app launcher — see nile doc "Shell launcher". They are not switcher
// state; hubFrame owns its own simple hub_* var if it needs one.)

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

launcher: Launcher = .{},

net: Net = .{},

// Capture backoff (boot-ms timestamp; 0 = no backoff). The server may
// answer capture_* with error code 3 when it can't serve a frame right now
// ("capture not implemented" on old servers, or transient busy/not-ready on
// slow ones streaming ~1fps). A single error must NOT permanently disable
// thumbnails, so we only pause new capture traffic until this timestamp and
// keep serving cache-or-null meanwhile. Cleared on the next success.
capture_backoff_until_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

// Test override for the socket path (live code always uses the canonical
// ../nile paths above).
socket_path_override: ?[]const u8 = null,

// Focus-window behaviour: whether focusing a window on another workspace
// should switch to it. Mirrors Nile's Bank.focus_switches_workspace
// (set_focus_config). Default `true` — alt-tab anywhere. Shell can set
// `false` to keep alt-tab within the current workspace only.
focus_switches_workspace: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

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
    self.capture_backoff_until_ms = std.atomic.Value(i64).init(0);
    self.focus_switches_workspace = std.atomic.Value(bool).init(true);
    self.wakeup_ctx = wakeup_ctx;
    self.wakeup_fn = wakeup_fn;
    self.launcher.init(alloc, io);
    self.net.init(alloc, io);
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
    self.launcher.deinit();
    self.net.deinit();
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

// ---------------------------------------------------------------------------
// Floating / tiling controls via nilebank
// Mirrors nile/Nile.zig + Bank.set_window_floating / set_workspace_mode /
// set_focus_config. All enqueued for the worker and acked with pong;
// visible outcome arrives as broadcast pushes (window_floating_changed,
// workspace_mode_changed, window_state_changed).
// ---------------------------------------------------------------------------

/// Set a window's floating flag directly.
pub fn setWindowFloating(self: *State, id: u64, floating: bool) void {
    self.req_q.push(self.alloc, self.io, .{ .set_window_floating = .{ .id = id, .floating = floating } });
}

/// Toggle a window's floating state (reads current model; falls back to true).
pub fn toggleWindowFloating(self: *State, id: u64) void {
    const cur = if (self.findWindow(id)) |w| w.floating else false;
    self.setWindowFloating(id, !cur);
}

/// Convenience: toggle the currently focused window (MRU head if focused flag missing).
pub fn toggleFocusedWindowFloating(self: *State) void {
    if (self.windows.len == 0) return;
    const id = for (self.windows) |*w| {
        if (w.focused) break w.id;
    } else self.windows[0].id;
    self.toggleWindowFloating(id);
}

/// Set a workspace's tiling/floating mode explicitly.
pub fn setWorkspaceMode(self: *State, id: u64, mode: proto.WorkspaceMode) void {
    self.req_q.push(self.alloc, self.io, .{ .set_workspace_mode = .{ .id = id, .mode = mode } });
}

/// Toggle a workspace's mode (reads current model; tiling -> floating).
pub fn toggleWorkspaceMode(self: *State, id: u64) void {
    const cur = self.getWorkspaceMode(id) orelse .tiling;
    const next: proto.WorkspaceMode = if (cur == .tiling) .floating else .tiling;
    self.setWorkspaceMode(id, next);
}

/// Toggle the current workspace (current == active/current flag).
pub fn toggleCurrentWorkspaceMode(self: *State) void {
    const cur_id = self.currentWorkspaceId() orelse return;
    self.toggleWorkspaceMode(cur_id);
}

/// Set the current workspace's mode directly.
pub fn setCurrentWorkspaceMode(self: *State, mode: proto.WorkspaceMode) void {
    const cur_id = self.currentWorkspaceId() orelse return;
    self.setWorkspaceMode(cur_id, mode);
}

/// Whether focusing a window on another workspace should switch to it.
/// Mirrors Nile Bank's `focus_switches_workspace`. Default `true`
/// (alt-tab anywhere).
pub fn getFocusSwitchesWorkspace(self: *State) bool {
    return self.focus_switches_workspace.load(.seq_cst);
}
pub fn setFocusConfig(self: *State, switch_workspace_on_focus: bool) void {
    self.focus_switches_workspace.store(switch_workspace_on_focus, .seq_cst);
    self.req_q.push(self.alloc, self.io, .{ .set_focus_config = .{ .switch_workspace_on_focus = switch_workspace_on_focus } });
}
/// Inverse convenience: only_current = !switch_workspace_on_focus.
pub fn getOnlyCurrentWorkspace(self: *State) bool {
    return !self.getFocusSwitchesWorkspace();
}
pub fn setOnlyCurrentWorkspace(self: *State, only_current: bool) void {
    self.setFocusConfig(!only_current);
}

/// Helpers for UI: read current model.
pub fn getWorkspaceMode(self: *State, id: u64) ?proto.WorkspaceMode {
    for (self.workspaces) |*ws| if (ws.id == id) return ws.mode;
    return null;
}
pub fn getWindowFloating(self: *State, id: u64) ?bool {
    if (self.findWindow(id)) |w| return w.floating;
    return null;
}
pub fn currentWorkspaceId(self: *State) ?u64 {
    for (self.workspaces) |*ws| if (ws.current or ws.active) return ws.id;
    return null;
}
pub fn currentWorkspaceMode(self: *State) ?proto.WorkspaceMode {
    const id = self.currentWorkspaceId() orelse return null;
    return self.getWorkspaceMode(id);
}

// UI thread only. Returns the cached capture for `id` as a dvui.ImageSource
// (packed RGBA rows, borrowing cache memory: use within the frame).
// Fetch-on-call: a miss enqueues an async capture and returns null (or stale
// pixels while refreshing); the listener/worker wakes the GUI when pixels
// land via the commit queue. Never blocks on IPC.
fn captureBackedOff(self: *State, now: i64) bool {
    return now < self.capture_backoff_until_ms.load(.seq_cst);
}

pub fn windowImage(self: *State, id: u64) ?dvui.ImageSource {
    const now = self.nowMs();
    if (self.images.getPtr(id)) |e| {
        if (e.fetched_ms != 0 and now - e.fetched_ms < image_ttl_ms) {
            return e.imageSource();
        }
        if (self.captureBackedOff(now)) {
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
    if (self.captureBackedOff(now)) return null;
    self.images.put(id, .{ .requested_ms = now }) catch return null;
    self.req_q.push(self.alloc, self.io, .{ .capture_window = .{ .id = id, .scale = image_capture_scale } });
    return null;
}

// UI thread only. Enqueue a capture for every listed window whose cached
// image is missing or stale. Call when opening the switcher so thumbnails
// converge in one round trip instead of one per frame. Never blocks on IPC;
// windowImage() coalescing still caps traffic to one request per window.
pub fn prefetchWindowImages(self: *State) void {
    const now = self.nowMs();
    if (self.captureBackedOff(now)) return;
    for (self.windows) |*w| {
        const e = self.images.getPtr(w.id);
        if (e) |entry| {
            if (entry.fetched_ms != 0 and now - entry.fetched_ms < image_ttl_ms) continue;
            if (now - entry.requested_ms < image_ttl_ms) continue;
            entry.requested_ms = now;
        } else {
            self.images.put(w.id, .{ .requested_ms = now }) catch continue;
        }
        self.req_q.push(self.alloc, self.io, .{ .capture_window = .{ .id = w.id, .scale = image_capture_scale } });
    }
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
        // Launcher search + icons: drain pending queues concurrently here.
        // Populated by UI via Launcher.search()/requestIcon(); ticks
        // materialize results and wake the GUI so the next frame sees them.
        // Icons are time-sliced (8/tick) so a burst of misses never starves
        // compositor IPC below.
        const had_pending = blk: {
            self.launcher.mu.lockUncancelable(self.io);
            const n = self.launcher.pending.items.len + self.launcher.icon_pending.items.len;
            const built = self.launcher.icon_themes_built;
            self.launcher.mu.unlock(self.io);
            // First icon tick also builds the theme index (one-time dir scan).
            break :blk n > 0 or !built;
        };
        if (had_pending) {
            self.launcher.tick() catch |e| {
                std.log.err("Launcher error {s}", .{@errorName(e)});
            };
            self.launcher.tickIcons(8) catch |e| {
                std.log.err("Launcher icon error {s}", .{@errorName(e)});
            };
            self.requestRefresh();
        }
        const net_changed = self.net.tick() catch |e| blk: {
            std.log.err("Net error {s}", .{@errorName(e)});
            break :blk false;
        };
        if (net_changed) self.requestRefresh();
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
        var i: usize = 0;
        var disconnected = false;
        while (i < batch.items.len) : (i += 1) {
            self.handleAction(conn, &batch.items[i]) catch {
                // Disconnected mid-batch: drop the connection so the next
                // tick reconnects. The batch was already popped, so re-queue
                // the unprocessed tail (including the failed action) instead
                // of dropping fills/captures on the floor.
                disconnected = true;
                break;
            };
            batch.items[i].deinit(self.alloc);
            if (self.stop.load(.seq_cst)) return;
        }
        if (disconnected) {
            // Re-queue the unprocessed tail (Action is plain data, no heap,
            // so copies are safe). The request queue is drained with popAll
            // and replayed in order, so appending items[i..] preserves the
            // original sequence.
            for (batch.items[i..]) |a| self.req_q.push(self.alloc, self.io, a);
            synced = false;
            self.dropConn();
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

// Worker-only. Decompose one full window record (a get_window reply) into
// owned incremental events so update() merges it into the existing row
// instead of replacing the whole list. Every string is duped: the source
// record is freed by the caller's `defer ev.deinit`.
fn commitFill(self: *State, w: *const proto.Window) void {
    if (w.title.len > 0) {
        const owned = self.alloc.dupe(u8, w.title) catch null;
        if (owned) |t| self.commitEvent(.{ .window_title_changed = .{ .id = w.id, .title = t } });
    }
    if (w.app_id.len > 0) {
        const owned = self.alloc.dupe(u8, w.app_id) catch null;
        if (owned) |a| self.commitEvent(.{ .window_app_id_changed = .{ .id = w.id, .app_id = a } });
    }
    self.commitEvent(.{ .window_state_changed = .{
        .id = w.id,
        .floating = w.floating,
        .fullscreen = w.fullscreen,
        .urgent = w.urgent,
        .focused = w.focused,
    } });
    self.commitEvent(.{ .window_workspace_changed = .{
        .id = w.id,
        .old_workspace = 0,
        .new_workspace = w.workspace,
    } });
    self.commitEvent(.{ .window_moved = .{ .id = w.id, .rect = w.rect } });
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
    // A fresh server gets a fresh capture probe; a late deinit closes us.
    self.capture_backoff_until_ms.store(0, .seq_cst);
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
// shell_register runs first (re-registration after every reconnect, since
// the compositor forgets it on restart): it tells ../nile which layer
// surface to focus on MOD press, and acks with pong (dropped here).
fn initialQuery(self: *State, conn: *nilebank.Connection) void {
    if (conn.requestCompositor(.{ .shell_register = .{ .namespace = shell_namespace } }, .raw)) |*ev| {
        ev.deinit(self.alloc);
    } else |_| {
        return;
    }
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
            // A get_window reply is a single-record fill, NOT a full list:
            // committing it as `.windows` would make applyEvent replace the
            // whole model with one row (the "switcher shows only one window"
            // bug). Decompose into incremental merges instead, so full-list
            // `.windows` pushes remain the only path that replaces (and thus
            // defines MRU focus order).
            var ev = try conn.requestCompositor(.{ .get_window = .{ .id = id } }, .raw);
            defer ev.deinit(self.alloc);
            if (ev != .windows) {
                // Unknown/gone window: prune a stale stub so it can't linger
                // as a blank switcher entry. A live window re-appears via
                // the next push + fill cycle.
                self.commitEvent(.{ .window_closed = .{ .id = id } });
                self.requestRefresh();
                return;
            }
            var filled = false;
            for (ev.windows.items) |*w| {
                self.commitFill(w);
                filled = true;
            }
            if (filled) self.requestRefresh();
        },
        .capture_window => |c| {
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
                            // Success clears any earlier backoff: the server
                            // is streaming, even if slowly.
                            self.capture_backoff_until_ms.store(0, .seq_cst);
                            self.commitEvent(ev);
                            self.requestRefresh();
                            consumed = true;
                        } else |_| {}
                    }
                },
                .error_msg => |e| {
                    if (e.code == 3) {
                        // Transient OR permanent ("not implemented"): either
                        // way just pause and retry later. A slow server that
                        // answers every now and then keeps flowing instead of
                        // being latched off forever.
                        const until = self.nowMs() + image_error_backoff_ms;
                        self.capture_backoff_until_ms.store(until, .seq_cst);
                        std.log.debug("capture error {d}, backing off {d}ms", .{ e.code, image_error_backoff_ms });
                    }
                },
                else => {},
            }
            if (!consumed) ev.deinit(self.alloc);
        },
        .set_window_floating => |v| {
            var ev = try conn.requestCompositor(.{ .set_window_floating = .{ .id = v.id, .floating = v.floating } }, .raw);
            defer ev.deinit(self.alloc);
        },
        .set_workspace_mode => |v| {
            var ev = try conn.requestCompositor(.{ .set_workspace_mode = .{ .id = v.id, .mode = v.mode } }, .raw);
            defer ev.deinit(self.alloc);
        },
        .set_focus_config => |v| {
            var ev = try conn.requestCompositor(.{ .set_focus_config = .{ .switch_workspace_on_focus = v.switch_workspace_on_focus } }, .raw);
            defer ev.deinit(self.alloc);
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
        const drow = out[y * @as(usize, w) * 4 ..][0 .. @as(usize, w) * 4];
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

// Move the row for `id` to index 0, preserving the relative order of the
// rest. No-op when already first or unknown. Keeps the model in MRU focus
// order on every focus signal, so the switcher stays sorted even if the
// server's full-list `.windows` re-push is delayed or missed.
fn moveWindowToFront(self: *State, id: u64) void {
    for (self.windows, 0..) |*w, i| {
        if (w.id != id) continue;
        if (i == 0) return;
        const tmp = self.windows[i];
        std.mem.copyBackwards(proto.Window, self.windows[1 .. i + 1], self.windows[0..i]);
        self.windows[0] = tmp;
        return;
    }
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

// Apply one queued broadcast to the model. Full-list `.windows` pushes
// replace (they are the server's current truth, already in MRU focus
// order); incremental pushes merge without disturbing order, except focus
// signals which move the focused row to the front. Unknown ids get a stub
// plus a get_window fill request so a missed new_window still converges
// once the worker answers (fills arrive decomposed as incremental merges,
// never as list replacements).
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
            // MRU first: the focused window heads the list so the switcher
            // mirrors focus order without waiting for the server re-push.
            if (v.id != 0) self.moveWindowToFront(v.id);
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
            if (v.focused) self.moveWindowToFront(v.id);
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
        .window_floating_changed => |v| {
            const created = self.ensureWindow(v.id);
            const rec = self.findWindow(v.id) orelse return;
            rec.floating = v.floating;
            if (created) self.req_q.push(self.alloc, self.io, .{ .get_window = v.id });
        },
        .workspace_mode_changed => |v| {
            for (self.workspaces) |*ws| if (ws.id == v.id) {
                ws.mode = v.mode;
                return;
            };
            // Unknown workspace: fetch via upsert fallback (rare).
            // Leave as-is; next full list will converge.
        },
        // MOD-tap launcher gesture (see ../nile Seat.shellModTap):
        // launcher_opened/launcher_closed are for the app launcher, not
        // the window switcher. hubFrame owns its own simple hub_* var
        // (like hub_keyboard_focused) if it wants local switcher state.
        .launcher_opened, .launcher_closed => {},
        else => {},
    }
}
