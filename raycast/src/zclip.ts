import { getPreferenceValues } from "@raycast/api";
import { execFile } from "child_process";
import { promisify } from "util";

const execFileAsync = promisify(execFile);

interface Preferences {
  binaryPath: string;
}

export interface Entry {
  id: number;
  content: string;
}

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
