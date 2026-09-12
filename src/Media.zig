const std = @import("std");
const Dbus = @import("Dbus.zig");

// MPRIS media state polled from the session bus (org.mpris.MediaPlayer2.*).
// Mirrors Net.zig's shape: the worker owns a session-bus connection and a
// cached model, the UI reads cheap snapshots, actions go through a queued
// Request token. Direct D-Bus — no compositor/nilebank involvement: the hub
// resize the clock expansion needs already works via setSize, so no
// protocol change was required there.

const mpris_prefix = "org.mpris.MediaPlayer2.";
const mpris_path = "/org/mpris/MediaPlayer2";
const mpris_player_iface = "org.mpris.MediaPlayer2.Player";
const props_iface = "org.freedesktop.DBus.Properties";
const dbus_dest = "org.freedesktop.DBus";
const dbus_path = "/org/freedesktop/DBus";
const dbus_iface = "org.freedesktop.DBus";

// Worker poll cadence (50ms so play/pause/track changes feel instant).
// Position interpolation (see Snapshot.positionUs) keeps the seek bar
// smooth between polls.
pub const refresh_ms: u64 = 50;
const retry_ms: i64 = 5000;

pub const Status = enum {
    stopped,
    playing,
    paused,
};

pub fn statusFromString(s: []const u8) Status {
    if (std.mem.eql(u8, s, "Playing")) return .playing;
    if (std.mem.eql(u8, s, "Paused")) return .paused;
    return .stopped;
}

pub const Snapshot = struct {
    gen: u64 = 0,
    present: bool = false, // a player answered this poll
    status: Status = .stopped,
    title: []const u8 = "",
    artist: []const u8 = "",
    player: []const u8 = "",
    position_us: i64 = 0, // interpolated estimate at snapshot time
    length_us: i64 = 0,
    has_media: bool = false, // title/length known (else show clock only)

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        if (self.title.len > 0) alloc.free(self.title);
        if (self.artist.len > 0) alloc.free(self.artist);
        if (self.player.len > 0) alloc.free(self.player);
        self.* = .{};
    }

    pub fn frac(self: *const Snapshot) f32 {
        if (self.length_us <= 0) return 0;
        const p = @as(f64, @floatFromInt(@max(self.position_us, 0)));
        const l = @as(f64, @floatFromInt(self.length_us));
        return @floatCast(@min(@max(p / l, 0), 1));
    }
};

// Owned per-frame copy helpers.
pub fn formatTime(buf: []u8, us: i64) []const u8 {
    const total_s: i64 = @max(@divTrunc(@max(us, 0), 1_000_000), 0);
    const mm: u64 = @intCast(@divTrunc(total_s, 60));
    const ss: u64 = @intCast(@mod(total_s, 60));
    // Manual two-digit fields: keeps m:ss correct past 99 minutes too.
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}:{d:0>2}", .{ mm, ss }) catch return "";
    // Pad a single minutes digit with a leading zero ("1:05" -> "01:05").
    if (mm < 10) {
        if (buf.len < s.len + 1) return "";
        buf[0] = '0';
        @memcpy(buf[1 .. s.len + 1], s);
        return buf[0 .. s.len + 1];
    }
    if (buf.len < s.len) return "";
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

// Truncate titles without splitting a UTF-8 codepoint; appends "..."
// when cut. Pure; unit-tested.
pub fn truncateTitle(out: []u8, s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s[0..s.len];
    if (max < 3) return s[0..@min(s.len, max)];
    var end: usize = max - 3;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    if (out.len < end + 3) return s[0..end];
    @memcpy(out[0..end], s[0..end]);
    @memcpy(out[end .. end + 3], "...");
    return out[0 .. end + 3];
}

