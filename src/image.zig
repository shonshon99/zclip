//! Pasteboard image bytes → (original dimensions, downscaled PNG thumbnail).
//!
//! Uses ImageIO's CGImageSource, which decodes and downscales in one pass and
//! never materialises the full-size bitmap. The AppKit route (NSImage +
//! NSBitmapImageRep) would need msgSend calls returning NSSize/NSRect structs,
//! which take the sret ABI path — avoidable risk for no gain.
//!
//! **The C symbols below are declared by hand, not via translate-c.** This is
//! the one place in the codebase that departs from the `src/sqlite_c.h` +
//! `b.addTranslateC` convention, because the Apple SDK headers do not survive
//! translate-c:
//!   1. CGColorSpace.h writes `CGFloat whitePoint[CG_NONNULL_ARRAY 3]`, and
//!      clang hard-errors on a nullability specifier inside an array bound.
//!      Fixable by `#undef`ing the nullability macros in a shim.
//!   2. CGPath.h then declares `typedef void (^CGPathApplyBlock)(...)`
//!      unguarded, and blocks require clang's `-fblocks`. Not fixable:
//!      `std.Build.Step.TranslateC` exposes include paths and `-D` macros and
//!      nothing else, so the flag cannot be passed. Narrowing the includes
//!      doesn't help either — CGPath.h arrives transitively via CGImage.h.
//!
//! Hand-declaring ~20 symbols also pins exactly what we depend on, so an SDK
//! bump can't silently change the surface. Frameworks are linked in build.zig.
//!
//! CoreFoundation ownership rules govern the rest of the file: a "Create" or
//! "Copy" in the name means we own the result and must `CFRelease` it; "Get"
//! means we borrow and must not.

const std = @import("std");

// ---- CoreFoundation / ImageIO FFI -------------------------------------------

// Every CF/CG object is an opaque pointer. Keeping them as bare `anyopaque`
// aliases (rather than distinct opaque types) is what lets the CFStringRef
// constants drop straight into the `?*const anyopaque` arrays that
// CFDictionaryCreate wants, with no @ptrCast at any call site.
const CFTypeRef = ?*const anyopaque;
const CFAllocatorRef = ?*const anyopaque;
const CFStringRef = ?*const anyopaque;
const CFDataRef = ?*const anyopaque;
const CFMutableDataRef = ?*anyopaque;
const CFDictionaryRef = ?*const anyopaque;
const CFNumberRef = ?*const anyopaque;
const CGImageSourceRef = ?*anyopaque;
const CGImageRef = ?*anyopaque;
const CGImageDestinationRef = ?*anyopaque;

const CFIndex = c_long;
const CFNumberType = CFIndex;
const CFStringEncoding = u32;
// CF's `Boolean` is `unsigned char`, not C99 `_Bool` — a Zig `bool` here would
// be the wrong ABI. CoreGraphics entry points do use real `bool`.
const Boolean = u8;

// From CFNumber.h's CFNumberType enum.
const kCFNumberSInt64Type: CFNumberType = 4;
const kCFNumberIntType: CFNumberType = 9;
const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

// `extern var` rather than `extern const`: these are ordinary globals in the
// dylib holding a pointer value, and we only ever read them.
extern "c" var kCFAllocatorNull: CFAllocatorRef;
extern "c" var kCFBooleanTrue: CFTypeRef;
extern "c" var kCGImageSourceCreateThumbnailFromImageAlways: CFStringRef;
extern "c" var kCGImageSourceCreateThumbnailWithTransform: CFStringRef;
extern "c" var kCGImageSourceThumbnailMaxPixelSize: CFStringRef;
extern "c" var kCGImagePropertyPixelWidth: CFStringRef;
extern "c" var kCGImagePropertyPixelHeight: CFStringRef;

extern "c" fn CFRelease(cf: CFTypeRef) void;
extern "c" fn CFDataCreateWithBytesNoCopy(
    allocator: CFAllocatorRef,
    bytes: [*]const u8,
    length: CFIndex,
    bytes_deallocator: CFAllocatorRef,
) CFDataRef;
extern "c" fn CFDataCreateMutable(allocator: CFAllocatorRef, capacity: CFIndex) CFMutableDataRef;
extern "c" fn CFDataGetBytePtr(data: CFDataRef) [*]const u8;
extern "c" fn CFDataGetLength(data: CFDataRef) CFIndex;
extern "c" fn CFStringCreateWithCString(
    allocator: CFAllocatorRef,
    c_str: [*:0]const u8,
    encoding: CFStringEncoding,
) CFStringRef;
extern "c" fn CFNumberCreate(
    allocator: CFAllocatorRef,
    the_type: CFNumberType,
    value_ptr: *const anyopaque,
) CFNumberRef;
extern "c" fn CFNumberGetValue(
    number: CFNumberRef,
    the_type: CFNumberType,
    value_ptr: *anyopaque,
) Boolean;
extern "c" fn CFDictionaryCreate(
    allocator: CFAllocatorRef,
    keys: [*]const ?*const anyopaque,
    values: [*]const ?*const anyopaque,
    num_values: CFIndex,
    key_callbacks: ?*const anyopaque,
    value_callbacks: ?*const anyopaque,
) CFDictionaryRef;
extern "c" fn CFDictionaryGetValue(dict: CFDictionaryRef, key: ?*const anyopaque) ?*const anyopaque;

