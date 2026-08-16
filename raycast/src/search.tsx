import {
  Action,
  ActionPanel,
  Clipboard,
  closeMainWindow,
  Form,
  Icon,
  Image,
  List,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import {
  Entry,
  existingThumbPath,
  query,
  tag,
  tags,
  thumb,
  untag,
  use,
} from "./zclip";

// "No tag filter". Not "" — that's a value zclip would accept as a tag name.
const ALL_TAGS = "__all__";

// Namespaces the synthetic "create this tag" item; the prefix is what tells
// submit() which branch it's in, since a raw typed string looks like a real tag.
const NEW_TAG = "__new__:";

// Concurrent `zclip thumb` subprocesses in the prefetch below. Small: each is a
// spawn plus an ImageIO decode, and saturating the CPU stalls list rendering.
const POOL_SIZE = 4;

// Absent from the thumb map means "not fetched yet", which drives the detail
// pane's loading spinner.
type ThumbState = { path: string } | { error: string };

// Collapses whitespace runs so a multi-line entry occupies one row. The whole
// collapsed string goes into the title: Raycast clips and ellipsises it against
// the real pane width, which moves with the window and no constant could track.
function oneLine(s: string): string {
  const collapsed = s.replace(/\s+/g, " ").trim();
  // Raycast warns on an empty title; a whitespace-only entry collapses to "".
  return collapsed || "(whitespace)";
}

// Renders detail-pane content verbatim rather than as markdown, so a copied
// "# heading" stays what's on the clipboard. The fence runs one backtick longer
// than the longest run inside, or copied ``` would close it early and spill the
// rest out as markup.
function fenced(s: string): string {
  let longest = 0;
  for (const run of s.match(/`+/g) ?? [])
    longest = Math.max(longest, run.length);
  const fence = "`".repeat(Math.max(3, longest + 1));
  // Copying a whole line takes its terminator too, so most code entries end in
  // \n and would render a blank last line above the closing fence. Drop exactly
  // one — further trailing blank lines are real content.
  const body = s.replace(/\r?\n$/, "");
  return `${fence}\n${body}\n${fence}`;
}

// CommonMark angle-bracket destination: encodeURI escapes spaces but not
// parens, and a bare "(" in $HOME would end an ![](…) destination early.
function fileUrl(p: string): string {
  return `<file://${encodeURI(p)}>`;
}

// Resolves every already-on-disk thumbnail synchronously, so the first render
// carries its icons instead of popping them in one subprocess at a time. Marks
// each hit in `seen`, which keeps the prefetch below from re-fetching them.
function seedCachedThumbs(
  rows: Entry[],
  seen: Set<number>,
): Record<number, ThumbState> {
  const seeded: Record<number, ThumbState> = {};
  for (const e of rows) {
    if (e.kind !== "image" || seen.has(e.id)) continue;
    const path = existingThumbPath(e.id);
    if (path === undefined) continue;
    seeded[e.id] = { path };
    seen.add(e.id);
  }
  return seeded;
}

function detailMarkdown(entry: Entry, state: ThumbState | undefined): string {
  if (entry.kind === "text") return fenced(entry.content);
  if (state === undefined) return "";
  if ("error" in state)
    return `Could not load thumbnail.\n\n${fenced(state.error)}`;
  return `![](${fileUrl(state.path)})`;
}

// One form, two inputs:
//
// add:    dropdown over the live tag list plus a synthetic Create "…" item, so
//         a typo can't silently spawn a near-duplicate tag.
// remove: free text. `zclip query` exposes no per-entry tag membership, so a
//         dropdown would offer removals that are no-ops.
function TagForm({
  entry,
  mode,
  tagList,
  onMutated,
}: {
  entry: Entry;
  mode: "add" | "remove";
  tagList: string[];
  onMutated: () => void;
}) {
  const { pop } = useNavigation();
  const verb = mode === "add" ? "Add Tag" : "Remove Tag";
  const [searchText, setSearchText] = useState("");
  const [selected, setSelected] = useState("");

  // Match zclip's normalization (trim + lowercase) so typing "Work" resolves
  // to the existing `work` instead of offering to create a second one.
  const typed = searchText.trim().toLowerCase();
  const showCreate =
    mode === "add" && typed.length > 0 && !tagList.includes(typed);

  async function submit(values: { name: string }) {
    const name = (
      mode === "remove"
        ? values.name
        : selected.startsWith(NEW_TAG)
          ? selected.slice(NEW_TAG.length)
          : // Falls back to the raw search text for the window where the
            // dropdown re-selected but onChange hasn't landed.
            selected || searchText
    ).trim();
    if (!name) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Tag name is empty",
      });
      return;
    }
    try {
      await (mode === "add" ? tag : untag)(entry.id, name);
      const past = mode === "add" ? "Tagged" : "Untagged";
      await showToast({
        style: Toast.Style.Success,
        title: `${past} #${entry.id}`,
        message: name,
      });
      onMutated(); // refreshes the parent list's dropdown + entries
      pop();
    } catch (err) {
      await showToast({
        style: Toast.Style.Failure,
        title: `Failed to ${verb.toLowerCase()}`,
        message: String(err),
      });
    }
  }

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm title={verb} onSubmit={submit} />
        </ActionPanel>
      }
    >
      {mode === "add" ? (
        // No controlled `value`: the Create item's value changes per keystroke,
        // so a pinned one goes stale and Raycast warns about a selection that
        // isn't in the list. `filtering` is forced on because passing
        // onSearchTextChange implicitly turns it off, and the native fuzzy
        // match over real tags is still wanted.
        <Form.Dropdown
          id="name"
          title="Tag"
          placeholder="Search or create a tag…"
          filtering
          autoFocus
          onSearchTextChange={setSearchText}
          onChange={setSelected}
        >
          {showCreate && (
            <Form.Dropdown.Item
              key={NEW_TAG + typed}
              title={`Create "${typed}"`}
              value={NEW_TAG + typed}
              icon={Icon.Plus}
            />
          )}
          {tagList.map((t) => (
            <Form.Dropdown.Item key={t} title={t} value={t} icon={Icon.Tag} />
          ))}
        </Form.Dropdown>
      ) : (
        <Form.TextField
          id="name"
          title="Tag"
          placeholder="e.g. work"
          autoFocus
        />
      )}
    </Form>
  );
}