// Position interpolation: while playing, the displayed position advances
// at wall-clock rate from the last sampled base. Pure; unit-tested.
pub fn interpolatePosition(base_us: i64, base_ms: i64, now_ms: i64, status: Status, length_us: i64) i64 {
    if (status != .playing) return @max(base_us, 0);
    const dt_ms = now_ms - base_ms;
    if (dt_ms <= 0) return @max(base_us, 0);
    const est = base_us + dt_ms * 1000;
    if (length_us > 0) return @min(@max(est, 0), length_us);
    return @max(est, 0);
}

pub const Seek = struct {
    position_us: i64,
    fn deinit(self: *Seek, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

pub const Action = union(enum) {
    refresh,
    play_pause,
    next,
    previous,
    seek: Seek,

    fn deinit(self: *Action, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .seek => |*s| s.deinit(alloc),
            else => {},
        }
    }
};

pub const RequestStatus = enum { pending, ok, failed };

pub const Request = struct {
    id: u64 = 0,

    pub fn isQueued(self: Request) bool {
        return self.id != 0;
    }

    pub fn poll(self: Request, media: *Media) RequestStatus {
        if (self.id == 0) return .failed;
        media.mu.lockUncancelable(media.io);
        defer media.mu.unlock(media.io);
        for (media.results.items) |*r| {
            if (r.id == self.id) return if (r.ok) .ok else .failed;
        }
        return .pending;
    }

    pub fn isPending(self: Request, media: *Media) bool {
        return self.poll(media) == .pending;
    }

    pub fn hasFailed(self: Request, media: *Media) bool {
        return self.poll(media) == .failed;
    }
};

const Queued = struct {
    id: u64,
    action: Action,
    fn deinit(self: *Queued, alloc: std.mem.Allocator) void {
        self.action.deinit(alloc);
    }
};

const ActionResult = struct { changed: bool, ok: bool };
const RequestOutcome = struct { id: u64, ok: bool };
const max_results: usize = 32;

const Media = @This();

mu: std.Io.Mutex = .init,
alloc: std.mem.Allocator = undefined,
io: std.Io = undefined,
inited: bool = false,

bus: ?*Dbus.Bus = null,
retry_at_ms: i64 = 0,
gen: u64 = 0,
actions: std.ArrayList(Queued) = .empty,
results: std.ArrayList(RequestOutcome) = .empty,
next_req: u64 = 1,

// Cached model (worker-owned under mu).
player: []const u8 = "",
status: Status = .stopped,
title: []const u8 = "",
artist: []const u8 = "",
trackid: []const u8 = "",
position_us: i64 = 0,
position_ms: i64 = 0, // boot-ms clock when position_us was sampled
length_us: i64 = 0,
present: bool = false,
next_poll_ms: i64 = 0,

pub fn init(self: *Media, alloc: std.mem.Allocator, io: std.Io) void {
    self.alloc = alloc;
    self.io = io;
    self.inited = true;
}

pub fn deinit(self: *Media) void {
    if (self.bus) |b| {
        Dbus.closeBus(b);
        self.bus = null;
    }
    for (self.actions.items) |*q| q.deinit(self.alloc);
    self.actions.deinit(self.alloc);
    self.results.deinit(self.alloc);
    self.freeModel();
    self.* = .{};
}

fn freeModel(self: *Media) void {
    if (self.player.len > 0) self.alloc.free(self.player);
    if (self.title.len > 0) self.alloc.free(self.title);
    if (self.artist.len > 0) self.alloc.free(self.artist);
    if (self.trackid.len > 0) self.alloc.free(self.trackid);
    self.player = "";
    self.title = "";
    self.artist = "";
    self.trackid = "";
    self.position_us = 0;
    self.length_us = 0;
    self.status = .stopped;
    self.present = false;
}

fn nowMs(self: *Media) i64 {
    return std.Io.Clock.boot.now(self.io).toMilliseconds();
}

fn bump(self: *Media) void {
    self.gen +%= 1;
}

fn finishRequest(self: *Media, id: u64, ok: bool) void {
    if (id == 0) return;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    self.results.append(self.alloc, .{ .id = id, .ok = ok }) catch return;
    while (self.results.items.len > max_results) {
        _ = self.results.orderedRemove(0);
    }
}

fn enqueue(self: *Media, action: Action) Request {
    if (!self.inited) {
        var tmp = action;
        tmp.deinit(self.alloc);
        return .{};
    }
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.next_req == 0) self.next_req = 1;
    const id = self.next_req;
    self.actions.append(self.alloc, .{ .id = id, .action = action }) catch {
        var tmp = action;
        tmp.deinit(self.alloc);
        return .{};
    };
    self.next_req = id +% 1;
    if (self.next_req == 0) self.next_req = 1;
    return .{ .id = id };
}

