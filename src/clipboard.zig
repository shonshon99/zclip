//! Thin NSPasteboard wrapper. Talks to AppKit via the Obj-C runtime.
//!
//! Every Obj-C method call is, at the ABI level, `objc_msgSend(receiver,
//! selector, args...)`. `mitchellh/zig-objc` wraps that: `Object.msgSend(R,
//! sel, .{args})` builds the right fn-pointer type from the Return + args
//! tuple at comptime and casts the runtime symbol to it.
//!
//! Architecture note: on ARM64 there's one msgSend entry — struct returns
//! use the sret-arg ABI. On x86_64 there are also `objc_msgSend_stret`
//! (struct return) and `_fpret` (x87 fp return); zig-objc picks the right
//! one based on Return type. The earlier hand-rolled version always called
//! plain `objc_msgSend` and would have miscompiled struct returns on x86_64.

const std = @import("std");
const objc = @import("objc");

// ---- NSString conversion helpers --------------------------------------------

// Returns an autoreleased NSString — caller must not hold past the current
// autorelease pool's deinit.
fn nsStringFromCStr(s: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{s});
}

fn nsStringFromSlice(allocator: std.mem.Allocator, s: []const u8) !objc.Object {
    const z = try allocator.dupeSentinel(u8, s, 0);
    defer allocator.free(z);
    return nsStringFromCStr(z.ptr);
}

fn cStrFromNSString(ns: objc.Object) ?[*:0]const u8 {
    if (ns.value == null) return null;
    return ns.msgSend([*:0]const u8, "UTF8String", .{});
}

// ---- Public API -------------------------------------------------------------

pub const Pasteboard = struct {
    pb: objc.Object,

    /// Custom pasteboard type set by `zclip use`. Daemon checks for this
    /// to skip its own writes (prevents feedback loop).
    pub const origin_type: [*:0]const u8 = "dev.zclip.origin";

    /// Convention used by 1Password, Bitwarden, Keychain etc. to mark
    /// sensitive items that history tools should skip.
    pub const concealed_type: [*:0]const u8 = "org.nspasteboard.ConcealedType";

    /// What `NSPasteboardTypeString` resolves to at runtime.
    pub const string_type: [*:0]const u8 = "public.utf8-plain-text";

    /// `.?` panics if NSPasteboard is missing — that's a linker/SDK bug,
    /// not a recoverable runtime condition.
    pub fn general() Pasteboard {
        const NSPasteboard = objc.getClass("NSPasteboard").?;
        const pb = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});
        return .{ .pb = pb };
    }

    /// `[pb changeCount]` — increments on every write. Cheap "did anything
    /// change?" probe without reading content.
    pub fn changeCount(self: Pasteboard) i64 {
        return @intCast(self.pb.msgSend(c_long, "changeCount", .{}));
    }

    /// Walks `[self.pb types]` looking for `wanted`.
    pub fn hasType(self: Pasteboard, wanted: [*:0]const u8) bool {
        const wanted_ns = nsStringFromCStr(wanted);

        const types = self.pb.msgSend(objc.Object, "types", .{});
        if (types.value == null) return false;

        const count = types.msgSend(c_long, "count", .{});

        var i: c_long = 0;
        while (i < count) : (i += 1) {
            const item = types.msgSend(objc.Object, "objectAtIndex:", .{i});
            if (item.msgSend(bool, "isEqualToString:", .{wanted_ns})) return true;
        }
        return false;
    }

    pub fn hasConcealed(self: Pasteboard) bool {
        return self.hasType(concealed_type);
    }

    pub fn hasOrigin(self: Pasteboard) bool {
        return self.hasType(origin_type);
    }

    /// Returns current plain-text content, or null if pasteboard holds no
    /// string. Caller owns the returned slice.
    pub fn readString(self: Pasteboard, allocator: std.mem.Allocator) !?[]u8 {
        const t = nsStringFromCStr(string_type);
        const ns = self.pb.msgSend(objc.Object, "stringForType:", .{t});
        const cstr = cStrFromNSString(ns) orelse return null;
        const slice = std.mem.span(cstr);
        // MUST copy: the NSString is autoreleased; caller can't hold a
        // pointer into its storage past the next pool drain.
        return try allocator.dupe(u8, slice);
    }

    /// Replace pasteboard contents with `content` AND tag with
    /// `dev.zclip.origin` so the daemon's poll loop skips this write.
    pub fn writeStringAsOrigin(self: Pasteboard, allocator: std.mem.Allocator, content: []const u8) !void {
        _ = self.pb.msgSend(c_long, "clearContents", .{});

        const content_ns = try nsStringFromSlice(allocator, content);
        const string_t = nsStringFromCStr(string_type);
        self.pb.msgSend(void, "setString:forType:", .{ content_ns, string_t });

        // Tag value can be anything non-empty — only the type's presence matters.
        const origin_ns = nsStringFromCStr("1");
        const origin_t = nsStringFromCStr(origin_type);
        self.pb.msgSend(void, "setString:forType:", .{ origin_ns, origin_t });
    }
};
