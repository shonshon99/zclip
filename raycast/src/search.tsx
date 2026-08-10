import {
  Action,
  ActionPanel,
  Clipboard,
  closeMainWindow,
  Form,
  Icon,
  List,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { Entry, query, tag, tags, thumb, untag, use } from "./zclip";

// Sentinel dropdown value meaning "no tag filter" — empty string would be a
// valid tag name to zclip, so use a value tags can't take.
const ALL_TAGS = "__all__";

// Namespaces the synthetic "create this tag" dropdown item. A raw typed string
// is indistinguishable from a real tag's value, so the prefix is what tells
// submit() which branch it's in.
const NEW_TAG = "__new__:";

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
  return `${fence}\n${s}\n${fence}`;
}

// CommonMark angle-bracket link destination. encodeURI escapes spaces but
// leaves parentheses alone, and a bare "(" in $HOME would otherwise terminate
// an ![](…) destination early.
function fileUrl(p: string): string {
  return `<file://${encodeURI(p)}>`;
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
  const [selectedId, setSelectedId] = useState<string | null>(null);
  // Never cleared on a revision bump: an entry's thumbnail is immutable, and
  // `zclip thumb` is keyed by the same rowid.
  const [thumbs, setThumbs] = useState<Record<number, ThumbState>>({});
  // A ref, not state, so a second render can't slip a duplicate exec past the
  // guard before the first one's setThumbs lands.
  const inFlight = useRef(new Set<number>());

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
      .then(setEntries)
      .catch((err) =>
        showToast({
          style: Toast.Style.Failure,
          title: "Failed to load zclip archive",
          message: String(err),
        }),
      )
      .finally(() => setLoading(false));
  }, [selectedTag, revision]);

  // Fetch the highlighted entry's thumbnail, one entry at a time. Deliberately
  // per-selection rather than eager over the whole archive: `zclip query` omits
  // the thumbnail BLOB for exactly this reason — a listing re-read on every
  // keystroke must not carry megabytes of image data.
  useEffect(() => {
    if (selectedId === null) return;
    const id = Number(selectedId);
    const entry = entries.find((e) => e.id === id);
    if (entry?.kind !== "image") return;
    if (thumbs[id] !== undefined || inFlight.current.has(id)) return;
    inFlight.current.add(id);
    thumb(id)
      .then((path) => setThumbs((m) => ({ ...m, [id]: { path } })))
      .catch((err) => setThumbs((m) => ({ ...m, [id]: { error: String(err) } })))
      .finally(() => inFlight.current.delete(id));
  }, [selectedId, entries, thumbs]);

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
      onSelectionChange={setSelectedId}
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
            icon={entry.kind === "image" ? Icon.Image : Icon.Text}
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
                    entry.kind === "text"
                      ? entry.content
                      : { file: entry.path }
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
