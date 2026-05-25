# Zig 0.16.0 — Language & Stdlib Changes

Distilled from the official release notes:
- https://ziglang.org/download/0.16.0/release-notes.html#Language-Changes
- https://ziglang.org/download/0.16.0/release-notes.html#Standard-Library

This is a quick-reference for working on **zclip** (pinned to 0.16.0). For the spec-level prose, follow the upstream links. For zclip-specific workarounds already in the code, see `CLAUDE.md` → "Critical gotchas".

---

## Why this matters for zclip

Zclip was originally drafted against 0.15.2. Bumping to 0.16.0 broke compilation in `main.zig` because the **Io refactor** stripped most syscall wrappers from `std.posix`, `std.fs`, `std.Thread`, and `std.time`. Today's workaround is to call libc extern fns directly (see `daemon.zig`, `db.zig`). The notes below explain the *why* and point to the eventual idiomatic replacements.

If you ever migrate zclip to the new `std.Io` interface fully, the relevant sections are: **I/O as an Interface**, **File System**, **Sync Primitives**, **Time**, **Process**, **"Juicy Main"**.

---

## Language Changes

### switch
Packed structs/unions usable as switch prong items. Union tag captures allowed for *all* prongs (not just inline). Decl literals permitted as switch items. Packed-type switches compare on backing integer.

```zig
const U = packed union(u2) { a: i2, b: u2 };
const u: U = .{ .a = -1 };
switch (u) {
    .{ .b = 3 } => {},
    else => unreachable,
}
```

### Equality on packed unions
Direct `==` on packed unions now works — no more wrapping in a struct.

### `@cImport` moving to build system
`@cImport` deprecated in source. Use `b.addTranslateC` in `build.zig` with a real header file.

```zig
const translate_c = b.addTranslateC(.{ .root_source_file = b.path("src/c.h") });
```

**zclip impact:** `db.zig` and `clipboard.zig` still use `@cImport`. Migrate when convenient — not urgent (still works, just deprecated).

### `@Type` → individual builtins
`@Type` replaced by `@Int`, `@Tuple`, `@Pointer`, `@Fn`, `@Struct`, `@Union`, `@Enum`, `@EnumLiteral`.

```zig
// Old: @Type(.{ .int = .{ .signedness = .unsigned, .bits = 10 } })
@Int(.unsigned, 10)
```

### Int → float coercion (when significand fits)
Integers that fit a float's significand coerce implicitly. `u24 → f32` safe; `u25 → f32` still needs `@floatFromInt`.

### Runtime vector indexes forbidden
Coerce vector → array first.

```zig
const vt = @typeInfo(@TypeOf(vector)).vector;
const arr: [vt.len]vt.child = vector;
```

### Vector ↔ array in-memory coercion removed
Use `@ptrCast` explicitly.

### Returning address of local → compile error
Previously runtime UB, now caught at comptime.

```zig
fn foo() *i32 { var x: i32 = 1234; return &x; } // error
```

### Unary float builtins forward result type
`@sqrt`, `@sin`, `@floor`, etc. propagate the result type through their argument — drop intermediate `@floatFromInt`.

```zig
const x: f64 = @sqrt(@floatFromInt(N));
```

### `@floor`/`@ceil`/`@round`/`@trunc` can produce ints directly
`@intFromFloat` deprecated.

```zig
const actual: u8 = @round(12.50); // 13
```

### Packed unions: no unused bits
Every field's `@bitSizeOf` must equal the backing integer. Pad explicitly.

### Pointers in packed structs/unions forbidden
Store as `usize` and convert with `@ptrFromInt`/`@intFromPtr`.

### Explicit backing integer on packed unions allowed
`packed union(u16) { ... }`.

### Extern contexts require explicit backing/tag types
Exported enums and packed types must annotate (`enum(u8)`, `packed struct(u8)`).

### Lazy field analysis
Struct/union/enum/opaque fields only resolved when needed. Use types as namespaces freely.

### Pointers to comptime-only types are runtime types
`*comptime_int` now runtime — enables more generic patterns.

### Aligned vs naturally-aligned pointers are distinct
`*u8` ≠ `*align(1) u8` as types, though they coerce.

### Simpler dependency-loop rules
Some prior-valid code now hits "dependency loop" errors with clearer messages.

### Zero-bit tuple fields not implicitly `comptime`
Affects code inspecting `@typeInfo(...).is_comptime`.

---

## Standard Library

