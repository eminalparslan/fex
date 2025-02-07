const std = @import("std");
const _sort = @import("./sort.zig");
const Item = @import("./Item.zig");

const ItemList = Item.ItemList;
const ItemError = Item.ItemError;

const SortType = _sort.SortType;

const fs = std.fs;
const mem = std.mem;
const os = std.os;

const print = std.debug.print;

const Self = @This();

root: *Item,
original_root: []const u8,
allocator: mem.Allocator,

pub fn init(allocator: mem.Allocator, root: []const u8) !Self {
    return .{
        .root = try Item.init(allocator, root),
        .original_root = root,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.root.deinit();
}

/// Sets root to current roots parent directory.
pub fn up(self: *Self) !?*Item {
    var new_root = self.root.parent() catch |err| {
        if (err == ItemError.NoParent) {
            return null;
        } else {
            return err;
        }
    };

    // Prevent memory leak, deinit orphaned children
    const index = try new_root.indexOfChild(self.root);
    if (index == null) {
        self.root.deinit();
    }

    self.root = new_root;
    return self.root;
}

/// Sets root to child in the opened tree. Everything above
/// child (new_root) is freed.
///
/// Returns new_root if child is found in tree else null.
pub fn down(self: *Self, child: *Item) !?*Item {
    const _parent = try _findParent(self.root, child);
    if (_parent == null) {
        return null;
    }

    var parent = _parent.?;
    const is_root = parent == self.root;
    parent.deinitSkipChild(child);
    if (!is_root) {
        self.root.deinit();
    }

    self.root = child;
    return self.root;
}

pub fn changeRoot(self: *Self, new_root: *Item) void {
    self.root.deinitSkipChild(new_root);
    self.root = new_root;
}

pub fn findParent(self: *Self, child: *Item) !?*Item {
    return try _findParent(self.root, child);
}

fn _findParent(parent: *Item, child: *Item) !?*Item {
    if (!parent.hasChildren()) {
        return null;
    }

    const children = try parent.children();
    for (children.items) |ch| {
        if (ch == child) {
            return parent;
        }

        if (try _findParent(ch, child)) |p| {
            return p;
        }
    }

    return null;
}

pub fn iterate(self: *Self, depth: i32, dotfiles: bool) !Iterator {
    return try Iterator.init(
        self.allocator,
        self.root,
        depth,
        dotfiles,
    );
}

pub const Iterator = struct {
    pub const Entry = struct {
        item: *Item,
        depth: usize,
        first: bool, // is first child
        last: bool, // is last child
        selected: bool = false,
    };
    const EntryList = std.ArrayList(*Entry);

    //// Itermode values:
    /// -1 : as deep as possible
    /// -2 : only if children are present
    ///  0 : do not expand
    ///  n : expand until depth `n`
    itermode: i32 = -1,
    stack: EntryList,
    allocator: mem.Allocator,
    dotfiles: bool,

    pub fn init(
        allocator: mem.Allocator,
        first: *Item,
        itermode: i32,
        dotfiles: bool,
    ) !Iterator {
        var stack = EntryList.init(allocator);
        const entry = try allocator.create(Entry);
        entry.* = .{
            .item = first,
            .depth = 0,
            .first = true,
            .last = true,
            .selected = false,
        };

        try stack.append(entry);
        return .{
            .stack = stack,
            .itermode = itermode,
            .allocator = allocator,
            .dotfiles = dotfiles,
        };
    }

    pub fn deinit(self: *Iterator) void {
        for (self.stack.items) |entry| {
            self.allocator.destroy(entry);
        }
        self.stack.deinit();
    }

    pub fn next(self: *Iterator) ?*Entry {
        if (self.stack.items.len == 0) {
            return null;
        }

        const last_or_null = self.stack.popOrNull();
        if (last_or_null) |last| {
            self.growStack(last) catch return null;
        }

        return last_or_null;
    }

    fn growStack(self: *Iterator, entry: *Entry) !void {
        // Invalid itermode value < -2
        if (self.itermode < -2) {
            return;
        }

        // Append children only if present == -2
        if (self.itermode == -2 and !entry.item.hasChildren()) {
            return;
        }

        // Don't append children deeper than configured
        if (self.itermode >= 0 and entry.depth > self.itermode) {
            return;
        }

        if (!try entry.item.isDir()) {
            return;
        }

        const children = try entry.item.children();
        var skip_count: usize = 0;
        for (0..children.items.len) |index| {
            // Required because Items are popped off the stack.
            const reverse_index = children.items.len - 1 - index;
            const item = children.items[reverse_index];

            if (skipChild(item, self.dotfiles)) {
                skip_count += 1;
                continue;
            }

            const child_entry = try self.allocator.create(Entry);
            child_entry.* = getEntry(reverse_index, entry.depth, children, skip_count);
            try self.stack.append(child_entry);
        }
    }
};

fn skipChild(item: *Item, dotfiles: bool) bool {
    if (dotfiles) {
        return false;
    }

    const name = item.name();
    if (name.len > 0 and name[0] == '.') {
        return true;
    }

    return false;
}

fn getEntry(
    index: usize,
    parent_depth: usize,
    children: ItemList,
    skip_count: usize,
) Iterator.Entry {
    return .{
        .item = children.items[index],
        .depth = parent_depth + 1,
        .first = (index -| skip_count) == 0,
        .last = index == children.items.len -| (1 + skip_count),
    };
}

pub fn sort(self: *Self, how: SortType, asc: bool) void {
    self.root.sortChildren(how, asc);
}

const testing = std.testing;
test "leaks in Manager" {
    var m = try Self.init(testing.allocator, ".");
    const r = m.root;
    _ = try m.up();
    try testing.expect(m.root != r);
    try testing.expectEqual(try m.findParent(r), m.root);

    var iter = try m.iterate(-1);
    defer iter.deinit();

    while (iter.next()) |_| continue;

    _ = try m.down(r);
    try testing.expectEqual(m.root, r);
    m.deinit();
}

test "change root free children" {
    var m = try Self.init(testing.allocator, ".");
    defer m.deinit();

    var iter = try m.iterate(-1);
    defer iter.deinit();
    while (iter.next()) |_| continue;
    _ = try m.up();
    if (try m.up()) |root| root.freeChildren(null);
}
