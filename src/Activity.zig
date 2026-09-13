const std = @import("std");
const builtin = @import("builtin");
const nilebank = @import("nilebank");
const proto = nilebank.protocols.compositor;

// Live system activity feeding the hub privacy indicators and the bar:
// screen-capture sessions (compositor, via the shell protocol), mic/camera
// consumption (PipeWire node graph), and in-progress browser downloads
// (partial files in the download dir).
//
// Mirrors Net.zig's shape: the worker owns the model and polls it on
// cadence, the UI reads cheap snapshots, stops go through a small queue.
// Compositor queries are NOT sent from here — the compositor socket belongs
// to State.worker, which asks for a session list when captureQueryDue()
// says so and adopts replies via the commit queue (see State.zig).

pub const Kind = enum { record, share, mic, camera, download };
pub const Source = enum { compositor, pipewire, downloads };

pub const Item = struct {
    id: u64, // compositor session id, or a local counter id
    kind: Kind,
    source: Source,
    label: []const u8, // owned: exe / app / file name
    detail: []const u8, // owned: "pid 1234" / "node 56" / ""
    stop_id: u64, // compositor session id or PipeWire node id; 0 = no stop

    fn deinit(self: *Item, alloc: std.mem.Allocator) void {
        if (self.label.len > 0) alloc.free(self.label);
        if (self.detail.len > 0) alloc.free(self.detail);
    }
};

pub const Snapshot = struct {
    items: []Item = &.{},
    gen: u64 = 0,

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        for (self.items) |*it| it.deinit(alloc);
        if (self.items.len > 0) alloc.free(self.items);
        self.* = .{};
    }
};

pub const Counts = struct {
    record: usize = 0,
    share: usize = 0,
    mic: usize = 0,
    camera: usize = 0,
    download: usize = 0,

    pub fn total(self: *const Counts) usize {
        return self.record + self.share + self.mic + self.camera + self.download;
    }
};

pub const StopCmd = struct {
    source: Source,
    stop_id: u64,
};

const CaptureEntry = struct {
    id: u64,
    pid: u32,
    exe: []const u8,
    app_id: []const u8,
    kind: proto.CaptureKind,

    fn deinit(self: *CaptureEntry, alloc: std.mem.Allocator) void {
        if (self.exe.len > 0) alloc.free(self.exe);
        if (self.app_id.len > 0) alloc.free(self.app_id);
    }
};

const StreamEntry = struct {
    node_id: u64,
    kind: Kind, // mic, camera, share or record (never download)
    app: []const u8,
    pid: u32,

    fn deinit(self: *StreamEntry, alloc: std.mem.Allocator) void {
        if (self.app.len > 0) alloc.free(self.app);
    }
};

const pw_poll_ms: i64 = 2000;
const dl_poll_ms: i64 = 5000;
const capture_poll_ms: i64 = 2000;
const max_download_names: usize = 8;

mu: std.Io.Mutex = .init,
alloc: std.mem.Allocator = undefined,
io: std.Io = undefined,
inited: bool = false,
gen: u64 = 0,
next_id: u64 = 1,

capture: std.ArrayList(CaptureEntry) = .empty,
streams: std.ArrayList(StreamEntry) = .empty,
downloads: std.ArrayList([]const u8) = .empty,
stops: std.ArrayList(StopCmd) = .empty,

next_pw_ms: i64 = 0,
next_dl_ms: i64 = 0,
next_capture_ms: i64 = 0,

const Activity = @This();

pub fn init(self: *Activity, alloc: std.mem.Allocator, io: std.Io) void {
    self.alloc = alloc;
    self.io = io;
    self.inited = true;
}

pub fn deinit(self: *Activity) void {
    for (self.capture.items) |*e| e.deinit(self.alloc);
    self.capture.deinit(self.alloc);
    for (self.streams.items) |*e| e.deinit(self.alloc);
    self.streams.deinit(self.alloc);
    for (self.downloads.items) |n| if (n.len > 0) self.alloc.free(n);
    self.downloads.deinit(self.alloc);
    self.stops.deinit(self.alloc);
    self.* = .{};
}

fn nowMs(self: *Activity) i64 {
    return std.Io.Clock.boot.now(self.io).toMilliseconds();
}

fn bump(self: *Activity) void {
    self.gen +%= 1;
}

fn allocId(self: *Activity) u64 {
    const id = self.next_id;
    self.next_id +%= 1;
    if (self.next_id == 0) self.next_id = 1;
    return id;
}

