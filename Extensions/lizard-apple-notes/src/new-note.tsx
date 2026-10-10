import { Action, ActionPanel, Form, popToRoot, showHUD } from "@raycast/api";
import { createNote } from "./notes";

export default function NewNote() {
  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Create Note"
            onSubmit={async (values: { title: string; body: string }) => {
              await createNote(values.title || "Untitled", values.body ?? "");
              await showHUD("Note created");
              await popToRoot();
            }}
          />
        </ActionPanel>
      }
    >
      <Form.TextField id="title" title="Title" placeholder="Meeting notes" />
      <Form.TextArea id="body" title="Note" placeholder="Write something…" />
    </Form>
  );
}
