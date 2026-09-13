const std = @import("std");
const Dbus = @import("Dbus.zig");

const Net = @This();

const nm_dest = "org.freedesktop.NetworkManager";
const nm_path = "/org/freedesktop/NetworkManager";
const nm_iface = "org.freedesktop.NetworkManager";
const nm_dev_iface = "org.freedesktop.NetworkManager.Device";
const nm_wired_iface = "org.freedesktop.NetworkManager.Device.Wired";
const nm_wireless_iface = "org.freedesktop.NetworkManager.Device.Wireless";
const nm_stats_iface = "org.freedesktop.NetworkManager.Device.Statistics";
const nm_ap_iface = "org.freedesktop.NetworkManager.AccessPoint";
const nm_ac_iface = "org.freedesktop.NetworkManager.Connection.Active";
const nm_settings_iface = "org.freedesktop.NetworkManager.Settings";
const nm_settings_path = "/org/freedesktop/NetworkManager/Settings";
const nm_conn_iface = "org.freedesktop.NetworkManager.Settings.Connection";
const nm_conn_settings_iface = "org.freedesktop.NetworkManager.Connection.Settings";
const props_iface = "org.freedesktop.DBus.Properties";

const bluez_dest = "org.bluez";
const bluez_root = "/";
const bluez_adapter_iface = "org.bluez.Adapter1";
const bluez_device_iface = "org.bluez.Device1";

// Shared worker/UI cadence: the worker runs a full NetworkManager poll
// this often, the open network panel re-requests fresh state this often
// (see HubUi's steady timer), and main's fallback wakeup ticks this often
// so frames — and snapshots — keep flowing with no input.
pub const refresh_ms: u64 = 750;
const bt_poll_ms: i64 = 3000;
const ap_stale_ms: i64 = 10000;
// Saved profiles change rarely; refresh lazily but keep the flag fresh
// enough that a just-saved password shows up on the next panel look.
const saved_stale_ms: i64 = 10000;
const retry_ms: i64 = 5000;

pub const DeviceKind = enum { ethernet, wifi, other };

const Device = struct {
    path: []const u8 = "",
    iface: []const u8 = "",
    kind: DeviceKind = .other,
    state: u32 = 0,
    carrier: bool = false,
    link_mbps: u32 = 0,
    rx_bps: f64 = 0,
    tx_bps: f64 = 0,
    prev_rx: u64 = 0,
    prev_tx: u64 = 0,
    prev_ms: i64 = 0,

    fn connected(self: *const Device) bool {
        return self.state == 100;
    }
};

const Ap = struct {
    path: []const u8 = "",
    ssid: []const u8 = "",
    strength: u8 = 0,
    secured: bool = false,
    freq_mhz: u32 = 0,
    active: bool = false,
    // Stable connection id assigned by the worker on scan (see
    // next_ap_id): reused across scans for the same ssid+frequency so
    // the UI can track a selected connection. 0 = unassigned.
    id: u64 = 0,
};

// One saved NetworkManager connection profile (wifi only): the profile's
// D-Bus path plus its SSID. Lets the panel gray out the password entry
// ("Password saved — click Connect") and lets Connect run
// ActivateConnection on the stored profile, so NM supplies the secret
// itself instead of the UI re-asking the user every time.
const SavedConn = struct {
    path: []const u8,
    ssid: []const u8,

    fn deinit(self: *SavedConn, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.ssid);
    }
};

const BtDev = struct {
    name: []const u8 = "",
    connected: bool = false,
    paired: bool = false,
};

const PrevStat = struct {
    path: []const u8 = "",
    rx: u64 = 0,
    tx: u64 = 0,
    ms: i64 = 0,
};

pub const Connect = struct {
    device_path: []const u8,
    ap_path: []const u8,
    ssid: []const u8,
    password: []const u8,

    fn deinit(self: *Connect, alloc: std.mem.Allocator) void {
        alloc.free(self.device_path);
        alloc.free(self.ap_path);
        alloc.free(self.ssid);
        alloc.free(self.password);
    }
};

// One saved-profile activation: reuses the stored secret. `conn_path` is a
// SavedConn.path; `ap_path`/`dev_path` pin the wifi device + access point.
pub const ConnectSaved = struct {
    device_path: []const u8,
    ap_path: []const u8,
    conn_path: []const u8,

    fn deinit(self: *ConnectSaved, alloc: std.mem.Allocator) void {
        alloc.free(self.device_path);
        alloc.free(self.ap_path);
        alloc.free(self.conn_path);
    }
};

pub const Action = union(enum) {
    wifi_set_enabled: bool,
    bt_set_enabled: bool,
    scan,
    refresh,
    connect: Connect,
    connect_saved: ConnectSaved,
    disconnect,

    fn deinit(self: *Action, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .connect => |*c| c.deinit(alloc),
            .connect_saved => |*c| c.deinit(alloc),
            else => {},
        }
    }
};

// Outcome of one worker-applied action, as observed by the requester.
// The worker applies actions asynchronously on its own thread, so a named
// method (setWifiEnabled, scan, ...) cannot return the D-Bus result
// directly. It returns a Request token instead; poll the token to learn
// whether the worker ran the action and whether it succeeded. Failure
// details (when the worker reports any) land in `Snapshot.last_error`.
pub const RequestStatus = enum { pending, ok, failed };

pub const Request = struct {
    id: u64 = 0, // 0 = never queued (immediate validation/enqueue failure)

    pub fn isQueued(self: Request) bool {
        return self.id != 0;
    }

    pub fn poll(self: Request, net: *Net) RequestStatus {
        if (self.id == 0) return .failed;
        net.mu.lockUncancelable(net.io);
        defer net.mu.unlock(net.io);
        for (net.results.items) |*r| {
            if (r.id == self.id) return if (r.ok) .ok else .failed;
        }
        return .pending;
    }

    pub fn isPending(self: Request, net: *Net) bool {
        return self.poll(net) == .pending;
    }

    pub fn hasFailed(self: Request, net: *Net) bool {
        return self.poll(net) == .failed;
    }
};

// Queued envelope: pairs an Action with its requester's id so the worker
// can record a per-request outcome. id 0 = untracked (plain push()).
const Queued = struct {
    id: u64,
    action: Action,

    fn deinit(self: *Queued, alloc: std.mem.Allocator) void {
        self.action.deinit(alloc);
    }
};

// Worker-side result of one applied action. `changed` preserves the old
// tick() contract (did the model/error state move?); `ok` is the new
// per-request signal (did the D-Bus call succeed?).
const ActionResult = struct { changed: bool, ok: bool };

// Recorded per-request outcome. Plain data, bounded (see max_results).
const RequestOutcome = struct { id: u64, ok: bool };

// Cap on remembered outcomes. Peek semantics (poll() never removes), so a
// caller that drops its Request without polling leaks one entry until it
// ages out here.
const max_results: usize = 32;

pub const DeviceView = struct {
    kind: DeviceKind,
    iface: []const u8,
    state: u32,
    connected: bool,
    carrier: bool,
    link_mbps: u32,
    rx_bps: f64,
    tx_bps: f64,
};

pub const ApView = struct {
    // Stable id (see Ap.id). Matches Snapshot.connected for the AP you
    // are joined to. 0 = unassigned.
    id: u64 = 0,
    path: []const u8,
    ssid: []const u8,
    strength: u8,
    secured: bool,
    freq_mhz: u32,
    active: bool,
    // A saved NM profile exists for this SSID (see SavedConn): the
    // password entry grays out and Connect activates the stored profile.
    saved: bool = false,
    // The saved profile's D-Bus path ("" when !saved). Owned by the
    // snapshot; freed in deinit.
    saved_path: []const u8 = "",
};

pub const BtDevView = struct {
    name: []const u8,
    connected: bool,
    paired: bool,
};

pub const Snapshot = struct {
    gen: u64 = 0,
    present: bool = false,
    networking_on: bool = true,
    wifi_on: bool = false,
    // Any wifi device present (gates toggles/rows that need a radio).
    wifi_supported: bool = false,
    connectivity: u32 = 0,
    devices: []DeviceView = &.{},
    active_id: []const u8 = "",
    active_state: u32 = 0,
    aps: []ApView = &.{},
    // Id of the currently connected network (an ApView.id), 0 = none.
    connected: u64 = 0,
    ap_error: []const u8 = "",
    bt_present: bool = false,
    bt_powered: bool = false,
    bt_devices: []BtDevView = &.{},
    last_error: []const u8 = "",

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        for (self.devices) |d| alloc.free(d.iface);
        if (self.devices.len > 0) alloc.free(self.devices);
        if (self.active_id.len > 0) alloc.free(self.active_id);
        for (self.aps) |a| {
            alloc.free(a.path);
            alloc.free(a.ssid);
            if (a.saved_path.len > 0) alloc.free(a.saved_path);
        }
        if (self.aps.len > 0) alloc.free(self.aps);
        if (self.ap_error.len > 0) alloc.free(self.ap_error);
        for (self.bt_devices) |d| alloc.free(d.name);
        if (self.bt_devices.len > 0) alloc.free(self.bt_devices);
        if (self.last_error.len > 0) alloc.free(self.last_error);
        self.* = .{};
    }
};

pub const Status = struct {
    present: bool = false,
    wifi_on: bool = false,
    // Active AP signal, 0-100 percent (mirrors Ap.strength; 0 = none or
    // unknown). Render bars via barsForStrength, never switch on this
    // directly (see the bar indicator in main.zig).
    strength: u8 = 0,
    // Associated with an access point (a router is on the other end),
    // whether or not it routes to the internet (see connectivity_full).
    connected: bool = false,
    // Last NetworkManager Connectivity state (see connectivity_full).
    connectivity: u32 = 0,
    eth_up: bool = false,
    // Bluetooth adapter present at all (gates the bar indicator).
    bt_present: bool = false,
    bt_powered: bool = false,
    down_bps: f64 = 0,
    up_bps: f64 = 0,
};

// NetworkManager Connectivity state (libnm NMConnectivityState):
// 0 unknown, 1 none, 2 portal, 3 limited, 4 full. Only FULL means usable
// internet; anything less with a link up is "connected, no internet".
pub const connectivity_full: u32 = 4;

/// True when the link actually routes to the internet.
pub fn online(connectivity: u32) bool {
    return connectivity == connectivity_full;
}

