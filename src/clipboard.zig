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

    /// A pasteboard image flavour, plus how we persist it.
    pub const ImageType = struct {
        /// Pasteboard type (UTI) to read/write bytes under.
        uti: [*:0]const u8,
        /// Stored in `images.mime`; also what maps back to a UTI on `use`.
        mime: []const u8,
        /// File extension for the original on disk.
        ext: []const u8,
    };

    /// Probe order is deliberate: a single copy usually lands on the
    /// pasteboard under several flavours at once (macOS screenshots publish
    /// both TIFF and PNG), and whichever we pick becomes the bytes we hash and
    /// archive. PNG first — lossless and far smaller than TIFF. JPEG last: it
    /// only shows up alone, from apps that publish nothing else.
    const image_types = [_]ImageType{
        .{ .uti = "public.png", .mime = "image/png", .ext = "png" },
        .{ .uti = "public.tiff", .mime = "image/tiff", .ext = "tiff" },
        .{ .uti = "public.jpeg", .mime = "image/jpeg", .ext = "jpg" },
    };

    /// First image flavour the pasteboard offers, or null if it holds none.
    pub fn imageType(self: Pasteboard) ?ImageType {
        for (image_types) |t| {
            if (self.hasType(t.uti)) return t;
        }
        return null;
    }

    /// Reverse of `imageType` for writing a stored image back out.
    pub fn imageTypeForMime(mime: []const u8) ?ImageType {
        for (image_types) |t| {
            if (std.mem.eql(u8, t.mime, mime)) return t;
        }
        return null;
    }

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

    /// Raw bytes for `ty`, or null if the pasteboard has no data under it.
    /// Caller owns the returned slice.
    pub fn readData(
        self: Pasteboard,
        allocator: std.mem.Allocator,
        ty: [*:0]const u8,
    ) !?[]u8 {
        const t = nsStringFromCStr(ty);
        const data = self.pb.msgSend(objc.Object, "dataForType:", .{t});
        if (data.value == null) return null;

        // `length` is NSUInteger; `bytes` is a `const void *` into storage the
        // autoreleased NSData owns.
        const len: usize = @intCast(data.msgSend(c_ulong, "length", .{}));
        if (len == 0) return null;
        const ptr = data.msgSend([*]const u8, "bytes", .{});
        // MUST copy, same contract as readString: the NSData is autoreleased.
        return try allocator.dupe(u8, ptr[0..len]);
    }

    /// Replace pasteboard contents with `content` AND tag with
    /// `dev.zclip.origin` so the daemon's poll loop skips this write.
    ///
    /// Returns AppKit's own verdict: `setString:forType:` answers NO when the
    /// type was never declared for the current change count, which is a real
    /// failure to put the data where the user asked. Callers must not report
    /// success on false — see `writeDataAsOrigin`.
    pub fn writeStringAsOrigin(self: Pasteboard, allocator: std.mem.Allocator, content: []const u8) !bool {
        _ = self.pb.msgSend(c_long, "clearContents", .{});
        self.markOrigin();

        const content_ns = try nsStringFromSlice(allocator, content);
        const string_t = nsStringFromCStr(string_type);
        return self.pb.msgSend(bool, "setString:forType:", .{ content_ns, string_t });
    }

    /// Image counterpart of `writeStringAsOrigin` — `bytes` go on under `ty`
    /// (the UTI the image was archived as), origin-tagged the same way.
    /// Same contract on the return value.
    pub fn writeDataAsOrigin(self: Pasteboard, bytes: []const u8, ty: [*:0]const u8) bool {
        _ = self.pb.msgSend(c_long, "clearContents", .{});
        self.markOrigin();

        const NSData = objc.getClass("NSData").?;
        // dataWithBytes:length: copies, so `bytes` need not outlive this call.
        // NSUInteger, so c_ulong. @intCast rather than a bare @as: the two are
        // the same width on every Apple target we build for, but that's a
        // target fact, not a language one.
        const data = NSData.msgSend(objc.Object, "dataWithBytes:length:", .{
            bytes.ptr,
            @as(c_ulong, @intCast(bytes.len)),
        });
        const t = nsStringFromCStr(ty);
        return self.pb.msgSend(bool, "setData:forType:", .{ data, t });
    }

    // Tag before content in both writers above: each set* bumps changeCount,
    // so the daemon can poll mid-write. Content-first would expose a
    // {content, no-tag} item it captures as its own (feedback loop).
    // Tag-first leaves only skippable transients. Value arbitrary — only the
    // type's presence matters.
    fn markOrigin(self: Pasteboard) void {
        const origin_ns = nsStringFromCStr("1");
        const origin_t = nsStringFromCStr(origin_type);
        self.pb.msgSend(void, "setString:forType:", .{ origin_ns, origin_t });
    }
};
