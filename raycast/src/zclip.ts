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
// off — inapplicable keys are *absent*, not null. So an image row has no
// `content` key at all, and a discriminated union on `kind` is what makes the
// compiler force a check before either half is touched.
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

// One-shot read of the whole archive. zclip does no server-side text search; we
// load once and let Raycast's <List> filter in-memory (the instant-fuzzy feel).
// --tag narrows the loaded set server-side; pass undefined for everything.
export async function query(tag?: string): Promise<Entry[]> {
  const args = ["query"];
  if (tag) args.push("--tag", tag);
  const { stdout } = await execFileAsync(binaryPath(), args, {
    // Archive is unbounded by design; raise the pipe ceiling well past default 1MB.
    maxBuffer: 64 * 1024 * 1024,
  });
  return JSON.parse(stdout) as Entry[];
}

// Writes entry <id> back to the pasteboard (marked dev.zclip.origin so the daemon
// skips it) and bumps its recency.
export async function use(id: number): Promise<void> {
  await execFileAsync(binaryPath(), ["use", String(id)]);
}

// Materialises entry <id>'s thumbnail into ~/.local/share/zclip/cache/<id>.png
// and returns that path. Prints a bare path + newline, not JSON — hence trim()
// rather than JSON.parse. Idempotent and cheap on repeat calls (zclip
// short-circuits on an existing file), so no caching is needed on this side.
// Rejects (exit 1) when <id> is a text entry or unknown.
export async function thumb(id: number): Promise<string> {
  const { stdout } = await execFileAsync(binaryPath(), ["thumb", String(id)]);
  return stdout.trim();
}

// Where `zclip thumb` writes, mirrored from src/main.zig (storageDir + the
// cache/<id>.png convention in runThumb). Duplicating the layout is the price
// of discovering an already-materialised thumbnail with a stat instead of a
// subprocess: the path becomes knowable synchronously, so the list can paint
// its icons in the same frame as its rows. Keep in step with main.zig — HOME is
// read directly there, with no XDG_DATA_HOME indirection to honour here.
//
// Keyed by rowid, so it carries the same caveat as the Zig side: nothing
// deletes entries today, and a future prune path must unlink these files or a
// recycled rowid will serve the previous entry's thumbnail.
function cachedThumbPath(id: number): string {
  return join(homedir(), ".local", "share", "zclip", "cache", `${id}.png`);
}

// The cached thumbnail's path, or undefined if it hasn't been materialised yet
// (first sighting of this entry — the caller falls back to `thumb`). Blocking
// stat, one per image row: negligible at hundreds, ~25ms at several thousand,
// and the archive is unbounded by design.
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