mu: std.Io.Mutex = .init,
alloc: std.mem.Allocator = undefined,
io: std.Io = undefined,
inited: bool = false,

bus: ?*Dbus.Bus = null,
retry_at_ms: i64 = 0,
gen: u64 = 0,
actions: std.ArrayList(Queued) = .empty,
// Per-request outcomes, oldest first; worker appends, poll() peeks.
results: std.ArrayList(RequestOutcome) = .empty,
next_req: u64 = 1,

networking_on: bool = true,
wifi_on: bool = false,
connectivity: u32 = 0,
devices: std.ArrayList(Device) = .empty,
prev_stats: std.ArrayList(PrevStat) = .empty,
active_id: []const u8 = "",
active_path: []const u8 = "",
active_state: u32 = 0,
active_ap_path: []const u8 = "",
active_ssid: []const u8 = "",
aps: std.ArrayList(Ap) = .empty,
ap_dirty: bool = true,
ap_next_ms: i64 = 0,
ap_error: []const u8 = "",
// Saved wifi profiles (see SavedConn). Refreshed with the AP list and
// after every connect (AddAndActivateConnection persists a new profile).
saved: std.ArrayList(SavedConn) = .empty,
saved_dirty: bool = true,
saved_next_ms: i64 = 0,
// Next stable AP id to hand out (see Ap.id). Never 0 (0 = unassigned).
next_ap_id: u64 = 1,
// Owned UI search query; snapshotCopy filters aps to SSIDs containing
// it (ASCII case-insensitive). Empty = no filter. Set synchronously
// via setSearch (typed text arrives every frame; no worker roundtrip).
search: []const u8 = "",
bt_present: bool = false,
bt_powered: bool = false,
bt_adapter: []const u8 = "",
bt_devices: std.ArrayList(BtDev) = .empty,
bt_dirty: bool = true,
bt_next_ms: i64 = 0,
last_error: []const u8 = "",
next_poll_ms: i64 = 0,
uuid_counter: u64 = 0,

pub fn init(self: *Net, alloc: std.mem.Allocator, io: std.Io) void {
    self.alloc = alloc;
    self.io = io;
    self.inited = true;
}

pub fn deinit(self: *Net) void {
    if (self.bus) |b| {
        Dbus.closeBus(b);
        self.bus = null;
    }
    for (self.actions.items) |*q| q.deinit(self.alloc);
    self.actions.deinit(self.alloc);
    self.results.deinit(self.alloc);
    self.freeModel();
    self.devices.deinit(self.alloc);
    self.prev_stats.deinit(self.alloc);
    self.aps.deinit(self.alloc);
    self.saved.deinit(self.alloc);
    self.bt_devices.deinit(self.alloc);
    self.* = .{};
}

// Drop the cached access-point list. Caller must hold the model mutex.
// Used when the radio goes off (stale networks must vanish immediately)
// and on external on->off transitions seen by pollCore.
fn clearApsLocked(self: *Net) void {
    for (self.aps.items) |*a| {
        if (a.path.len > 0) self.alloc.free(a.path);
        if (a.ssid.len > 0) self.alloc.free(a.ssid);
    }
    self.aps.clearRetainingCapacity();
}

fn freeModel(self: *Net) void {
    for (self.devices.items) |*d| {
        if (d.path.len > 0) self.alloc.free(d.path);
        if (d.iface.len > 0) self.alloc.free(d.iface);
    }
    self.devices.clearRetainingCapacity();
    for (self.prev_stats.items) |*p| {
        if (p.path.len > 0) self.alloc.free(p.path);
    }
    self.prev_stats.clearRetainingCapacity();
    self.clearApsLocked();
    for (self.saved.items) |*s| s.deinit(self.alloc);
    self.saved.clearRetainingCapacity();
    for (self.bt_devices.items) |*d| {
        if (d.name.len > 0) self.alloc.free(d.name);
    }
    self.bt_devices.clearRetainingCapacity();
    if (self.active_id.len > 0) self.alloc.free(self.active_id);
    if (self.active_path.len > 0) self.alloc.free(self.active_path);
    if (self.active_ap_path.len > 0) self.alloc.free(self.active_ap_path);
    if (self.active_ssid.len > 0) self.alloc.free(self.active_ssid);
    if (self.bt_adapter.len > 0) self.alloc.free(self.bt_adapter);
    if (self.ap_error.len > 0) self.alloc.free(self.ap_error);
    if (self.last_error.len > 0) self.alloc.free(self.last_error);
    if (self.search.len > 0) self.alloc.free(self.search);
    self.search = "";
    self.active_id = "";
    self.active_path = "";
    self.active_ap_path = "";
    self.active_ssid = "";
    self.bt_adapter = "";
    self.ap_error = "";
    self.last_error = "";
}

fn nowMs(self: *Net) i64 {
    return std.Io.Clock.boot.now(self.io).toMilliseconds();
}

fn bump(self: *Net) void {
    self.gen +%= 1;
}

fn setError(self: *Net, comptime fmt: []const u8, args: anytype) void {
    if (self.last_error.len > 0) self.alloc.free(self.last_error);
    self.last_error = std.fmt.allocPrint(self.alloc, fmt, args) catch "";
    self.bump();
}

fn clearError(self: *Net) void {
    if (self.last_error.len > 0) self.alloc.free(self.last_error);
    self.last_error = "";
    self.bump();
}

// Low-level fire-and-forget enqueue. Prefer the named methods below;
// they return a Request token whose poll() reports the worker's reply.
pub fn push(self: *Net, action: Action) void {
    _ = self.enqueue(action);
}

// Shared enqueue path. Assigns the next request id under the queue mutex
// (one lock hold for id + append) and wraps the action in its Queued
// envelope. Returns an invalid Request (id 0, polls as .failed) when the
// action was dropped instead of queued.
fn enqueue(self: *Net, action: Action) Request {
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
    // Advance only once the action is safely queued: an OOM drop must leave
    // next_req untouched, otherwise burned ids could eventually collide with
    // a live request and misattribute its outcome.
    self.next_req = id +% 1;
    if (self.next_req == 0) self.next_req = 1;
    return .{ .id = id };
}

// Records one worker-applied outcome for later poll(). Untracked actions
// (id 0, via push()) skip the store.
fn finishRequest(self: *Net, id: u64, ok: bool) void {
    if (id == 0) return;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    self.results.append(self.alloc, .{ .id = id, .ok = ok }) catch return;
    while (self.results.items.len > max_results) {
        _ = self.results.orderedRemove(0);
    }
}

// Named action methods. Each enqueues one worker action and returns its
// Request token: poll the token for .pending/.ok/.failed. Bus-dependent
// requests stay pending while the system bus is down and run once it
// connects (see Status.present); refresh() is local-only and completes
// even offline.
pub fn setWifiEnabled(self: *Net, on: bool) Request {
    return self.enqueue(.{ .wifi_set_enabled = on });
}

pub fn toggleWifi(self: *Net) Request {
    return self.setWifiEnabled(!self.wifiOn());
}

fn wifiOn(self: *Net) bool {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    return self.wifi_on;
}

pub fn setBluetoothEnabled(self: *Net, on: bool) Request {
    return self.enqueue(.{ .bt_set_enabled = on });
}

pub fn toggleBluetooth(self: *Net) Request {
    return self.setBluetoothEnabled(!self.bluetoothOn());
}

fn bluetoothOn(self: *Net) bool {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    return self.bt_powered;
}

pub fn scan(self: *Net) Request {
    return self.enqueue(.scan);
}

pub fn refresh(self: *Net) Request {
    return self.enqueue(.refresh);
}

// Synchronous UI search query for the AP list (see `search`). Dupes the
// query under the model mutex and bumps the generation so snapshots
// refresh; early-outs (no alloc, no bump) when unchanged, since the UI
// calls this every frame while the network panel is open. Empty clears
// the filter.
pub fn setSearch(self: *Net, query: []const u8) void {
    if (!self.inited) return;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (std.mem.eql(u8, self.search, query)) return;
    if (self.search.len > 0) self.alloc.free(self.search);
    self.search = self.alloc.dupe(u8, query) catch "";
    self.bump();
}

pub fn disconnect(self: *Net) Request {
    return self.enqueue(.disconnect);
}

pub fn connect(self: *Net, device_path: []const u8, ap_path: []const u8, ssid: []const u8, password: []const u8) Request {
    const c = Connect{
        .device_path = self.alloc.dupe(u8, device_path) catch return .{},
        .ap_path = self.alloc.dupe(u8, ap_path) catch unreachable,
        .ssid = self.alloc.dupe(u8, ssid) catch unreachable,
        .password = self.alloc.dupe(u8, password) catch unreachable,
    };
    if (c.ap_path.len == 0 or c.ssid.len == 0) {
        var tmp = Action{ .connect = c };
        tmp.deinit(self.alloc);
        return .{};
    }
    return self.enqueue(.{ .connect = c });
}

// Activate a saved NM profile on this AP/device: NetworkManager supplies
// the stored secret itself, so the UI never needs the password again.
pub fn connectSaved(self: *Net, device_path: []const u8, ap_path: []const u8, conn_path: []const u8) Request {
    const c = ConnectSaved{
        .device_path = self.alloc.dupe(u8, device_path) catch return .{},
        .ap_path = self.alloc.dupe(u8, ap_path) catch unreachable,
        .conn_path = self.alloc.dupe(u8, conn_path) catch unreachable,
    };
    if (c.ap_path.len == 0 or c.conn_path.len == 0) {
        var tmp = Action{ .connect_saved = c };
        tmp.deinit(self.alloc);
        return .{};
    }
    return self.enqueue(.{ .connect_saved = c });
}

pub fn status(self: *Net) Status {
    if (!self.inited) return .{};
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    var st = Status{ .present = self.bus != null, .wifi_on = self.wifi_on, .bt_present = self.bt_present, .bt_powered = self.bt_powered, .connectivity = self.connectivity };
    for (self.aps.items) |*a| {
        if (a.active) {
            st.strength = a.strength;
            st.connected = true;
            break;
        }
    }
    for (self.devices.items) |*d| {
        if (d.kind == .ethernet and d.connected() and d.carrier) st.eth_up = true;
        st.down_bps += d.rx_bps;
        st.up_bps += d.tx_bps;
    }
    return st;
}

