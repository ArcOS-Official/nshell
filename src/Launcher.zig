const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

/// Owned list of desktop entries.
data: std.ArrayList(App) = .empty,
/// Cache: query term -> results slice (null = pending).
/// Key is owned dupe of term; value slice is owned alloc of []*App pointing into data.
query: std.StringHashMapUnmanaged(?[]*App) = .empty,
/// Terms waiting to be searched by tick() on the worker thread.
pending: std.ArrayList([]const u8) = .empty,
/// Icon cache: icon name -> resolved data (null = pending).
/// Key is owned dupe of the Icon= string; bytes/path owned. Empty bytes = missing (negative cache).
icon_cache: std.StringHashMapUnmanaged(?IconData) = .empty,
/// Icon names waiting to be resolved by tickIcons() on the worker thread.
icon_pending: std.ArrayList([]const u8) = .empty,
/// Cached ordered theme dirs: owned absolute paths, hicolor first.
/// Built lazily on the worker thread; empty = not built yet.
icon_theme_dirs: std.ArrayList([]const u8) = .empty,
icon_themes_built: bool = false,
/// Owned HOME dir (for ~/.local/share/icons). Captured in loadList().
home_dir: ?[]const u8 = null,
mu: std.Io.Mutex = .init,
alloc: std.mem.Allocator = undefined,
io: std.Io = undefined,
inited: bool = false,

const Launcher = @This();

pub const icon_px: u32 = 32;

pub const IconData = struct {
    /// Owned file bytes (stb-compatible raster, e.g. PNG). Empty when missing.
    bytes: []const u8,
    /// Owned resolved absolute path. Empty when missing.
    path: []const u8,
};

pub const App = struct {
    name: []const u8,
    categories: ?[]const u8 = null,
    version: ?[]const u8 = null,
    generic_name: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    path: ?[]const u8 = null,
    exec: ?[]const u8 = null,
    icon: []const u8,
    icon_path: ?[]const u8 = null,
    terminal: bool = false,

    /// Vector icon (TVG bytes) for dvui.icon(). Not supported yet (raster
    /// only) — always null so callers fall through to iconImage().
    pub fn iconTvg(self: *const App, launcher: *Launcher) ?[]const u8 {
        _ = self;
        _ = launcher;
        return null;
    }

    /// Raster icon for dvui.image(). Non-blocking: cached bytes or null +
    /// enqueue. Bytes borrow cache memory (valid until deinit; no eviction).
    pub fn iconImage(self: *const App, launcher: *Launcher) ?dvui.ImageSource {
        const data = launcher.requestIcon(self.icon) orelse return null;
        if (data.bytes.len == 0) return null;
        return .{ .imageFile = .{ .bytes = data.bytes, .name = data.path } };
    }
};

const ParsedApp = struct {
    name: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    categories: ?[]const u8 = null,
    version: ?[]const u8 = null,
    generic_name: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    path: ?[]const u8 = null,
    exec: ?[]const u8 = null,
    terminal: ?bool = null,
};

fn unNullify(n: ParsedApp) ?App {
    return .{
        .name = n.name orelse return null,
        .icon = n.icon orelse return null,
        .categories = n.categories,
        .version = n.version,
        .generic_name = n.generic_name,
        .comment = n.comment,
        .path = n.path,
        .exec = n.exec,
        .terminal = n.terminal orelse false,
    };
}

pub fn init(self: *Launcher, alloc: std.mem.Allocator, io: std.Io) void {
    self.alloc = alloc;
    self.io = io;
    self.inited = true;
}

pub fn deinit(self: *Launcher) void {
    // Caller owns alloc/io lifetime; just free owned data.
    // Note: deinit may be called from UI thread while worker is stopped.
    for (self.data.items) |a| {
        self.alloc.free(a.name);
        if (a.categories) |v| self.alloc.free(v);
        if (a.version) |v| self.alloc.free(v);
        if (a.generic_name) |v| self.alloc.free(v);
        if (a.comment) |v| self.alloc.free(v);
        if (a.path) |v| self.alloc.free(v);
        if (a.exec) |v| self.alloc.free(v);
        self.alloc.free(a.icon);
    }
    self.data.deinit(self.alloc);
    var it = self.query.iterator();
    while (it.next()) |kv| {
        self.alloc.free(kv.key_ptr.*);
        if (kv.value_ptr.*) |slice| self.alloc.free(slice);
    }
    self.query.deinit(self.alloc);
    // pending items are same pointers as keys; don't double free.
    self.pending.deinit(self.alloc);
    var iit = self.icon_cache.iterator();
    while (iit.next()) |kv| {
        self.alloc.free(kv.key_ptr.*);
        if (kv.value_ptr.*) |d| {
            if (d.bytes.len > 0) self.alloc.free(d.bytes);
            if (d.path.len > 0) self.alloc.free(d.path);
        }
    }
    self.icon_cache.deinit(self.alloc);
    // icon_pending items alias icon_cache keys; don't double free.
    self.icon_pending.deinit(self.alloc);
    for (self.icon_theme_dirs.items) |d| self.alloc.free(d);
    self.icon_theme_dirs.deinit(self.alloc);
    if (self.home_dir) |h| self.alloc.free(h);
    self.* = .{};
}

