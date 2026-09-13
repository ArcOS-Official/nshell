const builtin = @import("builtin");
const std = @import("std");
const dvui = @import("dvui");

// nshell's copy of dvui's TextEntryWidget with one addition: InitOptions
// gains `align_x` (0 = left/dvui default, 0.5 = center, 1 = right).
//
// Copied from dvui @ ecffdbf (src/widgets/TextEntryWidget.zig) because
// stock dvui always lays text out left-aligned and exposes no knob.
// The ONLY behavioral delta vs upstream is the origin shift marked
// "nshell addition" below; everything else is verbatim. After a dvui
// bump, re-diff this file against the new TextEntryWidget and carry
// the marked block over.
//
// How alignment works: TextLayoutWidget starts every init with
// insert_pt at (0,0) and derives ALL run/cursor/selection/click
// positions from it, so shifting the origin right after
// textLayout.init() shifts the whole line consistently (cursor
// mapping, selection rendering and scroll-follow all stay correct).
// Limits: single-line only — wrapped lines reset insert_pt.x to 0
// inside TextLayoutWidget.addText, so multiline + align still renders
// first-line-shifted. Overflowing text (wider than the viewport)
// clamps the shift to 0 and scrolls exactly like stock dvui.

const Event = dvui.Event;
const Options = dvui.Options;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const ScrollInfo = dvui.ScrollInfo;
const Size = dvui.Size;
const Widget = dvui.Widget;
const WidgetData = dvui.WidgetData;
const ScrollAreaWidget = dvui.ScrollAreaWidget;
const TextLayoutWidget = dvui.TextLayoutWidget;
const AccessKit = dvui.AccessKit;

const AlignedEntry = @This();

/// If min_size_content is not given, use Font.sizeM(defaultMWidth, 1).
/// If multiline is false and max_size_content is not given, use min_size_content.
pub var defaultMWidth: f32 = 14;

pub var defaults: Options = .{
    .name = "TextEntry",
    .role = .text_input, // can change to multiline in init
    .margin = Rect.all(4),
    .corners = .default,
    .border = Rect.all(1),
    .padding = Rect.all(6),
    .background = true,
    .style = .content,
    // min_size_content/max_size_content is calculated in init()
};

const realloc_bin_size = 100;

pub const SyntaxHighlight = dvui.SyntaxHighlight;

pub const InitOptions = struct {
    pub const TextOption = union(enum) {
        /// Use this slice of bytes, cannot add more.
        buffer: []u8,

        /// Use and grow with realloc and shrink with resize as needed.
        buffer_dynamic: struct {
            backing: *[]u8,
            allocator: std.mem.Allocator,
            limit: usize = 10_000,
        },

        /// Use std.ArrayList(u8).  The limit is total characters, the
        /// arraylist might allocate more capacity.  ArrayList.items is updated
        /// in deinit() (file an issue if this is a problem).
        array_list: struct {
            backing: *std.ArrayList(u8),
            allocator: std.mem.Allocator,
            limit: usize = 10_000,
        },

        /// Use internal buffer up to limit.
        /// - use getText() to get contents.
        internal: struct {
            limit: usize = 10_000,
        },
    };

    text: TextOption = .{ .internal = .{} },
    tree_sitter: ?dvui.TreeSitter = null,
    /// Faded text shown when the textEntry is empty
    placeholder: ?[]const u8 = null,

    /// If true, assume text (and text height) is the same (excepting edits we
    /// do internally) as we saw last frame and only process what is needed for
    /// visibility (and copy).
    cache_layout: bool = false,

    break_lines: bool = false,
    kerning: ?bool = null,
    scroll_vertical: ?bool = null, // default is value of multiline
    scroll_vertical_bar: ?ScrollInfo.ScrollBarMode = null, // default .auto
    scroll_horizontal: ?bool = null, // default true
    scroll_horizontal_bar: ?ScrollInfo.ScrollBarMode = null, // default .auto if multiline, .hide if not

    // must be a single utf8 character
    password_char: ?[]const u8 = null,
    multiline: bool = false,

    /// nshell addition: horizontal text alignment as a fraction of the
    /// leftover line space (0 = left/stock dvui, 0.5 = center, 1 = right).
    /// Single-line only (see the origin shift in init); 0 disables the
    /// measuring entirely.
    align_x: f32 = 0,

    /// nshell addition: vertical text alignment as a fraction of the
    /// leftover content height (0 = top/stock dvui, 0.5 = middle,
    /// 1 = bottom). Single-line only, same mechanism as align_x.
    align_y: f32 = 0,
};

wd: WidgetData,
prevClip: Rect.Physical = undefined,
scroll: ScrollAreaWidget = undefined,
scrollClip: Rect.Physical = undefined,
textLayout: TextLayoutWidget = undefined,
textClip: Rect.Physical = undefined,
padding: Rect,

init_opts: InitOptions,
text: []u8,
len: usize,
enter_pressed: bool = false, // not valid if multiline
text_changed: bool = false,

// see textChanged()
text_changed_start: usize = std.math.maxInt(usize),
text_changed_end: usize = 0, // index of bytes before edits (so matches previous frame)
text_changed_added: i64 = 0, // bytes added
edited_outside_last_frame: *bool = undefined,

// nshell addition: layout-origin shift applied this frame for
// align_x/align_y, plus the textLayout min_size snapshot taken before
// layout ran. deinit subtracts the shift back out of min_size so
// parents and scrollbars see stock text extents, not the visual
// offset (without this the offset would inflate min_size every frame
// and ratchet ancestor heights).
align_shift: Size = .{},
align_min: Size = .{},

