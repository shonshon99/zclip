//! Thin NSPasteboard wrapper that talks to macOS through the Objective-C
//! runtime.
//!
//! BIG PICTURE FOR BEGINNERS
//! -------------------------
//! macOS's clipboard lives behind a class called `NSPasteboard` in the
//! AppKit framework. AppKit is written in Objective-C — a language that's
//! essentially "C plus dynamic message dispatch".
//!
//! Every Objective-C method call, after compilation, becomes a call to
//! one specific C function: `objc_msgSend(receiver, selector, args...)`.
//! The Objective-C runtime is itself a C library (`libobjc.dylib`) that
//! exposes Obj-C objects to the outside world through a C ABI.
//!
//! So when the Obj-C programmer writes:
//!     NSPasteboard *pb = [NSPasteboard generalPasteboard];
//! the compiler emits something like:
//!     pb = objc_msgSend(objc_getClass("NSPasteboard"),
//!                       sel_registerName("generalPasteboard"));
//!
//! Zig has no Obj-C compiler. We used to hand-roll those runtime calls
//! ourselves — declaring `objc_msgSend` as a void stub and casting its
//! address to a different fn-pointer type at each call site. That worked
//! but every selector added two things: a `Send*` typedef and a cast.
//!
//! Now we use mitchellh/zig-objc, which wraps `libobjc` once. The lib
//! provides:
//!   - `objc.Class`           — handle to a class (e.g. NSPasteboard)
//!   - `objc.Object`          — handle to an instance (e.g. one NSString)
//!   - `Class.msgSend(R, sel, .{args})` / `Object.msgSend(...)`
//!         At comptime, the lib builds the right fn-pointer type from
//!         the Return type and the args tuple, then casts the underlying
//!         `objc_msgSend` symbol to that type and calls it. End result:
//!         identical machine code to what we wrote by hand, no per-site
//!         scaffolding.
//!
//! On ARM64 there's one msgSend variant. On x86_64 the lib also picks
//! `objc_msgSend_stret` / `_fpret` when needed — our hand-rolled code
//! ignored that, which would have bitten us if we ever returned a large
//! struct by value.

const std = @import("std");
const objc = @import("objc");

// ---- NSString conversion helpers --------------------------------------------
//
// Most NSPasteboard methods want `NSString *` (an Obj-C object), not a
// plain C string. To bridge, we call `[NSString stringWithUTF8String:cstr]`
// — itself just another message send, now expressed via `Class.msgSend`.

// Build an autoreleased NSString from a C string. The returned object is
// owned by the autorelease pool, so don't hold it across pool boundaries.
fn nsStringFromCStr(s: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{s});
}

// Same but takes a Zig slice. `dupeSentinel` makes a 0-terminated copy
// because the C function needs a null terminator. We free our copy right
// away; the NSString has already copied the bytes internally.
fn nsStringFromSlice(allocator: std.mem.Allocator, s: []const u8) !objc.Object {
    const z = try allocator.dupeSentinel(u8, s, 0);
    defer allocator.free(z);
    return nsStringFromCStr(z.ptr);
}

// Pull the UTF-8 bytes out of an NSString by calling `[ns UTF8String]`.
// Returns null if the NSString itself is nil.
fn cStrFromNSString(ns: objc.Object) ?[*:0]const u8 {
    if (ns.value == null) return null;
    return ns.msgSend([*:0]const u8, "UTF8String", .{});
}

// ---- Public API: the Pasteboard wrapper -------------------------------------