pub fn snapshotCopy(self: *Net, alloc: std.mem.Allocator) Snapshot {
    var out = Snapshot{};
    if (!self.inited) return out;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    out.gen = self.gen;
    out.present = self.bus != null;
    out.networking_on = self.networking_on;
    out.wifi_on = self.wifi_on;
    out.connectivity = self.connectivity;
    out.active_state = self.active_state;
    out.bt_present = self.bt_present;
    out.bt_powered = self.bt_powered;
    for (self.devices.items) |*d| {
        if (d.kind == .wifi) {
            out.wifi_supported = true;
            break;
        }
    }
    out.active_id = alloc.dupe(u8, self.active_id) catch unreachable;
    out.ap_error = alloc.dupe(u8, self.ap_error) catch unreachable;
    out.last_error = alloc.dupe(u8, self.last_error) catch unreachable;
    out.devices = alloc.alloc(DeviceView, self.devices.items.len) catch &.{};
    for (self.devices.items, 0..) |*d, i| {
        out.devices[i] = .{
            .kind = d.kind,
            .iface = alloc.dupe(u8, d.iface) catch unreachable,
            .state = d.state,
            .connected = d.connected(),
            .carrier = d.carrier,
            .link_mbps = d.link_mbps,
            .rx_bps = d.rx_bps,
            .tx_bps = d.tx_bps,
        };
    }
    var n_aps: usize = 0;
    for (self.aps.items) |*a| {
        if (matchesQuery(a.ssid, self.search)) n_aps += 1;
    }
    out.aps = if (n_aps > 0) alloc.alloc(ApView, n_aps) catch &.{} else &.{};
    if (out.aps.len > 0) {
        var i: usize = 0;
        for (self.aps.items) |*a| {
            if (!matchesQuery(a.ssid, self.search)) continue;
            // Match a saved profile by SSID (profiles are per-network,
            // not per-band; first hit wins).
            var saved: ?SavedConn = null;
            for (self.saved.items) |*s| {
                if (std.mem.eql(u8, s.ssid, a.ssid)) {
                    saved = s.*;
                    break;
                }
            }
            out.aps[i] = .{
                .id = a.id,
                .path = alloc.dupe(u8, a.path) catch unreachable,
                .ssid = alloc.dupe(u8, a.ssid) catch unreachable,
                .strength = a.strength,
                .secured = a.secured,
                .freq_mhz = a.freq_mhz,
                .active = a.active,
                .saved = saved != null,
                .saved_path = if (saved) |s| (alloc.dupe(u8, s.path) catch "") else "",
            };
            if (a.active) out.connected = a.id;
            i += 1;
        }
    }
    out.bt_devices = alloc.alloc(BtDevView, self.bt_devices.items.len) catch &.{};
    for (self.bt_devices.items, 0..) |*d, i| {
        out.bt_devices[i] = .{
            .name = alloc.dupe(u8, d.name) catch "",
            .connected = d.connected,
            .paired = d.paired,
        };
    }
    return out;
}

pub fn tick(self: *Net) !bool {
    if (!self.inited) return false;
    if (self.bus == null) {
        // No bus yet: complete local-only actions (.refresh) so those
        // requests never hang pending; bus-dependent actions stay queued
        // until the bus connects.
        const local_changed = self.drainLocalActions();
        const now = self.nowMs();
        if (now < self.retry_at_ms) return local_changed;
        self.retry_at_ms = now + retry_ms;
        if (Dbus.openSystem()) |b| {
            self.mu.lockUncancelable(self.io);
            self.bus = b;
            self.ap_dirty = true;
            self.saved_dirty = true;
            self.bt_dirty = true;
            self.mu.unlock(self.io);
            self.bump();
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
        if (self.pollCore(now)) changed = true;
    }
    if (self.apDirtyDue(now)) {
        self.ap_dirty = false;
        self.ap_next_ms = now + ap_stale_ms;
        if (self.pollAps()) changed = true;
    }
    if (self.savedDirtyDue(now)) {
        self.saved_dirty = false;
        self.saved_next_ms = now + saved_stale_ms;
        if (self.pollSaved()) changed = true;
    }
    if (self.btDirtyDue(now)) {
        self.bt_dirty = false;
        self.bt_next_ms = now + bt_poll_ms;
        if (self.pollBt()) changed = true;
    }
    return changed;
}

fn drainLocalActions(self: *Net) bool {
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
            // Not runnable offline: re-queue in order for when the bus
            // connects. Same drop-on-OOM policy as push().
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
        self.ap_dirty = true;
        self.bt_dirty = true;
        self.mu.unlock(self.io);
        self.bump();
        changed = true;
        q.deinit(self.alloc);
    }
    return changed;
}

fn apDirtyDue(self: *Net, now: i64) bool {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.bus == null or !self.wifi_on) return false;
    if (self.ap_dirty) return true;
    if (self.aps.items.len > 0 and now >= self.ap_next_ms) return true;
    return false;
}

fn savedDirtyDue(self: *Net, now: i64) bool {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.bus == null) return false;
    if (self.saved_dirty) return true;
    if (self.aps.items.len > 0 and now >= self.saved_next_ms) return true;
    return false;
}

fn btDirtyDue(self: *Net, now: i64) bool {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.bus == null) return false;
    if (self.bt_dirty) return true;
    if (self.bt_present and now >= self.bt_next_ms) return true;
    return false;
}

fn applyAction(self: *Net, q: *Queued) ActionResult {
    const a = &q.action;
    const bus = self.bus orelse return .{ .changed = false, .ok = false };
    switch (a.*) {
        .wifi_set_enabled => |on| {
            if (self.setPropBool(bus, nm_dest, nm_path, nm_iface, "WirelessEnabled", on)) {
                self.mu.lockUncancelable(self.io);
                self.wifi_on = on;
                // Radio off: clear the list now (pollCore only converges
                // within a beat); radio on: refetch on the next tick.
                if (!on) self.clearApsLocked();
                self.ap_dirty = true;
                self.mu.unlock(self.io);
                self.bump();
                return .{ .changed = true, .ok = true };
            }
            self.setError("wifi toggle failed", .{});
            return .{ .changed = true, .ok = false };
        },
        .bt_set_enabled => |on| {
            const adapter = self.adapterPath() orelse return .{ .changed = false, .ok = false };
            defer self.alloc.free(adapter);
            const zpath = self.alloc.dupeZ(u8, adapter) catch return .{ .changed = false, .ok = false };
            defer self.alloc.free(zpath);
            if (self.setPropBool(bus, bluez_dest, zpath, bluez_adapter_iface, "Powered", on)) {
                self.mu.lockUncancelable(self.io);
                self.bt_powered = on;
                self.bt_dirty = true;
                self.mu.unlock(self.io);
                self.bump();
                return .{ .changed = true, .ok = true };
            }
            self.setError("bluetooth toggle failed", .{});
            return .{ .changed = true, .ok = false };
        },
        .scan => {
            if (self.requestScan(bus)) {
                self.mu.lockUncancelable(self.io);
                self.ap_dirty = true;
                self.mu.unlock(self.io);
                self.bump();
                return .{ .changed = true, .ok = true };
            }
            self.setError("scan request failed", .{});
            return .{ .changed = true, .ok = false };
        },
        .connect_saved => |*c| {
            if (self.activateSaved(bus, c)) {
                self.clearError();
                self.mu.lockUncancelable(self.io);
                self.ap_dirty = true;
                self.mu.unlock(self.io);
                self.bump();
                return .{ .changed = true, .ok = true };
            }
            self.mu.lockUncancelable(self.io);
            const detailed = self.last_error.len > 0;
            self.mu.unlock(self.io);
            if (!detailed) self.setError("connect failed", .{});
            return .{ .changed = true, .ok = false };
        },
        .refresh => {
            self.mu.lockUncancelable(self.io);
            self.ap_dirty = true;
            self.saved_dirty = true;
            self.bt_dirty = true;
            self.mu.unlock(self.io);
            self.bump();
            return .{ .changed = true, .ok = true };
        },
        .connect => |*c| {
            if (self.addAndActivate(bus, c)) {
                self.clearError();
                self.mu.lockUncancelable(self.io);
                self.ap_dirty = true;
                // The typed password just persisted a (possibly new)
                // profile: re-scan saved profiles so the row flips to the
                // grayed "saved" state on the next snapshot.
                self.saved_dirty = true;
                self.mu.unlock(self.io);
                self.bump();
                return .{ .changed = true, .ok = true };
            }
            self.mu.lockUncancelable(self.io);
            const detailed = self.last_error.len > 0;
            self.mu.unlock(self.io);
            if (!detailed) self.setError("connect failed", .{});
            return .{ .changed = true, .ok = false };
        },
        .disconnect => {
            const path = self.activeConnPath() orelse return .{ .changed = false, .ok = false };
            defer self.alloc.free(path);
            const zpath = self.alloc.dupeZ(u8, path) catch return .{ .changed = false, .ok = false };
            defer self.alloc.free(zpath);
            var m = Dbus.Method.init(bus, .{
                .destination = nm_dest,
                .path = nm_path,
                .interface = nm_iface,
                .member = "DeactivateConnection",
            }, .{Dbus.obj(zpath)}) orelse return .{ .changed = false, .ok = false };
            defer m.deinit();
            var r = m.send(bus) orelse {
                self.setError("disconnect failed: {s}", .{Dbus.errorText(&m.err)});
                return .{ .changed = true, .ok = false };
            };
            defer r.deinit();
            self.mu.lockUncancelable(self.io);
            self.ap_dirty = true;
            self.mu.unlock(self.io);
            self.bump();
            return .{ .changed = true, .ok = true };
        },
    }
}

fn adapterPath(self: *Net) ?[]const u8 {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.bt_adapter.len == 0) return null;
    return self.alloc.dupe(u8, self.bt_adapter) catch null;
}

fn activeConnPath(self: *Net) ?[]const u8 {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.active_path.len == 0) return null;
    return self.alloc.dupe(u8, self.active_path) catch null;
}

