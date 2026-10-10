import { LocalStorage } from "@raycast/api";

export interface Favorite {
  id: string;
  name: string;
  team: string;
  target: string;
  kind: "channel" | "user";
}

const KEY = "favorites";

export async function loadFavorites(): Promise<Favorite[]> {
  const raw = await LocalStorage.getItem<string>(KEY);
  return raw ? (JSON.parse(raw) as Favorite[]) : [];
}

export async function saveFavorites(favorites: Favorite[]) {
  await LocalStorage.setItem(KEY, JSON.stringify(favorites));
}

/**
 * Understands the links Slack's "Copy link" produces:
 *   https://app.slack.com/client/T0123/C0456
 *   https://acme.slack.com/archives/C0456 (team needed separately)
 *   https://acme.slack.com/team/U0789
 */
export function parseSlackLink(link: string, team?: string): Pick<Favorite, "team" | "target" | "kind"> | null {
  let url: URL;
  try {
    url = new URL(link.trim());
  } catch {
    return null;
  }
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts[0] === "client" && parts.length >= 3) {
    return { team: parts[1], target: parts[2], kind: parts[2].startsWith("U") || parts[2].startsWith("W") ? "user" : "channel" };
  }
  if ((parts[0] === "archives" || parts[0] === "team") && parts[1] && team) {
    return { team, target: parts[1], kind: parts[0] === "team" ? "user" : "channel" };
  }
  return null;
}

export function deepLink(favorite: Favorite): string {
  return favorite.kind === "user"
    ? `slack://user?team=${favorite.team}&id=${favorite.target}`
    : `slack://channel?team=${favorite.team}&id=${favorite.target}`;
}
