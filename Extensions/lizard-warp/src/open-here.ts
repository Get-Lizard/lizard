import { open, showHUD } from "@raycast/api";
import { runAppleScript } from "@raycast/utils";
import { homedir } from "node:os";

export default async function OpenWarpHere() {
  // The folder of the front Finder window, or home when Finder has none.
  let folder = homedir();
  try {
    const path = await runAppleScript(
      'tell application "Finder" to if (count of Finder windows) > 0 then return POSIX path of (target of front Finder window as alias)',
    );
    if (path.trim()) folder = path.trim();
  } catch {
    // Finder not scriptable / no windows: use home.
  }
  await open(`warp://action/new_tab?path=${encodeURIComponent(folder)}`);
  await showHUD(`Warp: ${folder.replace(homedir(), "~")}`);
}
