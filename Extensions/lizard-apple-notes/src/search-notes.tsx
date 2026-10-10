import { Action, ActionPanel, Detail, Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { listNotes, noteBody, showNote } from "./notes";

export default function SearchNotes() {
  const { data, isLoading } = usePromise(listNotes);
  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search Apple Notes…">
      {(data ?? []).map((note) => (
        <List.Item
          key={note.id}
          icon={Icon.Document}
          title={note.title}
          subtitle={note.folder}
          accessories={[{ date: new Date(note.modified) }]}
          actions={
            <ActionPanel>
              <Action.Push title="Read Note" icon={Icon.Eye} target={<NoteDetail id={note.id} title={note.title} />} />
              <Action title="Open in Notes" icon={Icon.ArrowRight} onAction={() => showNote(note.id)} />
              <Action.CopyToClipboard title="Copy Title" content={note.title} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}

function NoteDetail({ id, title }: { id: string; title: string }) {
  const { data, isLoading } = usePromise(noteBody, [id]);
  return (
    <Detail
      isLoading={isLoading}
      markdown={data ? data : ""}
      navigationTitle={title}
      actions={
        <ActionPanel>
          <Action title="Open in Notes" onAction={() => showNote(id)} />
          {data ? <Action.CopyToClipboard title="Copy Text" content={data} /> : null}
        </ActionPanel>
      }
    />
  );
}
