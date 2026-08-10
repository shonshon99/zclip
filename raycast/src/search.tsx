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

// Sentinel dropdown value meaning "no tag filter" — empty string would be a
// valid tag name to zclip, so use a value tags can't take.
const ALL_TAGS = "__all__";

// Namespaces the synthetic "create this tag" dropdown item. A raw typed string
// is indistinguishable from a real tag's value, so the prefix is what tells
// submit() which branch it's in.
const NEW_TAG = "__new__:";

// Concurrent `zclip thumb` subprocesses during the prefetch below. Small on
// purpose: each one is a process spawn plus an ImageIO decode, and saturating
// the CPU here would stall the list's own rendering.
const POOL_SIZE = 4;

// Resolved state of one entry's thumbnail. Absent from the map means "not
// fetched yet", which is what drives the detail pane's loading spinner.
type ThumbState = { path: string } | { error: string };

// Collapses every whitespace run (newlines included) so a multi-line entry
// still occupies exactly one row in the left pane. The *whole* collapsed string
// goes into the title: Raycast clips it to the pane and draws the ellipsis
// itself, so the cut tracks the real pane width — which no constant here could,
// since the width moves with the window size and the detail split.
function oneLine(s: string): string {
  const collapsed = s.replace(/\s+/g, " ").trim();
  // Raycast warns on an empty title; a whitespace-only entry collapses to "".
  return collapsed || "(whitespace)";
}

