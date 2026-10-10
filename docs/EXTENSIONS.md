# Building Lizard extensions

Lizard has **no extension store and no review queue**. An extension is a folder in a GitHub repository (yours, or
anyone's). People install it by pasting the repo link into Lizard; Lizard checks the repo for new commits and offers
updates. Follow this guide and your extension installs cleanly, updates automatically and works in Raycast too.

> **Agents:** this file is the contract. When asked to build a Lizard extension, follow every **must** below, run
> `lizardcli ext validate <folder>` until it reports no errors, and test with `lizardcli ext run`.

---

## 1. Quick start

```sh
lizardcli ext new my-extension <your-github-user>   # scaffold that passes validation (add assets/icon.png)
cd my-extension && npm install                      # types for your editor; Lizard bundles at install time
lizardcli ext validate .                            # check the rules below
lizardcli ext install "$PWD"                        # install your local copy into Lizard
lizardcli ext run my-extension index                # run a command headless; prints its UI tree as JSON
```

Publish by pushing the folder to GitHub. Anyone can then install it from Settings › Extensions › Install with
`github.com/<you>/<repo>` — or `github.com/<you>/<repo>/tree/main/<folder>` when one repo holds several extensions,
optionally pinned to a branch or tag with `@ref` (`<you>/<repo>/<folder>@v1.2.0`).

## 2. What an extension is

A Raycast-format package: Lizard implements the public `@raycast/api` and `@raycast/utils`, so most Raycast
extensions run unchanged and anything you write for Lizard can be submitted to Raycast too.

```
my-extension/
  package.json        manifest (below)
  README.md           what it does, setup, what it accesses
  assets/icon.png     512×512 PNG
  src/<command>.tsx   one entry file per command (default export)
  tsconfig.json
```

### package.json

```jsonc
{
  "name": "my-extension",                  // must: kebab-case, unique; also the install folder name
  "title": "My Extension",                 // must
  "description": "One sentence.",          // must
  "icon": "icon.png",                      // must: file in assets/
  "author": "your-github-user",            // must
  "license": "MIT",                        // must
  "repository": "github.com/you/repo/path",// should: lets people find the source
  "commands": [
    { "name": "index", "title": "Search Things", "description": "…", "mode": "view" },
    { "name": "badge", "title": "Thing Count", "mode": "menu-bar", "interval": "10m" },
    { "name": "quick-add", "title": "Quick Add", "mode": "no-view" }
  ],
  "preferences": [
    { "name": "apiHost", "type": "textfield", "title": "API Host", "default": "https://example.com", "required": false, "description": "…" }
  ],
  "dependencies": { "@raycast/api": "^1.100.0", "@raycast/utils": "^2.0.0" }
}
```

- `mode`: `view` (a List/Detail/Form/Grid in the launcher), `no-view` (runs and exits — show a HUD/toast), or
  `menu-bar` (a menu-bar item; Lizard re-runs it on `interval`, e.g. `"5m"`, `"1h"`, minimum 1 minute recommended).
- Preference types: `textfield`, `password`, `checkbox`, `dropdown` (with `data`), `appPicker`, `file`, `directory`.
  `password` values are never included in backups or exports.

## 3. Rules

**Must**
1. Pass `lizardcli ext validate` with no errors.
2. Keep the extension in a public (or the installer's own) GitHub repo; one folder per extension.
3. Say in the README exactly what it accesses: files and folders, network hosts, other apps, CLIs, AppleScript.
4. Ask before destructive actions (`confirmAlert`) — deleting files, killing processes, sending messages.
5. Never send the user's data anywhere they didn't ask for; no analytics or tracking without an explicit opt-in.
6. Store secrets in `password` preferences (or the system's own CLI login) — never in code, LocalStorage or the repo.
7. Write original code. Don't copy other people's extensions without respecting their license and crediting them.

**Should**
- Prefer local apps, URL schemes and official CLIs (`gh`, `op`, …) over asking users for API keys.
- Handle "not installed / not signed in" with a clear `List.EmptyView` that explains the fix.
- Keep startup fast: show the UI first (`isLoading`), fetch after.
- Keep the folder small (no build output, no `node_modules`, no large media).
- Tag releases (`v1.2.0`) so people can pin a version.

**Don't**
- Rely on npm `install`/`postinstall` scripts — Lizard installs with `--ignore-scripts`.
- Use OAuth through `OAuth.PKCEClient` yet (not supported); use a CLI login or a token preference.
- Write outside `environment.supportPath` except where the user chose a location.

## 4. API support in Lizard

| Area | Supported |
|---|---|
| UI | `List` (sections, items, accessories, detail pane, dropdown, empty view), `Detail` (+ metadata), `Form` (text field/area, password, checkbox, dropdown, date picker, description, separator), `Grid`, `ActionPanel` (+ sections, submenus), `MenuBarExtra` (+ items, sections, submenus, separators) |
| Actions | `Action`, `CopyToClipboard`, `Paste`, `OpenInBrowser`, `Open`, `OpenWith`, `ShowInFinder`, `Trash`, `Push`, `SubmitForm` |
| Feedback | `showToast` (+ updates, primary action), `showHUD`, `confirmAlert`, `closeMainWindow`, `popToRoot` |
| Data | `LocalStorage`, `Cache`, `getPreferenceValues`, `environment` (`supportPath`, `assetsPath`, `launchType`, …) |
| System | `Clipboard`, `open`, `showInFinder`, `trash`, `getSelectedText`, `getSelectedFinderItems`, `getApplications`, `getFrontmostApplication`, `launchCommand`, `updateCommandMetadata` |
| AI | `AI.ask` — answered by the user's Lizard AI (on-device by default) |
| Utils | `usePromise`, `useCachedPromise`, `useCachedState`, `useFetch`, `useExec`, `useLocalStorage`, `useForm` + `FormValidation`, `runAppleScript`, `showFailureToast`, `getFavicon`, `getAvatarIcon`, `withCache`, `useFrecencySorting`, `useAI` |
| Not yet | `OAuth.PKCEClient`, `Action.PickDate`/`CreateQuicklink`/`CreateSnippet`, background intervals for no-view commands, React 19-only APIs |

Icons: use `Icon.*` (mapped to SF Symbols), `Color.*`, image URLs or files in `assets/`.

## 5. Testing

```sh
lizardcli ext validate .
lizardcli ext install "$PWD"           # rebuilds from your folder each time
lizardcli ext run my-extension index   # first settled UI tree as JSON
lizardcli ext run my-extension index someThing=value   # override preferences
```

Inside Lizard, the command appears in search right after install; changes need a reinstall.

## 6. Sharing and updates

- **Updates:** Lizard checks every installed GitHub extension every 6 hours for a newer commit touching its folder
  and offers **Update** (preferences and stored data are kept).
- **Share with a friend:** Settings › Extensions › ⋯ › *Share Extension* writes a `.lizardext` file with the code only —
  none of your preferences or data. They install it with *Install from File…*.
- **Backups** (`.lizardbackup`) include your extensions *with* their data; they're for your own Macs.

## 7. Responsibility

Every extension not shipped inside Lizard is shown as **External**, and Lizard asks for confirmation before installing
one. External extensions are written and maintained by their authors, aren't reviewed by Lizard, and run with the
user's permissions. Lizard isn't responsible for what they do.