/// It's expected to call this when `self` is `undefined`
pub fn init(self: *AlignedEntry, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) void {
    var scroll_init_opts = ScrollAreaWidget.InitOpts{
        .vertical = if (init_opts.scroll_vertical orelse init_opts.multiline) .auto else .none,
        .vertical_bar = init_opts.scroll_vertical_bar orelse .auto,
        .horizontal = if (init_opts.scroll_horizontal orelse true) .auto else .none,
        .horizontal_bar = init_opts.scroll_horizontal_bar orelse (if (init_opts.multiline) .auto else .hide),
    };

    var options = defaults.min_sizeM(defaultMWidth, 1);

    if (init_opts.password_char != null) {
        options.role = .password_input;
    } else if (init_opts.multiline) {
        options.role = .multiline_text_input;
    }

    options = options.override(opts);
    if (!init_opts.multiline and options.max_size_content == null) {
        options = options.override(.{ .max_size_content = .size(options.min_size_contentGet()) });
    }

    // padding is interpreted as the padding for the TextLayoutWidget, but
    // we also need to add it to content size because TextLayoutWidget is
    // inside the scroll area
    const padding = options.paddingGet();
    options.padding = null;
    options.min_size_content.?.w += padding.x + padding.w;
    options.min_size_content.?.h += padding.y + padding.h;
    if (options.max_size_content != null) {
        options.max_size_content.?.w += padding.x + padding.w;
        options.max_size_content.?.h += padding.y + padding.h;
    }

    const wd = WidgetData.init(src, .{}, options);
    scroll_init_opts.focus_id = wd.id;

    var text: []u8 = undefined;
    var find_zero = true;
    var len_utf8_boundary: usize = undefined;
    switch (init_opts.text) {
        .buffer => |b| text = b,
        .buffer_dynamic => |b| text = b.backing.*,
        .internal => text = dvui.dataGetSliceDefault(null, wd.id, "_buffer", []u8, &.{}),
        .array_list => |al| {
            find_zero = false;
            text = al.backing.items.ptr[0..@min(al.limit, al.backing.capacity)];
            len_utf8_boundary = dvui.findUtf8Start(text, al.backing.items.len);
        },
    }

    if (find_zero) {
        const len_byte = std.mem.findScalar(u8, text, 0) orelse text.len;
        len_utf8_boundary = dvui.findUtf8Start(text[0..len_byte], len_byte);
    }

    self.* = .{
        .wd = wd,
        .padding = padding,
        .init_opts = init_opts,
        .text = text,
        .len = len_utf8_boundary,

        // SAFETY: The following fields are set bellow
        .prevClip = undefined,
        .scroll = undefined,
        .scrollClip = undefined,
        .textLayout = undefined,
        .textClip = undefined,
    };

    self.data().register();

    dvui.tabIndexSet(self.data().id, self.data().options.tab_index, self.data().rectScale().r);

    dvui.parentSet(self.widget());

    self.data().borderAndBackground(.{});

    self.prevClip = dvui.clip(self.data().borderRectScale().r);
    const borderClip = dvui.clipGet();

    // We do this dance with last_focused_id_this_frame so scroll will process
    // key events we skip (like page up/down). Normally it would not (text
    // entry is not a child of scroll). So with this we make scroll think that
    // text entry ran as a child.
    const focused = (self.data().id == dvui.lastFocusedIdInFrame());
    if (focused) dvui.currentWindow().last_focused_id_this_frame = .zero;

    // scrollbars process mouse events here
    self.scroll.init(@src(), scroll_init_opts, self.data().options.strip().override(.{ .role = .none, .expand = .both }));

    if (focused) dvui.currentWindow().last_focused_id_this_frame = self.data().id;

    self.scrollClip = dvui.clipGet();

    self.edited_outside_last_frame = dvui.dataGetPtrDefault(null, self.data().id, "_edited_outside", bool, false);
    if (self.init_opts.cache_layout and self.edited_outside_last_frame.*) {
        dvui.log.debug("AlignedEntry forcing cache_layout false due to text being edited after drawing last frame", .{});
        self.init_opts.cache_layout = false;
        self.edited_outside_last_frame.* = false;
        self.text_changed = true; // trigger tree_sitter full reparse
    }

    self.textLayout.init(@src(), .{
        .break_lines = self.init_opts.break_lines,
        .kerning = self.init_opts.kerning,
        .touch_edit_just_focused = false,
        .cache_layout = self.init_opts.cache_layout,
        .focused = self.data().id == dvui.focusedWidgetId(),
        .show_touch_draggables = (self.len > 0),
    }, self.data().options.strip().override(.{
        .role = .none,
        .expand = .both,
        .padding = self.padding,
    }));

    // nshell addition: shift the layout origin for align_x/align_y.
    // Everything below (runs, cursor, selection, click mapping,
    // scroll-follow) derives from insert_pt, so one bump here shifts the
    // line as a whole. Extents are measured with the entry font: the
    // drawn text when non-empty, the placeholder when empty, or count x
    // password glyph. Overflow clamps to 0 (stock scrolling takes over).
    // The applied shift is stored (with the pre-layout min_size) so
    // deinit can subtract it back out of min_size reporting.
    if (self.init_opts.align_x > 0 or self.init_opts.align_y > 0) {
        const font = self.data().options.fontGet();
        const shown_w: f32 = w: {
            if (self.len == 0) {
                if (self.init_opts.placeholder) |ph| break :w font.textSize(ph).w;
                break :w 0;
            }
            if (self.init_opts.password_char) |pc| {
                var n: usize = 0;
                var it = (std.unicode.Utf8View.initUnchecked(self.text[0..self.len])).iterator();
                while (it.nextCodepoint() != null) n += 1;
                break :w font.textSize(pc).w * @as(f32, @floatFromInt(n));
            }
            break :w font.textSize(self.text[0..self.len]).w;
        };
        const shown_h: f32 = h: {
            if (self.len == 0) {
                if (self.init_opts.placeholder) |ph| break :h font.textSize(ph).h;
                break :h font.textSize("").h;
            }
            if (self.init_opts.password_char) |pc| break :h font.textSize(pc).h;
            break :h font.textSize(self.text[0..self.len]).h;
        };
        const content = self.textLayout.data().contentRect();
        self.align_min = self.textLayout.data().min_size;
        self.align_shift = .{
            .w = if (self.init_opts.align_x > 0) @max(0, (content.w - shown_w) * self.init_opts.align_x) else 0,
            .h = if (self.init_opts.align_y > 0) @max(0, (content.h - shown_h) * self.init_opts.align_y) else 0,
        };
        self.textLayout.insert_pt.x += self.align_shift.w;
        self.textLayout.insert_pt.y += self.align_shift.h;
    }

    // if textLayout forced cache_layout to false, we need to honor that
    self.init_opts.cache_layout = self.textLayout.cache_layout;

    self.textClip = dvui.clipGet();

    if (self.textLayout.touchEditing()) |floating_widget| {
        defer floating_widget.deinit();

        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .corners = dvui.ButtonWidget.defaults.cornersGet(),
            .background = true,
            .border = dvui.Rect.all(1),
        });
        defer hbox.deinit();

        if (dvui.buttonIcon(@src(), "paste", dvui.entypo.clipboard, .{}, .{}, .{
            .min_size_content = .{ .h = 20 },
            .margin = Rect.all(2),
        })) {
            self.paste();
        }

        if (dvui.buttonIcon(@src(), "select all", dvui.entypo.swap, .{}, .{}, .{
            .min_size_content = .{ .h = 20 },
            .margin = Rect.all(2),
        })) {
            self.textLayout.selection.selectAll();
        }

        if (dvui.buttonIcon(@src(), "cut", dvui.entypo.scissors, .{}, .{}, .{
            .min_size_content = .{ .h = 20 },
            .margin = Rect.all(2),
        })) {
            self.cut();
        }

        if (dvui.buttonIcon(@src(), "copy", dvui.entypo.copy, .{}, .{}, .{
            .min_size_content = .{ .h = 20 },
            .margin = Rect.all(2),
        })) {
            self.copy();
        }
    }

    // don't call textLayout.processEvents here, we forward events inside our own processEvents

    // textLayout is maintaining the selection for us, but if the text
    // changed, we need to update the selection to be valid before we
    // process any events
    var sel = self.textLayout.selection;
    sel.start = dvui.findUtf8Start(self.text[0..self.len], sel.start);
    sel.cursor = dvui.findUtf8Start(self.text[0..self.len], sel.cursor);
    sel.end = dvui.findUtf8Start(self.text[0..self.len], sel.end);

    // textLayout clips to its content, but we need to get events out to our border
    dvui.clipSet(borderClip);
    if (self.data().accesskit_node()) |ak_node| {
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.focus);
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.set_value);
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.set_text_selection);
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.replace_selected_text);
        // NOTE: mirrors upstream TextEntryWidget. dvui's AccessKit action
        // handler for scroll_into_view is still a no-op, so this only
        // advertises future behavior; re-check on the next dvui re-diff.
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.scroll_into_view);
        // Correct: overflowing single-line text is clipped to the content
        // box (see clipSet(borderClip) above), so children never paint
        // outside this node's bounds.
        AccessKit.nodeSetClipsChildren(ak_node);

        if (self.data().options.role != .password_input) {
            const str = self.text[0..self.len];
            AccessKit.nodeSetValueWithLength(ak_node, str.ptr, str.len);
        }
    }
}

