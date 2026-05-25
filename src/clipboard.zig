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
//! the compiler emits:
//!     pb = objc_msgSend(objc_getClass("NSPasteboard"),
//!                       sel_registerName("generalPasteboard"));
//!
//! Zig has no Obj-C compiler. So we manually call those same C runtime
//! functions ourselves. The result is identical machine code — we just
//! type out by hand what the Obj-C compiler would have generated.
//!
//! We declare the runtime symbols ourselves rather than `@cImport`ing
//! `<objc/runtime.h>` to keep the API surface tiny and avoid
//! Objective-C header surprises through translate-c.

const std = @import("std");

// ---- Opaque types ------------------------------------------------------------
//
// `opaque {}` declares a type with unknown layout. Zig refuses to let you
// dereference, copy, or take `sizeof` of it. You can only hold pointers to
// it. This matches C's `typedef struct objc_class *Class;` pattern: we
// never look inside these structs, we just pass pointers around.
const objc_class = opaque {};
const objc_object = opaque {};
const objc_selector = opaque {};

// `Class` is a non-nullable pointer to a class.
// `Id` is a nullable pointer to an object — Objective-C methods can return
// `nil`, which we represent with Zig's optional (`?`) type.
// `Sel` is a pointer to an interned method-name token.
pub const Class = *objc_class;
pub const Id = ?*objc_object;
pub const Sel = *objc_selector;

// ---- External function declarations -----------------------------------------
//
// `extern "c" fn` is doing two things at once:
//   1. `extern`     — "this function isn't defined in our Zig source. The
//                     linker will find a symbol with this name in some
//                     shared library." Here, libobjc (pulled in via the
//                     AppKit framework link in build.zig).
//   2. `"c"`        — "use the C calling convention." On macOS that's the
//                     standard AAPCS64 / AMD64 SysV ABI. Zig is otherwise
//                     free to use its own internal calling convention.
//
// `[*:0]const u8` reads "a many-item pointer to `const u8`, sentinel-
// terminated by 0". That's a C-style `const char *`.

extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "c" fn sel_registerName(name: [*:0]const u8) Sel;

// `objc_msgSend` is the universal Objective-C method dispatcher. Its real
// signature changes per call — sometimes it takes 2 args and returns an
// object, sometimes 3 args and returns an integer, etc. C handles this
// with varargs; we handle it by casting `&objc_msgSend` to the right
// function-pointer type at each call site (see the `msg` helper below).
//
// We declare it as taking nothing and returning void here purely as a
// symbol stub — we never call it through this declaration directly.
extern "c" fn objc_msgSend() void;

// ---- Small helpers -----------------------------------------------------------

// Re-type a `Class` pointer as an `Id`. In Objective-C, classes *are*
// objects (they're instances of metaclasses), so the message receiver in
// `objc_msgSend` can be either.
fn classAsId(c: Class) Id {
    return @ptrCast(c);
}

// Look up a class, panicking if it's missing. Misspelled class names are
// a programming bug, not a runtime failure, so panic is appropriate.
fn requireClass(name: [*:0]const u8) Class {
    return objc_getClass(name) orelse std.debug.panic("Objective-C class missing: {s}", .{name});
}

// ---- msgSend signature shims ------------------------------------------------
//
// Each alias describes a possible shape of `objc_msgSend`. Read each as
// "pointer to a function with this signature, using the C calling
// convention." We use them with `@ptrCast(&objc_msgSend)` to call
// `objc_msgSend` with the right argument and return types per call site.
//
// Naming: SendABCD_E means "send takes (A, B, C, D), returns E".
//   - Id     = an Obj-C object pointer (nullable)
//   - Sel    = a selector
//   - Long   = c_long return (used for integer-returning methods)
//   - Cstr   = a `[*:0]const u8` (C string)
//   - Void   = no return value

const SendIdToId = *const fn (Id, Sel) callconv(.c) Id;
const SendIdToLong = *const fn (Id, Sel) callconv(.c) c_long;
const SendIdToVoid = *const fn (Id, Sel) callconv(.c) void;
const SendIdId_Id = *const fn (Id, Sel, Id) callconv(.c) Id;
const SendIdId_Void = *const fn (Id, Sel, Id) callconv(.c) void;
const SendIdIdId_Void = *const fn (Id, Sel, Id, Id) callconv(.c) void;
const SendIdCstr_Id = *const fn (Id, Sel, [*:0]const u8) callconv(.c) Id;
const SendIdToCstr = *const fn (Id, Sel) callconv(.c) [*:0]const u8;