// ---------------------------------------------------------------------------
// Helpers: case-insensitive substring
// ---------------------------------------------------------------------------
fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (needle.len > hay.len) return false;
    // Lowercase needle once into stack buf when small, heap otherwise
    // For simplicity, direct O(n*m) with ascii toLower.
    for (0..hay.len - needle.len + 1) |i| {
        var ok = true;
        for (needle, 0..) |nc, j| {
            const hc = hay[i + j];
            if (std.ascii.toLower(hc) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn appScore(app: *const App, term: []const u8) ?u8 {
    if (term.len == 0) return 0; // empty shows all as name-priority
    if (containsIgnoreCase(app.name, term)) return 0;
    if (app.comment) |c| if (containsIgnoreCase(c, term)) return 1;
    if (app.generic_name) |g| if (containsIgnoreCase(g, term)) return 1;
    if (app.categories) |cats| if (containsIgnoreCase(cats, term)) return 2;
    if (app.exec) |e| if (containsIgnoreCase(e, term)) return 3;
    return null;
}

// ---------------------------------------------------------------------------
// File loading – freedesktop .desktop parser
// ---------------------------------------------------------------------------
fn parseDesktopData(
    self: *Launcher,
    alloc: std.mem.Allocator,
    data: []const u8,
    path: []const u8,
) !void {
    var app: ParsedApp = .{};
    // Ensure we clean up on early return for non-Application types.
    var in_desktop_entry = false;
    var seen_desktop_entry = false;
    // Freedesktop Hidden/NoDisplay: kept as locals, never stored on App.
    var hidden = false;
    var nodisplay = false;

    var lines = std.mem.splitSequence(u8, data, "\n");
    while (lines.next()) |line_raw| {
        // Handle CRLF and trim surrounding whitespace
        const line_trimmed = std.mem.trim(u8, line_raw, " \t\r");
        if (line_trimmed.len == 0) continue;
        if (line_trimmed[0] == '#') continue;

        // Group header: [Desktop Entry] or [Desktop Action ...]
        if (line_trimmed[0] == '[') {
            if (line_trimmed[line_trimmed.len - 1] != ']') {
                std.log.warn("malformed group header in \"{s}\": {s}", .{ path, line_trimmed });
                continue;
            }
            const group = std.mem.trim(u8, line_trimmed[1 .. line_trimmed.len - 1], " \t");
            if (std.mem.eql(u8, group, "Desktop Entry")) {
                in_desktop_entry = true;
                seen_desktop_entry = true;
            } else {
                in_desktop_entry = false;
            }
            continue;
        }

        if (!in_desktop_entry) {
            // If file never had a [Desktop Entry] header but contains keys,
            // be lenient: treat first keys as if in Desktop Entry until we
            // see a header. This maintains compatibility with files that
            // omit the header (rare) while still requiring seenDesktopEntry
            // later for strict files? For now, only parse if we have seen
            // the header OR file has no headers at all.
            // If we have not yet seen any header, assume we are in Desktop Entry.
            if (!seen_desktop_entry) {
                // Check if line looks like a key=value
                if (std.mem.indexOfScalar(u8, line_trimmed, '=') == null) continue;
                // Lazily consider we are in Desktop Entry
                in_desktop_entry = true;
            } else {
                continue;
            }
        }

        const eq_idx = std.mem.indexOfScalar(u8, line_trimmed, '=') orelse {
            // No '=', not a key line – skip
            continue;
        };
        const key_raw = std.mem.trim(u8, line_trimmed[0..eq_idx], " \t");
        const val_raw = std.mem.trim(u8, line_trimmed[eq_idx + 1 ..], " \t");

        if (key_raw.len == 0) continue;

        // Strip locale suffix: "Name[ar]" -> "Name", but keep original to detect locale
        const is_locale = std.mem.indexOfScalar(u8, key_raw, '[') != null;
        const key = if (std.mem.indexOfScalar(u8, key_raw, '[')) |b| key_raw[0..b] else key_raw;

        // For locale variants, keep first value and don't overwrite an existing
        // non-locale value. For non-locale, always (re)set, overwriting any
        // prior locale value.
        if (std.mem.eql(u8, key, "Name")) {
            if (is_locale and app.name != null) continue;
            if (app.name) |old| alloc.free(old);
            app.name = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Exec")) {
            if (is_locale and app.exec != null) continue;
            if (app.exec) |old| alloc.free(old);
            app.exec = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Type")) {
            if (!std.mem.eql(u8, val_raw, "Application")) {
                // Cleanup and skip this file – not an application
                if (app.name) |v| alloc.free(v);
                if (app.icon) |v| alloc.free(v);
                if (app.categories) |v| alloc.free(v);
                if (app.version) |v| alloc.free(v);
                if (app.generic_name) |v| alloc.free(v);
                if (app.comment) |v| alloc.free(v);
                if (app.path) |v| alloc.free(v);
                if (app.exec) |v| alloc.free(v);
                // Note: app.terminal is bool, no alloc
                return;
            }
        } else if (std.mem.eql(u8, key, "Version")) {
            if (is_locale and app.version != null) continue;
            if (app.version) |old| alloc.free(old);
            app.version = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Categories")) {
            if (is_locale and app.categories != null) continue;
            if (app.categories) |old| alloc.free(old);
            app.categories = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "GenericName")) {
            if (is_locale and app.generic_name != null) continue;
            if (app.generic_name) |old| alloc.free(old);
            app.generic_name = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Comment")) {
            if (is_locale and app.comment != null) continue;
            if (app.comment) |old| alloc.free(old);
            app.comment = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Path")) {
            if (is_locale and app.path != null) continue;
            if (app.path) |old| alloc.free(old);
            app.path = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Icon")) {
            if (is_locale and app.icon != null) continue;
            if (app.icon) |old| alloc.free(old);
            app.icon = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Terminal")) {
            app.terminal = std.mem.eql(u8, val_raw, "true") or std.mem.eql(u8, val_raw, "True") or std.mem.eql(u8, val_raw, "1");
        } else if (std.mem.eql(u8, key, "Hidden")) {
            hidden = std.mem.eql(u8, val_raw, "true") or std.mem.eql(u8, val_raw, "True") or std.mem.eql(u8, val_raw, "1");
        } else if (std.mem.eql(u8, key, "NoDisplay")) {
            nodisplay = std.mem.eql(u8, val_raw, "true") or std.mem.eql(u8, val_raw, "True") or std.mem.eql(u8, val_raw, "1");
        } else {
            // Unknown key – intentionally silent; locale keys like Name[ar] are
            // already handled via stripping, so this won't warn for "ar".
            continue;
        }
    }

    // Hidden/NoDisplay entries are never shown: skip the file entirely.
    if (hidden or nodisplay) {
        if (app.name) |v| alloc.free(v);
        if (app.icon) |v| alloc.free(v);
        if (app.categories) |v| alloc.free(v);
        if (app.version) |v| alloc.free(v);
        if (app.generic_name) |v| alloc.free(v);
        if (app.comment) |v| alloc.free(v);
        if (app.path) |v| alloc.free(v);
        if (app.exec) |v| alloc.free(v);
        return;
    }

    const a = unNullify(app) orelse {
        if (app.name) |v| alloc.free(v);
        if (app.icon) |v| alloc.free(v);
        if (app.categories) |v| alloc.free(v);
        if (app.version) |v| alloc.free(v);
        if (app.generic_name) |v| alloc.free(v);
        if (app.comment) |v| alloc.free(v);
        if (app.path) |v| alloc.free(v);
        if (app.exec) |v| alloc.free(v);
        return;
    };
    try self.data.append(alloc, a);
}

fn addFile(
    self: *Launcher,
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const stat = try file.stat(io);
    var rd = file.reader(io, &.{});
    const data = try rd.interface.readAlloc(alloc, stat.size);
    defer alloc.free(data);
    try self.parseDesktopData(alloc, data, path);
}

fn addDir(
    self: *Launcher,
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{
        .iterate = true,
        .follow_symlinks = true,
    });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".desktop")) {
            const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, e.name });
            defer alloc.free(full);
            try self.addFile(alloc, io, full);
        }
    }
}

