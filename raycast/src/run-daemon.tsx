import { showToast, Toast } from "@raycast/api";
import { spawn } from "child_process";
import { binaryPath } from "./zclip";

export default async function Command() {
  // Raycast tears down a command's process when the command returns, so the
  // daemon must be detached + unref'd to outlive it. The daemon enforces single
  // instance itself (exclusive pidfile lock) — a second spawn exits immediately
  // with error.WouldBlock, so re-running this command is harmless.
  try {
    const child = spawn(binaryPath(), ["daemon"], {
      detached: true,
      stdio: "ignore",
    });
    // spawn reports a bad/missing binary via an async 'error' event, not a sync
    // throw. Without this listener Node escalates ENOENT to an uncaught
    // exception and crashes the command. Must attach before unref().
    child.on("error", (err) =>
      showToast({
        style: Toast.Style.Failure,
        title: "Failed to start daemon",
        message: String(err),
      }),
    );
    child.unref();
    await showToast({
      style: Toast.Style.Success,
      title: "zclip daemon started",
    });
  } catch (err) {
    // Belt-and-suspenders: spawn only throws sync on arg-validation errors.
    await showToast({
      style: Toast.Style.Failure,
      title: "Failed to start daemon",
      message: String(err),
    });
  }
}