pub fn matchEvent(self: *AlignedEntry, e: *Event) bool {
    // textLayout could be passively listening to events in matchEvent, so
    // don't short circuit
    const match1 = dvui.eventMatchSimple(e, self.data());
    const match2 = self.scroll.scroll.?.matchEvent(e);
    const match3 = self.textLayout.matchEvent(e);
    return match1 or match2 or match3;
}

pub fn processEvents(self: *AlignedEntry) void {
    const evts = dvui.events();
    for (evts) |*e| {
        if (!self.matchEvent(e))
            continue;

        self.processEvent(e);
    }
}

pub fn draw(self: *AlignedEntry) void {
    self.drawBeforeText();

    if (self.len == 0) {
        if (self.init_opts.placeholder) |placeholder| {
            if (self.data().accesskit_node()) |ak_node| {
                AccessKit.nodeSetPlaceholderWithLength(ak_node, placeholder.ptr, placeholder.len);

                // Create an empty text run for the empty text entry.
                dvui.currentWindow().accesskit.text_run_parent = self.data().id;
                self.textLayout.textRunCreateEmpty(self.data().id, true);
                // prevent textLayout from making a text run for the placeholder text
                dvui.currentWindow().accesskit.text_run_parent = null;
            }
            self.textLayout.addText(placeholder, .{ .color_text = self.textLayout.data().options.color(.text).opacity(0.65) });
        }
    }

    if (dvui.accesskit_enabled) {
        // parent text runs to us
        dvui.currentWindow().accesskit.text_run_parent = self.data().id;
    }

    if (self.init_opts.password_char) |pc| {
        {
            // adjust selection for obfuscation
            var count: usize = 0;
            var bytes: usize = 0;
            var sel = self.textLayout.selection;
            var sstart: ?usize = null;
            var scursor: ?usize = null;
            var send: ?usize = null;
            var utf8it = (std.unicode.Utf8View.initUnchecked(self.text[0..self.len])).iterator();
            while (utf8it.nextCodepoint()) |codepoint| {
                if (sstart == null and sel.start == bytes) sstart = count * pc.len;
                if (scursor == null and sel.cursor == bytes) scursor = count * pc.len;
                if (send == null and sel.end == bytes) send = count * pc.len;
                count += 1;
                bytes += std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
            } else {
                if (sstart == null and sel.start >= bytes) sstart = count * pc.len;
                if (scursor == null and sel.cursor >= bytes) scursor = count * pc.len;
                if (send == null and sel.end >= bytes) send = count * pc.len;
            }
            sel.start = sstart.?;
            sel.cursor = scursor.?;
            sel.end = send.?;
            const password_str: ?[]u8 = dvui.currentWindow().lifo().alloc(u8, count * pc.len) catch null;
            if (password_str) |pstr| {
                defer dvui.currentWindow().lifo().free(pstr);
                for (0..count) |i| {
                    for (0..pc.len) |pci| {
                        pstr[i * pc.len + pci] = pc[pci];
                    }
                }
                self.textLayout.addText(pstr, self.data().options.strip());
            } else {
                dvui.log.warn("Could not allocate password_str, falling back to one single password_str", .{});
                self.textLayout.addText(pc, self.data().options.strip());
            }
        }

        self.textLayout.addTextDone(self.data().options.strip());

        {
            // reset selection
            var count: usize = 0;
            var bytes: usize = 0;
            var sel = self.textLayout.selection;
            var sstart: ?usize = null;
            var scursor: ?usize = null;
            var send: ?usize = null;
            // NOTE: We assume that all text in the area it valid utf8, loop with exit early on invalid utf8
            var utf8it = (std.unicode.Utf8View.initUnchecked(self.text[0..self.len])).iterator();
            while (utf8it.nextCodepoint()) |codepoint| {
                if (sstart == null and sel.start == count * pc.len) sstart = bytes;
                if (scursor == null and sel.cursor == count * pc.len) scursor = bytes;
                if (send == null and sel.end == count * pc.len) send = bytes;
                count += 1;
                bytes += std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
            } else {
                if (sstart == null and sel.start >= count * pc.len) sstart = bytes;
                if (scursor == null and sel.cursor >= count * pc.len) scursor = bytes;
                if (send == null and sel.end >= count * pc.len) send = bytes;
            }
            sel.start = sstart.?;
            sel.cursor = scursor.?;
            sel.end = send.?;
        }

        self.drawAfterText();
        return;
    }

    // syntax highlighting
    if (dvui.useTreeSitter) {
        if (self.init_opts.tree_sitter) |ts| {
            // parse is lazy
            var iter = ts.parse(self.data().id, "parser", self.text[0..self.len]);
            defer iter.deinit();

            iter.debug = ts.log_captures;

            // reparse if needed
            if (self.text_changed and !dvui.firstFrame(self.data().id)) {
                var edit: ?dvui.c.TSInputEdit = null;
                if (self.init_opts.cache_layout) {
                    edit = @as(dvui.c.TSInputEdit, undefined);
                    edit.?.start_byte = @intCast(self.text_changed_start);
                    edit.?.old_end_byte = @intCast(self.text_changed_end);
                    edit.?.new_end_byte = @intCast(@as(i64, @intCast(self.text_changed_end)) + self.text_changed_added);

                    edit.?.start_point = .{ .row = 0, .column = 0 };
                    edit.?.old_end_point = .{ .row = 0, .column = 0 };
                    edit.?.new_end_point = .{ .row = 0, .column = 0 };
                }

                iter.reparse(edit);
            }

            // set the bytes we need matches for
            if (self.textLayout.cacheLayoutBytes()) |clb| {
                iter.setByteRange(clb.start, clb.end);
            }

            // do all matches
            const normal_opts = self.data().options.strip();
            while (iter.next()) |h| {
                self.textLayout.addText(h.text, h.opts orelse normal_opts);
            }

            self.textLayout.addTextDone(normal_opts);
            self.drawAfterText();
            return;
        }
    }

    // simple text
    self.textLayout.addText(self.text[0..self.len], self.data().options.strip());
    self.textLayout.addTextDone(self.data().options.strip());

    self.drawAfterText();
}

