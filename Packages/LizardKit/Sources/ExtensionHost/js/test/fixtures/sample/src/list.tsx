import { Action, ActionPanel, Icon, List, getPreferenceValues, showToast } from "@raycast/api";
import { useState } from "react";

export default function Command() {
  const { greeting } = getPreferenceValues<{ greeting: string }>();
  const [count, setCount] = useState(0);
  return (
    <List searchBarPlaceholder="Filter">
      <List.Section title="Things">
        <List.Item
          title={`${greeting} ${count}`}
          icon={Icon.Star}
          accessories={[{ text: "acc" }]}
          actions={
            <ActionPanel>
              <Action title="Increment" onAction={() => setCount((c) => c + 1)} />
              <Action.CopyToClipboard content="copied" />
            </ActionPanel>
          }
        />
      </List.Section>
    </List>
  );
}