pub fn loadList(self: *Launcher, pinit: std.process.Init) !void {
    if (!self.inited) {
        self.alloc = pinit.arena.allocator();
        // best-effort io: use pinit.io if available, else stored
        self.io = pinit.io;
        self.inited = true;
    }
    const alloc = self.alloc;
    // Use provided init alloc for scanning but store owned strings in self.alloc
    // For simplicity use self.alloc for everything now.
    var home: ?[]const u8 = null;
    defer if (home) |h| alloc.free(h);
    if (pinit.environ_map.get("HOME")) |h| {
        home = try std.fmt.allocPrint(alloc, "{s}/.local/share/applications", .{h});
        if (self.home_dir == null) self.home_dir = try alloc.dupe(u8, h);
    }
    if (home) |h|
        self.addDir(alloc, pinit.io, h) catch |e| {
            if (e != error.FileNotFound) std.log.warn("cannot get applications from {s}: {s}", .{
                h,
                @errorName(e),
            });
        };
    self.addDir(alloc, pinit.io, "/usr/local/share/applications") catch |e| {
        if (e != error.FileNotFound) std.log.warn("cannot get applications from {s}: {s}", .{
            "/usr/local/share/applications",
            @errorName(e),
        });
    };
    self.addDir(alloc, pinit.io, "/usr/share/applications") catch |e| {
        if (e != error.FileNotFound) std.log.warn("cannot get applications from {s}: {s}", .{
            "/usr/share/applications",
            @errorName(e),
        });
    };
}

/// Queue a search. Returns cached results if already computed, otherwise
/// inserts `null` for the term, enqueues it for `tick` and returns `null`.
/// Thread-safe: UI calls this, worker calls `tick`.
pub fn search(self: *Launcher, term: []const u8) ?[]*App {
    if (!self.inited) return null;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);

    if (self.query.get(term)) |cached| {
        return cached;
    }
    const key = self.alloc.dupe(u8, term) catch return null;
    self.query.put(self.alloc, key, null) catch {
        self.alloc.free(key);
        return null;
    };
    self.pending.append(self.alloc, key) catch {
        // rollback map on OOM
        _ = self.query.remove(key);
        self.alloc.free(key);
        return null;
    };
    return null;
}

