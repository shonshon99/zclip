// Shim header consumed by build.zig's addTranslateC step.
//
// Source-level `@cImport` was deprecated in Zig 0.16 in favor of running
// translate-c through the build system. This file is the single point we
// hand to addTranslateC; the resulting generated .zig module is then
// `@import`ed from src/db.zig as `sqlite_c`.
//
// Add more SQLite-related headers here if needed (e.g. sqlite3ext.h).
#include <sqlite3.h>
