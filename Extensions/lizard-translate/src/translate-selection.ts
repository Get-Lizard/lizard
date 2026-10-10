import { Clipboard, getPreferenceValues, getSelectedText, showHUD } from "@raycast/api";
import { LANGUAGES, translate } from "./lib/google";

export default async function TranslateSelection() {
  const { target } = getPreferenceValues<{ target: string }>();
  let text = "";
  try {
    text = await getSelectedText();
  } catch {
    text = (await Clipboard.readText()) ?? "";
  }
  if (!text.trim()) {
    await showHUD("Select some text first");
    return;
  }
  const result = await translate(text, target || "en");
  await Clipboard.copy(result.text);
  await showHUD(`Copied ${LANGUAGES[target] ?? target} translation`);
}