// ---------------------------------------------------------------------------
// UI reads (cheap, mutex-guarded, no allocation except snapshotCopy)
// ---------------------------------------------------------------------------

/// Per-kind counts for the hub indicator strip + pill sizing. No allocation.
pub fn counts(self: *Activity) Counts {
    if (!self.inited) return .{};
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    var c = Counts{};
    for (self.capture.items) |*e| {
        if (isRecorderExe(e.exe)) c.record += 1 else c.share += 1;
    }
    for (self.streams.items) |*e| switch (e.kind) {
        .record => c.record += 1,
        .share => c.share += 1,
        .mic => c.mic += 1,
        .camera => c.camera += 1,
        .download => {},
    };
    c.download = self.downloads.items.len;
    return c;
}

/// Owned per-frame copy for the control center. Caller deinits.
pub fn snapshotCopy(self: *Activity, alloc: std.mem.Allocator) Snapshot {
    var out = Snapshot{};
    if (!self.inited) return out;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    out.gen = self.gen;
    var list: std.ArrayList(Item) = .empty;
    errdefer {
        for (list.items) |*it| it.deinit(alloc);
        list.deinit(alloc);
    }
    for (self.capture.items) |*e| {
        const kind: Kind = if (isRecorderExe(e.exe)) .record else .share;
        const label = if (e.app_id.len > 0)
            std.fmt.allocPrint(alloc, "{s} ({s})", .{ e.app_id, e.exe }) catch ""
        else
            alloc.dupe(u8, e.exe) catch "";
        errdefer if (label.len > 0) alloc.free(label);
        const detail = std.fmt.allocPrint(alloc, "pid {d}", .{e.pid}) catch "";
        errdefer if (detail.len > 0) alloc.free(detail);
        list.append(alloc, .{
            .id = e.id,
            .kind = kind,
            .source = .compositor,
            .label = label,
            .detail = detail,
            .stop_id = e.id,
        }) catch {
            if (label.len > 0) alloc.free(label);
            if (detail.len > 0) alloc.free(detail);
            continue;
        };
    }
    for (self.streams.items) |*e| {
        const label = alloc.dupe(u8, e.app) catch "";
        errdefer if (label.len > 0) alloc.free(label);
        const detail = std.fmt.allocPrint(alloc, "pid {d} · node {d}", .{ e.pid, e.node_id }) catch "";
        errdefer if (detail.len > 0) alloc.free(detail);
        list.append(alloc, .{
            .id = e.node_id,
            .kind = e.kind,
            .source = .pipewire,
            .label = label,
            .detail = detail,
            .stop_id = e.node_id,
        }) catch {
            if (label.len > 0) alloc.free(label);
            if (detail.len > 0) alloc.free(detail);
            continue;
        };
    }
    for (self.downloads.items) |n| {
        const label = alloc.dupe(u8, n) catch "";
        list.append(alloc, .{
            .id = 0,
            .kind = .download,
            .source = .downloads,
            .label = label,
            .detail = "",
            .stop_id = 0,
        }) catch {
            if (label.len > 0) alloc.free(label);
            continue;
        };
    }
    out.items = list.toOwnedSlice(alloc) catch &.{};
    return out;
}

/// UI-thread stop request (control-center Stop button). Drained by
/// takeStops() on the worker: compositor ids become shell-protocol revoke
/// actions, PipeWire node ids become `pw-cli destroy` spawns.
pub fn requestStop(self: *Activity, source: Source, stop_id: u64) void {
    if (!self.inited or stop_id == 0) return;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    self.stops.append(self.alloc, .{ .source = source, .stop_id = stop_id }) catch {};
}

/// Worker-side: swap out queued stops. Caller owns the list.
pub fn takeStops(self: *Activity, out: *std.ArrayList(StopCmd)) void {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    std.mem.swap(std.ArrayList(StopCmd), &self.stops, out);
}

/// Absolute path of the download dir, written into buf. Never fails: falls
/// back to $HOME/Downloads, then /tmp. HOME comes from /proc/self/environ
/// (libc-free; this also runs in the link-light test builds on Linux).
pub fn downloadDir(self: *Activity, buf: []u8) []const u8 {
    var homebuf: [std.fs.max_path_bytes]u8 = undefined;
    const home = self.homeDir(&homebuf);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/.config/user-dirs.dirs", .{home}) catch null;
    if (p) |path| {
        if (self.readDownloadDir(path, home, buf)) |d| return d;
    }
    return std.fmt.bufPrint(buf, "{s}/Downloads", .{home}) catch "/tmp";
}