// Fences content for the detail pane so it renders verbatim rather than as
// markdown — a copied "# heading" or table stays what's actually on the
// clipboard. The fence is one backtick longer than the longest run inside the
// content, otherwise copied markdown containing ``` would close it early and
// spill the rest out as rendered markup.
function fenced(s: string): string {
  let longest = 0;
  for (const run of s.match(/`+/g) ?? [])
    longest = Math.max(longest, run.length);
  const fence = "`".repeat(Math.max(3, longest + 1));
  // Editors put the line terminator on the clipboard when you copy a whole
  // line, so most code entries already end in \n. The closing fence needs its
  // own newline, and the two together would render a blank last line — drop
  // exactly one, never more: further trailing blank lines are real content.
  const body = s.replace(/\r?\n$/, "");
  return `${fence}\n${body}\n${fence}`;
}

// CommonMark angle-bracket link destination. encodeURI escapes spaces but
// leaves parentheses alone, and a bare "(" in $HOME would otherwise terminate
// an ![](…) destination early.
function fileUrl(p: string): string {
  return `<file://${encodeURI(p)}>`;
}

// Resolves every thumbnail that's already on disk, synchronously, so the first
// render can carry its icons instead of popping them in one subprocess result
// at a time. Marks each hit in `seen` — that's what keeps the prefetch below
// from re-fetching a thumbnail we just proved exists.
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

// One form serves both tag and untag, but the input differs by mode.
//
// add:    a searchable dropdown over the live tag list, plus a synthetic
//         Create "…" item when the typed text matches no existing tag — picking
//         beats retyping, and typos can't silently spawn near-duplicate tags.
// remove: still free text. `zclip query` exposes no per-entry tag membership,
//         so we can't know which tags *this* entry carries; a dropdown of all
//         tags would offer removals that are no-ops.
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

  // Match zclip's own normalization (it trims + lowercases before storing) so
  // typing "Work" resolves to the existing `work` instead of offering to
  // create a second one.
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
            // dropdown re-selected but onChange hasn't landed yet.
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
      onMutated(); // refresh dropdown + entries in the parent list
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
        // No controlled `value`: the Create item's value changes on every
        // keystroke, so a pinned value would go stale and Raycast would warn
        // about a selection that isn't in the item list.
        //
        // `filtering` is forced true because passing onSearchTextChange
        // implicitly turns it off — we still want native fuzzy matching over
        // the real tags, and only use the text to build the Create item.
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
  // Bumped after a tag/untag so both fetches below re-run (new tag may need to
  // appear in the dropdown; current tag's entry set may have changed).
  const [revision, setRevision] = useState(0);
  // Never cleared on a revision bump: an entry's thumbnail is immutable, and
  // `zclip thumb` is keyed by the same rowid.
  const [thumbs, setThumbs] = useState<Record<number, ThumbState>>({});
  // A ref, not state, so a second render can't slip a duplicate exec past the
  // guard before the first one's setThumbs lands. Tracks *requested*, not
  // in-flight: entries already resolved into `thumbs` must stay marked, or the
  // effect below would re-queue them on its next run.
  const requested = useRef(new Set<number>());

  // (Re)load the tag list for the dropdown.
  useEffect(() => {
    tags()
      .then(setTagList)
      .catch(() => undefined);
  }, [revision]);

  // Re-fetch entries whenever the selected tag changes — this is the only
  // server-side narrowing (`zclip query --tag`). It runs on tag change, NOT
  // per keystroke: the <List> below still filters the loaded set in-memory.
  useEffect(() => {
    setLoading(true);
    query(selectedTag === ALL_TAGS ? undefined : selectedTag)
      .then((rows) => {
        // Seeded outside the updater on purpose: seedCachedThumbs mutates
        // `requested`, and StrictMode double-invokes updater functions. Called
        // inline, the second invocation would find every id already marked,
        // return {}, and silently drop the whole seed.
        const seeded = seedCachedThumbs(rows, requested.current);
        // Both setStates land in one tick, so React batches them into a single
        // render and the first frame showing rows already shows their icons.
        // Split these across ticks and the pop-in comes straight back.
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

  // Materialise the thumbnails the seed above *couldn't* resolve — an image
  // copied since the last open, or a first run against a cold cache. Everything
  // already on disk was marked in `requested` before the first paint, so in the
  // steady state this queue is empty and no subprocess runs at all.
  //
  // Bounded pool because each `zclip thumb` is a subprocess and the archive is
  // unbounded by design. Only the first pass over a given entry actually
  // renders; zclip short-circuits on an existing cache file after that.
  //
  // Depends on `entries` alone, never `thumbs`: resolving one thumbnail
  // re-renders, and a `thumbs` dep would re-enter here and spawn another full
  // set of workers each time. `requested` is what makes the queue idempotent.
  useEffect(() => {
    const queue = entries.filter(
      (e) => e.kind === "image" && !requested.current.has(e.id),
    );
    if (queue.length === 0) return;
    for (const e of queue) requested.current.add(e.id);

    // No cancellation on cleanup, deliberately. A thumbnail is immutable and
    // keyed by rowid, so a result landing after a re-render, a tag switch, or
    // an unmount is still correct — and React 18 makes a setState on an
    // unmounted component a no-op, so there's nothing to leak. Dropping late
    // results is what broke this before: an effect re-run (StrictMode's
    // double-invoke, or a tag switch mid-prefetch) discarded the in-flight
    // batch, and since `requested` already had those ids, nothing re-queued
    // them — exactly POOL_SIZE rows kept the placeholder icon forever.
    async function worker() {
      for (let e = queue.shift(); e; e = queue.shift()) {
        const id = e.id;
        try {
          const path = await thumb(id);
          setThumbs((m) => ({ ...m, [id]: { path } }));
        } catch (err) {
          // Stays marked as requested — a thumb that failed once (unlinked
          // original, bad rowid) fails the same way on every retry.
          setThumbs((m) => ({ ...m, [id]: { error: String(err) } }));
        }
      }
    }
    for (let i = 0; i < POOL_SIZE; i++) void worker();
  }, [entries]);

  async function paste(entry: Entry) {
    // Record the use (bumps recency, writes to pasteboard with origin marker)…
    await use(entry.id).catch(() => undefined);
    // …then paste the content into the frontmost app and dismiss Raycast.
    // Images have no `content`; Raycast pastes them from the original on disk.
    await Clipboard.paste(
      entry.kind === "text" ? entry.content : { file: entry.path },
    );
    // Invalidate the fetch so the next time this command opens, the just-used
    // entry shows at the top (zclip use bumped its copied_at). Guards against
    // Raycast keeping the command "warm" and skipping a remount.
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
            // Explicit id so onSelectionChange hands back something we can map
            // straight back to an entry.
            id={String(entry.id)}
            // The thumbnail itself once it lands; Icon.Image is the placeholder
            // for the window before the prefetch resolves (and permanently for
            // one that failed).
            icon={
              state && "path" in state
                ? { source: state.path, mask: Image.Mask.RoundedRectangle }
                : entry.kind === "image"
                  ? Icon.Image
                  : Icon.Text
            }
            // The in-memory filter matches on title, so image entries are only
            // reachable by typing "image" or their dimensions. There is no text
            // on them to match against.
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