fn setPropBool(self: *Net, bus: *Dbus.Bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, prop: [*:0]const u8, val: bool) bool {
    _ = self;
    var m = Dbus.Method.init(bus, .{
        .destination = dest,
        .path = path,
        .interface = props_iface,
        .member = "Set",
    }, .{ iface, prop }) orelse return false;
    defer m.deinit();
    if (!m.open('v', "b")) return false;
    if (!m.boolean(val)) return false;
    if (!m.close()) return false;
    var r = m.send(bus) orelse return false;
    defer r.deinit();
    return true;
}

fn getAll(self: *Net, bus: *Dbus.Bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8) ?Dbus.Reply {
    _ = self;
    var m = Dbus.Method.init(bus, .{
        .destination = dest,
        .path = path,
        .interface = props_iface,
        .member = "GetAll",
    }, .{iface}) orelse return null;
    defer m.deinit();
    return m.send(bus);
}

fn getProp(self: *Net, bus: *Dbus.Bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, prop: [*:0]const u8) ?Dbus.Reply {
    _ = self;
    var m = Dbus.Method.init(bus, .{
        .destination = dest,
        .path = path,
        .interface = props_iface,
        .member = "Get",
    }, .{ iface, prop }) orelse return null;
    defer m.deinit();
    var r = m.send(bus) orelse return null;
    const pk = r.peek() orelse {
        r.deinit();
        return null;
    };
    if (pk.t != 'v') {
        r.deinit();
        return null;
    }
    if (!enterVariant(&r, pk.contents)) {
        r.deinit();
        return null;
    }
    return r;
}

fn enterVariant(r: *Dbus.Reply, sig: []const u8) bool {
    var buf: [32]u8 = undefined;
    if (sig.len == 0 or sig.len + 1 > buf.len) return false;
    @memcpy(buf[0..sig.len], sig);
    buf[sig.len] = 0;
    return r.enterRaw('v', buf[0..sig.len :0]) > 0;
}

const Val = union(enum) {
    s: []const u8,
    o: []const u8,
    u: u32,
    b: bool,
    t: u64,
    y: u8,
    bytes: []const u8,
    paths: [][]const u8,

    fn free(self: *Val, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .s => |v| alloc.free(v),
            .o => |v| alloc.free(v),
            .bytes => |v| alloc.free(v),
            .paths => |v| {
                for (v) |p| alloc.free(p);
                alloc.free(v);
            },
            else => {},
        }
    }
};

fn readVariant(self: *Net, r: *Dbus.Reply) ?Val {
    const pk = r.peek() orelse return null;
    if (pk.t != 'v') return null;
    if (!enterVariant(r, pk.contents)) return null;
    const inner = pk.contents;
    if (std.mem.eql(u8, inner, "s")) {
        const v = r.readStr() orelse {
            _ = r.exit();
            return null;
        };
        const owned = self.alloc.dupe(u8, v) catch {
            _ = r.exit();
            return null;
        };
        _ = r.exit();
        return .{ .s = owned };
    }
    if (std.mem.eql(u8, inner, "o")) {
        const v = r.readObj() orelse {
            _ = r.exit();
            return null;
        };
        const owned = self.alloc.dupe(u8, v) catch {
            _ = r.exit();
            return null;
        };
        _ = r.exit();
        return .{ .o = owned };
    }
    if (std.mem.eql(u8, inner, "u")) {
        const v = r.readU32() orelse {
            _ = r.exit();
            return null;
        };
        _ = r.exit();
        return .{ .u = v };
    }
    if (std.mem.eql(u8, inner, "b")) {
        const v = r.readBool() orelse {
            _ = r.exit();
            return null;
        };
        _ = r.exit();
        return .{ .b = v };
    }
    if (std.mem.eql(u8, inner, "t")) {
        const v = r.readU64() orelse {
            _ = r.exit();
            return null;
        };
        _ = r.exit();
        return .{ .t = v };
    }
    if (std.mem.eql(u8, inner, "y")) {
        const v = r.readU8() orelse {
            _ = r.exit();
            return null;
        };
        _ = r.exit();
        return .{ .y = v };
    }
    if (std.mem.eql(u8, inner, "ay")) {
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        if (r.enterRaw('a', "y") > 0) {
            while (len < buf.len) {
                const b = r.readU8() orelse break;
                buf[len] = b;
                len += 1;
            }
            _ = r.exit();
        }
        const owned = self.alloc.dupe(u8, buf[0..len]) catch {
            _ = r.exit();
            return null;
        };
        _ = r.exit();
        return .{ .bytes = owned };
    }
    if (std.mem.eql(u8, inner, "ao")) {
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(self.alloc);
        if (r.enterRaw('a', "o") > 0) {
            while (r.readObj()) |p| {
                const owned = self.alloc.dupe(u8, p) catch break;
                list.append(self.alloc, owned) catch {
                    self.alloc.free(owned);
                    break;
                };
            }
            _ = r.exit();
        }
        const owned = list.toOwnedSlice(self.alloc) catch {
            _ = r.exit();
            return null;
        };
        _ = r.exit();
        return .{ .paths = owned };
    }
    _ = r.skip("v");
    return null;
}

fn pollCore(self: *Net, now: i64) bool {
    const bus = self.bus orelse return false;
    var mgr = self.getAll(bus, nm_dest, nm_path, nm_iface) orelse return false;
    defer mgr.deinit();
    var wifi_on = self.wifi_on;
    var networking_on = self.networking_on;
    var connectivity = self.connectivity;
    var dev_paths: [][]const u8 = &.{};
    defer {
        for (dev_paths) |p| self.alloc.free(p);
        if (dev_paths.len > 0) self.alloc.free(dev_paths);
    }
    var ac_paths: [][]const u8 = &.{};
    defer {
        for (ac_paths) |p| self.alloc.free(p);
        if (ac_paths.len > 0) self.alloc.free(ac_paths);
    }
    if (mgr.enterRaw('a', "{sv}") >= 0) {
        while (mgr.enterRaw('e', "sv") > 0) {
            const key = mgr.readStr() orelse break;
            if (std.mem.eql(u8, key, "WirelessEnabled")) {
                if (self.readVariant(&mgr)) |v| {
                    if (v == .b) wifi_on = v.b;
                    var tmp = v;
                    tmp.free(self.alloc);
                }
            } else if (std.mem.eql(u8, key, "NetworkingEnabled")) {
                if (self.readVariant(&mgr)) |v| {
                    if (v == .b) networking_on = v.b;
                    var tmp = v;
                    tmp.free(self.alloc);
                }
            } else if (std.mem.eql(u8, key, "Connectivity")) {
                if (self.readVariant(&mgr)) |v| {
                    if (v == .u) connectivity = v.u;
                    var tmp = v;
                    tmp.free(self.alloc);
                }
            } else if (std.mem.eql(u8, key, "Devices")) {
                if (self.readVariant(&mgr)) |v| {
                    if (v == .paths) {
                        for (dev_paths) |p| self.alloc.free(p);
                        if (dev_paths.len > 0) self.alloc.free(dev_paths);
                        dev_paths = @constCast(v.paths);
                    } else {
                        var tmp = v;
                        tmp.free(self.alloc);
                    }
                }
            } else if (std.mem.eql(u8, key, "ActiveConnections")) {
                if (self.readVariant(&mgr)) |v| {
                    if (v == .paths) {
                        for (ac_paths) |p| self.alloc.free(p);
                        if (ac_paths.len > 0) self.alloc.free(ac_paths);
                        ac_paths = @constCast(v.paths);
                    } else {
                        var tmp = v;
                        tmp.free(self.alloc);
                    }
                }
            } else {
                _ = mgr.skip("v");
            }
            _ = mgr.exit();
        }
        _ = mgr.exit();
    }

    var fresh: std.ArrayList(Device) = .empty;
    defer fresh.deinit(self.alloc);
    for (dev_paths) |dp| {
        var d = Device{};
        d.path = self.alloc.dupe(u8, dp) catch continue;
        var dr = self.getAllZ(bus, dp, nm_dev_iface) orelse {
            self.alloc.free(d.path);
            continue;
        };
        defer dr.deinit();
        if (dr.enterRaw('a', "{sv}") >= 0) {
            while (dr.enterRaw('e', "sv") > 0) {
                const key = dr.readStr() orelse break;
                if (std.mem.eql(u8, key, "DeviceType")) {
                    if (self.readVariant(&dr)) |v| {
                        if (v == .u) d.kind = switch (v.u) {
                            1 => .ethernet,
                            2 => .wifi,
                            else => .other,
                        };
                        var tmp = v;
                        tmp.free(self.alloc);
                    }
                } else if (std.mem.eql(u8, key, "Interface")) {
                    if (self.readVariant(&dr)) |v| {
                        if (v == .s) {
                            self.alloc.free(d.iface);
                            d.iface = v.s;
                        } else {
                            var tmp = v;
                            tmp.free(self.alloc);
                        }
                    }
                } else if (std.mem.eql(u8, key, "State")) {
                    if (self.readVariant(&dr)) |v| {
                        if (v == .u) d.state = v.u;
                        var tmp = v;
                        tmp.free(self.alloc);
                    }
                } else {
                    _ = dr.skip("v");
                }
                _ = dr.exit();
            }
            _ = dr.exit();
        }
        if (d.kind == .ethernet) {
            var wr = self.getAllZ(bus, dp, nm_wired_iface) orelse null;
            if (wr) |*w| {
                defer w.deinit();
                if (w.enterRaw('a', "{sv}") >= 0) {
                    while (w.enterRaw('e', "sv") > 0) {
                        const key = w.readStr() orelse break;
                        if (std.mem.eql(u8, key, "Carrier")) {
                            if (self.readVariant(w)) |v| {
                                if (v == .b) d.carrier = v.b;
                                var tmp = v;
                                tmp.free(self.alloc);
                            }
                        } else if (std.mem.eql(u8, key, "Speed")) {
                            if (self.readVariant(w)) |v| {
                                if (v == .u) d.link_mbps = v.u;
                                var tmp = v;
                                tmp.free(self.alloc);
                            }
                        } else {
                            _ = w.skip("v");
                        }
                        _ = w.exit();
                    }
                    _ = w.exit();
                }
            }
        }
        if (d.kind == .wifi) {
            var wr = self.getAllZ(bus, dp, nm_wireless_iface) orelse null;
            if (wr) |*w| {
                defer w.deinit();
                if (w.enterRaw('a', "{sv}") >= 0) {
                    while (w.enterRaw('e', "sv") > 0) {
                        const key = w.readStr() orelse break;
                        if (std.mem.eql(u8, key, "ActiveAccessPoint")) {
                            if (self.readVariant(w)) |v| {
                                if (v == .o) {
                                    self.mu.lockUncancelable(self.io);
                                    if (self.active_ap_path.len > 0) self.alloc.free(self.active_ap_path);
                                    self.active_ap_path = self.alloc.dupe(u8, v.o) catch "";
                                    self.mu.unlock(self.io);
                                }
                                var tmp = v;
                                tmp.free(self.alloc);
                            }
                        } else {
                            _ = w.skip("v");
                        }
                        _ = w.exit();
                    }
                    _ = w.exit();
                }
            }
        }
        var sr = self.getAllZ(bus, dp, nm_stats_iface) orelse null;
        if (sr) |*s| {
            defer s.deinit();
            var rx: u64 = 0;
            var tx: u64 = 0;
            if (s.enterRaw('a', "{sv}") >= 0) {
                while (s.enterRaw('e', "sv") > 0) {
                    const key = s.readStr() orelse break;
                    if (std.mem.eql(u8, key, "RxBytes")) {
                        if (self.readVariant(s)) |v| {
                            if (v == .t) rx = v.t;
                            var tmp = v;
                            tmp.free(self.alloc);
                        }
                    } else if (std.mem.eql(u8, key, "TxBytes")) {
                        if (self.readVariant(s)) |v| {
                            if (v == .t) tx = v.t;
                            var tmp = v;
                            tmp.free(self.alloc);
                        }
                    } else {
                        _ = s.skip("v");
                    }
                    _ = s.exit();
                }
                _ = s.exit();
            }
            const sample = self.sampleStats(d.path, rx, tx, now);
            d.rx_bps = sample.rx_bps;
            d.tx_bps = sample.tx_bps;
            d.prev_rx = rx;
            d.prev_tx = tx;
            d.prev_ms = now;
        }
        fresh.append(self.alloc, d) catch {
            if (d.path.len > 0) self.alloc.free(d.path);
            if (d.iface.len > 0) self.alloc.free(d.iface);
        };
    }

    var new_id: []const u8 = "";
    var new_ac_path: []const u8 = "";
    var new_ac_state: u32 = 0;
    if (ac_paths.len > 0) {
        var ar = self.getAllZ(bus, ac_paths[0], nm_ac_iface) orelse null;
        if (ar) |*a| {
            defer a.deinit();
            if (a.enterRaw('a', "{sv}") >= 0) {
                while (a.enterRaw('e', "sv") > 0) {
                    const key = a.readStr() orelse break;
                    if (std.mem.eql(u8, key, "Id")) {
                        if (self.readVariant(a)) |v| {
                            if (v == .s) {
                                self.alloc.free(new_id);
                                new_id = v.s;
                            } else {
                                var tmp = v;
                                tmp.free(self.alloc);
                            }
                        }
                    } else if (std.mem.eql(u8, key, "State")) {
                        if (self.readVariant(a)) |v| {
                            if (v == .u) new_ac_state = v.u;
                            var tmp = v;
                            tmp.free(self.alloc);
                        }
                    } else {
                        _ = a.skip("v");
                    }
                    _ = a.exit();
                }
                _ = a.exit();
            }
        }
        new_ac_path = self.alloc.dupe(u8, ac_paths[0]) catch "";
    }

    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    for (self.devices.items) |*d| {
        if (d.path.len > 0) self.alloc.free(d.path);
        if (d.iface.len > 0) self.alloc.free(d.iface);
    }
    self.devices.clearRetainingCapacity();
    for (fresh.items) |*d| {
        self.devices.append(self.alloc, d.*) catch {
            if (d.path.len > 0) self.alloc.free(d.path);
            if (d.iface.len > 0) self.alloc.free(d.iface);
        };
    }
    fresh.items.len = 0;
    // External radio changes (not via our toggle): going off drops the
    // cached APs so the panel empties; coming back on refetches them.
    if (self.wifi_on != wifi_on) {
        if (wifi_on) {
            self.ap_dirty = true;
        } else {
            self.clearApsLocked();
        }
    }
    self.wifi_on = wifi_on;
    self.networking_on = networking_on;
    self.connectivity = connectivity;
    if (self.active_id.len > 0) self.alloc.free(self.active_id);
    self.active_id = new_id;
    if (self.active_path.len > 0) self.alloc.free(self.active_path);
    self.active_path = new_ac_path;
    self.active_state = new_ac_state;
    self.bump();
    return true;
}

