import { Action, ActionPanel, Form, popToRoot, showHUD } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { create, listNames } from "./reminders";

export default function QuickReminder() {
  const { data: lists } = usePromise(listNames);
  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Add Reminder"
            onSubmit={async (values: { name: string; list: string; due?: Date | null; hasDue?: boolean }) => {
              if (!values.name) return;
              await create(values.name, values.list ?? lists?.[0] ?? "Reminders", values.hasDue && values.due ? new Date(values.due) : undefined);
              await showHUD("Reminder added");
              await popToRoot();
            }}
          />
        </ActionPanel>
      }
    >
      <Form.TextField id="name" title="Reminder" placeholder="Review PR #42" />
      <Form.Dropdown id="list" title="List">
        {(lists ?? []).map((list) => (
          <Form.Dropdown.Item key={list} value={list} title={list} />
        ))}
      </Form.Dropdown>
      <Form.Checkbox id="hasDue" label="Has a due date" />
      <Form.DatePicker id="due" title="Due" />
    </Form>
  );
}