pub fn push(self: *Media, action: Action) void {
    _ = self.enqueue(action);
}

pub fn playPause(self: *Media) Request {
    return self.enqueue(.play_pause);
}

pub fn next(self: *Media) Request {
    return self.enqueue(.next);
}

pub fn previous(self: *Media) Request {
    return self.enqueue(.previous);
}

pub fn seek(self: *Media, position_us: i64) Request {
    return self.enqueue(.{ .seek = .{ .position_us = @max(position_us, 0) } });
}

pub fn refresh(self: *Media) Request {
    return self.enqueue(.refresh);
}

// Cheap UI-thread check: is there an active (playing/paused) player with
// something to show? No allocation; drives the clock hub expansion without
// a snapshot copy. Mirrors Snapshot.has_media so the resize decision and
// the render decision never disagree (expanded hub showing only a clock).
pub fn active(self: *Media) bool {
    if (!self.inited) return false;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    return self.present and self.status != .stopped and
        (self.title.len > 0 or self.length_us > 0);
}

pub fn snapshotCopy(self: *Media, alloc: std.mem.Allocator) Snapshot {    var out = Snapshot{};
    if (!self.inited) return out;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    const now = std.Io.Clock.boot.now(self.io).toMilliseconds();
    out.gen = self.gen;
    out.present = self.present;
    out.status = self.status;
    out.length_us = self.length_us;
    out.position_us = interpolatePosition(self.position_us, self.position_ms, now, self.status, self.length_us);
    out.title = alloc.dupe(u8, self.title) catch "";
    out.artist = alloc.dupe(u8, self.artist) catch "";
    out.player = alloc.dupe(u8, self.player) catch "";
    out.has_media = self.present and (self.title.len > 0 or self.length_us > 0);
    return out;
}

pub fn tick(self: *Media) !bool {
    if (!self.inited) return false;
    if (self.bus == null) {
        const local_changed = self.drainLocalActions();
        const now = self.nowMs();
        if (now < self.retry_at_ms) return local_changed;
        self.retry_at_ms = now + retry_ms;
        if (Dbus.openSession()) |b| {
            self.mu.lockUncancelable(self.io);
            self.bus = b;
            self.next_poll_ms = 0;
            self.mu.unlock(self.io);
            self.mu.lockUncancelable(self.io);
            self.gen +%= 1;
            self.mu.unlock(self.io);
            return true;
        }
        return local_changed;
    }
    var batch: std.ArrayList(Queued) = .empty;
    defer batch.deinit(self.alloc);
    {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.actions.items.len == 0) {
            batch = .empty;
        } else {
            std.mem.swap(std.ArrayList(Queued), &self.actions, &batch);
        }
    }
    var changed = false;
    for (batch.items) |*q| {
        const r = self.applyAction(q);
        if (r.changed) changed = true;
        self.finishRequest(q.id, r.ok);
        q.deinit(self.alloc);
    }
    const now = self.nowMs();
    if (now >= self.next_poll_ms) {
        self.next_poll_ms = now + @as(i64, @intCast(refresh_ms));
        if (self.pollMpris()) changed = true;
    }
    return changed;
}