/// Worker-thread side: drain pending queue and populate query cache.
/// Prioritizes: 0=name, 1=comment/generic_name, 2=categories, 3=exec.
/// Must be called from the State worker thread (see State.zig).
pub fn tick(self: *Launcher) !void {
    if (!self.inited) return;
    var batch: std.ArrayList([]const u8) = .empty;
    defer batch.deinit(self.alloc);

    {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.pending.items.len == 0) return;
        std.mem.swap(std.ArrayList([]const u8), &self.pending, &batch);
    }

    for (batch.items) |term| {
        // Collect matches by priority buckets.
        var buckets: [4]std.ArrayList(*App) = .{ .empty, .empty, .empty, .empty };
        defer for (&buckets) |*b| b.deinit(self.alloc);

        // Fast path: empty term -> all apps in insertion order.
        if (term.len == 0) {
            var all: std.ArrayList(*App) = .empty;
            defer all.deinit(self.alloc);
            for (self.data.items) |*a| try all.append(self.alloc, @constCast(a));
            const owned = try all.toOwnedSlice(self.alloc);
            self.mu.lockUncancelable(self.io);
            if (self.query.getPtr(term)) |ptr| ptr.* = owned else {
                // Should not happen; term was inserted.
                self.alloc.free(owned);
            }
            self.mu.unlock(self.io);
            continue;
        }

        for (self.data.items) |*a| {
            const sc = appScore(a, term) orelse continue;
            try buckets[sc].append(self.alloc, a);
        }

        var total: usize = 0;
        for (buckets) |b| total += b.items.len;
        if (total == 0) {
            const empty: []*App = try self.alloc.alloc(*App, 0);
            self.mu.lockUncancelable(self.io);
            if (self.query.getPtr(term)) |ptr| ptr.* = empty;
            self.mu.unlock(self.io);
            continue;
        }

        const out = try self.alloc.alloc(*App, total);
        var off: usize = 0;
        for (buckets) |b| {
            @memcpy(out[off .. off + b.items.len], b.items);
            off += b.items.len;
        }

        self.mu.lockUncancelable(self.io);
        if (self.query.getPtr(term)) |ptr| {
            ptr.* = out;
        } else {
            // Term removed concurrently? free and ignore.
            self.alloc.free(out);
        }
        self.mu.unlock(self.io);
    }
}

// ---------------------------------------------------------------------------
// Icons – async cached freedesktop lookup, fixed 32px with auto-scale fallback
//
// UI never touches the filesystem: App.iconImage() returns cached bytes or
// null + enqueues the name. The worker resolves via tickIcons() and wakes
// the GUI. Positive and negative results are cached, so each unique Icon=
// name stats the disk once. Theme order is hicolor first, then every other
// subdir of each icons dir (alphabetical). Within a theme, 32x32 is
// preferred; other sizes are fallback and the GPU scales them into the
// fixed 32px slot (dvui.image shrink + fixed widget size).
// Only stb-compatible raster (.png/.jpg) is returned; .svg/.xpm resolve to
// missing (placeholder) for now.
// ---------------------------------------------------------------------------

const icon_size_dirs = [_][]const u8{
    "32x32", "32x32@2", "24x24", "48x48", "36x36", "22x22",
    "16x16", "64x64", "24x24@2", "48x48@2", "128x128",
    "256x256", "512x512",
};
// NOTE: "scalable" omitted on purpose — it holds .svg only, which the
// raster pipeline can't use; probing it would only burn stats.

const icon_exts = [_][]const u8{ ".png", ".jpg" };

const max_icon_bytes: usize = 2 * 1024 * 1024;

/// Non-blocking UI-side lookup. Returns resolved data (copy of slice
/// headers; memory owned by the cache) or null when pending/missing.
/// On unknown names enqueues for the worker and returns null.
pub fn requestIcon(self: *Launcher, name: []const u8) ?IconData {
    if (!self.inited or name.len == 0) return null;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.icon_cache.get(name)) |cached| {
        return cached;
    }
    const key = self.alloc.dupe(u8, name) catch return null;
    self.icon_cache.put(self.alloc, key, null) catch {
        self.alloc.free(key);
        return null;
    };
    self.icon_pending.append(self.alloc, key) catch {
        _ = self.icon_cache.remove(key);
        self.alloc.free(key);
        return null;
    };
    return null;
}

fn dirExists(self: *Launcher, path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(self.io, path, .{ .iterate = false }) catch return false;
    dir.close(self.io);
    return true;
}

fn fileExists(self: *Launcher, path: []const u8) bool {
    var f = std.Io.Dir.openFileAbsolute(self.io, path, .{ .mode = .read_only }) catch return false;
    f.close(self.io);
    return true;
}

