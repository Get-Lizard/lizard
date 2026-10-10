import { open, showHUD } from "@raycast/api";

export default async function OpenSlack() {
  try {
    await open("slack://open");
  } catch {
    await showHUD("Slack isn't installed");
  }
}