fn drainLocalActions(self: *Media) bool {
    var batch: std.ArrayList(Queued) = .empty;
    {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        std.mem.swap(std.ArrayList(Queued), &self.actions, &batch);
    }
    defer batch.deinit(self.alloc);
    var changed = false;
    for (batch.items) |*q| {
        if (q.action != .refresh) {
            self.mu.lockUncancelable(self.io);
            self.actions.append(self.alloc, q.*) catch {
                var tmp = q.*;
                tmp.deinit(self.alloc);
            };
            self.mu.unlock(self.io);
            continue;
        }
        self.finishRequest(q.id, true);
        self.mu.lockUncancelable(self.io);
        self.next_poll_ms = 0;
        self.mu.unlock(self.io);
        changed = true;
        q.deinit(self.alloc);
    }
    return changed;
}

fn currentPlayer(self: *Media) ?[]const u8 {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.player.len == 0) return null;
    return self.alloc.dupe(u8, self.player) catch null;
}

fn applyAction(self: *Media, q: *Queued) ActionResult {
    const bus = self.bus orelse return .{ .changed = false, .ok = false };
    switch (q.action) {
        .refresh => {
            self.mu.lockUncancelable(self.io);
            self.next_poll_ms = 0;
            self.mu.unlock(self.io);
            return .{ .changed = true, .ok = true };
        },
        .play_pause => {
            const p = self.currentPlayer() orelse return .{ .changed = false, .ok = false };
            defer self.alloc.free(p);
            if (!callPlayerMethod(self, bus, p, "PlayPause")) return .{ .changed = false, .ok = false };
            self.mu.lockUncancelable(self.io);
            self.next_poll_ms = 0;
            self.mu.unlock(self.io);
            return .{ .changed = true, .ok = true };
        },
        .next => {
            const p = self.currentPlayer() orelse return .{ .changed = false, .ok = false };
            defer self.alloc.free(p);
            if (!callPlayerMethod(self, bus, p, "Next")) return .{ .changed = false, .ok = false };
            self.mu.lockUncancelable(self.io);
            self.next_poll_ms = 0;
            self.mu.unlock(self.io);
            return .{ .changed = true, .ok = true };
        },
        .previous => {
            const p = self.currentPlayer() orelse return .{ .changed = false, .ok = false };
            defer self.alloc.free(p);
            if (!callPlayerMethod(self, bus, p, "Previous")) return .{ .changed = false, .ok = false };
            self.mu.lockUncancelable(self.io);
            self.next_poll_ms = 0;
            self.mu.unlock(self.io);
            return .{ .changed = true, .ok = true };
        },
        .seek => |s| {
            const p = self.currentPlayer() orelse return .{ .changed = false, .ok = false };
            defer self.alloc.free(p);
            self.mu.lockUncancelable(self.io);
            const track = self.alloc.dupe(u8, self.trackid) catch "";
            const cur = interpolatePosition(self.position_us, self.position_ms, self.nowMs(), self.status, self.length_us);
            self.mu.unlock(self.io);
            defer if (track.len > 0) self.alloc.free(track);
            if (!seekTo(self, bus, p, track, s.position_us, cur)) {
                if (track.len > 0) self.alloc.free(track);
                return .{ .changed = false, .ok = false };
            }
            self.mu.lockUncancelable(self.io);
            self.position_us = s.position_us;
            self.position_ms = self.nowMs();
            self.next_poll_ms = 0;
            self.mu.unlock(self.io);
            self.bump();
            return .{ .changed = true, .ok = true };
        },
    }
}

// ---------------------------------------------------------------------------
// MPRIS D-Bus helpers. All blocking sd-bus calls run on the State worker
// thread, never the UI thread.
// ---------------------------------------------------------------------------

