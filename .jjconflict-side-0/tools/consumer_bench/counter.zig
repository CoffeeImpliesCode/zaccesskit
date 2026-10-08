const std = @import("std");

// This wrapper counts requested allocator bytes, not allocator metadata or RSS.
// The benchmark uses the child allocator directly unless counting is requested.
pub const Counter = struct {
    child: std.mem.Allocator,
    stats: Stats = .{},

    pub const Stats = struct {
        allocations: u64 = 0,
        resizes: u64 = 0,
        remaps: u64 = 0,
        frees: u64 = 0,
        requested_bytes: u64 = 0,
        live_bytes: u64 = 0,
        peak_bytes: u64 = 0,
    };

    pub fn allocator(self: *Counter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn account(self: *Counter, old_len: usize, new_len: usize) void {
        self.stats.live_bytes -= old_len;
        self.stats.live_bytes += new_len;
        self.stats.peak_bytes = @max(self.stats.peak_bytes, self.stats.live_bytes);
    }

    fn alloc(
        ptr: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        self.stats.requested_bytes += len;
        const memory = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.stats.allocations += 1;
        self.account(0, len);
        return memory;
    }

    fn resize(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        self.stats.requested_bytes += new_len;
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.stats.resizes += 1;
        self.account(memory.len, new_len);
        return true;
    }

    fn remap(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        self.stats.requested_bytes += new_len;
        const new_memory = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse
            return null;
        self.stats.remaps += 1;
        self.account(memory.len, new_len);
        return new_memory;
    }

    fn free(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        self.child.rawFree(memory, alignment, ret_addr);
        self.stats.frees += 1;
        self.account(memory.len, 0);
    }
};