fn homeDir(self: *Activity, buf: []u8) []const u8 {
    var f = std.Io.Dir.openFileAbsolute(self.io, "/proc/self/environ", .{}) catch return "/tmp";
    defer f.close(self.io);
    var text: [8192]u8 = undefined;
    var len: usize = 0;
    var tmp: [1024]u8 = undefined;
    while (len < text.len) {
        const n = std.Io.File.readStreaming(f, self.io, &.{tmp[0..]}) catch break;
        if (n == 0) break;
        const room = @min(n, text.len - len);
        @memcpy(text[len..][0..room], tmp[0..room]);
        len += room;
        if (n < tmp.len) break;
    }
    var it = std.mem.splitScalar(u8, text[0..len], 0);
    while (it.next()) |e| {
        if (std.mem.startsWith(u8, e, "HOME=")) {
            const h = e["HOME=".len..];
            if (h.len > 0) return std.fmt.bufPrint(buf, "{s}", .{h}) catch "/tmp";
        }
    }
    return "/tmp";
}

fn readDownloadDir(self: *Activity, path: []const u8, home: []const u8, buf: []u8) ?[]const u8 {
    var f = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return null;
    defer f.close(self.io);
    var fbuf: [2048]u8 = undefined;
    var len: usize = 0;
    while (len < fbuf.len) {
        const n = std.Io.File.readStreaming(f, self.io, &.{fbuf[len..]}) catch break;
        if (n == 0) break;
        len += n;
    }
    const text = fbuf[0..len];
    const key = "XDG_DOWNLOAD_DIR=\"";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    var val = rest[0..end];
    if (std.mem.startsWith(u8, val, "$HOME/")) val = val["$HOME".len..];
    // val is either "$HOME/..." remainder or absolute; join with home.
    if (std.fs.path.isAbsolute(val)) return std.fmt.bufPrint(buf, "{s}", .{val}) catch null;
    const rel = if (std.mem.startsWith(u8, val, "/")) val[1..] else val;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, rel }) catch null;
}

// ---------------------------------------------------------------------------
// Compositor session intake (called on the UI thread from State.update;
// the worker never touches `capture` except through snapshot/count reads)
// ---------------------------------------------------------------------------

/// Adopt a polled session list, stealing ownership (caller must reset its
/// slice to &.{} like the windows_snapshot path in State.applyEvent).
pub fn adoptCaptureSessions(self: *Activity, items: []proto.CaptureSession) void {
    if (!self.inited) {
        for (items) |*s| s.deinit(self.alloc);
        if (items.len > 0) self.alloc.free(items);
        return;
    }
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    for (self.capture.items) |*e| e.deinit(self.alloc);
    self.capture.clearRetainingCapacity();
    for (items) |*s| {
        self.capture.append(self.alloc, .{
            .id = s.id,
            .pid = s.pid,
            .exe = s.exe,
            .app_id = s.app_id,
            .kind = s.kind,
        }) catch {
            s.deinit(self.alloc);
            continue;
        };
    }
    if (items.len > 0) self.alloc.free(items);
    self.bump();
}

pub fn upsertCaptureSession(self: *Activity, id: u64, pid: u32, exe: []const u8, app_id: []const u8, kind: proto.CaptureKind) void {
    if (!self.inited) return;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    for (self.capture.items) |*e| {
        if (e.id != id) continue;
        if (e.exe.len > 0) self.alloc.free(e.exe);
        if (e.app_id.len > 0) self.alloc.free(e.app_id);
        e.pid = pid;
        e.exe = self.alloc.dupe(u8, exe) catch "";
        e.app_id = self.alloc.dupe(u8, app_id) catch "";
        e.kind = kind;
        self.bump();
        return;
    }
    self.capture.append(self.alloc, .{
        .id = id,
        .pid = pid,
        .exe = self.alloc.dupe(u8, exe) catch "",
        .app_id = self.alloc.dupe(u8, app_id) catch "",
        .kind = kind,
    }) catch return;
    self.bump();
}

pub fn removeCaptureSession(self: *Activity, id: u64) void {
    if (!self.inited) return;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    for (self.capture.items, 0..) |*e, i| {
        if (e.id != id) continue;
        var gone = e.*;
        gone.deinit(self.alloc);
        _ = self.capture.orderedRemove(i);
        self.bump();
        return;
    }
}

