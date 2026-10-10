import { runAppleScript } from "@raycast/utils";

export interface Reminder {
  id: string;
  name: string;
  list: string;
  due: string | null;
  notes: string | null;
}

const OPEN = `
const app = Application("Reminders");
const out = [];
for (const list of app.lists()) {
  const listName = list.name();
  const items = list.reminders.whose({ completed: false })();
  for (const r of items) {
    const due = r.dueDate();
    out.push({ id: r.id(), name: r.name(), list: listName, due: due ? due.toISOString() : null, notes: r.body() || null });
  }
}
JSON.stringify(out);
`;

export async function openReminders(): Promise<Reminder[]> {
  return JSON.parse(await runAppleScript(OPEN, { language: "JavaScript", timeout: 30000 })) as Reminder[];
}

export async function listNames(): Promise<string[]> {
  return JSON.parse(await runAppleScript('JSON.stringify(Application("Reminders").lists.name())', { language: "JavaScript" })) as string[];
}

export async function complete(id: string) {
  await runAppleScript(`Application("Reminders").reminders.byId(${JSON.stringify(id)}).completed = true`, { language: "JavaScript" });
}

export async function create(name: string, list: string, due?: Date) {
  const props = due ? `{ name: ${JSON.stringify(name)}, dueDate: new Date(${JSON.stringify(due.toISOString())}) }` : `{ name: ${JSON.stringify(name)} }`;
  await runAppleScript(
    `const app = Application("Reminders"); const list = app.lists.byName(${JSON.stringify(list)}); list.reminders.push(app.Reminder(${props}));`,
    { language: "JavaScript" },
  );
}

export function isDueToday(reminder: Reminder) {
  if (!reminder.due) return false;
  const end = new Date();
  end.setHours(23, 59, 59, 999);
  return new Date(reminder.due) <= end;
}