fn getAllZ(self: *Net, bus: *Dbus.Bus, path: []const u8, iface: [*:0]const u8) ?Dbus.Reply {
    const zpath = self.alloc.dupeZ(u8, path) catch return null;
    defer self.alloc.free(zpath);
    return self.getAll(bus, nm_dest, zpath, iface);
}

fn sampleStats(self: *Net, path: []const u8, rx: u64, tx: u64, now: i64) struct { rx_bps: f64, tx_bps: f64 } {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    for (self.prev_stats.items) |*p| {
        if (!std.mem.eql(u8, p.path, path)) continue;
        const dt = @max(now - p.ms, 1);
        const rx_bps = emaRate(0, @as(f64, @floatFromInt(rx -| p.rx)) * 1000.0 / @as(f64, @floatFromInt(dt)));
        const tx_bps = emaRate(0, @as(f64, @floatFromInt(tx -| p.tx)) * 1000.0 / @as(f64, @floatFromInt(dt)));
        const prev_rx = findDeviceRate(self.devices.items, path);
        p.rx = rx;
        p.tx = tx;
        p.ms = now;
        return .{
            .rx_bps = emaRate(prev_rx.rx_bps, rx_bps),
            .tx_bps = emaRate(prev_rx.tx_bps, tx_bps),
        };
    }
    const owned = self.alloc.dupe(u8, path) catch return .{ .rx_bps = 0, .tx_bps = 0 };
    self.prev_stats.append(self.alloc, .{ .path = owned, .rx = rx, .tx = tx, .ms = now }) catch {
        self.alloc.free(owned);
    };
    return .{ .rx_bps = 0, .tx_bps = 0 };
}

fn findDeviceRate(devices: []Device, path: []const u8) struct { rx_bps: f64, tx_bps: f64 } {
    for (devices) |*d| {
        if (std.mem.eql(u8, d.path, path)) return .{ .rx_bps = d.rx_bps, .tx_bps = d.tx_bps };
    }
    return .{ .rx_bps = 0, .tx_bps = 0 };
}

pub fn wifiDevicePath(self: *Net) ?[]const u8 {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    for (self.devices.items) |*d| {
        if (d.kind == .wifi) return self.alloc.dupe(u8, d.path) catch null;
    }
    return null;
}

fn pollAps(self: *Net) bool {
    const bus = self.bus orelse return false;
    const wifidev = self.wifiDevicePath() orelse return false;
    defer self.alloc.free(wifidev);
    const zwifi = self.alloc.dupeZ(u8, wifidev) catch return false;
    defer self.alloc.free(zwifi);
    var m = Dbus.Method.init(bus, .{
        .destination = nm_dest,
        .path = zwifi,
        .interface = nm_wireless_iface,
        .member = "GetAccessPoints",
    }, .{}) orelse return false;
    defer m.deinit();
    var r = m.send(bus) orelse {
        self.setApError("{s}", .{Dbus.errorText(&m.err)});
        return true;
    };
    defer r.deinit();
    var fresh: std.ArrayList(Ap) = .empty;
    defer fresh.deinit(self.alloc);
    if (r.enterRaw('a', "o") >= 0) {
        while (r.readObj()) |ap_path| {
            var ar = self.getAllZ(bus, ap_path, nm_ap_iface) orelse continue;
            defer ar.deinit();
            var a = Ap{};
            a.path = self.alloc.dupe(u8, ap_path) catch continue;
            if (ar.enterRaw('a', "{sv}") >= 0) {
                while (ar.enterRaw('e', "sv") > 0) {
                    const key = ar.readStr() orelse break;
                    if (std.mem.eql(u8, key, "Ssid")) {
                        if (self.readVariant(&ar)) |v| {
                            if (v == .bytes) {
                                self.alloc.free(a.ssid);
                                a.ssid = v.bytes;
                            } else {
                                var tmp = v;
                                tmp.free(self.alloc);
                            }
                        }
                    } else if (std.mem.eql(u8, key, "Strength")) {
                        if (self.readVariant(&ar)) |v| {
                            if (v == .y) a.strength = v.y;
                            var tmp = v;
                            tmp.free(self.alloc);
                        }
                    } else if (std.mem.eql(u8, key, "Flags")) {
                        if (self.readVariant(&ar)) |v| {
                            if (v == .u) a.secured = (v.u & 0x1) != 0;
                            var tmp = v;
                            tmp.free(self.alloc);
                        }
                    } else if (std.mem.eql(u8, key, "Frequency")) {
                        if (self.readVariant(&ar)) |v| {
                            if (v == .u) a.freq_mhz = v.u;
                            var tmp = v;
                            tmp.free(self.alloc);
                        }
                    } else {
                        _ = ar.skip("v");
                    }
                    _ = ar.exit();
                }
                _ = ar.exit();
            }
            if (a.ssid.len == 0) {
                self.alloc.free(a.path);
                continue;
            }
            fresh.append(self.alloc, a) catch {
                self.alloc.free(a.path);
                self.alloc.free(a.ssid);
            };
        }
        _ = r.exit();
    }
    sortAps(fresh.items);
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    reuseApIds(self, fresh.items);
    for (self.aps.items) |*a| {
        if (a.path.len > 0) self.alloc.free(a.path);
        if (a.ssid.len > 0) self.alloc.free(a.ssid);
    }
    self.aps.clearRetainingCapacity();
    for (fresh.items) |*a| {
        var c = a.*;
        c.active = std.mem.eql(u8, a.path, self.active_ap_path);
        self.aps.append(self.alloc, c) catch {
            if (a.path.len > 0) self.alloc.free(a.path);
            if (a.ssid.len > 0) self.alloc.free(a.ssid);
        };
    }
    fresh.items.len = 0;
    if (self.ap_error.len > 0) self.alloc.free(self.ap_error);
    self.ap_error = "";
    self.bump();
    return true;
}