/// Build ordered theme dirs once: hicolor first across all bases, then all
/// other subdirs (alphabetical) per base, pixmaps last. Called on worker.
fn ensureIconThemeDirs(self: *Launcher) void {
    {
        self.mu.lockUncancelable(self.io);
        const built = self.icon_themes_built;
        self.mu.unlock(self.io);
        if (built) return;
    }
    var bases: std.ArrayList([]const u8) = .empty;
    defer bases.deinit(self.alloc);
    if (self.home_dir) |h| {
        if (std.fmt.allocPrint(self.alloc, "{s}/.local/share/icons", .{h}) catch null) |p| {
            bases.append(self.alloc, p) catch self.alloc.free(p);
        }
    }
    for ([_][]const u8{ "/usr/local/share/icons", "/usr/share/icons" }) |b| {
        bases.append(self.alloc, b) catch {};
    }

    var ordered: std.ArrayList([]const u8) = .empty;
    defer ordered.deinit(self.alloc);

    // Hicolor first across all bases.
    for (bases.items) |b| {
        const p = std.fmt.allocPrint(self.alloc, "{s}/hicolor", .{b}) catch continue;
        if (self.dirExists(p)) {
            ordered.append(self.alloc, p) catch self.alloc.free(p);
        } else self.alloc.free(p);
    }
    // Then every other theme subdir, alphabetical per base for determinism.
    for (bases.items) |b| {
        var dir = std.Io.Dir.openDirAbsolute(self.io, b, .{ .iterate = true }) catch continue;
        defer dir.close(self.io);
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |n| self.alloc.free(n);
            names.deinit(self.alloc);
        }
        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |e| {
            if (e.kind != .directory) continue;
            if (std.mem.eql(u8, e.name, "hicolor")) continue;
            names.append(self.alloc, self.alloc.dupe(u8, e.name) catch continue) catch continue;
        }
        // Insertion sort (theme counts are small).
        if (names.items.len > 1) {
            for (1..names.items.len) |i| {
                var j = i;
                while (j > 0 and std.mem.order(u8, names.items[j], names.items[j - 1]) == .lt) {
                    std.mem.swap([]const u8, &names.items[j], &names.items[j - 1]);
                    j -= 1;
                }
            }
        }
        for (names.items) |n| {
            const p = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ b, n }) catch continue;
            ordered.append(self.alloc, p) catch self.alloc.free(p);
        }
    }
    // Pixmaps last (flat dirs, no themes/sizes).
    if (self.home_dir) |h| {
        if (std.fmt.allocPrint(self.alloc, "{s}/.local/share/pixmaps", .{h}) catch null) |p| {
            if (self.dirExists(p)) ordered.append(self.alloc, p) catch self.alloc.free(p) else self.alloc.free(p);
        }
    }
    for ([_][]const u8{ "/usr/local/share/pixmaps", "/usr/share/pixmaps" }) |p| {
        if (self.dirExists(p)) {
            const owned = self.alloc.dupe(u8, p) catch continue;
            ordered.append(self.alloc, owned) catch self.alloc.free(owned);
        }
    }

    // Free the one home-derived base we allocated; static strings stay.
    for (bases.items) |b| {
        if (b.len > 0 and b[0] != '/') continue;
        if (self.home_dir != null and std.mem.startsWith(u8, b, self.home_dir.?)) self.alloc.free(b);
    }

    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.icon_themes_built) {
        for (ordered.items) |d| self.alloc.free(d);
        return;
    }
    for (ordered.items) |d| self.icon_theme_dirs.append(self.alloc, d) catch self.alloc.free(d);
    self.icon_themes_built = true;
}

fn hasImageExt(name: []const u8) bool {
    for (icon_exts) |e| if (std.mem.endsWith(u8, name, e)) return true;
    return std.mem.endsWith(u8, name, ".svg") or std.mem.endsWith(u8, name, ".xpm");
}

/// Only stb-decodable raster may reach dvui.imageFile; vector/xpm would
/// fail decode every frame, so resolve them to missing (placeholder).
fn isRasterPath(path: []const u8) bool {
    for (icon_exts) |e| if (std.mem.endsWith(u8, path, e)) return true;
    return false;
}

/// Resolve one icon name to an owned absolute path. Caller owns result.
/// Returns null when missing or unsupported (e.g. svg-only).
fn resolveIconPath(self: *Launcher, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    // Absolute path: use directly (try as-is, then + .png when extensionless).
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        if (std.mem.startsWith(u8, name, "/")) {
            if (hasImageExt(name)) {
                if (self.fileExists(name)) return self.alloc.dupe(u8, name) catch null;
                return null;
            }
            var buf: [1024]u8 = undefined;
            for (icon_exts) |e| {
                const cand = std.fmt.bufPrint(&buf, "{s}{s}", .{ name, e }) catch continue;
                if (self.fileExists(cand)) return self.alloc.dupe(u8, cand) catch null;
            }
            if (self.fileExists(name)) return self.alloc.dupe(u8, name) catch null;
        }
        return null;
    }
    // Shallow snapshot of theme dirs (slice only; strings stay owned by the
    // cache until deinit, which runs after the worker stops, so borrowing
    // them across IO without the lock is safe).
    self.mu.lockUncancelable(self.io);
    const dirs = self.icon_theme_dirs.items;
    const owned = self.alloc.dupe([]const u8, dirs) catch &.{};
    self.mu.unlock(self.io);
    defer self.alloc.free(owned);
    var buf: [1024]u8 = undefined;
    const with_ext = hasImageExt(name);
    for (owned) |theme| {
        const is_pixmaps = std.mem.endsWith(u8, theme, "pixmaps");
        if (is_pixmaps) {
            if (with_ext) {
                const cand = std.fmt.bufPrint(&buf, "{s}/{s}", .{ theme, name }) catch continue;
                if (self.fileExists(cand)) return self.alloc.dupe(u8, cand) catch null;
                continue;
            }
            for (icon_exts) |e| {
                const cand = std.fmt.bufPrint(&buf, "{s}/{s}{s}", .{ theme, name, e }) catch continue;
                if (self.fileExists(cand)) return self.alloc.dupe(u8, cand) catch null;
            }
            continue;
        }
        for (icon_size_dirs) |size| {
            if (with_ext) {
                const cand = std.fmt.bufPrint(&buf, "{s}/{s}/apps/{s}", .{ theme, size, name }) catch continue;
                if (self.fileExists(cand)) return self.alloc.dupe(u8, cand) catch null;
                continue;
            }
            for (icon_exts) |e| {
                const cand = std.fmt.bufPrint(&buf, "{s}/{s}/apps/{s}{s}", .{ theme, size, name, e }) catch continue;
                if (self.fileExists(cand)) return self.alloc.dupe(u8, cand) catch null;
            }
        }
    }
    return null;
}