pub const Pasteboard = struct {
    // One field: the underlying Obj-C pasteboard object handle. `objc.Object`
    // wraps the raw `id` (nullable pointer) and adds the `.msgSend` method.
    pb: objc.Object,

    // Constants visible to other files as `Pasteboard.origin_type`, etc.
    /// Custom pasteboard type set on entries written by `zclip use` so the
    /// daemon can ignore its own writes (preventing a feedback loop).
    pub const origin_type: [*:0]const u8 = "dev.zclip.origin";

    /// Convention used by 1Password, Bitwarden, Keychain etc. to mark
    /// sensitive items that history tools should not retain.
    pub const concealed_type: [*:0]const u8 = "org.nspasteboard.ConcealedType";

    /// `NSPasteboardTypeString` resolves to this UTI at runtime.
    pub const string_type: [*:0]const u8 = "public.utf8-plain-text";

    /// Static factory method — Objective-C equivalent:
    ///     NSPasteboard *pb = [NSPasteboard generalPasteboard];
    ///
    /// `objc.getClass` returns `?objc.Class`. The `.?` unwraps the optional
    /// and panics if NSPasteboard is missing — a missing AppKit class is a
    /// linker/SDK bug, not a runtime condition we can recover from.
    pub fn general() Pasteboard {
        const NSPasteboard = objc.getClass("NSPasteboard").?;
        const pb = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});
        return .{ .pb = pb };
    }

    /// Wraps `[pb changeCount]`. The pasteboard increments this integer
    /// every time something is written to it, so it's the cheapest way to
    /// detect "did anything change?" without reading the content.
    pub fn changeCount(self: Pasteboard) i64 {
        // `@intCast` converts between integer types when the value fits
        // at runtime (panics in debug builds if it doesn't). Here
        // c_long → i64. On 64-bit macOS they're the same size, but
        // c_long's width is platform-dependent so the cast is explicit.
        return @intCast(self.pb.msgSend(c_long, "changeCount", .{}));
    }

    /// Returns true if any of the pasteboard's available types matches
    /// `wanted`. Used by `hasConcealed`/`hasOrigin`.
    ///
    /// Obj-C equivalent:
    ///     for (NSString *t in [self.pb types])
    ///         if ([t isEqualToString:wanted]) return YES;
    ///     return NO;
    pub fn hasType(self: Pasteboard, wanted: [*:0]const u8) bool {
        const wanted_ns = nsStringFromCStr(wanted);

        // `[self.pb types]` — get the NSArray of type identifiers.
        const types = self.pb.msgSend(objc.Object, "types", .{});
        if (types.value == null) return false;

        // `[types count]` — length of the array.
        const count = types.msgSend(c_long, "count", .{});

        var i: c_long = 0;
        while (i < count) : (i += 1) {
            // `objectAtIndex:` is just another `msgSend`. The lib infers
            // that the arg is `c_long` from the tuple type — no per-site
            // fn-pointer cast needed.
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

    /// Returns the current plain-text content, or null if the pasteboard
    /// doesn't currently hold a string.
    ///
    /// Return type `!?[]u8` reads right-to-left:
    ///   "error union of (optional of (slice of u8))".
    /// Three layers of meaning: it might error, on success it might be
    /// null, on non-null you get owned bytes.
    pub fn readString(self: Pasteboard, allocator: std.mem.Allocator) !?[]u8 {
        const t = nsStringFromCStr(string_type);
        // [self.pb stringForType:t] → NSString *
        const ns = self.pb.msgSend(objc.Object, "stringForType:", .{t});
        const cstr = cStrFromNSString(ns) orelse return null;
        const slice = std.mem.span(cstr);
        // Critical: copy the bytes into caller-owned memory. The NSString
        // is autoreleased and could be reclaimed soon — we can't hand a
        // pointer into its storage back to the caller.
        return try allocator.dupe(u8, slice);
    }

    /// Replaces the pasteboard contents with `content` as plain text and
    /// also tags the entry with `dev.zclip.origin` so the polling daemon
    /// recognises it as our own write and skips it.
    ///
    /// Obj-C equivalent (roughly):
    ///     [pb clearContents];
    ///     [pb setString:content forType:NSPasteboardTypeString];
    ///     [pb setString:@"1"   forType:@"dev.zclip.origin"];
    pub fn writeStringAsOrigin(self: Pasteboard, allocator: std.mem.Allocator, content: []const u8) !void {
        // clearContents returns a new changeCount (NSInteger) which we discard.
        _ = self.pb.msgSend(c_long, "clearContents", .{});

        const content_ns = try nsStringFromSlice(allocator, content);
        const string_t = nsStringFromCStr(string_type);
        self.pb.msgSend(void, "setString:forType:", .{ content_ns, string_t });

        // The origin tag — value can be anything non-empty; we just need
        // the *type* to be present so `hasOrigin()` returns true.
        const origin_ns = nsStringFromCStr("1");
        const origin_t = nsStringFromCStr(origin_type);
        self.pb.msgSend(void, "setString:forType:", .{ origin_ns, origin_t });
    }
};