fn setApError(self: *Net, comptime fmt: []const u8, args: anytype) void {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.ap_error.len > 0) self.alloc.free(self.ap_error);
    self.ap_error = std.fmt.allocPrint(self.alloc, fmt, args) catch "";
    self.bump();
}

fn pollBt(self: *Net) bool {
    const bus = self.bus orelse return false;
    var found: []const u8 = "";
    var powered = false;
    var hci: [32]u8 = undefined;
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        const path = std.fmt.bufPrint(&hci, "/org/bluez/hci{d}", .{i}) catch break;
        const zpath = self.alloc.dupeZ(u8, path) catch break;
        defer self.alloc.free(zpath);
        var pr = self.getProp(bus, bluez_dest, zpath, bluez_adapter_iface, "Powered") orelse continue;
        defer pr.deinit();
        const on = pr.readBool() orelse continue;
        self.alloc.free(found);
        found = self.alloc.dupe(u8, path) catch "";
        powered = on;
        break;
    }
    self.mu.lockUncancelable(self.io);
    if (self.bt_adapter.len > 0) self.alloc.free(self.bt_adapter);
    self.bt_adapter = found;
    self.bt_present = found.len > 0;
    self.bt_powered = powered;
    const want_devices = self.bt_dirty or (self.bt_present and self.bt_powered);
    self.mu.unlock(self.io);
    if (want_devices) self.pollBtDevices(bus);
    self.bump();
    return true;
}

fn pollBtDevices(self: *Net, bus: *Dbus.Bus) void {
    var m = Dbus.Method.init(bus, .{
        .destination = bluez_dest,
        .path = bluez_root,
        .interface = "org.freedesktop.DBus.ObjectManager",
        .member = "GetManagedObjects",
    }, .{}) orelse return;
    defer m.deinit();
    var r = m.send(bus) orelse return;
    defer r.deinit();
    var fresh: std.ArrayList(BtDev) = .empty;
    defer fresh.deinit(self.alloc);
    if (r.enterRaw('a', "{oa{sa{sv}}}") >= 0) {
        while (r.enterRaw('e', "oa{sa{sv}}") > 0) {
            const obj_path = r.readObj() orelse break;
            const is_dev = std.mem.indexOf(u8, obj_path, "/dev_") != null;
            if (r.enterRaw('a', "{sa{sv}}") < 0) {
                _ = r.exit();
                continue;
            }
            var got_iface = false;
            while (r.enterRaw('e', "sa{sv}") > 0) {
                const iname = r.readStr() orelse break;
                if (is_dev and std.mem.eql(u8, iname, bluez_device_iface)) {
                    got_iface = true;
                    var d = BtDev{};
                    if (r.enterRaw('a', "{sv}") >= 0) {
                        while (r.enterRaw('e', "sv") > 0) {
                            const key = r.readStr() orelse break;
                            if (std.mem.eql(u8, key, "Name") or std.mem.eql(u8, key, "Address")) {
                                const prefer = std.mem.eql(u8, key, "Name") or d.name.len == 0;
                                if (self.readVariant(&r)) |v| {
                                    if (v == .s and prefer) {
                                        if (d.name.len > 0) self.alloc.free(d.name);
                                        d.name = v.s;
                                    } else {
                                        var tmp = v;
                                        tmp.free(self.alloc);
                                    }
                                }
                            } else if (std.mem.eql(u8, key, "Connected")) {
                                if (self.readVariant(&r)) |v| {
                                    if (v == .b) d.connected = v.b;
                                    var tmp = v;
                                    tmp.free(self.alloc);
                                }
                            } else if (std.mem.eql(u8, key, "Paired")) {
                                if (self.readVariant(&r)) |v| {
                                    if (v == .b) d.paired = v.b;
                                    var tmp = v;
                                    tmp.free(self.alloc);
                                }
                            } else {
                                _ = r.skip("v");
                            }
                            _ = r.exit();
                        }
                        _ = r.exit();
                    }
                    if (d.paired or d.connected) {
                        if (d.name.len == 0) {
                            self.alloc.free(d.name);
                            d.name = self.alloc.dupe(u8, obj_path) catch "";
                        }
                        fresh.append(self.alloc, d) catch {
                            if (d.name.len > 0) self.alloc.free(d.name);
                        };
                        if (fresh.items.len >= 16) {
                            _ = r.exit();
                            break;
                        }
                    } else {
                        if (d.name.len > 0) self.alloc.free(d.name);
                    }
                } else {
                    _ = r.skip("a{sv}");
                }
                _ = r.exit();
                if (got_iface) {
                    while (r.enterRaw('e', "sa{sv}") > 0) {
                        _ = r.skip("s");
                        _ = r.skip("a{sv}");
                        _ = r.exit();
                    }
                    break;
                }
            }
            _ = r.exit();
            _ = r.exit();
        }
        _ = r.exit();
    }
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    for (self.bt_devices.items) |*d| {
        if (d.name.len > 0) self.alloc.free(d.name);
    }
    self.bt_devices.clearRetainingCapacity();
    for (fresh.items) |*d| {
        self.bt_devices.append(self.alloc, d.*) catch {
            if (d.name.len > 0) self.alloc.free(d.name);
        };
    }
    fresh.items.len = 0;
}

// Scan NetworkManager's saved connection profiles (Settings.ListConnections
// -> Connection.GetSettings) and cache the wifi ones as SSID -> path pairs
// (see SavedConn). The snapshot joins this against the AP list so the UI
// can tell "password already stored, just click Connect" from "type one".
fn pollSaved(self: *Net) bool {
    const bus = self.bus orelse return false;
    var m = Dbus.Method.init(bus, .{
        .destination = nm_dest,
        .path = nm_settings_path,
        .interface = nm_settings_iface,
        .member = "ListConnections",
    }, .{}) orelse return false;
    defer m.deinit();
    var r = m.send(bus) orelse return false;
    defer r.deinit();
    var fresh: std.ArrayList(SavedConn) = .empty;
    defer fresh.deinit(self.alloc);
    if (r.enterRaw('a', "o") >= 0) {
        while (r.readObj()) |conn_path| {
            // Settings dict: { "connection": {id, type...},
            // "802-11-wireless": {ssid: ay, ...}, ... }.
            var cr = self.getAllZ(bus, conn_path, nm_conn_settings_iface) orelse continue;
            defer cr.deinit();
            // Owned copies; freed on every early-continue path via errdefer-
            // style cleanup below (alloc failures only — parse failures just
            // drop the entry).
            var ssid_owned: []const u8 = "";
            var got_wifi_type = false;
            var got_ssid = false;
            if (cr.enterRaw('a', "{sa{sv}}") >= 0) {
                while (cr.enterRaw('e', "sa{sv}") > 0) {
                    const section = cr.readStr() orelse break;
                    const is_wifi_section = std.mem.eql(u8, section, "802-11-wireless");
                    if (is_wifi_section or std.mem.eql(u8, section, "connection")) {
                        if (cr.enterRaw('a', "{sv}") >= 0) {
                            while (cr.enterRaw('e', "sv") > 0) {
                                const key = cr.readStr() orelse break;
                                if (is_wifi_section and std.mem.eql(u8, key, "ssid")) {
                                    if (self.readVariant(&cr)) |v| {
                                        var tmp = v;
                                        defer tmp.free(self.alloc);
                                        if (v == .bytes and v.bytes.len > 0) {
                                            if (got_ssid) self.alloc.free(ssid_owned);
                                            ssid_owned = self.alloc.dupe(u8, v.bytes) catch "";
                                            got_ssid = ssid_owned.len > 0;
                                        }
                                    }
                                } else if (!is_wifi_section and std.mem.eql(u8, key, "type")) {
                                    if (self.readVariant(&cr)) |v| {
                                        var tmp = v;
                                        defer tmp.free(self.alloc);
                                        if (v == .s and std.mem.eql(u8, v.s, "802-11-wireless")) {
                                            got_wifi_type = true;
                                        }
                                    }
                                } else {
                                    _ = cr.skip("v");
                                }
                                _ = cr.exit();
                            }
                            _ = cr.exit();
                        }
                    } else {
                        _ = cr.skip("a{sv}");
                    }
                    _ = cr.exit();
                }
                _ = cr.exit();
            }
            if (got_wifi_type and got_ssid) {
                const path_owned = self.alloc.dupe(u8, conn_path) catch {
                    self.alloc.free(ssid_owned);
                    continue;
                };
                fresh.append(self.alloc, .{ .path = path_owned, .ssid = ssid_owned }) catch {
                    self.alloc.free(path_owned);
                    self.alloc.free(ssid_owned);
                    continue;
                };
            } else {
                self.alloc.free(ssid_owned);
            }
        }
        _ = r.exit();
    }
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    for (self.saved.items) |*s| s.deinit(self.alloc);
    self.saved.clearRetainingCapacity();
    for (fresh.items) |*s| {
        self.saved.append(self.alloc, s.*) catch {
            if (s.path.len > 0) self.alloc.free(s.path);
            if (s.ssid.len > 0) self.alloc.free(s.ssid);
        };
    }
    fresh.items.len = 0;
    self.bump();
    return true;
}

// Activate an existing saved profile: NM supplies the stored secret.
fn activateSaved(self: *Net, bus: *Dbus.Bus, c: *ConnectSaved) bool {
    const dev_z = self.alloc.dupeZ(u8, c.device_path) catch return false;
    defer self.alloc.free(dev_z);
    const ap_z = self.alloc.dupeZ(u8, c.ap_path) catch return false;
    defer self.alloc.free(ap_z);
    const conn_z = self.alloc.dupeZ(u8, c.conn_path) catch return false;
    defer self.alloc.free(conn_z);
    var m = Dbus.Method.init(bus, .{
        .destination = nm_dest,
        .path = nm_path,
        .interface = nm_iface,
        .member = "ActivateConnection",
    }, .{Dbus.obj(conn_z), Dbus.obj(dev_z), Dbus.obj(ap_z)}) orelse return false;
    defer m.deinit();
    var r = m.send(bus) orelse {
        self.setError("connect: {s}", .{Dbus.errorText(&m.err)});
        return false;
    };
    defer r.deinit();
    _ = r.readObj();
    return true;
}