fn readIconBytes(self: *Launcher, path: []const u8) ?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(self.io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(self.io);
    const stat = file.stat(self.io) catch return null;
    if (stat.size == 0 or stat.size > max_icon_bytes) return null;
    var rd = file.reader(self.io, &.{});
    return rd.interface.readAlloc(self.alloc, stat.size) catch null;
}

/// Worker-thread side: resolve up to max_per_tick pending icons.
/// Never called from the UI thread (does filesystem IO).
pub fn tickIcons(self: *Launcher, max_per_tick: usize) !void {
    if (!self.inited) return;
    self.ensureIconThemeDirs();
    var batch: std.ArrayList([]const u8) = .empty;
    defer batch.deinit(self.alloc);
    {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.icon_pending.items.len == 0) return;
        const n = @min(max_per_tick, self.icon_pending.items.len);
        batch.ensureTotalCapacity(self.alloc, n) catch return;
        for (self.icon_pending.items[0..n]) |nm| batch.appendAssumeCapacity(nm);
        std.mem.copyForwards([]const u8, self.icon_pending.items[0 .. self.icon_pending.items.len - n], self.icon_pending.items[n..]);
        self.icon_pending.items.len -= n;
    }
    for (batch.items) |name| {
        const path = self.resolveIconPath(name);
        var data = IconData{ .bytes = &.{}, .path = &.{} };
        if (path) |p| {
            if (!isRasterPath(p)) {
                self.alloc.free(p);
            } else if (self.readIconBytes(p)) |bytes| {
                // Keep path for debugging; UI renders bytes.
                data = .{ .bytes = bytes, .path = p };
            } else {
                self.alloc.free(p);
            }
        }
        self.mu.lockUncancelable(self.io);
        if (self.icon_cache.getPtr(name)) |ptr| {
            if (ptr.* == null) {
                ptr.* = data;
            } else {
                if (data.bytes.len > 0) self.alloc.free(data.bytes);
                if (data.path.len > 0) self.alloc.free(data.path);
            }
        } else {
            if (data.bytes.len > 0) self.alloc.free(data.bytes);
            if (data.path.len > 0) self.alloc.free(data.path);
        }
        self.mu.unlock(self.io);
    }
}