pub fn drawBeforeText(self: *AlignedEntry) void {
    const focused = (self.data().id == dvui.focusedWidgetId());

    if (focused) {
        dvui.wantTextInput(self.data().borderRectScale().r.toNatural());
    }

    // set clip back to what textLayout had, so we don't draw over the scrollbars
    dvui.clipSet(self.textClip);

    if (self.init_opts.cache_layout) {
        self.textLayout.cache_layout_bytes = self.textLayout.bytesNeeded(
            self.text_changed_start,
            self.text_changed_end,
            self.text_changed_added,
        );
    }
}

pub fn drawAfterText(self: *AlignedEntry) void {
    const focused = (self.data().id == dvui.focusedWidgetId());
    if (focused) {
        self.drawCursor();
    }

    dvui.clipSet(self.prevClip);

    if (focused) {
        self.data().focusBorder();
    }
}

pub fn drawCursor(self: *AlignedEntry) void {
    var sel = self.textLayout.selectionGet(self.len);
    if (sel.empty()) {
        // the cursor can be slightly outside the textLayout clip
        dvui.clipSet(self.scrollClip);

        var crect = self.textLayout.cursor_rect.plus(.{ .x = -1 });
        crect.w = 2;
        self.textLayout.screenRectScale(crect).r.fill(.{}, .{ .color = dvui.themeGet().focus, .fade = 1.0 });
    }
}

pub fn widget(self: *AlignedEntry) Widget {
    return Widget.init(self, data, rectFor, screenRectScale, minSizeForChild);
}

pub fn data(self: *AlignedEntry) *WidgetData {
    return self.wd.validate();
}

pub fn rectFor(self: *AlignedEntry, id: dvui.Id, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
    _ = id;
    return dvui.placeIn(self.data().contentRect().justSize(), min_size, e, g);
}

pub fn screenRectScale(self: *AlignedEntry, rect: Rect) RectScale {
    return self.data().contentRectScale().rectToRectScale(rect);
}

pub fn minSizeForChild(self: *AlignedEntry, s: Size) void {
    self.data().minSizeMax(self.data().options.padSize(s));
}

pub fn textChangedRemoved(self: *AlignedEntry, start: usize, end: usize) void {
    self.textChanged(start, end, @as(i64, @intCast(start)) - @as(i64, @intCast(end)));
}

// Inserting text is at a single point in the previous frame's indexing.
pub fn textChangedAdded(self: *AlignedEntry, pos: usize, added: usize) void {
    self.textChanged(pos, pos, @intCast(added));
}

