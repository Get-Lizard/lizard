import { Action, ActionPanel, Icon, List, getPreferenceValues } from "@raycast/api";
import { useEffect, useState } from "react";
import { LANGUAGES, Translation, translate } from "./lib/google";

export default function TranslateText() {
  const { target: preferred } = getPreferenceValues<{ target: string }>();
  const [text, setText] = useState("");
  const [target, setTarget] = useState(preferred || "en");
  const [result, setResult] = useState<Translation | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const input = text.trim();
    if (!input) {
      setResult(null);
      return;
    }
    const controller = new AbortController();
    const timer = setTimeout(async () => {
      setBusy(true);
      try {
        setResult(await translate(input, target, "auto", controller.signal));
      } catch {
        if (!controller.signal.aborted) setResult(null);
      } finally {
        if (!controller.signal.aborted) setBusy(false);
      }
    }, 300);
    return () => {
      controller.abort();
      clearTimeout(timer);
    };
  }, [text, target]);

  const swap = () => {
    if (!result) return;
    const from = result.detected in LANGUAGES ? result.detected : "en";
    setText(result.text);
    setTarget(from);
  };

  return (
    <List
      isLoading={busy}
      searchText={text}
      onSearchTextChange={setText}
      searchBarPlaceholder="Type something to translate…"
      searchBarAccessory={
        <List.Dropdown tooltip="Translate to" value={target} onChange={setTarget}>
          {Object.entries(LANGUAGES)
            .filter(([code]) => code !== "auto")
            .map(([code, name]) => (
              <List.Dropdown.Item key={code} value={code} title={name} />
            ))}
        </List.Dropdown>
      }
    >
      {result ? (
        <List.Item
          icon={Icon.Globe}
          title={result.text}
          subtitle={`${LANGUAGES[result.detected] ?? result.detected} → ${LANGUAGES[target] ?? target}`}
          actions={
            <ActionPanel>
              <Action.CopyToClipboard title="Copy Translation" content={result.text} />
              <Action.Paste title="Paste Translation" content={result.text} />
              <Action title="Swap Languages" icon={Icon.Repeat} onAction={swap} />
              <Action.OpenInBrowser
                title="Open in Google Translate"
                url={`https://translate.google.com/?sl=auto&tl=${target}&text=${encodeURIComponent(text)}`}
              />
            </ActionPanel>
          }
        />
      ) : (
        <List.EmptyView icon={Icon.Globe} title="Translate" description="Start typing — the language is detected for you." />
      )}
    </List>
  );
}