fn listPlayers(self: *Media, bus: *Dbus.Bus) []const []const u8 {
    var m = Dbus.Method.init(bus, .{
        .destination = dbus_dest,
        .path = dbus_path,
        .interface = dbus_iface,
        .member = "ListNames",
    }, .{}) orelse return &.{};
    defer m.deinit();
    var r = m.send(bus) orelse return &.{};
    defer r.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(self.alloc);
    if (r.enterRaw('a', "s") < 0) return &.{};
    while (r.readStr()) |name| {
        if (!std.mem.startsWith(u8, name, mpris_prefix)) continue;
        const owned = self.alloc.dupe(u8, name) catch continue;
        out.append(self.alloc, owned) catch {
            self.alloc.free(owned);
            break;
        };
        if (out.items.len >= 16) break;
    }
    _ = r.exit();
    const slice = out.toOwnedSlice(self.alloc) catch return &.{};
    return slice;
}

fn getStatusProp(self: *Media, bus: *Dbus.Bus, player: []const u8) ?Status {
    const dest = self.alloc.dupeZ(u8, player) catch return null;
    defer self.alloc.free(dest);
    var m = Dbus.Method.init(bus, .{
        .destination = dest,
        .path = mpris_path,
        .interface = props_iface,
        .member = "Get",
    }, .{ mpris_player_iface, "PlaybackStatus" }) orelse return null;
    defer m.deinit();
    var r = m.send(bus) orelse return null;
    defer r.deinit();
    const pk = r.peek() orelse return null;
    if (pk.t != 'v' or !std.mem.eql(u8, pk.contents, "s")) {
        _ = r.skip("v");
        return null;
    }
    if (!enterVariant(&r, pk.contents)) return null;
    const s = r.readStr() orelse {
        _ = r.exit();
        return null;
    };
    const st = statusFromString(s);
    _ = r.exit();
    return st;
}

fn enterVariant(r: *Dbus.Reply, sig: []const u8) bool {
    var buf: [64]u8 = undefined;
    if (sig.len == 0 or sig.len + 1 > buf.len) return false;
    @memcpy(buf[0..sig.len], sig);
    buf[sig.len] = 0;
    return r.enterRaw('v', buf[0..sig.len :0]) > 0;
}

const Meta = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    length_us: i64 = 0,
    trackid: []const u8 = "",

    fn deinit(self: *Meta, alloc: std.mem.Allocator) void {
        if (self.title.len > 0) alloc.free(self.title);
        if (self.artist.len > 0) alloc.free(self.artist);
        if (self.trackid.len > 0) alloc.free(self.trackid);
        self.* = .{};
    }
};