extern "c" fn CGImageSourceCreateWithData(data: CFDataRef, options: CFDictionaryRef) CGImageSourceRef;
extern "c" fn CGImageSourceCopyPropertiesAtIndex(
    src: CGImageSourceRef,
    index: usize,
    options: CFDictionaryRef,
) CFDictionaryRef;
extern "c" fn CGImageSourceCreateThumbnailAtIndex(
    src: CGImageSourceRef,
    index: usize,
    options: CFDictionaryRef,
) CGImageRef;
extern "c" fn CGImageDestinationCreateWithData(
    data: CFMutableDataRef,
    uti: CFStringRef,
    count: usize,
    options: CFDictionaryRef,
) CGImageDestinationRef;
extern "c" fn CGImageDestinationAddImage(
    dest: CGImageDestinationRef,
    image: CGImageRef,
    properties: CFDictionaryRef,
) void;
extern "c" fn CGImageDestinationFinalize(dest: CGImageDestinationRef) bool;

// ---- Public API -------------------------------------------------------------

pub const Error = error{ DecodeFailed, EncodeFailed, OutOfMemory };

pub const Summary = struct {
    width: i64,
    height: i64,
    /// PNG bytes, owned by the caller's allocator. Its own dimensions aren't
    /// reported: they're in the PNG's IHDR chunk, so anything holding these
    /// bytes can read them without us carrying a second copy around.
    thumb: []u8,
};

/// Read `bytes`' pixel dimensions and render a PNG thumbnail whose longest
/// side is at most `max_px`. Caller owns `Summary.thumb`.
pub fn summarize(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_px: u32,
) Error!Summary {
    // NoCopy + kCFAllocatorNull: CF reads straight out of `bytes` and is told
    // not to free a buffer it doesn't own. Safe because every CF object made
    // from it is released before this returns, well inside the caller's
    // ownership of `bytes`.
    const data = CFDataCreateWithBytesNoCopy(
        null,
        bytes.ptr,
        @intCast(bytes.len),
        kCFAllocatorNull,
    ) orelse return Error.DecodeFailed;
    defer CFRelease(data);

    // A CGImageSource is a lazy handle on the container — creating it parses
    // headers only, no pixels.
    const src = CGImageSourceCreateWithData(data, null) orelse return Error.DecodeFailed;
    defer CFRelease(src);

    // Dimensions come from container metadata, so an 8000x8000 screenshot
    // costs the same here as a 16x16 icon.
    const props = CGImageSourceCopyPropertiesAtIndex(src, 0, null) orelse
        return Error.DecodeFailed;
    defer CFRelease(props);
    const width = dictInt(props, kCGImagePropertyPixelWidth) orelse return Error.DecodeFailed;
    const height = dictInt(props, kCGImagePropertyPixelHeight) orelse return Error.DecodeFailed;

    const thumb_img = try makeThumb(src, max_px);
    defer CFRelease(thumb_img);

    return .{
        .width = width,
        .height = height,
        .thumb = try encodePng(allocator, thumb_img),
    };
}

fn makeThumb(src: CGImageSourceRef, max_px: u32) Error!CGImageRef {
    var px: c_int = @intCast(max_px);
    const num = CFNumberCreate(null, kCFNumberIntType, &px) orelse return Error.DecodeFailed;
    defer CFRelease(num);

    // FromImageAlways: JPEGs often carry a tiny embedded EXIF thumbnail, and
    // without this ImageIO hands that back instead of downscaling the real
    // image. WithTransform applies the EXIF orientation so the thumbnail isn't
    // rotated relative to what the user actually copied.
    const keys = [_]?*const anyopaque{
        kCGImageSourceCreateThumbnailFromImageAlways,
        kCGImageSourceCreateThumbnailWithTransform,
        kCGImageSourceThumbnailMaxPixelSize,
    };
    const vals = [_]?*const anyopaque{ kCFBooleanTrue, kCFBooleanTrue, num };

    // Null callbacks = the dictionary stores raw pointers and does not
    // retain/release its keys or values. Legal per CFDictionary, and correct
    // here: `num` and the constants all outlive `opts`, which is released
    // first (defers unwind in reverse).
    const opts = CFDictionaryCreate(null, &keys, &vals, keys.len, null, null) orelse
        return Error.DecodeFailed;
    defer CFRelease(opts);

    // MaxPixelSize caps the *longest* side and preserves aspect ratio, so
    // there's no target rect to compute.
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts) orelse Error.DecodeFailed;
}

fn encodePng(allocator: std.mem.Allocator, img: CGImageRef) Error![]u8 {
    const out = CFDataCreateMutable(null, 0) orelse return Error.EncodeFailed;
    defer CFRelease(out);

    // The raw UTI string, not kUTTypePNG — that constant is deprecated in
    // favour of the UniformTypeIdentifiers framework, which would mean linking
    // another framework to say the same eleven characters.
    const uti = CFStringCreateWithCString(null, "public.png", kCFStringEncodingUTF8) orelse
        return Error.EncodeFailed;
    defer CFRelease(uti);

    const dest = CGImageDestinationCreateWithData(out, uti, 1, null) orelse
        return Error.EncodeFailed;
    defer CFRelease(dest);

    CGImageDestinationAddImage(dest, img, null);
    // Finalize is where encoding actually happens; AddImage only queues.
    if (!CGImageDestinationFinalize(dest)) return Error.EncodeFailed;

    // Borrowed pointer into the CFMutableData — must copy before the defer
    // above releases it.
    const ptr = CFDataGetBytePtr(out);
    const len: usize = @intCast(CFDataGetLength(out));
    return allocator.dupe(u8, ptr[0..len]) catch Error.OutOfMemory;
}

// CFDictionaryGetValue borrows (no release). CFNumberGetValue returns false on
// a lossy conversion — treated as "absent", same as a missing key.
fn dictInt(dict: CFDictionaryRef, key: CFStringRef) ?i64 {
    const v = CFDictionaryGetValue(dict, key) orelse return null;
    var out: i64 = 0;
    if (CFNumberGetValue(v, kCFNumberSInt64Type, &out) == 0) return null;
    return out;
}