// ---------------------------------------------------------------------------
// Worker tick
// ---------------------------------------------------------------------------

/// True when State.worker should ask the compositor for a fresh session
/// list (advances the deadline so repeat ticks don't spam).
pub fn captureQueryDue(self: *Activity, now: i64) bool {
    if (!self.inited) return false;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (now < self.next_capture_ms) return false;
    self.next_capture_ms = now + capture_poll_ms;
    return true;
}

pub fn tick(self: *Activity) !bool {
    if (!self.inited) return false;
    const now = self.nowMs();
    var changed = false;
    {
        self.mu.lockUncancelable(self.io);
        const pw_due = now >= self.next_pw_ms;
        const dl_due = now >= self.next_dl_ms;
        if (pw_due) self.next_pw_ms = now + pw_poll_ms;
        if (dl_due) self.next_dl_ms = now + dl_poll_ms;
        self.mu.unlock(self.io);
        if (pw_due and self.pollPipeWire()) changed = true;
        if (dl_due and self.pollDownloads()) changed = true;
    }
    return changed;
}

/// Destroy one PipeWire stream node (force-stop for mic/camera/share).
/// Fire-and-forget detached spawn, mirroring Launcher.run's reap pattern.
pub fn destroyPipewireNode(self: *Activity, node_id: u64) void {
    if (!self.inited or node_id == 0) return;
    var idbuf: [24]u8 = undefined;
    const id = std.fmt.bufPrint(&idbuf, "{d}", .{node_id}) catch return;
    // idbuf is stack: copy the argv line before spawning.
    var argvbuf: [32]u8 = undefined;
    const idcpy = std.fmt.bufPrint(&argvbuf, "{s}", .{id}) catch return;
    self.spawnDetached(&.{ "/usr/bin/env", "pw-cli", "destroy", idcpy });
}

/// Open the download dir in the file browser (control-center button).
/// Detached spawn from the UI thread, mirroring Launcher.run.
pub fn openDownloads(self: *Activity) void {
    if (!self.inited) return;
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = self.downloadDir(&dirbuf);
    var argvbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dircpy = std.fmt.bufPrint(&argvbuf, "{s}", .{dir}) catch return;
    self.spawnDetached(&.{ "/usr/bin/env", "xdg-open", dircpy });
}

