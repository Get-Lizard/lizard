import { Action, ActionPanel, Icon, List, open, showInFinder } from "@raycast/api";
import { readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const FOLDER = join(homedir(), ".warp", "launch_configurations");

function configurations(): string[] {
  try {
    return readdirSync(FOLDER)
      .filter((file) => file.endsWith(".yaml") || file.endsWith(".yml"))
      .map((file) => file.replace(/\.ya?ml$/, ""))
      .sort();
  } catch {
    return [];
  }
}

export default function LaunchConfigurations() {
  const names = configurations();
  return (
    <List searchBarPlaceholder="Search launch configurations…">
      <List.EmptyView
        icon={Icon.Terminal}
        title="No launch configurations"
        description="Save one in Warp (File › Save New Launch Configuration) and it appears here."
      />
      {names.map((name) => (
        <List.Item
          key={name}
          icon={Icon.Terminal}
          title={name}
          actions={
            <ActionPanel>
              <Action title="Launch" icon={Icon.Play} onAction={() => open(`warp://launch/${encodeURIComponent(name)}`)} />
              <Action title="Show File" icon={Icon.Finder} onAction={() => showInFinder(join(FOLDER, `${name}.yaml`))} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
