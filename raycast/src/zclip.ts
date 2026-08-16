import { getPreferenceValues } from "@raycast/api";
import { execFile } from "child_process";
import { existsSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { promisify } from "util";

const execFileAsync = promisify(execFile);

interface Preferences {
  binaryPath: string;
}

// Mirrors zclip query's JSON, which serialises with emit_null_optional_fields
// off — inapplicable keys are *absent*, not null, so an image row has no
// `content` key at all. The union on `kind` makes the compiler force a check
// before either half is touched.
export type Entry =
  | { id: number; kind: "text"; content: string }
  | {
      id: number;
      kind: "image";
      width: number;
      height: number;
      // Original on disk; what `zclip use` puts back on the pasteboard.
      path: string;
      byte_len: number;
    };

export function binaryPath(): string {
  return (
    getPreferenceValues<Preferences>().binaryPath || "/usr/local/bin/zclip"
  );
}

// One-shot read of the whole archive: zclip has no server-side text search, so
// <List> filters the loaded set in-memory. `--tag` is the one server-side
// narrowing; pass undefined for everything.
export async function query(tag?: string): Promise<Entry[]> {
  const args = ["query"];
  if (tag) args.push("--tag", tag);
  const { stdout } = await execFileAsync(binaryPath(), args, {
    // Archive is unbounded by design; default pipe ceiling is 1MB.
    maxBuffer: 64 * 1024 * 1024,
  });
  return JSON.parse(stdout) as Entry[];
}

// Writes entry <id> back to the pasteboard (marked dev.zclip.origin so the
// daemon skips it) and bumps its recency.
export async function use(id: number): Promise<void> {
  await execFileAsync(binaryPath(), ["use", String(id)]);
}

// Materialises entry <id>'s thumbnail and returns its path. Bare path +
// newline, not JSON — hence trim(). Cheap on repeat calls (zclip
// short-circuits on an existing file), so no caching needed here. Rejects
// (exit 1) when <id> is a text entry or unknown.
export async function thumb(id: number): Promise<string> {
  const { stdout } = await execFileAsync(binaryPath(), ["thumb", String(id)]);
  return stdout.trim();
}

// Duplicates src/main.zig's storageDir + runThumb's cache/<id>.png convention.
// The price buys a synchronous stat instead of a subprocess, so the list paints
// icons in the same frame as its rows; diverge from main.zig and every stat
// misses silently. Same recycled-rowid caveat as the Zig side.
function cachedThumbPath(id: number): string {
  return join(homedir(), ".local", "share", "zclip", "cache", `${id}.png`);
}

// The cached thumbnail's path, or undefined on first sighting of an entry (the
// caller falls back to `thumb`). Blocking stat, one per image row: negligible
// at hundreds, ~25ms at several thousand.
export function existingThumbPath(id: number): string | undefined {
  const p = cachedThumbPath(id);
  return existsSync(p) ? p : undefined;
}

// Attaches one tag to an entry. zclip trims + lowercases the name itself.
export async function tag(id: number, name: string): Promise<void> {
  await execFileAsync(binaryPath(), ["tag", String(id), name]);
}

// Removes one tag from an entry. No-op if the entry didn't carry it.
export async function untag(id: number, name: string): Promise<void> {
  await execFileAsync(binaryPath(), ["untag", String(id), name]);
}

// All tag names (alphabetical) — populates the search dropdown.
export async function tags(): Promise<string[]> {
  const { stdout } = await execFileAsync(binaryPath(), ["tags"]);
  return JSON.parse(stdout) as string[];
}