fn spawnDetached(self: *Activity, argv: []const []const u8) void {
    var child = std.process.spawn(self.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    const pid = child.id orelse return;
    child.id = null;
    if (child.stdin) |*f| f.close(self.io);
    if (child.stdout) |*f| f.close(self.io);
    if (child.stderr) |*f| f.close(self.io);
    const Box = struct { pid: std.posix.pid_t };
    const box = self.alloc.create(Box) catch return;
    box.pid = pid;
    const thread = std.Thread.spawn(.{}, struct {
        fn reap(b: *Box, alloc: std.mem.Allocator) void {
            defer alloc.destroy(b);
            // Raw syscall on Linux so headless tests stay libc-free;
            // libc elsewhere (mirrors Launcher.run).
            if (builtin.os.tag == .linux) {
                var status: u32 = 0;
                _ = std.os.linux.waitpid(b.pid, &status, 0);
            } else {
                var status: c_int = 0;
                _ = std.c.waitpid(b.pid, &status, 0);
            }
        }
    }.reap, .{ box, self.alloc }) catch {
        self.alloc.destroy(box);
        return;
    };
    thread.detach();
}

// ---------------------------------------------------------------------------
// PipeWire polling (worker)
// ---------------------------------------------------------------------------

const PwNode = struct {
    id: u64,
    class: []const u8 = "",
    name: []const u8 = "",
    app: []const u8 = "",
    bin: []const u8 = "",
    pid: u32 = 0,
    running: bool = false,
};

fn pollPipeWire(self: *Activity) bool {
    const text = self.runPwDump() catch return false;
    defer self.alloc.free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, text, .{}) catch return false;
    defer parsed.deinit();
    // pw-dump prints a bare JSON array at top level.
    if (parsed.value != .array) return false;
    const list = parsed.value.array.items;

    var nodes: std.ArrayList(PwNode) = .empty;
    defer nodes.deinit(self.alloc);
    var links: std.ArrayList([2]u64) = .empty;
    defer links.deinit(self.alloc);

    // Bare top-level array (checked above); each entry is one object.
    for (list) |*o| {
        if (o.* != .object) continue;
        const typ = jsonStr(o.object.get("type")) orelse continue;
        if (std.mem.eql(u8, typ, "PipeWire:Interface:Link")) {
            const info = o.object.get("info") orelse continue;
            if (info != .object) continue;
            if (!std.mem.eql(u8, jsonStr(info.object.get("state")) orelse "", "active")) continue;
            const out_id = jsonU64(info.object.get("output-node-id")) orelse continue;
            const in_id = jsonU64(info.object.get("input-node-id")) orelse continue;
            links.append(self.alloc, .{ out_id, in_id }) catch continue;
            continue;
        }
        if (!std.mem.eql(u8, typ, "PipeWire:Interface:Node")) continue;
        const id = jsonU64(o.object.get("id")) orelse continue;
        const info = o.object.get("info") orelse continue;
        if (info != .object) continue;
        const props = info.object.get("props");
        const state = jsonStr(info.object.get("state")) orelse "";
        var n = PwNode{ .id = id, .running = std.mem.eql(u8, state, "running") };
        if (props) |p| {
            if (p != .object) continue;
            n.class = jsonStr(p.object.get("media.class")) orelse "";
            n.name = jsonStr(p.object.get("node.name")) orelse "";
            n.app = jsonStr(p.object.get("application.name")) orelse "";
            n.bin = jsonStr(p.object.get("application.process.binary")) orelse "";
            n.pid = @intCast(jsonU64(p.object.get("application.process.id")) orelse 0);
        }
        nodes.append(self.alloc, n) catch continue;
    }

    var fresh: std.ArrayList(StreamEntry) = .empty;
    errdefer {
        for (fresh.items) |*e| e.deinit(self.alloc);
        fresh.deinit(self.alloc);
    }
    for (nodes.items) |*src| {
        const is_audio = std.mem.eql(u8, src.class, "Audio/Source");
        const is_video = std.mem.eql(u8, src.class, "Video/Source");
        if (!is_audio and !is_video) continue;
        if (!src.running) continue;
        // Monitor ports echo sink output; they are not microphones.
        if (std.mem.indexOf(u8, src.name, "monitor") != null) continue;
        for (links.items) |lk| {
            if (lk[0] != src.id) continue;
            const consumer = self.findNode(nodes.items, lk[1]) orelse continue;
            if (!std.mem.startsWith(u8, consumer.class, "Stream/Input")) continue;
            // One entry per consumer stream.
            var dup = false;
            for (fresh.items) |*e| if (e.node_id == consumer.id) {
                dup = true;
                break;
            };
            if (dup) continue;
            const app = if (consumer.app.len > 0) consumer.app else consumer.bin;
            const kind: Kind = if (is_audio) .mic else if (isCameraSource(src.name)) .camera else if (isRecorderExe(consumer.bin) or isRecorderExe(consumer.app)) .record else .share;
            fresh.append(self.alloc, .{
                .node_id = consumer.id,
                .kind = kind,
                .app = self.alloc.dupe(u8, if (app.len > 0) app else "unknown") catch "",
                .pid = consumer.pid,
            }) catch continue;
        }
    }

    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (sameStreams(self.streams.items, fresh.items)) {
        for (fresh.items) |*e| e.deinit(self.alloc);
        fresh.deinit(self.alloc);
        return false;
    }
    for (self.streams.items) |*e| e.deinit(self.alloc);
    self.streams.clearRetainingCapacity();
    for (fresh.items) |*e| self.streams.append(self.alloc, e.*) catch e.deinit(self.alloc);
    fresh.deinit(self.alloc);
    self.bump();
    return true;
}

fn findNode(self: *Activity, nodes: []const PwNode, id: u64) ?*const PwNode {
    _ = self;
    for (nodes) |*n| if (n.id == id) return n;
    return null;
}

fn sameStreams(a: []const StreamEntry, b: []const StreamEntry) bool {
    if (a.len != b.len) return false;
    for (a) |*x| {
        var hit = false;
        for (b) |*y| if (x.node_id == y.node_id and x.kind == y.kind and x.pid == y.pid and std.mem.eql(u8, x.app, y.app)) {
            hit = true;
            break;
        };
        if (!hit) return false;
    }
    return true;
}

fn jsonStr(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return if (val == .string) val.string else null;
}

fn jsonU64(v: ?std.json.Value) ?u64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