fn requestScan(self: *Net, bus: *Dbus.Bus) bool {
    const wifidev = self.wifiDevicePath() orelse return false;
    defer self.alloc.free(wifidev);
    const zwifi = self.alloc.dupeZ(u8, wifidev) catch return false;
    defer self.alloc.free(zwifi);
    var m = Dbus.Method.init(bus, .{
        .destination = nm_dest,
        .path = zwifi,
        .interface = nm_wireless_iface,
        .member = "RequestScan",
    }, .{}) orelse return false;
    defer m.deinit();
    if (!m.open('a', "{sv}")) return false;
    if (!m.close()) return false;
    var r = m.send(bus) orelse {
        self.setError("scan: {s}", .{Dbus.errorText(&m.err)});
        return false;
    };
    defer r.deinit();
    return true;
}

fn addAndActivate(self: *Net, bus: *Dbus.Bus, c: *Connect) bool {
    const dev_z = self.alloc.dupeZ(u8, c.device_path) catch return false;
    defer self.alloc.free(dev_z);
    const ap_z = self.alloc.dupeZ(u8, c.ap_path) catch return false;
    defer self.alloc.free(ap_z);
    const ssid_z = self.alloc.dupeZ(u8, c.ssid) catch return false;
    defer self.alloc.free(ssid_z);
    const uuid = self.newUuid();
    const uuid_z = self.alloc.dupeZ(u8, uuid[0..]) catch return false;
    defer self.alloc.free(uuid_z);
    const pw_z = if (c.password.len > 0) self.alloc.dupeZ(u8, c.password) catch return false else null;
    defer if (pw_z) |p| self.alloc.free(p);
    if (self.addAndActivateVolatile(bus, dev_z, ap_z, ssid_z, uuid_z, pw_z)) return true;
    if (self.addAndActivateSaved(bus, dev_z, ap_z, ssid_z, uuid_z, pw_z)) return true;
    return false;
}

fn appendSettings(self: *Net, m: *Dbus.Method, ssid: []const u8, ssid_z: [*:0]const u8, uuid_z: [*:0]const u8, pw_z: ?[:0]u8) bool {
    if (!m.open('a', "{sa{sv}}")) return false;
    if (!self.appendSection(m, "connection", &[_]KV{
        .{ .key = "id", .val = .{ .s = ssid_z } },
        .{ .key = "type", .val = .{ .s = "802-11-wireless" } },
        .{ .key = "uuid", .val = .{ .s = uuid_z } },
    })) return false;
    if (pw_z) |pw| {
        if (!self.appendSection(m, "802-11-wireless", &[_]KV{
            .{ .key = "ssid", .val = .{ .ay = ssid } },
            .{ .key = "mode", .val = .{ .s = "infrastructure" } },
            .{ .key = "security", .val = .{ .s = "802-11-wireless-security" } },
        })) return false;
        if (!self.appendSection(m, "802-11-wireless-security", &[_]KV{
            .{ .key = "key-mgmt", .val = .{ .s = "wpa-psk" } },
            .{ .key = "psk", .val = .{ .s = pw } },
        })) return false;
    } else {
        if (!self.appendSection(m, "802-11-wireless", &[_]KV{
            .{ .key = "ssid", .val = .{ .ay = ssid } },
            .{ .key = "mode", .val = .{ .s = "infrastructure" } },
        })) return false;
    }
    if (!m.close()) return false;
    return true;
}

fn addAndActivateVolatile(self: *Net, bus: *Dbus.Bus, dev_z: [*:0]const u8, ap_z: [*:0]const u8, ssid_z: [*:0]const u8, uuid_z: [*:0]const u8, pw_z: ?[:0]u8) bool {
    const c_ssid = std.mem.span(ssid_z);
    var m = Dbus.Method.init(bus, .{
        .destination = nm_dest,
        .path = nm_path,
        .interface = nm_iface,
        .member = "AddAndActivateConnection2",
    }, .{}) orelse return false;
    defer m.deinit();
    if (!self.appendSettings(&m, c_ssid, ssid_z, uuid_z, pw_z)) return false;
    if (!m.obj(dev_z)) return false;
    if (!m.obj(ap_z)) return false;
    if (!m.open('a', "{sv}")) return false;
    if (!m.open('e', "sv")) return false;
    if (!m.str("persist")) return false;
    if (!m.open('v', "s")) return false;
    if (!m.str("volatile")) return false;
    if (!m.close()) return false;
    if (!m.close()) return false;
    if (!m.close()) return false;
    var r = m.send(bus) orelse {
        if (Dbus.errorIsUnknownMethod(&m.err)) return false;
        self.setError("connect: {s}", .{Dbus.errorText(&m.err)});
        return false;
    };
    defer r.deinit();
    _ = r.readObj();
    _ = r.readObj();
    return true;
}

fn addAndActivateSaved(self: *Net, bus: *Dbus.Bus, dev_z: [*:0]const u8, ap_z: [*:0]const u8, ssid_z: [*:0]const u8, uuid_z: [*:0]const u8, pw_z: ?[:0]u8) bool {
    const c_ssid = std.mem.span(ssid_z);
    var m = Dbus.Method.init(bus, .{
        .destination = nm_dest,
        .path = nm_path,
        .interface = nm_iface,
        .member = "AddAndActivateConnection",
    }, .{}) orelse return false;
    defer m.deinit();
    if (!self.appendSettings(&m, c_ssid, ssid_z, uuid_z, pw_z)) return false;
    if (!m.obj(dev_z)) return false;
    if (!m.obj(ap_z)) return false;
    var r = m.send(bus) orelse {
        self.setError("connect: {s}", .{Dbus.errorText(&m.err)});
        return false;
    };
    defer r.deinit();
    _ = r.readObj();
    _ = r.readObj();
    return true;
}

const KVVal = union(enum) { s: [*:0]const u8, ay: []const u8 };
const KV = struct { key: [*:0]const u8, val: KVVal };

fn appendSection(self: *Net, m: *Dbus.Method, name: [*:0]const u8, kvs: []const KV) bool {
    _ = self;
    if (!m.open('e', "sa{sv}")) return false;
    if (!m.str(name)) return false;
    if (!m.open('a', "{sv}")) return false;
    for (kvs) |kv| {
        if (!m.open('e', "sv")) return false;
        if (!m.str(kv.key)) return false;
        switch (kv.val) {
            .s => |s| {
                if (!m.open('v', "s")) return false;
                if (!m.str(s)) return false;
                if (!m.close()) return false;
            },
            .ay => |bytes| {
                if (!m.open('v', "ay")) return false;
                if (!m.open('a', "y")) return false;
                for (bytes) |b| {
                    if (!m.byte(b)) return false;
                }
                if (!m.close()) return false;
                if (!m.close()) return false;
            },
        }
        if (!m.close()) return false;
    }
    if (!m.close()) return false;
    if (!m.close()) return false;
    return true;
}

fn newUuid(self: *Net) [36]u8 {
    const now: u64 = @bitCast(self.nowMs());
    self.mu.lockUncancelable(self.io);
    self.uuid_counter +%= 1;
    const ctr = self.uuid_counter;
    self.mu.unlock(self.io);
    var prng = std.Random.DefaultPrng.init(now ^ (ctr *% 0x9e3779b97f4a7c15));
    var bytes: [16]u8 = undefined;
    prng.random().bytes(&bytes);
    const hex = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var j: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[j] = '-';
            j += 1;
        }
        out[j] = hex[b >> 4];
        out[j + 1] = hex[b & 0xf];
        j += 2;
    }
    return out;
}

pub fn emaRate(prev: f64, sample: f64) f64 {
    if (sample < 0) return prev;
    if (prev <= 0) return sample;
    return prev * 0.5 + sample * 0.5;
}

pub fn barsForStrength(strength: u8) u3 {
    if (strength >= 80) return 4;
    if (strength >= 55) return 3;
    if (strength >= 30) return 2;
    if (strength >= 5) return 1;
    return 0;
}

pub fn formatSpeed(buf: []u8, bps: f64) []const u8 {
    const v: f64 = @max(bps, 0);
    if (v < 1000) return std.fmt.bufPrint(buf, "{d:.0} B/s", .{v}) catch "";
    if (v < 1000 * 1000) return std.fmt.bufPrint(buf, "{d:.1} KB/s", .{v / 1000}) catch "";
    if (v < 1000 * 1000 * 1000) return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{v / (1000 * 1000)}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} GB/s", .{v / (1000 * 1000 * 1000)}) catch "";
}

pub fn sortAps(aps: []Ap) void {
    var i: usize = 1;
    while (i < aps.len) : (i += 1) {
        var j = i;
        while (j > 0 and aps[j].strength > aps[j - 1].strength) {
            std.mem.swap(Ap, &aps[j], &aps[j - 1]);
            j -= 1;
        }
    }
}

// Empty query matches everything; otherwise ASCII case-insensitive
// substring on the SSID.
pub fn matchesQuery(ssid: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > ssid.len) return false;
    var i: usize = 0;
    while (i + query.len <= ssid.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(ssid[i..][0..query.len], query)) return true;
    }
    return false;
}

// Assign stable ids to a fresh scan result (see Ap.id). Entries whose
// ssid+frequency match a currently known AP keep their id; the rest
// take the next free id (never 0). Call before the old model strings
// are freed (matching borrows them).
fn reuseApIds(self: *Net, fresh: []Ap) void {
    for (fresh) |*f| {
        for (self.aps.items) |*old| {
            if (old.id != 0 and old.freq_mhz == f.freq_mhz and std.mem.eql(u8, old.ssid, f.ssid)) {
                f.id = old.id;
                break;
            }
        }
        if (f.id == 0) {
            if (self.next_ap_id == 0) self.next_ap_id = 1;
            f.id = self.next_ap_id;
            self.next_ap_id +%= 1;
            if (self.next_ap_id == 0) self.next_ap_id = 1;
        }
    }
}

test "net: speed formatting" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B/s", formatSpeed(&buf, 0));
    try std.testing.expectEqualStrings("999 B/s", formatSpeed(&buf, 999));
    try std.testing.expectEqualStrings("1.5 KB/s", formatSpeed(&buf, 1500));
    try std.testing.expectEqualStrings("2.4 MB/s", formatSpeed(&buf, 2_400_000));
    try std.testing.expectEqualStrings("3.0 GB/s", formatSpeed(&buf, 3_000_000_000));
}