// Only needed when cache_layout is true.  We are maintaining an interval of
// bytes from last frame plus a total number added (might be negative) in that
// interval.  This is sent to textLayout so it will process at least this
// interval (plus whatever is visible).
pub fn textChanged(self: *AlignedEntry, start: usize, end: usize, added: i64) void {
    self.text_changed = true;
    if (end > self.text_changed_start) {
        // end is in current bytes, so we update it to previous frame's indexing
        var end_old: usize = undefined;
        if (self.text_changed_added >= 0) {
            end_old = end - @as(usize, @intCast(self.text_changed_added));
        } else {
            end_old = end + @as(usize, @intCast(-self.text_changed_added));
        }
        // This assumes that the current update happens after (in bytes) all
        // previous updates.  This is not exact, but will always give an
        // interval that includes all the updates.
        self.text_changed_end = @max(self.text_changed_end, end_old);
    } else {
        // before previous updates then indexing is the same
        self.text_changed_end = @max(self.text_changed_end, end);
    }

    // if we are before the previous updates then the indexing is the same
    self.text_changed_start = @min(self.text_changed_start, start);
    self.text_changed_added += added;

    if (self.textLayout.add_text_done) {
        self.edited_outside_last_frame.* = true;
    }

    //std.debug.print("textChanged {d} {d} {d}\n", .{ self.text_changed_start, self.text_changed_end, self.text_changed_added });
}

/// Return text as a slice to the backing storage.  The returned slice is
/// valid after `deinit`, and is only invalidated by events or functions that
/// change the text (like `textSet` or `paste`).
pub fn textGet(self: *const AlignedEntry) []u8 {
    return self.text[0..self.len];
}

/// Deprecated in favor of `textGet`.
pub fn getText(self: *const AlignedEntry) []u8 {
    return self.textGet();
}

pub fn textSet(self: *AlignedEntry, text: []const u8, selected: bool) void {
    self.textLayout.selection.selectAll();
    self.textTyped(text, selected);
}

pub fn textTyped(self: *AlignedEntry, new: []const u8, selected: bool) void {
    // strip out carriage returns, which we get from copy/paste on windows
    if (std.mem.findScalar(u8, new, '\r')) |idx| {
        self.textTyped(new[0..idx], selected);
        self.textTyped(new[idx + 1 ..], selected);
        return;
    }

    var sel = self.textLayout.selectionGet(self.len);
    if (!sel.empty()) {
        // delete selection
        self.textChangedRemoved(sel.start, sel.end);
        @memmove(self.text[sel.start..][0 .. self.len - sel.end], self.text[sel.end..self.len]);
        self.len -= (sel.end - sel.start);
        sel.end = sel.start;
        sel.cursor = sel.start;
    }

    const space_left = self.text.len - self.len;
    if (space_left < new.len) {
        var new_size = realloc_bin_size * (@divTrunc(self.len + new.len, realloc_bin_size) + 1);
        switch (self.init_opts.text) {
            .buffer => {},
            .buffer_dynamic => |b| {
                new_size = @min(new_size, b.limit);
                b.backing.* = b.allocator.realloc(self.text, new_size) catch |err| blk: {
                    dvui.logError(@src(), err, "{x} AlignedEntry.textTyped failed to realloc backing (current size {d}, new size {d})", .{ self.data().id, self.text.len, new_size });
                    break :blk b.backing.*;
                };
                self.text = b.backing.*;
            },
            .array_list => |al| {
                new_size = @min(new_size, al.limit);
                al.backing.ensureTotalCapacity(al.allocator, new_size) catch |err| {
                    dvui.logError(@src(), err, "{x} AlignedEntry.textTyped failed to realloc ArrayList backing (current size {d}, new size {d})", .{ self.data().id, self.text.len, new_size });
                };
                self.text = al.backing.items.ptr[0..@min(al.limit, al.backing.capacity)];
            },
            .internal => |i| {
                new_size = @min(new_size, i.limit);
                // If we are the same size then there is no work to do
                // This is important because same sized data allocations will be reused
                if (new_size != self.text.len) {
                    // NOTE: Using prev_text is safe because data is trashed and stays valid until the end of the frame
                    const prev_text = self.text;
                    dvui.dataSetSliceCopies(null, self.data().id, "_buffer", &[_]u8{0}, new_size);
                    self.text = dvui.dataGetSlice(null, self.data().id, "_buffer", []u8).?;
                    const min_len = @min(prev_text.len, self.text.len);
                    if (self.text.ptr != prev_text.ptr) {
                        @memcpy(self.text[0..min_len], prev_text[0..min_len]);
                    }
                }
            },
        }
    }
    var new_len = @min(new.len, self.text.len - self.len);

    // find start of last utf8 char
    var last: usize = new_len -| 1;
    while (last < new_len and new[last] & 0xc0 == 0x80) {
        last -|= 1;
    }

    // if the last utf8 char can't fit, don't include it
    if (last < new_len) {
        const utf8_size = std.unicode.utf8ByteSequenceLength(new[last]) catch 0;
        if (utf8_size != (new_len - last)) {
            new_len = last;
        }
    }

    // make room if we can
    if (new_len > 0 and sel.cursor + new_len < self.text.len) {
        @memmove(self.text[sel.cursor + new_len ..][0 .. self.len - sel.cursor], self.text[sel.cursor..self.len]);
    }

    if (new_len > 0) {
        self.textChangedAdded(sel.cursor, new_len);
    }

    // update our len and maintain 0 termination if possible
    self.setLen(self.len + new_len);

    // insert
    @memmove(self.text[sel.cursor..][0..new_len], new[0..new_len]);
    if (selected) {
        sel.start = sel.cursor;
        sel.cursor += new_len;
        sel.end = sel.cursor;
    } else {
        sel.cursor += new_len;
        sel.end = sel.cursor;
        sel.start = sel.cursor;
    }
    if (std.mem.findScalar(u8, new[0..new_len], '\n') != null) {
        sel.affinity = .after;
    }

    // we might have dropped to a new line, so make sure the cursor is visible
    self.textLayout.scroll_to_cursor_next_frame = true;
    dvui.refresh(null, @src(), self.data().id);
}