### I/O as an Interface (**THE big one**)
All blocking / nondeterministic ops now require an `Io` instance passed in.

Implementations:
- `Io.Threaded` — feature-complete, supports cancelation
- `Io.Evented` — experimental M:N (no networking yet)
- `Io.Uring`, `Io.Kqueue`, `Io.Dispatch` — POC backends
- `Io.failing` — no-op for testing

**zclip impact:** zclip avoids `std.Io` entirely by calling libc. Idiomatic path is to take `io: std.Io` in `daemon.run()` and pass through. Not done — POC scope.

#### Future / Group / Cancelation / Batch
```zig
var fut = io.async(foo, .{args});
defer if (fut.cancel(io)) |r| r.deinit() else |_| {}
const result = try fut.await(io);
```
`Group` = O(1)-per-task scheduler. Cancelation surfaces `error.Canceled`. `Batch` is a low-level op-layer concurrency primitive.

#### Sync Primitives — relocated under `std.Io`
- `std.Thread.ResetEvent` → `std.Io.Event`
- `std.Thread.WaitGroup` → `std.Io.Group`
- `std.Thread.Futex` → `std.Io.Futex`
- `std.Thread.Mutex` → `std.Io.Mutex`
- `std.Thread.Condition` → `std.Io.Condition`
- `std.Thread.Semaphore` → `std.Io.Semaphore`
- `std.Thread.RwLock` → `std.Io.RwLock`
- `std.once` — **removed**

#### Entropy
`io.random()` / `io.randomSecure()`.

#### Time
- `std.time.Instant` → `std.Io.Timestamp`
- `std.time.Timer` → `std.Io.Timestamp`
- `std.time.timestamp()` → `std.Io.Timestamp.now()`
- Clock resolution queries added.

**zclip impact:** zclip uses libc `time(NULL)` because `std.time.timestamp` was removed. The Io-aware replacement is `std.Io.Timestamp.now()`.

#### File System
All `fs.*` migrated under `std.Io`. Pass `io` to operations.

```zig
file.close(io); // not file.close()
```

Major renames:
- `fs.Dir` → `std.Io.Dir`
- `fs.File` → `std.Io.File`
- `fs.Dir.makeDir` → `std.Io.Dir.createDir`
- `fs.Dir.makePath` → `std.Io.Dir.createDirPath`
- `fs.File.setEndPos` → `setLength`
- `fs.File.getEndPos` → `length`
- `fs.File.updateTimes` → `setTimestamps` / `setTimestampsNow`
- `fs.File.read` → `readStreaming`
- `fs.File.write` → `writeStreaming`

Deprecated (still works): `fs.path` → `std.Io.Dir.path`; `fs.max_path_bytes` → `std.Io.Dir.max_path_bytes`.

**Removed entirely:** all `*Z` / `*W` suffix variants (null-terminated, wide-char).

**File.MemoryMap:** content sync only at explicit sync points.

#### Networking
All `net` under `std.Io`. `Io.Evented` does not yet implement networking.

#### Process
```zig
// New spawn
var child = try std.process.spawn(io, .{
    .argv = argv,
    .stdin = .pipe, .stdout = .pipe, .stderr = .pipe,
});

// execv → replace
const err = std.process.replace(io, .{ .argv = argv });
```

#### `posix` and `os.windows` removals
**Most medium-level wrappers gone.** Pick higher-level `std.Io` *or* lower-level `std.posix.system` (raw syscalls). The middle layer is dead.

**zclip impact:** explains every "where did `std.posix.open` go?" moment. They're not coming back. Either go full Io or full libc.

---

### `heap.ArenaAllocator` → thread-safe & lock-free
Now lock-free. ~Same perf as old single-threaded version; slight speedup up to ~7 threads.

### `heap.ThreadSafeAllocator` removed
Was an anti-pattern. Allocators implement thread safety themselves.

### Deflate compression added
First-party deflate writer (`Raw`, `Huffman` variants). ~9.7% faster than zlib at default; ~1% worse ratio.

### Segfault handler / unwinding — expanded targets
Stack traces work on all major targets now. Windows resolves inline callers from debug info.

### `ucontext_t` and related removed
Deprecated POSIX control-flow gone. Define your own types for signal handler inspection.

### Debug info reworked
Default unwind = safe (uses unwind info, not frame-pointer walking).

