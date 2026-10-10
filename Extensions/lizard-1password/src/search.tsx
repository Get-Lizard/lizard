import { Action, ActionPanel, Clipboard, Icon, List, closeMainWindow, showHUD, showToast, Toast } from "@raycast/api";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { useEffect, useState } from "react";

// The 1Password CLI, unlocked through the desktop app (Touch ID) — no account keys stored anywhere.
const CANDIDATES = ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"];
const op = CANDIDATES.find((path) => existsSync(path));

interface Item {
  id: string;
  title: string;
  category: string;
  vault: { name: string };
  additional_information?: string;
  urls?: Array<{ href: string; primary?: boolean }>;
}

function run(args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    if (!op) return reject(new Error("missing"));
    execFile(op, args, { maxBuffer: 32 * 1024 * 1024, timeout: 60000 }, (error, stdout, stderr) =>
      error ? reject(new Error(stderr.trim() || error.message)) : resolve(stdout),
    );
  });
}

async function copyField(item: Item, field: "username" | "password" | "otp") {
  try {
    const value =
      field === "otp"
        ? await run(["item", "get", item.id, "--otp"])
        : await run(["item", "get", item.id, "--fields", `label=${field}`, "--reveal"]);
    await Clipboard.copy(value.trim(), { concealed: field !== "username" });
    await closeMainWindow();
    await showHUD(`Copied ${field === "otp" ? "one-time code" : field}`);
  } catch (error) {
    await showToast({ style: Toast.Style.Failure, title: `No ${field} on this item`, message: String((error as Error).message) });
  }
}

export default function Search1Password() {
  const [items, setItems] = useState<Item[] | null>(null);
  const [problem, setProblem] = useState<string | null>(op ? null : "missing");

  useEffect(() => {
    if (!op) return;
    run(["item", "list", "--format", "json"])
      .then((output) => setItems(JSON.parse(output) as Item[]))
      .catch((error: Error) => {
        setProblem(error.message);
        setItems([]);
      });
  }, []);

  if (problem) {
    return (
      <List>
        <List.EmptyView
          icon={Icon.Lock}
          title={problem === "missing" ? "1Password CLI not found" : "Couldn't reach 1Password"}
          description={
            problem === "missing"
              ? "Install it with `brew install 1password-cli`, then in 1Password › Settings › Developer turn on “Integrate with 1Password CLI”."
              : `${problem}\n\nIn 1Password › Settings › Developer, turn on “Integrate with 1Password CLI”.`
          }
          actions={
            <ActionPanel>
              <Action.OpenInBrowser title="Open Setup Guide" url="https://developer.1password.com/docs/cli/get-started/" />
            </ActionPanel>
          }
        />
      </List>
    );
  }

  return (
    <List isLoading={items === null} searchBarPlaceholder="Search 1Password…">
      {(items ?? []).map((item) => (
        <List.Item
          key={item.id}
          icon={item.category === "LOGIN" ? Icon.Key : item.category === "CREDIT_CARD" ? Icon.CreditCard : Icon.Lock}
          title={item.title}
          subtitle={item.additional_information}
          keywords={[item.vault.name, ...(item.urls ?? []).map((url) => url.href)]}
          accessories={[{ tag: item.vault.name }]}
          actions={
            <ActionPanel>
              <Action title="Copy Password" icon={Icon.Key} onAction={() => copyField(item, "password")} />
              <Action title="Copy Username" icon={Icon.Person} onAction={() => copyField(item, "username")} />
              <Action title="Copy One-Time Code" icon={Icon.Clock} onAction={() => copyField(item, "otp")} />
              {item.urls?.[0] ? <Action.OpenInBrowser title="Open Website" url={item.urls[0].href} /> : null}
              <Action.Open title="Open in 1Password" target={`onepassword://view-item/?i=${item.id}`} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
