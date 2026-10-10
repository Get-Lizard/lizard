import { MenuBarExtra, Icon } from "@raycast/api";

export default function Command() {
  return (
    <MenuBarExtra icon={Icon.Bell} title="3">
      <MenuBarExtra.Section title="Inbox">
        <MenuBarExtra.Item title="One" onAction={() => {}} />
      </MenuBarExtra.Section>
    </MenuBarExtra>
  );
}