// `comptime T: type` means "the parameter T is a *type*, known at compile
// time". Zig generates a separate copy of `msg` for each T we pass.
//
// `@ptrCast(&objc_msgSend)` re-interprets the address of `objc_msgSend`
// as a pointer of a different type. `@as(T, value)` then asserts that
// value coerces to T at compile time.
//
// End result: `msg(SendIdToLong)` returns `&objc_msgSend` re-typed as
// `*const fn(Id, Sel) callconv(.c) c_long`, ready to be called with that
// shape.
fn msg(comptime T: type) T {
    return @as(T, @ptrCast(&objc_msgSend));
}

// ---- NSString conversion helpers --------------------------------------------
//
// Most NSPasteboard methods want `NSString *` (an Obj-C object), not a
// plain C string. To bridge, we call `[NSString stringWithUTF8String:cstr]`
// — itself just another message send.

// Build an autoreleased NSString from a C string. The returned object is
// owned by the autorelease pool, so don't hold it across pool boundaries.
fn nsStringFromCStr(s: [*:0]const u8) Id {
    const NSString = classAsId(requireClass("NSString"));
    return msg(SendIdCstr_Id)(NSString, sel_registerName("stringWithUTF8String:"), s);
}

// Same but takes a Zig slice. `dupeZ` makes a 0-terminated copy because
// the C function needs a null terminator. We free our copy right away;
// the NSString has already copied the bytes internally.
fn nsStringFromSlice(allocator: std.mem.Allocator, s: []const u8) !Id {
    const z = try allocator.dupeZ(u8, s);
    defer allocator.free(z);
    return nsStringFromCStr(z.ptr);
}

// Pull the UTF-8 bytes out of an NSString by calling `[ns UTF8String]`.
// Returns null if the NSString itself is nil.
fn cStrFromNSString(ns: Id) ?[*:0]const u8 {
    if (ns == null) return null;
    return msg(SendIdToCstr)(ns, sel_registerName("UTF8String"));
}

// ---- Public API: the Pasteboard wrapper -------------------------------------
//
// A Zig `struct` can have data fields, `pub const` constants, and methods
// (just functions whose first parameter is `self`).

pub const Pasteboard = struct {
    // One field: the underlying Obj-C pasteboard object pointer.
    pb: Id,

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
    pub fn general() Pasteboard {
        const NSPasteboard = classAsId(requireClass("NSPasteboard"));
        const pb = msg(SendIdToId)(NSPasteboard, sel_registerName("generalPasteboard"));
        // `.{ .pb = pb }` is an anonymous struct literal. Zig infers the
        // struct type (Pasteboard) from the function return type.
        return .{ .pb = pb };
    }

    /// Wraps `[pb changeCount]`. The pasteboard increments this integer
    /// every time something is written to it, so it's the cheapest way to
    /// detect "did anything change?" without reading the content.
    pub fn changeCount(self: Pasteboard) i64 {
        // `@intCast(x)` converts between integer types when the value fits
        // at runtime (panics in debug builds if it doesn't). Here
        // c_long → i64. On 64-bit macOS they're the same size, but
        // c_long's width is platform-dependent so the cast is explicit.
        return @intCast(msg(SendIdToLong)(self.pb, sel_registerName("changeCount")));
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
        const types = msg(SendIdToId)(self.pb, sel_registerName("types"));
        if (types == null) return false;
        // `[types count]` — length of the array.
        const count = msg(SendIdToLong)(types, sel_registerName("count"));
        var i: c_long = 0;
        while (i < count) : (i += 1) {
            // One-off call shape: takes a c_long arg, returns an object.
            // Cast inline instead of adding another named alias.
            const item = @as(
                *const fn (Id, Sel, c_long) callconv(.c) Id,
                @ptrCast(&objc_msgSend),
            )(types, sel_registerName("objectAtIndex:"), i);
            // [item isEqualToString:wanted_ns] → bool.
            const eq = @as(
                *const fn (Id, Sel, Id) callconv(.c) bool,
                @ptrCast(&objc_msgSend),
            )(item, sel_registerName("isEqualToString:"), wanted_ns);
            if (eq) return true;
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
        const ns = msg(SendIdId_Id)(self.pb, sel_registerName("stringForType:"), t);
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
        _ = msg(SendIdToLong)(self.pb, sel_registerName("clearContents"));

        const content_ns = try nsStringFromSlice(allocator, content);
        const string_t = nsStringFromCStr(string_type);
        msg(SendIdIdId_Void)(
            self.pb,
            sel_registerName("setString:forType:"),
            content_ns,
            string_t,
        );

        // The origin tag — value can be anything non-empty; we just need
        // the *type* to be present so `hasOrigin()` returns true.
        const origin_ns = nsStringFromCStr("1");
        const origin_t = nsStringFromCStr(origin_type);
        msg(SendIdIdId_Void)(
            self.pb,
            sel_registerName("setString:forType:"),
            origin_ns,
            origin_t,
        );
    }
};