fn getMetadata(self: *Media, bus: *Dbus.Bus, player: []const u8) ?Meta {
    const dest = self.alloc.dupeZ(u8, player) catch return null;
    defer self.alloc.free(dest);
    var m = Dbus.Method.init(bus, .{
        .destination = dest,
        .path = mpris_path,
        .interface = props_iface,
        .member = "Get",
    }, .{ mpris_player_iface, "Metadata" }) orelse return null;
    defer m.deinit();
    var r = m.send(bus) orelse return null;
    defer r.deinit();
    const pk = r.peek() orelse return null;
    if (pk.t != 'v') {
        _ = r.skip("v");
        return null;
    }
    if (!enterVariant(&r, pk.contents)) return null;
    defer _ = r.exit();
    if (!std.mem.eql(u8, pk.contents, "a{sv}")) return null;
    var meta = Meta{};
    errdefer meta.deinit(self.alloc);
    if (r.enterRaw('a', "{sv}") < 0) return meta;
    while (r.enterRaw('e', "sv") > 0) {
        const key = r.readStr() orelse break;
        const vk = r.peek() orelse {
            _ = r.exit();
            break;
        };
        if (vk.t != 'v') {
            _ = r.skip("v");
            _ = r.exit();
            continue;
        }
        if (std.mem.eql(u8, key, "xesam:title")) {
            if (enterVariant(&r, vk.contents) and std.mem.eql(u8, vk.contents, "s")) {
                if (r.readStr()) |v| {
                    if (meta.title.len > 0) self.alloc.free(meta.title);
                    meta.title = self.alloc.dupe(u8, v) catch "";
                }
                _ = r.exit();
            } else {
                _ = r.skip("v");
            }
        } else if (std.mem.eql(u8, key, "xesam:artist")) {
            if (enterVariant(&r, vk.contents) and std.mem.eql(u8, vk.contents, "as")) {
                if (r.enterRaw('a', "s") >= 0) {
                    if (r.readStr()) |v| {
                        if (meta.artist.len > 0) self.alloc.free(meta.artist);
                        meta.artist = self.alloc.dupe(u8, v) catch "";
                    }
                    while (r.readStr()) |_| {}
                    _ = r.exit();
                }
                _ = r.exit();
            } else {
                _ = r.skip("v");
            }
        } else if (std.mem.eql(u8, key, "mpris:length")) {
            if (enterVariant(&r, vk.contents)) {
                if (std.mem.eql(u8, vk.contents, "x")) {
                    meta.length_us = r.readI64() orelse meta.length_us;
                } else if (std.mem.eql(u8, vk.contents, "t")) {
                    meta.length_us = @intCast(r.readU64() orelse @as(u64, @intCast(@max(meta.length_us, 0))));
                } else if (std.mem.eql(u8, vk.contents, "u")) {
                    meta.length_us = @intCast(r.readU32() orelse 0);
                } else if (std.mem.eql(u8, vk.contents, "i")) {
                    meta.length_us = @intCast(r.readI32() orelse 0);
                } else {
                    _ = r.skip("v");
                }
                _ = r.exit();
            } else {
                _ = r.skip("v");
            }
        } else if (std.mem.eql(u8, key, "mpris:trackid")) {
            if (enterVariant(&r, vk.contents) and std.mem.eql(u8, vk.contents, "o")) {
                if (r.readObj()) |v| {
                    if (meta.trackid.len > 0) self.alloc.free(meta.trackid);
                    meta.trackid = self.alloc.dupe(u8, v) catch "";
                }
                _ = r.exit();
            } else {
                _ = r.skip("v");
            }
        } else {
            _ = r.skip("v");
        }
        _ = r.exit();
    }
    _ = r.exit();
    return meta;
}

fn getPositionProp(self: *Media, bus: *Dbus.Bus, player: []const u8) ?i64 {
    const dest = self.alloc.dupeZ(u8, player) catch return null;
    defer self.alloc.free(dest);
    var m = Dbus.Method.init(bus, .{
        .destination = dest,
        .path = mpris_path,
        .interface = props_iface,
        .member = "Get",
    }, .{ mpris_player_iface, "Position" }) orelse return null;
    defer m.deinit();
    var r = m.send(bus) orelse return null;
    defer r.deinit();
    const pk = r.peek() orelse return null;
    if (pk.t != 'v') {
        _ = r.skip("v");
        return null;
    }
    if (!enterVariant(&r, pk.contents)) return null;
    defer _ = r.exit();
    if (std.mem.eql(u8, pk.contents, "x")) return r.readI64();
    if (std.mem.eql(u8, pk.contents, "t")) {
        const v = r.readU64() orelse return null;
        return @intCast(v);
    }
    return null;
}

fn callPlayerMethod(self: *Media, bus: *Dbus.Bus, player: []const u8, member: [*:0]const u8) bool {
    const dest = self.alloc.dupeZ(u8, player) catch return false;
    defer self.alloc.free(dest);
    var m = Dbus.Method.init(bus, .{
        .destination = dest,
        .path = mpris_path,
        .interface = mpris_player_iface,
        .member = member,
    }, .{}) orelse return false;
    defer m.deinit();
    var r = m.send(bus) orelse return false;
    defer r.deinit();
    return true;
}