```zig
pub const StackUnwindOptions = struct {
    first_address: ?usize = null,
    context: ?CpuContextPtr = null,
    allow_unsafe_unwind: bool = false,
};
pub fn captureCurrentStackTrace(opts, addr_buf) StackTrace;
pub fn writeCurrentStackTrace(opts, t: Io.Terminal) Writer.Error!void;
pub fn dumpCurrentStackTrace(opts) void;
```

Renames:
- `captureStackTrace` → `captureCurrentStackTrace`
- `dumpStackTraceFromBase` → `dumpCurrentStackTrace`
- `walkStackWindows` → `captureCurrentStackTrace`
- `writeStackTraceWindows` → `writeCurrentStackTrace`
- `std.debug.StackIterator` no longer `pub`

Override via `@import("root").debug.SelfInfo`.

### `std.Progress` — IPC reporting on Windows
Child process progress reporting on Windows. Max node length 40 → 120 chars.

### Windows networking without `ws2_32.dll`
Direct AFD access. Enables proper Cancelation / Batch.

### NtDll migration complete
All Windows stdlib calls go through NtDll. Only certs (kernel32, crypt32) remain external.

### "Juicy Main"
```zig
pub const Init = struct {
    minimal: Minimal,
    arena: *std.heap.ArenaAllocator,
    gpa: Allocator,
    io: Io,
    // environment, arguments, stdout, stderr, ...
};
pub fn main(init: std.process.Init) !void { ... }
```

Fallback if not using Io:
```zig
var threaded: Io.Threaded = .init_single_threaded;
const io = threaded.io();
```

**zclip impact:** zclip's `main` signature already uses this form (`pub fn main(init: std.process.Init)`).

### Env vars & process args become non-global
Access via `std.process.Init` rather than `std.os.environ` / `std.process.argsAlloc` with implicit state.

**zclip impact:** explains why `std.posix.getenv` no longer exists — env is owned by `Init`, not global.

### `mem`: `cut` functions; "index of" → `find`
New `cut` family. `indexOf*` → `find*`.

### Selective directory tree walking
Filter which subdirs to descend.

### `fs.path` Windows improvements
Better Windows path handling.

### `fs.path.relative` is pure
No longer touches cwd.

### `File.Stat.atime` optional
Some filesystems don't track atime.

### WASI preopens
Preopened directory support.

### Atomic / temp file APIs enhanced

### Memory locking / protection → `std.process`
Moved out of `std.os`.

### Cwd manipulation renamed
`fs.Dir.setAsCwd` → `std.process.setCurrentDir`.

### Containers → "unmanaged" by default
Better flexibility.

### `PriorityDequeue` added; `PriorityQueue` interface updated

### `std.Thread.Pool` removed
Use `std.Io.Group`.

### `std.builtin.subsystem` removed
Use `std.Io.Subsystem`.

### `Target.SubSystem` → `zig.Subsystem` (field renames)

### Io: `GenericReader`/`AnyReader`/`FixedBufferStream` deleted
Use concrete impls.

### `{D}` format specifier → `Io.Duration.format()` method

### `fs.getAppDataDir` removed
Use platform APIs directly.

### `Io.Writer.Allocating` tracks alignment

### `fs.Dir.readFileAlloc` / `fs.File.readToEndAlloc` updated for Io

### crypto: AES-SIV, AES-GCM-SIV added

### crypto: Ascon-AEAD, Ascon-Hash, Ascon-CHash added

### Misc additions
- `Io.Dir.renamePreserve` — rename without overwriting
- `Io.net.Socket.createPair`

### Misc removals
- `SegmentedList`
- `meta.declList`
- `Io.GenericWriter`, `Io.AnyWriter`, `Io.null_writer`, `Io.CountingReader`
- `Thread.Mutex.Recursive`

### Error renames
- `error.RenameAcrossMountPoints` → `error.CrossDevice`
- `error.NotSameFileSystem` → `error.CrossDevice`
- `error.SharingViolation` → `error.FileBusy`
- `error.EnvironmentVariableNotFound` → `error.EnvironmentVariableMissing`

### Other
- `fmt.Formatter` → `fmt.Alt`
- `fmt.format` → `std.Io.Writer.print`
- `fmt.FormatOptions` → `fmt.Options`
- `fmt.bufPrintZ` → `fmt.bufPrintSentinel`
- `compress` modules now `Io.Reader`/`Io.Writer`
- `DynLib` lost Windows support
- `math.sign` returns smallest fitting integer type
- Auto-fetch root certs on Windows
- `tar.extract` sanitizes path traversal
- `BitSet`, `EnumSet` use decl literals (not `initEmpty`/`initFull`)
