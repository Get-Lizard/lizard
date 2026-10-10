import { Icon, MenuBarExtra, open } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { complete, isDueToday, openReminders } from "./reminders";

export default function DueToday() {
  const { data, isLoading, revalidate } = usePromise(openReminders);
  const today = (data ?? []).filter(isDueToday);
  return (
    <MenuBarExtra icon={Icon.CheckList} title={today.length ? String(today.length) : undefined} tooltip="Reminders due today" isLoading={isLoading}>
      <MenuBarExtra.Section title={today.length ? "Due today — click to complete" : "Nothing due today"}>
        {today.map((reminder) => (
          <MenuBarExtra.Item
            key={reminder.id}
            icon={Icon.Circle}
            title={reminder.name}
            subtitle={reminder.list}
            onAction={async () => {
              await complete(reminder.id);
              revalidate();
            }}
          />
        ))}
      </MenuBarExtra.Section>
      <MenuBarExtra.Section>
        <MenuBarExtra.Item title="Open Reminders" icon={Icon.ArrowRight} onAction={() => open("x-apple-reminderkit://")} />
      </MenuBarExtra.Section>
    </MenuBarExtra>
  );
}