fn seekTo(self: *Media, bus: *Dbus.Bus, player: []const u8, trackid: []const u8, target_us: i64, current_us: i64) bool {
    const dest = self.alloc.dupeZ(u8, player) catch return false;
    defer self.alloc.free(dest);
    // Preferred: SetPosition(trackid, position). Falls back to relative
    // Seek when the player rejects it (e.g. no trackid or unsupported).
    if (trackid.len > 0) {
        const track_z = self.alloc.dupeZ(u8, trackid) catch null;
        if (track_z) |tz| {
            defer self.alloc.free(tz);
            var m = Dbus.Method.init(bus, .{
                .destination = dest,
                .path = mpris_path,
                .interface = mpris_player_iface,
                .member = "SetPosition",
            }, .{ Dbus.obj(tz), target_us }) orelse null;
            if (m) |*mm| {
                defer mm.deinit();
                if (mm.send(bus)) |*rr| {
                    var r = rr.*;
                    defer r.deinit();
                    return true;
                }
            }
        }
    }
    const offset: i64 = target_us - current_us;
    var m = Dbus.Method.init(bus, .{
        .destination = dest,
        .path = mpris_path,
        .interface = mpris_player_iface,
        .member = "Seek",
    }, .{offset}) orelse return false;
    defer m.deinit();
    var r = m.send(bus) orelse return false;
    defer r.deinit();
    return true;
}

fn pollMpris(self: *Media) bool {
    const bus = self.bus orelse return false;
    const names = self.listPlayers(bus);
    defer {
        for (names) |n| self.alloc.free(n);
        if (names.len > 0) self.alloc.free(names);
    }
    if (names.len == 0) {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (!self.present and self.status == .stopped) return false;
        self.freeModelLocked();
        self.bump();
        return true;
    }
    // Prefer Playing > Paused > anything else, like LeafShell's find_active.
    var best: ?[]const u8 = null;
    var best_rank: u8 = 255;
    var best_status: Status = .stopped;
    for (names) |n| {
        const st = self.getStatusProp(bus, n) orelse continue;
        const rank: u8 = switch (st) {
            .playing => 0,
            .paused => 1,
            .stopped => 2,
        };
        if (rank < best_rank) {
            best_rank = rank;
            best = n;
            best_status = st;
            if (rank == 0) break;
        }
    }
    const chosen = best orelse names[0];
    const st = if (best) |_| best_status else (self.getStatusProp(bus, chosen) orelse .stopped);
    var meta = self.getMetadata(bus, chosen) orelse Meta{};
    defer meta.deinit(self.alloc);
    const pos = self.getPositionProp(bus, chosen) orelse 0;
    const now = self.nowMs();

    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    var changed = false;
    if (!std.mem.eql(u8, self.player, chosen)) changed = true;
    if (self.status != st) changed = true;
    if (!std.mem.eql(u8, self.title, meta.title)) changed = true;
    if (!std.mem.eql(u8, self.artist, meta.artist)) changed = true;
    if (!std.mem.eql(u8, self.trackid, meta.trackid)) changed = true;
    if (self.length_us != meta.length_us) changed = true;
    // Position always moves while playing; treat a >2s jump as a change
    // so the UI wakes, otherwise the interpolation covers it silently.
    if (st == .playing and @abs(pos - self.position_us) > 2_000_000) changed = true;
    if (!self.present) changed = true;

    if (!changed) {
        // Still refresh the base so interpolation doesn't drift.
        self.position_us = pos;
        self.position_ms = now;
        return false;
    }
    if (self.player.len > 0) self.alloc.free(self.player);
    if (self.title.len > 0) self.alloc.free(self.title);
    if (self.artist.len > 0) self.alloc.free(self.artist);
    if (self.trackid.len > 0) self.alloc.free(self.trackid);
    self.player = self.alloc.dupe(u8, chosen) catch "";
    self.title = self.alloc.dupe(u8, meta.title) catch "";
    self.artist = self.alloc.dupe(u8, meta.artist) catch "";
    self.trackid = self.alloc.dupe(u8, meta.trackid) catch "";
    self.status = st;
    self.position_us = pos;
    self.position_ms = now;
    self.length_us = meta.length_us;
    self.present = true;
    self.bump();
    return true;
}