test "net: strength bars" {
    try std.testing.expectEqual(@as(u3, 0), barsForStrength(0));
    try std.testing.expectEqual(@as(u3, 1), barsForStrength(10));
    try std.testing.expectEqual(@as(u3, 2), barsForStrength(40));
    try std.testing.expectEqual(@as(u3, 3), barsForStrength(70));
    try std.testing.expectEqual(@as(u3, 4), barsForStrength(100));
}

test "net: ap sort strongest first" {
    var aps = [_]Ap{
        .{ .ssid = "weak", .strength = 10 },
        .{ .ssid = "strong", .strength = 90 },
        .{ .ssid = "mid", .strength = 50 },
    };
    sortAps(&aps);
    try std.testing.expectEqualStrings("strong", aps[0].ssid);
    try std.testing.expectEqualStrings("mid", aps[1].ssid);
    try std.testing.expectEqualStrings("weak", aps[2].ssid);
}

test "net: tick without bus is harmless" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var net: Net = .{};
    net.init(alloc, io);
    defer net.deinit();
    try std.testing.expect(try net.tick() == false);
    const req = net.setWifiEnabled(true);
    try std.testing.expect(req.isQueued());
    // Bus-dependent actions stay queued while the bus is down.
    try std.testing.expectEqual(RequestStatus.pending, req.poll(&net));
    try std.testing.expect(try net.tick() == false);
    try std.testing.expect(req.isPending(&net));
    const st = net.status();
    try std.testing.expect(!st.present);
}

test "net: methods on uninit net fail fast" {
    var net: Net = .{};
    try std.testing.expect(net.setWifiEnabled(true).hasFailed(&net));
    try std.testing.expect(net.toggleWifi().hasFailed(&net));
    try std.testing.expect(net.scan().hasFailed(&net));
    try std.testing.expect(net.refresh().hasFailed(&net));
    try std.testing.expect(net.disconnect().hasFailed(&net));
}

test "net: OOM enqueue leaves id counter untouched" {
    const io = std.testing.io;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var net: Net = .{};
    net.init(failing.allocator(), io);
    defer net.deinit();
    // The queue append fails: invalid request, and next_req must not have
    // advanced (a burned id could later collide with a live request and
    // misattribute its outcome).
    const req = net.setWifiEnabled(true);
    try std.testing.expect(!req.isQueued());
    try std.testing.expect(req.hasFailed(&net));
    try std.testing.expectEqual(@as(u64, 1), net.next_req);
    // Recovery with a working allocator reuses the unburned id.
    net.alloc = std.testing.allocator;
    const retry = net.setWifiEnabled(true);
    try std.testing.expect(retry.isQueued());
    try std.testing.expectEqual(@as(u64, 1), retry.id);
}

test "net: refresh completes without bus" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var net: Net = .{};
    net.init(alloc, io);
    defer net.deinit();
    const req = net.refresh();
    try std.testing.expect(req.isQueued());
    try std.testing.expectEqual(RequestStatus.pending, req.poll(&net));
    try std.testing.expect(try net.tick() == true);
    try std.testing.expectEqual(RequestStatus.ok, req.poll(&net));
    // Peek semantics: polling again still reports ok.
    try std.testing.expectEqual(RequestStatus.ok, req.poll(&net));
}

test "net: connect validates input" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var net: Net = .{};
    net.init(alloc, io);
    defer net.deinit();
    // Empty ap path / ssid can never succeed: invalid request, fails fast.
    try std.testing.expect(net.connect("/dev/1", "", "", "").hasFailed(&net));
    try std.testing.expect(net.connect("/dev/1", "/ap/1", "", "pw").hasFailed(&net));
    const req = net.connect("/dev/1", "/ap/1", "Home", "secret");
    try std.testing.expect(req.isQueued());
    // Bus-dependent: pending until the bus connects.
    try std.testing.expect(req.isPending(&net));
}

test "net: request outcomes are bounded" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var net: Net = .{};
    net.init(alloc, io);
    defer net.deinit();
    var first: Request = .{};
    var i: usize = 0;
    while (i < max_results + 8) : (i += 1) {
        const req = net.refresh();
        if (i == 0) first = req;
        try std.testing.expect(try net.tick() == true);
        try std.testing.expectEqual(RequestStatus.ok, req.poll(&net));
    }
    // The oldest outcome aged out of the bounded store: reads as pending
    // again (documented staleness for callers that never poll).
    try std.testing.expect(first.isPending(&net));
    try std.testing.expectEqual(@as(usize, max_results), net.results.items.len);
}

test "net: snapshot copies model and status aggregates" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var net: Net = .{};
    net.init(alloc, io);
    defer net.deinit();
    try net.devices.append(alloc, .{
        .path = try alloc.dupe(u8, "/dev/1"),
        .iface = try alloc.dupe(u8, "wlan0"),
        .kind = .wifi,
        .state = 100,
        .rx_bps = 1000,
        .tx_bps = 500,
    });
    try net.devices.append(alloc, .{
        .path = try alloc.dupe(u8, "/dev/2"),
        .iface = try alloc.dupe(u8, "eth0"),
        .kind = .ethernet,
        .state = 30,
        .carrier = false,
    });
    try net.aps.append(alloc, .{
        .path = try alloc.dupe(u8, "/ap/1"),
        .ssid = try alloc.dupe(u8, "Home"),
        .strength = 80,
        .secured = true,
        .freq_mhz = 5180,
        .active = true,
    });
    net.wifi_on = true;
    net.connectivity = connectivity_full;
    const st = net.status();
    try std.testing.expectEqual(@as(u8, 80), st.strength);
    try std.testing.expect(st.connected);
    try std.testing.expect(online(st.connectivity));
    try std.testing.expect(!online(1));
    try std.testing.expectEqual(@as(f64, 1000), st.down_bps);
    try std.testing.expectEqual(@as(f64, 500), st.up_bps);
    try std.testing.expect(!st.eth_up);
    var snap = net.snapshotCopy(alloc);
    defer snap.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), snap.devices.len);
    try std.testing.expect(snap.devices[0].connected);
    try std.testing.expectEqualStrings("wlan0", snap.devices[0].iface);
    try std.testing.expectEqual(@as(usize, 1), snap.aps.len);
    try std.testing.expectEqualStrings("Home", snap.aps[0].ssid);
    try std.testing.expect(snap.aps[0].active);
}

test "net: action queue roundtrip and snapshot" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var net: Net = .{};
    net.init(alloc, io);
    defer net.deinit();
    net.push(.{ .wifi_set_enabled = true });
    net.mu.lockUncancelable(io);
    const n = net.actions.items.len;
    net.mu.unlock(io);
    try std.testing.expectEqual(@as(usize, 1), n);
    var snap = net.snapshotCopy(alloc);
    defer snap.deinit(alloc);
    try std.testing.expect(!snap.present);
}

test "net: ap ids are stable across scans" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var net: Net = .{};
    net.init(alloc, io);
    defer net.deinit();
    try net.aps.append(alloc, .{
        .path = try alloc.dupe(u8, "/ap/old"),
        .ssid = try alloc.dupe(u8, "Home"),
        .freq_mhz = 5180,
        .id = 7,
    });
    net.next_ap_id = 8;
    var fresh = [_]Ap{
        // Same ssid+freq, new D-Bus path: keeps id 7.
        .{ .path = "/ap/new", .ssid = "Home", .freq_mhz = 5180 },
        // Same ssid, different band: new id.
        .{ .path = "/ap/24", .ssid = "Home", .freq_mhz = 2412 },
        // Brand new network: new id.
        .{ .path = "/ap/cafe", .ssid = "Cafe", .freq_mhz = 2412 },
    };
    net.reuseApIds(&fresh);
    try std.testing.expectEqual(@as(u64, 7), fresh[0].id);
    try std.testing.expectEqual(@as(u64, 8), fresh[1].id);
    try std.testing.expectEqual(@as(u64, 9), fresh[2].id);
    try std.testing.expect(fresh[0].id != fresh[1].id and fresh[1].id != fresh[2].id);
}

test "net: search filters snapshot aps case-insensitively" {
    try std.testing.expect(matchesQuery("HomeNet", ""));
    try std.testing.expect(matchesQuery("HomeNet", "home"));
    try std.testing.expect(matchesQuery("HomeNet", "MEN"));
    try std.testing.expect(!matchesQuery("HomeNet", "cafe"));
    try std.testing.expect(!matchesQuery("Ho", "HomeNet"));

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var net: Net = .{};
    net.init(alloc, io);
    defer net.deinit();
    try net.aps.append(alloc, .{
        .path = try alloc.dupe(u8, "/ap/1"),
        .ssid = try alloc.dupe(u8, "Home"),
        .id = 3,
        .active = true,
    });
    try net.aps.append(alloc, .{
        .path = try alloc.dupe(u8, "/ap/2"),
        .ssid = try alloc.dupe(u8, "Cafe"),
        .id = 4,
    });
    net.setSearch("hom");
    var snap = net.snapshotCopy(alloc);
    defer snap.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), snap.aps.len);
    try std.testing.expectEqualStrings("Home", snap.aps[0].ssid);
    try std.testing.expectEqual(@as(u64, 3), snap.aps[0].id);
    try std.testing.expectEqual(@as(u64, 3), snap.connected);
    net.setSearch("");
    var snap2 = net.snapshotCopy(alloc);
    defer snap2.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), snap2.aps.len);
    try std.testing.expectEqual(@as(u64, 3), snap2.connected);
}

test "net: snapshot reports wifi support" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var net: Net = .{};
    net.init(alloc, io);
    defer net.deinit();
    var snap0 = net.snapshotCopy(alloc);
    defer snap0.deinit(alloc);
    try std.testing.expect(!snap0.wifi_supported);
    try net.devices.append(alloc, .{
        .path = try alloc.dupe(u8, "/dev/1"),
        .iface = try alloc.dupe(u8, "wlan0"),
        .kind = .wifi,
    });
    var snap1 = net.snapshotCopy(alloc);
    defer snap1.deinit(alloc);
    try std.testing.expect(snap1.wifi_supported);
}
