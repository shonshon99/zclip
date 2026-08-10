# Zclip

Search and paste from your [zclip](https://github.com/shonshon99/zclip) clipboard archive — a permanent, locally-owned clipboard history for macOS.

This extension is a thin front end over the `zclip` command-line tool. It does **not** bundle the binary; you install `zclip` yourself and point the extension at it.

## Setup

This extension requires the `zclip` binary on your machine.

1. **Build and install zclip** (Zig 0.16.0 required):

   ```sh
   git clone https://github.com/shonshon99/zclip
   cd zclip
   zig build                       # produces zig-out/bin/zclip
   cp zig-out/bin/zclip /usr/local/bin/zclip
   ```

2. **Set the binary path** (only if you installed it somewhere other than
   `/usr/local/bin/zclip`): open the extension preferences and set
   **Zclip Binary Path** to the absolute path of your `zclip` executable.

3. **Start the daemon** so new copies get recorded: run the **Run Daemon**
   command once. It detaches and keeps running in the background, enforcing a
   single instance via an exclusive pidfile lock.

## Commands

- **Search Clipboard** — loads the archive, filters in-memory as you type,
  filters by tag via the dropdown, and pastes or copies a chosen entry. Also
  supports adding (`⌘T`) and removing (`⌘⇧T`) tags.

  The view is split: the left pane shows one line per entry (text collapsed to a
  single line, images labelled `Image (WxH)`), and the right pane shows the full
  content — text verbatim in a code block, images as the thumbnail `zclip thumb`
  writes to `~/.local/share/zclip/cache/`. Thumbnails are fetched only for the
  highlighted entry, so a large archive stays cheap to browse.
- **Run Daemon** — starts the `zclip` polling daemon in the background.

## Privacy

All data stays in a single local SQLite file you own (`~/.local/share/zclip`).
The extension shells out to your local `zclip` binary only; nothing is sent off
your machine.