/// Remove all characters that not present in filter_chars.
/// Designed to run after event processing and before drawing.
pub fn filterIn(self: *AlignedEntry, filter_chars: []const u8) void {
    if (filter_chars.len == 0) {
        return;
    }

    var i: usize = 0;
    var j: usize = 0;
    const n = self.len;
    while (i < n) {
        if (std.mem.findScalar(u8, filter_chars, self.text[i]) == null) {
            self.len -= 1;
            var sel = self.textLayout.selection;
            if (sel.start > i) sel.start -= 1;
            if (sel.cursor > i) sel.cursor -= 1;
            if (sel.end > i) sel.end -= 1;
            self.text_changed = true;

            i += 1;
        } else {
            self.text[j] = self.text[i];
            i += 1;
            j += 1;
        }
    }

    if (j < self.text.len)
        self.text[j] = 0;
}

/// Remove all instances of the string needle.
/// Designed to run after event processing and before drawing.
pub fn filterOut(self: *AlignedEntry, needle: []const u8) void {
    if (needle.len == 0) {
        return;
    }

    var i: usize = 0;
    var j: usize = 0;
    const n = self.len;
    while (i < n) {
        if (std.mem.startsWith(u8, self.text[i..], needle)) {
            self.len -= needle.len;
            var sel = self.textLayout.selection;
            if (sel.start > i) sel.start -= needle.len;
            if (sel.cursor > i) sel.cursor -= needle.len;
            if (sel.end > i) sel.end -= needle.len;
            self.text_changed = true;

            i += needle.len;
        } else {
            self.text[j] = self.text[i];
            i += 1;
            j += 1;
        }
    }

    if (j < self.text.len)
        self.text[j] = 0;
}

/// Sets the new length and does fixups:
/// - add null terminator if there is space
/// - shrink allocation if needed
/// - fixup array_list backing
pub fn setLen(self: *AlignedEntry, newlen: usize) void {
    self.len = newlen;

    // add null terminator if there is space
    if (self.len < self.text.len) {
        self.text[self.len] = 0;
    }

    // shrink allocation if needed
    const needed_binds = @divTrunc(self.len, realloc_bin_size) + 1;
    const current_bins = @divTrunc(self.text.len, realloc_bin_size);
    // dvui.log.debug("TextEntry {x} needs {d} bins, has {d}", .{ self.data().id, needed_binds, current_bins });
    if (self.len == 0 or needed_binds < current_bins) {
        // we want to shrink the allocation
        const new_len = if (self.len == 0) 0 else realloc_bin_size * needed_binds;
        switch (self.init_opts.text) {
            .buffer => {},
            .buffer_dynamic => |b| {
                if (b.allocator.resize(self.text, new_len)) {
                    b.backing.*.len = new_len;
                    self.text.len = new_len;
                } else {
                    dvui.logError(@src(), std.mem.Allocator.Error.OutOfMemory, "{x} AlignedEntry.textTyped failed to realloc backing (current size {d}, new size {d})", .{ self.data().id, self.text.len, new_len });
                }
            },
            .array_list => |al| {
                if (new_len < al.backing.capacity / 2) {
                    al.backing.items.len = al.backing.capacity;
                    al.backing.shrinkAndFree(al.allocator, new_len);
                    self.text = al.backing.items.ptr[0..@min(al.limit, al.backing.capacity)];
                }
            },
            .internal => {
                // NOTE: Using prev_text is safe because data is trashed and stays valid until the end of the frame
                const prev_text = self.text;
                dvui.dataSetSliceCopies(null, self.data().id, "_buffer", &[_]u8{0}, new_len);
                self.text = dvui.dataGetSlice(null, self.data().id, "_buffer", []u8).?;
                const min_len = @min(prev_text.len, self.text.len);
                @memcpy(self.text[0..min_len], prev_text[0..min_len]);
            },
        }
    }

    // fixup array_list backing
    switch (self.init_opts.text) {
        .array_list => |al| {
            al.backing.items.len = self.len;
        },
        else => {},
    }
}