fn runPwDump(self: *Activity) ![]u8 {
    var child = try std.process.spawn(self.io, .{
        .argv = &.{ "/usr/bin/env", "pw-dump" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer {
        // wait() reaps the child and its stdio; closing here too would
        // double-close (BADF abort). Manual close is only for the
        // detached spawn in destroyPipewireNode, which never waits.
        _ = child.wait(self.io) catch {};
    }
    const out = child.stdout orelse return error.NoPipe;
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(self.alloc);
    var tmp: [8192]u8 = undefined;
    while (list.items.len < 8 << 20) {
        const n = std.Io.File.readStreaming(out, self.io, &.{tmp[0..]}) catch break;
        if (n == 0) break;
        list.appendSlice(self.alloc, tmp[0..n]) catch break;
    }
    if (list.items.len == 0) return error.Empty;
    return list.toOwnedSlice(self.alloc);
}

// ---------------------------------------------------------------------------
// Download polling (worker)
// ---------------------------------------------------------------------------

fn pollDownloads(self: *Activity) bool {
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = self.downloadDir(&dirbuf);
    var d = std.Io.Dir.openDirAbsolute(self.io, dir, .{}) catch return false;
    defer d.close(self.io);
    var fresh: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fresh.items) |n| if (n.len > 0) self.alloc.free(n);
        fresh.deinit(self.alloc);
    }
    var it = d.iterate();
    while (it.next(self.io) catch null) |entry| {
        if (fresh.items.len >= max_download_names + 1) break;
        const name = entry.name;
        const partial = std.mem.endsWith(u8, name, ".part") or std.mem.endsWith(u8, name, ".crdownload");
        if (!partial) continue;
        const base = if (std.mem.endsWith(u8, name, ".part"))
            name[0 .. name.len - ".part".len]
        else
            name[0 .. name.len - ".crdownload".len];
        if (base.len == 0) continue;
        fresh.append(self.alloc, self.alloc.dupe(u8, base) catch "") catch continue;
    }
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (sameNames(self.downloads.items, fresh.items)) {
        for (fresh.items) |n| if (n.len > 0) self.alloc.free(n);
        fresh.deinit(self.alloc);
        return false;
    }
    for (self.downloads.items) |n| if (n.len > 0) self.alloc.free(n);
    self.downloads.clearRetainingCapacity();
    for (fresh.items) |n| self.downloads.append(self.alloc, n) catch if (n.len > 0) self.alloc.free(n);
    fresh.deinit(self.alloc);
    self.bump();
    return true;
}

fn sameNames(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a) |x| {
        var hit = false;
        for (b) |y| if (std.mem.eql(u8, x, y)) {
            hit = true;
            break;
        };
        if (!hit) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Classification helpers (pure; unit-tested)
// ---------------------------------------------------------------------------

/// Executables whose video capture means "recording to a file" (red).
/// Anything else capturing video is treated as sharing (green).
fn isRecorderExe(exe: []const u8) bool {
    const known = [_][]const u8{
        "obs",
        "wf-recorder",
        "gpu-screen-recorder",
        "gpu-screen-recorder-gtk",
        "kooha",
        "peek",
        "simplescreenrecorder",
        "vokoscreen",
        "vokoscreenNG",
    };
    for (known) |k| if (std.mem.eql(u8, exe, k)) return true;
    return false;
}

/// Video source names that mean a physical camera (blue) rather than a
/// shared screen (green). Portal/screen-share streams never match.
fn isCameraSource(name: []const u8) bool {
    // Lowercase once into a stack buffer; names are short.
    var buf: [128]u8 = undefined;
    const n = @min(name.len, buf.len);
    for (name[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const lower = buf[0..n];
    const hints = [_][]const u8{ "v4l2", "libcamera", "uvc", "usb", "camera", "webcam", "integrated" };
    for (hints) |h| if (std.mem.indexOf(u8, lower, h) != null) return true;
    return false;
}

test "activity: recorder classification" {
    try std.testing.expect(isRecorderExe("obs"));
    try std.testing.expect(isRecorderExe("wf-recorder"));
    try std.testing.expect(!isRecorderExe("firefox"));
    try std.testing.expect(!isRecorderExe("xdg-desktop-portal-wlr"));
    try std.testing.expect(!isRecorderExe(""));
}

test "activity: camera source names" {
    try std.testing.expect(isCameraSource("v4l2_input.pci-0000_00.0"));
    try std.testing.expect(isCameraSource("libcamera_input"));
    try std.testing.expect(isCameraSource("USB_Webcam"));
    try std.testing.expect(!isCameraSource("xdpw-stream-1234"));
    try std.testing.expect(!isCameraSource(""));
}