export default function Command() {
  const [entries, setEntries] = useState<Entry[]>([]);
  const [tagList, setTagList] = useState<string[]>([]);
  const [selectedTag, setSelectedTag] = useState<string>(ALL_TAGS);
  const [loading, setLoading] = useState(true);
  // Bumped after a tag/untag so both fetches below re-run.
  const [revision, setRevision] = useState(0);
  // Never cleared on a revision bump: thumbnails are immutable and keyed by
  // rowid.
  const [thumbs, setThumbs] = useState<Record<number, ThumbState>>({});
  // A ref, not state, so a second render can't slip a duplicate exec past the
  // guard before the first setThumbs lands. Tracks *requested*, not in-flight:
  // resolved ids stay marked, which is what lets the prefetch effect below
  // depend on `entries` alone.
  const requested = useRef(new Set<number>());

  // (Re)load the tag list for the dropdown.
  useEffect(() => {
    tags()
      .then(setTagList)
      .catch(() => undefined);
  }, [revision]);

  // Runs on tag change, not per keystroke: `--tag` is the only server-side
  // narrowing, and the <List> below filters the loaded set in-memory.
  useEffect(() => {
    setLoading(true);
    query(selectedTag === ALL_TAGS ? undefined : selectedTag)
      .then((rows) => {
        // Seeded outside the updater: seedCachedThumbs mutates `requested`, and
        // StrictMode double-invokes updaters — inline, the second call would
        // find every id marked, return {}, and drop the whole seed.
        const seeded = seedCachedThumbs(rows, requested.current);
        // Same tick, so React batches one render and the first frame with rows
        // already has icons. Split across ticks and the pop-in comes back.
        setThumbs((m) => ({ ...m, ...seeded }));
        setEntries(rows);
      })
      .catch((err) =>
        showToast({
          style: Toast.Style.Failure,
          title: "Failed to load zclip archive",
          message: String(err),
        }),
      )
      .finally(() => setLoading(false));
  }, [selectedTag, revision]);

  // Materialises what the seed above couldn't — an image copied since the last
  // open, or a cold cache. In the steady state this queue is empty.
  //
  // Depends on `entries` alone, never `thumbs`: resolving one thumbnail
  // re-renders, so a `thumbs` dep would re-enter and spawn a fresh pool every
  // time. `requested` is what makes the queue idempotent.
  useEffect(() => {
    const queue = entries.filter(
      (e) => e.kind === "image" && !requested.current.has(e.id),
    );
    if (queue.length === 0) return;
    for (const e of queue) requested.current.add(e.id);

    // Never cancel on cleanup. Thumbnails are immutable and keyed by rowid, so
    // a late result is still correct, and React 18 no-ops a setState after
    // unmount. Cancelling is what broke this before: any effect re-run
    // (StrictMode, a tag switch mid-prefetch) discarded the in-flight batch
    // while its ids stayed marked in `requested`, so exactly POOL_SIZE rows
    // kept the placeholder icon forever.
    async function worker() {
      for (let e = queue.shift(); e; e = queue.shift()) {
        const id = e.id;
        try {
          const path = await thumb(id);
          setThumbs((m) => ({ ...m, [id]: { path } }));
        } catch (err) {
          // Stays marked requested — a thumb that failed once (unlinked
          // original, bad rowid) fails the same way every retry.
          setThumbs((m) => ({ ...m, [id]: { error: String(err) } }));
        }
      }
    }
    for (let i = 0; i < POOL_SIZE; i++) void worker();
  }, [entries]);

  async function paste(entry: Entry) {
    // Bumps recency and writes to the pasteboard with the origin marker.
    await use(entry.id).catch(() => undefined);
    // Images have no `content`; Raycast pastes them from the original on disk.
    await Clipboard.paste(
      entry.kind === "text" ? entry.content : { file: entry.path },
    );
    // Invalidate so the just-used entry shows at the top next open — Raycast
    // may keep the command warm and skip a remount.
    setRevision((r) => r + 1);
    await closeMainWindow();
  }

  return (
    <List
      isLoading={loading}
      isShowingDetail
      searchBarPlaceholder="Search clipboard history…"
      searchBarAccessory={
        <List.Dropdown
          tooltip="Filter by tag"
          value={selectedTag}
          onChange={setSelectedTag}
        >
          <List.Dropdown.Item title="All tags" value={ALL_TAGS} />
          {tagList.map((t) => (
            <List.Dropdown.Item key={t} title={t} value={t} />
          ))}
        </List.Dropdown>
      }
    >
      <List.EmptyView
        icon={Icon.Clipboard}
        title={
          selectedTag === ALL_TAGS
            ? "No clipboard entries"
            : `No entries tagged "${selectedTag}"`
        }
        description={
          selectedTag === ALL_TAGS
            ? "Copy something or start the zclip daemon to populate the archive."
            : "Try a different tag or clear the filter."
        }
      />
      {entries.map((entry) => {
        const state = entry.kind === "image" ? thumbs[entry.id] : undefined;
        return (
          <List.Item
            key={entry.id}
            // Explicit id so onSelectionChange hands back something mappable.
            id={String(entry.id)}
            // Icon.Image is the placeholder until the prefetch resolves, and
            // permanently for one that failed.
            icon={
              state && "path" in state
                ? { source: state.path, mask: Image.Mask.RoundedRectangle }
                : entry.kind === "image"
                  ? Icon.Image
                  : Icon.Text
            }
            // The in-memory filter matches on title, and images carry no text,
            // so they're reachable only by typing "image" or their dimensions.
            title={
              entry.kind === "image"
                ? `Image (${entry.width}x${entry.height})`
                : oneLine(entry.content)
            }
            detail={
              <List.Item.Detail
                isLoading={entry.kind === "image" && state === undefined}
                markdown={detailMarkdown(entry, state)}
              />
            }
            actions={
              <ActionPanel>
                <Action title="Paste" onAction={() => paste(entry)} />
                <Action.CopyToClipboard
                  title="Copy to Clipboard"
                  content={
                    entry.kind === "text" ? entry.content : { file: entry.path }
                  }
                />
                <Action.Push
                  title="Add Tag"
                  icon={Icon.Tag}
                  shortcut={{ modifiers: ["cmd"], key: "t" }}
                  target={
                    <TagForm
                      entry={entry}
                      mode="add"
                      tagList={tagList}
                      onMutated={() => setRevision((r) => r + 1)}
                    />
                  }
                />
                <Action.Push
                  title="Remove Tag"
                  icon={Icon.Tag}
                  shortcut={{ modifiers: ["cmd", "shift"], key: "t" }}
                  target={
                    <TagForm
                      entry={entry}
                      mode="remove"
                      tagList={tagList}
                      onMutated={() => setRevision((r) => r + 1)}
                    />
                  }
                />
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
