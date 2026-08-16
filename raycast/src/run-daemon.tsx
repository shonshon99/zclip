import { showToast, Toast } from "@raycast/api";
import { spawn } from "child_process";
import { binaryPath } from "./zclip";

export default async function Command() {
  // Raycast tears down the command's process on return, so the daemon must be
  // detached + unref'd to outlive it. Re-running is harmless: the pidfile lock
  // makes a second spawn exit immediately with error.WouldBlock.
  try {
    const child = spawn(binaryPath(), ["daemon"], {
      detached: true,
      stdio: "ignore",
    });
    // spawn reports a missing binary via an async 'error' event, not a throw;
    // without this listener Node escalates ENOENT to an uncaught exception and
    // crashes the command. Attach before unref().
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
    // spawn only throws synchronously on arg-validation errors.
    await showToast({
      style: Toast.Style.Failure,
      title: "Failed to start daemon",
      message: String(err),
    });
  }
}
