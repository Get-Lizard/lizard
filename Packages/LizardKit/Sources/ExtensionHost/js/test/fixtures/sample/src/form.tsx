import { Action, ActionPanel, Form, showToast } from "@raycast/api";

export default function Command() {
  return (
    <Form actions={<ActionPanel><Action.SubmitForm onSubmit={(v: { name: string }) => showToast({ title: `hello ${v.name}` })} /></ActionPanel>}>
      <Form.TextField id="name" title="Name" />
      <Form.Dropdown id="kind" title="Kind"><Form.Dropdown.Item value="a" title="A" /></Form.Dropdown>
    </Form>
  );
}
