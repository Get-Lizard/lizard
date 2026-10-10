import { Action, ActionPanel, Form, Icon, List, open, showToast, Toast, useNavigation } from "@raycast/api";
import { useEffect, useState } from "react";
import { Favorite, deepLink, loadFavorites, parseSlackLink, saveFavorites } from "./links";

export default function OpenFavorite() {
  const [favorites, setFavorites] = useState<Favorite[] | null>(null);

  const reload = () => loadFavorites().then(setFavorites);
  useEffect(() => {
    reload();
  }, []);

  const remove = async (favorite: Favorite) => {
    const next = (favorites ?? []).filter((item) => item.id !== favorite.id);
    await saveFavorites(next);
    setFavorites(next);
  };

  const addAction = <Action.Push title="Add Favorite" icon={Icon.Plus} target={<AddFavorite onSaved={reload} />} />;

  return (
    <List isLoading={favorites === null} searchBarPlaceholder="Search favourites…">
      <List.EmptyView
        icon={Icon.SpeechBubble}
        title="No favourites yet"
        description="In Slack, right-click a channel or person › Copy › Copy link, then add it here."
        actions={<ActionPanel>{addAction}</ActionPanel>}
      />
      {(favorites ?? []).map((favorite) => (
        <List.Item
          key={favorite.id}
          icon={favorite.kind === "user" ? Icon.Person : Icon.Hashtag}
          title={favorite.name}
          subtitle={favorite.kind === "user" ? "Person" : "Channel"}
          actions={
            <ActionPanel>
              <Action title="Open in Slack" icon={Icon.ArrowRight} onAction={() => open(deepLink(favorite))} />
              {addAction}
              <Action title="Remove Favorite" icon={Icon.Trash} style={Action.Style.Destructive} onAction={() => remove(favorite)} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}

function AddFavorite({ onSaved }: { onSaved: () => void }) {
  const { pop } = useNavigation();
  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Save Favorite"
            onSubmit={async (values: { name: string; link: string; team: string }) => {
              const parsed = parseSlackLink(values.link, values.team || undefined);
              if (!parsed || !values.name) {
                await showToast({ style: Toast.Style.Failure, title: "Need a name and a Slack link", message: "For …slack.com/archives links, also fill in the workspace ID (T…)." });
                return;
              }
              const favorites = await loadFavorites();
              favorites.push({ id: `${parsed.team}:${parsed.target}`, name: values.name, ...parsed });
              await saveFavorites(favorites);
              onSaved();
              pop();
            }}
          />
        </ActionPanel>
      }
    >
      <Form.TextField id="name" title="Name" placeholder="#eng-backend" />
      <Form.TextField id="link" title="Slack link" placeholder="https://app.slack.com/client/T…/C…" />
      <Form.TextField id="team" title="Workspace ID" placeholder="T0123ABCD (only for …/archives/ links)" />
      <Form.Description text="Copy a link from Slack (right-click › Copy › Copy link). No tokens or sign-in needed — Lizard just opens the Slack app." />
    </Form>
  );
}