fn freeModelLocked(self: *Media) void {
    if (self.player.len > 0) self.alloc.free(self.player);
    if (self.title.len > 0) self.alloc.free(self.title);
    if (self.artist.len > 0) self.alloc.free(self.artist);
    if (self.trackid.len > 0) self.alloc.free(self.trackid);
    self.player = "";
    self.title = "";
    self.artist = "";
    self.trackid = "";
    self.position_us = 0;
    self.length_us = 0;
    self.status = .stopped;
    self.present = false;
}

test "media: status strings" {
    try std.testing.expectEqual(Status.playing, statusFromString("Playing"));
    try std.testing.expectEqual(Status.paused, statusFromString("Paused"));
    try std.testing.expectEqual(Status.stopped, statusFromString("Stopped"));
    try std.testing.expectEqual(Status.stopped, statusFromString(""));
    try std.testing.expectEqual(Status.stopped, statusFromString("Unknown"));
}

test "media: position interpolation" {
    try std.testing.expectEqual(@as(i64, 5_000_000), interpolatePosition(5_000_000, 1000, 2000, .paused, 60_000_000));
    try std.testing.expectEqual(@as(i64, 6_000_000), interpolatePosition(5_000_000, 1000, 2000, .playing, 60_000_000));
    // Clamped at the track length.
    try std.testing.expectEqual(@as(i64, 60_000_000), interpolatePosition(59_500_000, 1000, 2000, .playing, 60_000_000));
    // Paused never advances, even with a newer clock.
    try std.testing.expectEqual(@as(i64, 0), interpolatePosition(0, 1000, 5000, .stopped, 0));
}

test "media: time formatting" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("00:00", formatTime(&buf, 0));
    try std.testing.expectEqualStrings("01:05", formatTime(&buf, 65_000_000));
    try std.testing.expectEqualStrings("10:00", formatTime(&buf, 600_000_000));
    try std.testing.expectEqualStrings("00:00", formatTime(&buf, -5));
}

test "media: title truncation keeps utf8 boundaries" {
    var out: [32]u8 = undefined;
    try std.testing.expectEqualStrings("hi", truncateTitle(&out, "hi", 14));
    try std.testing.expectEqualStrings("hello...", truncateTitle(&out, "hello world, this is long", 8));
    // "é" is 2 bytes: cutting inside it must step back, not split.
    const s = "abcd\xc3\xa9fghij";
    const t = truncateTitle(&out, s, 6);
    try std.testing.expect(t.len <= 6);
    try std.testing.expect(std.unicode.utf8ValidateSlice(t));
}

test "media: snapshot frac clamps" {
    const s = Snapshot{ .position_us = 30_000_000, .length_us = 60_000_000 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.frac(), 0.001);
    const over = Snapshot{ .position_us = 90_000_000, .length_us = 60_000_000 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), over.frac(), 0.001);
    const empty = Snapshot{};
    try std.testing.expectEqual(@as(f32, 0), empty.frac());
}

test "media: tick without session bus is harmless" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var media: Media = .{};
    media.init(alloc, io);
    defer media.deinit();
    try std.testing.expect(try media.tick() == false);
    const req = media.playPause();
    try std.testing.expect(req.isQueued());
    try std.testing.expectEqual(RequestStatus.pending, req.poll(&media));
    var snap = media.snapshotCopy(alloc);
    defer snap.deinit(alloc);
    try std.testing.expect(!snap.present);
}

test "media: refresh completes without bus" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var media: Media = .{};
    media.init(alloc, io);
    defer media.deinit();
    const req = media.refresh();
    try std.testing.expect(req.isQueued());
    try std.testing.expect(try media.tick() == true);
    try std.testing.expectEqual(RequestStatus.ok, req.poll(&media));
}

test "media: seek queues a valid request" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var media: Media = .{};
    media.init(alloc, io);
    defer media.deinit();
    const req = media.seek(30_000_000);
    try std.testing.expect(req.isQueued());
    try std.testing.expect(req.isPending(&media));
}
