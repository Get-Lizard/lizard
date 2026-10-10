import { runAppleScript } from "@raycast/utils";

export interface AppleNote {
  id: string;
  title: string;
  folder: string;
  modified: string;
}

// JXA keeps the parsing simple: Notes hands back JSON we build ourselves.
const LIST = `
const Notes = Application("Notes");
const out = [];
for (const folder of Notes.folders()) {
  const name = folder.name();
  if (name === "Recently Deleted") continue;
  for (const note of folder.notes()) {
    out.push({ id: note.id(), title: note.name(), folder: name, modified: note.modificationDate().toISOString() });
  }
}
JSON.stringify(out.sort((a, b) => b.modified.localeCompare(a.modified)).slice(0, 400));
`;

export async function listNotes(): Promise<AppleNote[]> {
  return JSON.parse(await runAppleScript(LIST, { language: "JavaScript", timeout: 30000 })) as AppleNote[];
}

export async function noteBody(id: string): Promise<string> {
  const script = `Application("Notes").notes.byId(${JSON.stringify(id)}).plaintext()`;
  return runAppleScript(script, { language: "JavaScript", timeout: 15000 });
}

export async function showNote(id: string) {
  await runAppleScript(`const n = Application("Notes"); n.activate(); n.show(n.notes.byId(${JSON.stringify(id)}));`, { language: "JavaScript" });
}

export async function createNote(title: string, body: string) {
  const html = `<h1>${escape(title)}</h1>` + body.split("\n").map((line) => `<div>${escape(line) || "<br>"}</div>`).join("");
  await runAppleScript(`const n = Application("Notes"); n.make({ new: "note", withProperties: { body: ${JSON.stringify(html)} } });`, { language: "JavaScript" });
}

function escape(text: string) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