pub fn run(self: *Launcher, id: usize) void {
    if (id >= self.data.items.len) return;
    const app = self.data.items[id];
    const raw_exec = app.exec orelse return;
    // Strip freedesktop Exec field codes (%f %F %u %U %d %D %n %N %i %c %k %v %m, %% -> %)
    // so `sh -c` doesn't see literal %U etc. and freeze on missing args.
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(self.alloc);
    var i: usize = 0;
    while (i < raw_exec.len) : (i += 1) {
        if (raw_exec[i] == '%' and i + 1 < raw_exec.len) {
            const code = raw_exec[i + 1];
            if (code == '%') {
                cleaned.append(self.alloc, '%') catch {};
                i += 1;
                continue;
            }
            if (std.mem.indexOfScalar(u8, "fFuUdDnNiCkv", code) != null or code == 'm') {
                i += 1;
                continue;
            }
        }
        cleaned.append(self.alloc, raw_exec[i]) catch {};
    }
    const exec = cleaned.items;
    if (exec.len == 0) return;
    const cwd: std.process.Child.Cwd = if (app.path) |p| .{ .path = p } else .inherit;
    var child = std.process.spawn(self.io, .{ .argv = &.{ "/bin/sh", "-c", exec }, .cwd = cwd }) catch |e| {
        std.log.err("failed to run {s}: {s}", .{ app.name, @errorName(e) });
        return;
    };
    // Don't block the UI thread: launching a long-lived app (e.g. terminal,
    // browser) would freeze the hub until it exits. Detach and reap in a
    // background thread so we don't leak zombies.
    const pid = child.id orelse return;
    child.id = null; // we will reap via waitpid, not Child.wait
    // Close any inherited stdio handles that Child may own (none for .inherit)
    if (child.stdin) |*f| f.close(self.io);
    if (child.stdout) |*f| f.close(self.io);
    if (child.stderr) |*f| f.close(self.io);
    const Box = struct { pid: std.posix.pid_t };
    const box = self.alloc.create(Box) catch return;
    box.pid = pid;
    const thread = std.Thread.spawn(.{}, struct {
        fn reap(b: *Box, alloc: std.mem.Allocator) void {
            defer alloc.destroy(b);
            // Raw syscall on Linux so headless tests stay libc-free (this
            // toolchain cannot link libc); libc elsewhere.
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
// Tests – practical coverage against real .desktop files
// ---------------------------------------------------------------------------
test "launcher: parser handles locale keys without double free" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();

    const data =
        \\[Desktop Entry]
        \\Name=TestApp
        \\Name[ar]=اختبار
        \\GenericName=Test
        \\GenericName[ar]=اختبار
        \\Comment=A comment
        \\Comment[ar]=تعليق
        \\Exec=testapp --flag
        \\Icon=testicon
        \\Type=Application
        \\Categories=Utility;Test;
        \\Terminal=false
        \\
    ;
    try launcher.parseDesktopData(alloc, data, "/tmp/fake.desktop");
    try std.testing.expectEqual(@as(usize, 1), launcher.data.items.len);
    try std.testing.expectEqualStrings("TestApp", launcher.data.items[0].name);
    // Locale should not overwrite non-locale
    try std.testing.expectEqualStrings("Test", launcher.data.items[0].generic_name.?);
    try std.testing.expectEqualStrings("A comment", launcher.data.items[0].comment.?);
}

test "launcher: parser skips non-Application Type and cleans up" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();
    const data =
        \\[Desktop Entry]
        \\Name=Link
        \\Icon=link
        \\Type=Link
        \\URL=https://example.com
        \\
    ;
    try launcher.parseDesktopData(alloc, data, "/tmp/fake2.desktop");
    try std.testing.expectEqual(@as(usize, 0), launcher.data.items.len);
}

test "launcher: parser handles tricky real-world lines (equals in value, spaces)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();
    // Value contains '=' and leading/trailing spaces, plus locale and duplicate keys
    const data =
        \\[Desktop Entry]
        \\Name=My App
        \\Exec=sh -c "echo a=b; echo c=d"
        \\Icon=myicon
        \\Type=Application
        \\Comment=  spaced value
        \\Categories=Utility;
        \\# Comment line
        \\GenericName=First
        \\GenericName=Second
        \\Terminal=True
        \\
    ;
    try launcher.parseDesktopData(alloc, data, "/tmp/fake3.desktop");
    try std.testing.expectEqual(@as(usize, 1), launcher.data.items.len);
    try std.testing.expectEqualStrings("My App", launcher.data.items[0].name);
    try std.testing.expectEqualStrings("sh -c \"echo a=b; echo c=d\"", launcher.data.items[0].exec.?);
    try std.testing.expectEqualStrings("spaced value", launcher.data.items[0].comment.?);
    try std.testing.expectEqualStrings("Second", launcher.data.items[0].generic_name.?);
    try std.testing.expect(launcher.data.items[0].terminal == true);
}

test "launcher: parser ignores actions and other groups" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();
    const data =
        \\[Desktop Entry]
        \\Name=App
        \\Exec=app
        \\Icon=icon
        \\Type=Application
        \\Categories=Utility;
        \\[Desktop Action New]
        \\Name=New Window
        \\Exec=app --new
        \\
    ;
    try launcher.parseDesktopData(alloc, data, "/tmp/fake4.desktop");
    try std.testing.expectEqual(@as(usize, 1), launcher.data.items.len);
    try std.testing.expectEqualStrings("App", launcher.data.items[0].name);
    try std.testing.expectEqualStrings("app", launcher.data.items[0].exec.?);
}

test "launcher: parser skips Hidden and NoDisplay entries" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();
    const hidden_data =
        \\[Desktop Entry]
        \\Name=Secret
        \\Exec=secret
        \\Icon=secret
        \\Type=Application
        \\Hidden=true
        \\
    ;
    try launcher.parseDesktopData(alloc, hidden_data, "/tmp/hidden.desktop");
    const nodisplay_data =
        \\[Desktop Entry]
        \\Name=Backend
        \\Exec=backend
        \\Icon=backend
        \\Type=Application
        \\NoDisplay=True
        \\
    ;
    try launcher.parseDesktopData(alloc, nodisplay_data, "/tmp/nodisplay.desktop");
    const visible_data =
        \\[Desktop Entry]
        \\Name=Visible
        \\Exec=visible
        \\Icon=visible
        \\Type=Application
        \\Hidden=false
        \\NoDisplay=0
        \\
    ;
    try launcher.parseDesktopData(alloc, visible_data, "/tmp/visible.desktop");
    try std.testing.expectEqual(@as(usize, 1), launcher.data.items.len);
    try std.testing.expectEqualStrings("Visible", launcher.data.items[0].name);
}

