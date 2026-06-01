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
import { useEffect, useState } from "react";
import { Entry, query, tag, tags, untag, use } from "./zclip";

// Sentinel dropdown value meaning "no tag filter" — empty string would be a
// valid tag name to zclip, so use a value tags can't take.
const ALL_TAGS = "__all__";

// One free-text form serves both tag and untag. The name is typed (not picked
// from a list) because the operations take an arbitrary name: add may create a
// brand-new tag, and remove may target a tag not in the current filtered set.
function TagForm({ entry, mode, onMutated }: { entry: Entry; mode: "add" | "remove"; onMutated: () => void }) {
  const { pop } = useNavigation();
  const verb = mode === "add" ? "Add Tag" : "Remove Tag";

  async function submit(values: { name: string }) {
    const name = values.name.trim();
    if (!name) {
      await showToast({ style: Toast.Style.Failure, title: "Tag name is empty" });
      return;
    }
    try {
      await (mode === "add" ? tag : untag)(entry.id, name);
      const past = mode === "add" ? "Tagged" : "Untagged";
      await showToast({ style: Toast.Style.Success, title: `${past} #${entry.id}`, message: name });
      onMutated(); // refresh dropdown + entries in the parent list
      pop();
    } catch (err) {
      await showToast({ style: Toast.Style.Failure, title: `Failed to ${verb.toLowerCase()}`, message: String(err) });
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
      <Form.TextField id="name" title="Tag" placeholder="e.g. work" autoFocus />
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

  // (Re)load the tag list for the dropdown.
  useEffect(() => {
    tags().then(setTagList).catch(() => undefined);
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

  async function paste(entry: Entry) {
    // Record the use (bumps recency, writes to pasteboard with origin marker)…
    await use(entry.id).catch(() => undefined);
    // …then paste the content into the frontmost app and dismiss Raycast.
    await Clipboard.paste(entry.content);
    // Invalidate the fetch so the next time this command opens, the just-used
    // entry shows at the top (zclip use bumped its copied_at). Guards against
    // Raycast keeping the command "warm" and skipping a remount.
    setRevision((r) => r + 1);
    await closeMainWindow();
  }

  return (
    <List
      isLoading={loading}
      searchBarPlaceholder="Search clipboard history…"
      searchBarAccessory={
        <List.Dropdown tooltip="Filter by tag" value={selectedTag} onChange={setSelectedTag}>
          <List.Dropdown.Item title="All tags" value={ALL_TAGS} />
          {tagList.map((t) => (
            <List.Dropdown.Item key={t} title={t} value={t} />
          ))}
        </List.Dropdown>
      }
    >
      {entries.map((entry) => (
        <List.Item
          key={entry.id}
          title={entry.content.replace(/\s+/g, " ").trim()}
          actions={
            <ActionPanel>
              <Action title="Paste" onAction={() => paste(entry)} />
              <Action.CopyToClipboard title="Copy to Clipboard" content={entry.content} />
              <Action.Push
                title="Add Tag"
                icon={Icon.Tag}
                shortcut={{ modifiers: ["cmd"], key: "t" }}
                target={<TagForm entry={entry} mode="add" onMutated={() => setRevision((r) => r + 1)} />}
              />
              <Action.Push
                title="Remove Tag"
                icon={Icon.Tag}
                shortcut={{ modifiers: ["cmd", "shift"], key: "t" }}
                target={<TagForm entry={entry} mode="remove" onMutated={() => setRevision((r) => r + 1)} />}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
