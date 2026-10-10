import { Action, ActionPanel, Color, Icon, List, open, showToast } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { complete, isDueToday, openReminders } from "./reminders";

export default function ShowReminders() {
  const { data, isLoading, revalidate } = usePromise(openReminders);
  const lists = Array.from(new Set((data ?? []).map((reminder) => reminder.list)));
  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search reminders…">
      {lists.map((list) => (
        <List.Section key={list} title={list}>
          {(data ?? [])
            .filter((reminder) => reminder.list === list)
            .map((reminder) => (
              <List.Item
                key={reminder.id}
                icon={{ source: Icon.Circle, tintColor: isDueToday(reminder) ? Color.Orange : Color.SecondaryText }}
                title={reminder.name}
                subtitle={reminder.notes ?? undefined}
                accessories={reminder.due ? [{ date: new Date(reminder.due) }] : []}
                actions={
                  <ActionPanel>
                    <Action
                      title="Mark as Done"
                      icon={Icon.CheckCircle}
                      onAction={async () => {
                        await complete(reminder.id);
                        await showToast({ title: "Done", message: reminder.name });
                        revalidate();
                      }}
                    />
                    <Action title="Open Reminders" icon={Icon.ArrowRight} onAction={() => open("x-apple-reminderkit://")} />
                  </ActionPanel>
                }
              />
            ))}
        </List.Section>
      ))}
    </List>
  );
}