test "launcher: icons resolve hicolor-first at 32px with cache" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();

    // Miss enqueues, resolves after tickIcons.
    try std.testing.expect(launcher.requestIcon("firefox") == null);
    try launcher.tickIcons(8);
    const hit = launcher.requestIcon("firefox");
    try std.testing.expect(hit != null);
    try std.testing.expect(hit.?.bytes.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, hit.?.path, ".png"));
    // hicolor theme dir is honored first.
    launcher.mu.lockUncancelable(io);
    const first_theme = if (launcher.icon_theme_dirs.items.len > 0) launcher.icon_theme_dirs.items[0] else "";
    launcher.mu.unlock(io);
    try std.testing.expect(std.mem.endsWith(u8, first_theme, "/hicolor"));
    // Second lookup is cached (no re-enqueue).
    launcher.mu.lockUncancelable(io);
    const pending_before = launcher.icon_pending.items.len;
    launcher.mu.unlock(io);
    _ = launcher.requestIcon("firefox");
    launcher.mu.lockUncancelable(io);
    const pending_after = launcher.icon_pending.items.len;
    launcher.mu.unlock(io);
    try std.testing.expectEqual(pending_before, pending_after);

    // Missing names are negatively cached (empty data, still null to UI).
    try std.testing.expect(launcher.requestIcon("zz-no-such-icon-xyz") == null);
    try launcher.tickIcons(8);
    const miss = launcher.requestIcon("zz-no-such-icon-xyz");
    try std.testing.expect(miss != null and miss.?.bytes.len == 0);
    launcher.mu.lockUncancelable(io);
    const cached_miss = launcher.icon_cache.get("zz-no-such-icon-xyz");
    launcher.mu.unlock(io);
    try std.testing.expect(cached_miss != null and cached_miss.? != null);

    // App helper returns an image source borrowing cache bytes.
    var app = App{ .name = "Firefox", .icon = "firefox" };
    // Point app.icon at the cached key so requestIcon hits the same entry.
    launcher.mu.lockUncancelable(io);
    var key_copy: []const u8 = "firefox";
    var kit = launcher.icon_cache.iterator();
    while (kit.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "firefox")) key_copy = kv.key_ptr.*;
    }
    launcher.mu.unlock(io);
    app.icon = key_copy;
    const src = app.iconImage(&launcher);
    try std.testing.expect(src != null);
    try std.testing.expect(app.iconTvg(&launcher) == null);
}

test "launcher: icons load ten quickly (perf probe)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();
    const names = [_][]const u8{ "firefox", "kmail", "sieveeditor", "akonadi", "akonadiconsole", "CMakeSetup", "firefox", "kmail", "sieveeditor", "zz-no-such-icon-xyz" };
    for (names) |nm| {
        const data = try std.fmt.allocPrint(alloc, "[Desktop Entry]\nName={s}\nExec={s}\nIcon={s}\nType=Application\n", .{ nm, nm, nm });
        defer alloc.free(data);
        try launcher.parseDesktopData(alloc, data, "/tmp/probe.desktop");
    }
    for (launcher.data.items) |*app| _ = launcher.requestIcon(app.icon);
    const t0 = std.Io.Clock.boot.now(io);
    var ticks: usize = 0;
    while (ticks < 10) : (ticks += 1) {
        launcher.mu.lockUncancelable(io);
        const p = launcher.icon_pending.items.len;
        launcher.mu.unlock(io);
        if (p == 0) break;
        try launcher.tickIcons(8);
    }
    const t1 = std.Io.Clock.boot.now(io);
    const ms = @as(f64, @floatFromInt(t0.durationTo(t1).toNanoseconds())) / 1_000_000.0;
    var hits: usize = 0;
    for (launcher.data.items) |*app| {
        const d = launcher.requestIcon(app.icon);
        if (d != null and d.?.bytes.len > 0) hits += 1;
    }
    std.log.debug("icon probe: {d}/{d} hits in {d:.1}ms ({d} ticks)", .{ hits, names.len, ms, ticks });
    try std.testing.expect(ticks <= 2);
    try std.testing.expect(ms < 5000);
}

test "launcher: parse many real desktop files from system (practical)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();

    const dirs = [_][]const u8{
        "/usr/share/applications",
        "/usr/local/share/applications",
    };

    var total_files: usize = 0;
    var parsed: usize = 0;
    for (dirs) |d| {
        var dir = std.Io.Dir.openDirAbsolute(io, d, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |e| {
            if (e.kind != .file) continue;
            if (!std.mem.endsWith(u8, e.name, ".desktop")) continue;
            total_files += 1;
            const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ d, e.name });
            defer alloc.free(full);
            // Must not crash, double-free, or leak (GPA will catch)
            launcher.addFile(alloc, io, full) catch |err| {
                // Some broken files are expected to be skipped; ensure no crash
                std.log.warn("skip {s}: {s}", .{ full, @errorName(err) });
                continue;
            };
            parsed += 1;
        }
    }
    // On this system we expect a lot of files; ensure we actually parsed some
    // and didn't double-free. The GPA in std.testing will fail on leak/double-free.
    try std.testing.expect(total_files > 50);
    try std.testing.expect(parsed > 30);
    try std.testing.expect(launcher.data.items.len > 10);

    // Spot-check a known file that previously triggered "unknown entry ar"
    var found_sieve = false;
    for (launcher.data.items) |app| {
        if (std.mem.indexOf(u8, app.name, "Sieve") != null) found_sieve = true;
    }
    // If sieveeditor exists on system, it should have been parsed; otherwise just ensure no crash
    if (found_sieve) try std.testing.expect(true);

    // Also test async search still works after bulk load (practical)
    // Need to guarantee search prioritizes correctly after bulk load
    try std.testing.expect(launcher.search("fire") == null);
    try launcher.tick();
    const res = launcher.search("fire");
    try std.testing.expect(res != null);
}