pub fn processEvent(self: *AlignedEntry, e: *Event) void {
    // scroll gets first crack, because it is logically outside the text area
    self.scroll.scroll.?.processEvent(e);
    if (e.handled) return;

    switch (e.evt) {
        .key => |ke| blk: {
            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("next_widget")) {
                e.handle(@src(), self.data());
                dvui.tabIndexNext(e.num);
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("prev_widget")) {
                e.handle(@src(), self.data());
                dvui.tabIndexPrev(e.num);
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("paste")) {
                e.handle(@src(), self.data());
                self.paste();
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("cut")) {
                e.handle(@src(), self.data());
                self.cut();
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("copy")) {
                e.handle(@src(), self.data());
                self.copy();
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("text_start")) {
                e.handle(@src(), self.data());
                self.textLayout.selection.moveCursor(0, false);
                self.textLayout.scroll_to_cursor = true;
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("text_end")) {
                e.handle(@src(), self.data());
                self.textLayout.selection.moveCursor(std.math.maxInt(usize), false);
                self.textLayout.scroll_to_cursor = true;
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("line_start")) {
                e.handle(@src(), self.data());
                if (self.textLayout.sel_move == .none) {
                    self.textLayout.sel_move = .{ .expand_pt = .{ .select = false, .which = .home } };
                }
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("line_end")) {
                e.handle(@src(), self.data());
                if (self.textLayout.sel_move == .none) {
                    self.textLayout.sel_move = .{ .expand_pt = .{ .select = false, .which = .end } };
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("word_left")) {
                e.handle(@src(), self.data());
                if (!self.textLayout.selection.empty()) {
                    self.textLayout.selection.moveCursor(self.textLayout.selection.start, false);
                } else {
                    if (self.textLayout.sel_move == .none) {
                        self.textLayout.sel_move = .{ .word_left_right = .{ .select = false } };
                    }
                    if (self.textLayout.sel_move == .word_left_right) {
                        self.textLayout.sel_move.word_left_right.count -= 1;
                    }
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("word_right")) {
                e.handle(@src(), self.data());
                if (!self.textLayout.selection.empty()) {
                    self.textLayout.selection.moveCursor(self.textLayout.selection.end, false);
                    self.textLayout.selection.affinity = .before;
                } else {
                    if (self.textLayout.sel_move == .none) {
                        self.textLayout.sel_move = .{ .word_left_right = .{ .select = false } };
                    }
                    if (self.textLayout.sel_move == .word_left_right) {
                        self.textLayout.sel_move.word_left_right.count += 1;
                    }
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_left")) {
                e.handle(@src(), self.data());
                if (!self.textLayout.selection.empty()) {
                    self.textLayout.selection.moveCursor(self.textLayout.selection.start, false);
                } else {
                    if (self.textLayout.sel_move == .none) {
                        self.textLayout.sel_move = .{ .char_left_right = .{ .select = false } };
                    }
                    if (self.textLayout.sel_move == .char_left_right) {
                        self.textLayout.sel_move.char_left_right.count -= 1;
                    }
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_right")) {
                e.handle(@src(), self.data());
                if (!self.textLayout.selection.empty()) {
                    self.textLayout.selection.moveCursor(self.textLayout.selection.end, false);
                    self.textLayout.selection.affinity = .before;
                } else {
                    if (self.textLayout.sel_move == .none) {
                        self.textLayout.sel_move = .{ .char_left_right = .{ .select = false } };
                    }
                    if (self.textLayout.sel_move == .char_left_right) {
                        self.textLayout.sel_move.char_left_right.count += 1;
                    }
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_up")) {
                e.handle(@src(), self.data());
                if (self.textLayout.sel_move == .none) {
                    self.textLayout.sel_move = .{ .cursor_updown = .{ .select = false } };
                }
                if (self.textLayout.sel_move == .cursor_updown) {
                    self.textLayout.sel_move.cursor_updown.count -= 1;
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_down")) {
                e.handle(@src(), self.data());
                if (self.textLayout.sel_move == .none) {
                    self.textLayout.sel_move = .{ .cursor_updown = .{ .select = false } };
                }
                if (self.textLayout.sel_move == .cursor_updown) {
                    self.textLayout.sel_move.cursor_updown.count += 1;
                }
                break :blk;
            }

            switch (ke.code) {
                .backspace => {
                    if (ke.action == .down or ke.action == .repeat) {
                        e.handle(@src(), self.data());
                        var sel = self.textLayout.selectionGet(self.len);
                        if (!sel.empty()) {
                            // just delete selection
                            self.textChangedRemoved(sel.start, sel.end);
                            @memmove(self.text[sel.start..][0 .. self.len - sel.end], self.text[sel.end..self.len]);
                            self.setLen(self.len - (sel.end - sel.start));
                            sel.end = sel.start;
                            sel.cursor = sel.start;
                            self.textLayout.scroll_to_cursor = true;
                        } else if (ke.matchBind("delete_prev_word")) {
                            // delete word before cursor

                            const oldcur = sel.cursor;
                            // find end of last word
                            if (sel.cursor > 0 and std.mem.findAny(u8, self.text[sel.cursor - 1 ..][0..1], " \n") != null) {
                                sel.cursor = std.mem.findLastNone(u8, self.text[0..sel.cursor], " \n") orelse 0;
                            }

                            // find start of word
                            if (std.mem.findLastAny(u8, self.text[0..sel.cursor], " \n")) |last_space| {
                                sel.cursor = last_space + 1;
                            } else {
                                sel.cursor = 0;
                            }

                            // delete from sel.cursor to oldcur
                            if (sel.cursor != oldcur) self.textChangedRemoved(sel.cursor, oldcur);
                            @memmove(self.text[sel.cursor..][0 .. self.len - oldcur], self.text[oldcur..self.len]);
                            self.setLen(self.len - (oldcur - sel.cursor));
                            sel.end = sel.cursor;
                            sel.start = sel.cursor;
                            self.textLayout.scroll_to_cursor = true;
                        } else if (sel.cursor > 0) {
                            // delete character just before cursor
                            //
                            // A utf8 char might consist of more than one byte.
                            // Find the beginning of the last byte by iterating over
                            // the string backwards. The first byte of a utf8 char
                            // does not have the pattern 10xxxxxx.
                            var i: usize = 1;
                            while (sel.cursor - i > 0 and self.text[sel.cursor - i] & 0xc0 == 0x80) : (i += 1) {}
                            self.textChangedRemoved(sel.cursor - i, sel.cursor);
                            @memmove(self.text[sel.cursor - i ..][0 .. self.len - sel.cursor], self.text[sel.cursor..self.len]);
                            self.setLen(self.len - i);
                            sel.cursor -= i;
                            sel.start = sel.cursor;
                            sel.end = sel.cursor;
                            self.textLayout.scroll_to_cursor = true;
                        }
                    }
                },
                .delete => {
                    if (ke.action == .down or ke.action == .repeat) {
                        e.handle(@src(), self.data());
                        var sel = self.textLayout.selectionGet(self.len);
                        if (!sel.empty()) {
                            // just delete selection
                            self.textChangedRemoved(sel.start, sel.end);
                            @memmove(self.text[sel.start..][0 .. self.len - sel.end], self.text[sel.end..self.len]);
                            self.setLen(self.len - (sel.end - sel.start));
                            sel.end = sel.start;
                            sel.cursor = sel.start;
                            self.textLayout.scroll_to_cursor = true;
                        } else if (ke.matchBind("delete_next_word")) {
                            // delete word after cursor

                            const oldcur = sel.cursor;
                            // find start of next word
                            if (sel.cursor < self.len and std.mem.findAny(u8, self.text[sel.cursor..][0..1], " \n") != null) {
                                sel.cursor = std.mem.findNonePos(u8, self.text, sel.cursor, " \n") orelse self.len;
                            }

                            // find end of word
                            if (std.mem.findAny(u8, self.text[sel.cursor..self.len], " \n")) |last_space| {
                                sel.cursor = sel.cursor + last_space;
                            } else {
                                sel.cursor = self.len;
                            }

                            // delete from oldcur to sel.cursor
                            if (sel.cursor != oldcur) self.textChangedRemoved(oldcur, sel.cursor);
                            @memmove(self.text[oldcur..][0 .. self.len - sel.cursor], self.text[sel.cursor..self.len]);
                            self.setLen(self.len - (sel.cursor - oldcur));
                            sel.cursor = oldcur;
                            sel.end = sel.cursor;
                            sel.start = sel.cursor;
                            self.textLayout.scroll_to_cursor = true;
                        } else if (sel.cursor < self.len) {
                            // delete the character just after the cursor
                            //
                            // A utf8 char might consist of more than one byte.
                            const ii = std.unicode.utf8ByteSequenceLength(self.text[sel.cursor]) catch 1;
                            const i = @min(ii, self.len - sel.cursor);

                            self.textChangedRemoved(sel.cursor, sel.cursor + i);
                            const remaining = self.len - (sel.cursor + i);
                            @memmove(self.text[sel.cursor..][0..remaining], self.text[sel.cursor + i ..][0..remaining]);
                            self.setLen(self.len - i);
                            self.textLayout.scroll_to_cursor = true;
                        }
                    }
                },
                .enter => {
                    if (ke.action == .down or ke.action == .repeat) {
                        e.handle(@src(), self.data());
                        if (self.init_opts.multiline) {
                            self.textTyped("\n", false);
                        } else if (ke.action == .down) {
                            self.enter_pressed = true;
                            dvui.refresh(null, @src(), self.data().id);
                        }
                    }
                },
                else => {},
            }
        },
        .text => |te| {
            switch (te.action) {
                .value => |set| {
                    e.handle(@src(), self.data());
                    var new = std.mem.sliceTo(set.txt, 0);
                    if (self.init_opts.multiline) {
                        self.textTyped(new, set.selected);
                    } else {
                        var i: usize = 0;
                        while (i < new.len) {
                            if (std.mem.findScalar(u8, new[i..], '\n')) |idx| {
                                self.textTyped(new[i..][0..idx], set.selected);
                                i += idx + 1;
                            } else {
                                self.textTyped(new[i..], set.selected);
                                break;
                            }
                        }
                    }
                },
                else => {},
            }
        },
        .mouse => |me| {
            if (me.action == .focus) {
                e.handle(@src(), self.data());
                dvui.focusWidget(self.data().id, null, e.num);
            }
        },
        else => {},
    }

    if (!e.handled) {
        self.textLayout.processEvent(e);

        if (!e.handled and e.evt == .key) {
            switch (e.evt.key.code) {
                .page_up, .page_down => {}, // handled by scroll container
                else => {
                    // Mark all remaining key events as handled. This allows
                    // checking a keybind (like "d") after the textEntry, but
                    // where textEntry will get it first.
                    e.handle(@src(), self.data());
                },
            }
        }
    }
}

pub fn paste(self: *AlignedEntry) void {
    const clip_text = dvui.clipboardText();

    if (self.init_opts.multiline) {
        self.textTyped(clip_text, false);
    } else {
        var i: usize = 0;
        while (i < clip_text.len) {
            if (std.mem.findScalar(u8, clip_text[i..], '\n')) |idx| {
                self.textTyped(clip_text[i..][0..idx], false);
                i += idx + 1;
            } else {
                self.textTyped(clip_text[i..], false);
                break;
            }
        }
    }
}

pub fn cut(self: *AlignedEntry) void {
    var sel = self.textLayout.selectionGet(self.len);
    if (!sel.empty()) {
        // copy selection to clipboard
        dvui.clipboardTextSet(self.text[sel.start..sel.end]);

        // delete selection
        self.textChangedRemoved(sel.start, sel.end);
        @memmove(self.text[sel.start..][0 .. self.len - sel.end], self.text[sel.end..self.len]);
        self.setLen(self.len - (sel.end - sel.start));
        sel.end = sel.start;
        sel.cursor = sel.start;
        self.textLayout.scroll_to_cursor = true;
    }
}

/// This could use textLayout.copy(), but that doesn't work if we have a masked
/// password field (textLayout only sees the password char).
pub fn copy(self: *AlignedEntry) void {
    var sel = self.textLayout.selectionGet(self.len);
    if (!sel.empty()) {
        // copy selection to clipboard
        dvui.clipboardTextSet(self.text[sel.start..sel.end]);
    }
}

pub fn deinit(self: *AlignedEntry) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;

    // nshell addition: undo the align shift in min-size reporting (see
    // init). The offset inflates textLayout min_size via the insert_pt
    // paths; reporting it raw would ratchet ancestor heights frame over
    // frame (linear drift for align == 1). Floors keep the pre-layout
    // options min so we never report below stock.
    {
        const m = &self.textLayout.data().min_size;
        m.w = @max(self.align_min.w, m.w - self.align_shift.w);
        m.h = @max(self.align_min.h, m.h - self.align_shift.h);
    }

    // set clip back to what textLayout had, because it might need it to set
    // the mouse cursor
    dvui.clipSet(self.textClip);
    self.textLayout.deinit();
    self.scroll.deinit();

    dvui.clipSet(self.prevClip);
    self.data().minSizeSetAndRefresh();
    self.data().minSizeReportToParent();
    dvui.parentReset(self.data().id, self.data().parent);
}

/// Drop-in mirror of `dvui.textEntry` for AlignedEntry: same
/// alloc/init/processEvents/draw sequence. `init_opts.align_x` controls
/// horizontal text alignment (0 = left/stock, 0.5 = center, 1 = right)
/// and `init_opts.align_y` the vertical one (0 = top/stock, 0.5 =
/// middle, 1 = bottom). Both single-line only.
pub fn textEntry(src: std.builtin.SourceLocation, init_opts: AlignedEntry.InitOptions, opts: dvui.Options) *AlignedEntry {
    var ret = dvui.widgetAlloc(AlignedEntry);
    ret.init(src, init_opts, opts);
    ret.processEvents();
    ret.draw();
    return ret;
}


// No test blocks here on purpose: this file is never a test-step
// root (see build.zig), and this toolchain only collects tests from
// the root file — copied upstream tests would compile but never run.
// The alignment path is type-checked with the exe build (hubFrame
// instantiates it) and behaves identically to stock dvui when align_x
// is 0; centered rendering is verified visually in the running app.
