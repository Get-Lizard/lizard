// Lizard's implementation of the public `@raycast/api` surface. Components render to host
// nodes the native app understands; services talk to Lizard over the bridge or use macOS
// command-line tools directly.
"use strict";

const React = require("react");
const fs = require("node:fs");
const path = require("node:path");
const { execFile, execFileSync } = require("node:child_process");
const bridge = require("./bridge");

const h = React.createElement;

// ---------------------------------------------------------------------------------------------
// Environment and preferences (filled in by the host before the command runs)

const LaunchType = Object.freeze({ UserInitiated: "userInitiated", Background: "background" });

const environment = {
  appearance: "dark",
  assetsPath: "",
  commandMode: "view",
  commandName: "",
  extensionName: "",
  isDevelopment: false,
  launchType: LaunchType.UserInitiated,
  raycastVersion: "1.100.0",
  ownerOrAuthorName: "",
  supportPath: "",
  textSize: "medium",
  theme: { appearance: "dark" },
  // AI is only "accessible" when the person has some AI set up in Lizard.
  canAccess: (api) => (api === AI ? process.env.LIZARD_AI_AVAILABLE === "1" : true),
};

const state = { preferences: {}, launchContext: undefined, arguments: {} };

function getPreferenceValues() {
  return { ...state.preferences };
}

// ---------------------------------------------------------------------------------------------
// Icons, colors, images, keyboard (plain data the native side maps to SF Symbols / colors)

const Icon = new Proxy({}, { get: (_, name) => (typeof name === "string" ? `icon:${name}` : undefined) });

const Color = Object.freeze({
  Blue: "color:blue", Green: "color:green", Magenta: "color:magenta", Orange: "color:orange", Purple: "color:purple",
  Red: "color:red", Yellow: "color:yellow", PrimaryText: "color:primaryText", SecondaryText: "color:secondaryText",
});

const Image = { Mask: Object.freeze({ Circle: "circle", RoundedRectangle: "roundedRectangle" }) };

const Keyboard = {
  Shortcut: {
    Common: Object.freeze({
      Copy: { modifiers: ["cmd", "shift"], key: "c" }, CopyDeeplink: { modifiers: ["cmd", "shift"], key: "c" },
      CopyName: { modifiers: ["cmd", "shift"], key: "." }, CopyPath: { modifiers: ["cmd", "shift"], key: "," },
      Duplicate: { modifiers: ["cmd"], key: "d" }, Edit: { modifiers: ["cmd"], key: "e" }, MoveDown: { modifiers: ["cmd", "shift"], key: "arrowDown" },
      MoveUp: { modifiers: ["cmd", "shift"], key: "arrowUp" }, New: { modifiers: ["cmd"], key: "n" }, Open: { modifiers: ["cmd"], key: "o" },
      OpenWith: { modifiers: ["cmd", "shift"], key: "o" }, Pin: { modifiers: ["cmd", "shift"], key: "p" }, Refresh: { modifiers: ["cmd"], key: "r" },
      Remove: { modifiers: ["ctrl"], key: "x" }, RemoveAll: { modifiers: ["ctrl", "shift"], key: "x" }, ToggleQuickLook: { modifiers: ["cmd"], key: "y" },
    }),
  },
};

// ---------------------------------------------------------------------------------------------
// Components. Element-valued props (actions, detail, metadata…) become "slot:<name>" children
// so they go through the renderer like everything else.

function host(type, slots = []) {
  function Component(props) {
    const rest = { ...props };
    const children = rest.children;
    delete rest.children;
    const slotElements = [];
    for (const slot of slots) {
      if (rest[slot] != null) slotElements.push(h(`slot:${slot}`, { key: `slot:${slot}` }, rest[slot]));
      delete rest[slot];
    }
    return h(type, rest, ...slotElements, children);
  }
  Component.displayName = type;
  return Component;
}

const List = host("List", ["searchBarAccessory", "actions"]);
List.Section = host("List.Section");
List.Item = host("List.Item", ["actions", "detail"]);
List.Item.Detail = host("List.Item.Detail", ["metadata"]);
List.Item.Detail.Metadata = host("Metadata");
List.Item.Detail.Metadata.Label = host("Metadata.Label");
List.Item.Detail.Metadata.Link = host("Metadata.Link");
List.Item.Detail.Metadata.Separator = host("Metadata.Separator");
List.Item.Detail.Metadata.TagList = host("Metadata.TagList");
List.Item.Detail.Metadata.TagList.Item = host("Metadata.TagList.Item");
List.EmptyView = host("List.EmptyView", ["actions"]);
List.Dropdown = host("List.Dropdown");
List.Dropdown.Item = host("List.Dropdown.Item");
List.Dropdown.Section = host("List.Dropdown.Section");

const Grid = host("Grid", ["searchBarAccessory", "actions"]);
Grid.Section = host("Grid.Section");
Grid.Item = host("Grid.Item", ["actions"]);
Grid.EmptyView = host("Grid.EmptyView", ["actions"]);
Grid.Dropdown = List.Dropdown;
Grid.Inset = Object.freeze({ Small: "small", Medium: "medium", Large: "large" });
Grid.Fit = Object.freeze({ Contain: "contain", Fill: "fill" });

const Detail = host("Detail", ["actions", "metadata"]);
Detail.Metadata = List.Item.Detail.Metadata;

const Form = host("Form", ["actions", "searchBarAccessory"]);
for (const field of ["TextField", "TextArea", "PasswordField", "Checkbox", "DatePicker", "Description", "Separator", "FilePicker", "LinkAccessory"]) {
  Form[field] = host(`Form.${field}`);
}
Form.Dropdown = host("Form.Dropdown");
Form.Dropdown.Item = host("Form.Dropdown.Item");
Form.Dropdown.Section = host("Form.Dropdown.Section");
Form.TagPicker = host("Form.TagPicker");
Form.TagPicker.Item = host("Form.TagPicker.Item");
Form.DatePicker.Type = Object.freeze({ Date: "date", DateTime: "dateTime" });

const ActionPanel = host("ActionPanel");
ActionPanel.Section = host("ActionPanel.Section");
ActionPanel.Submenu = host("ActionPanel.Submenu");

const MenuBarExtra = host("MenuBarExtra");
MenuBarExtra.Item = host("MenuBarExtra.Item");
MenuBarExtra.Section = host("MenuBarExtra.Section");
MenuBarExtra.Submenu = host("MenuBarExtra.Submenu");
MenuBarExtra.Separator = host("MenuBarExtra.Separator");

// Actions: every variant is an "Action" node with a title and an onAction the native side calls.
const ActionHost = host("Action");

function makeAction(defaults, run) {
  return function ActionVariant(props) {
    const navigation = useNavigationInternal();
    const { onAction, ...rest } = props;
    return h(ActionHost, {
      ...defaults(props),
      ...rest,
      title: props.title ?? defaults(props).title,
      onAction: async (...args) => {
        try {
          await run(props, navigation, args);
          if (onAction) await onAction(...args);
        } catch (error) {
          await showToast({ style: Toast.Style.Failure, title: "Action failed", message: String(error?.message ?? error) });
        }
      },
    });
  };
}

const Action = function Action(props) {
  return h(ActionHost, props);
};
Action.Style = Object.freeze({ Regular: "regular", Destructive: "destructive" });
Action.CopyToClipboard = makeAction(
  () => ({ title: "Copy to Clipboard", icon: Icon.Clipboard, kind: "copy" }),
  async (props) => {
    await Clipboard.copy(props.content, { concealed: props.concealed });
    if (props.onCopy) props.onCopy(props.content);
    await showHUD("Copied to Clipboard");
  },
);
Action.Paste = makeAction(
  () => ({ title: "Paste", icon: Icon.Clipboard, kind: "paste" }),
  async (props) => {
    await Clipboard.paste(props.content);
    if (props.onPaste) props.onPaste(props.content);
  },
);
Action.OpenInBrowser = makeAction(
  () => ({ title: "Open in Browser", icon: Icon.Globe, kind: "open" }),
  async (props) => {
    await open(props.url);
    if (props.onOpen) props.onOpen(props.url);
    await closeMainWindow();
  },
);
Action.Open = makeAction(
  (props) => ({ title: props.title ?? "Open", icon: Icon.ArrowRight, kind: "open" }),
  async (props) => {
    await open(props.target, props.application);
    if (props.onOpen) props.onOpen(props.target);
    await closeMainWindow();
  },
);
Action.OpenWith = makeAction(
  () => ({ title: "Open With…", icon: Icon.AppWindow, kind: "open" }),
  async (props) => open(props.path),
);
Action.ShowInFinder = makeAction(
  () => ({ title: "Show in Finder", icon: Icon.Finder, kind: "open" }),
  async (props) => showInFinder(props.path),
);
Action.Trash = makeAction(
  () => ({ title: "Move to Trash", icon: Icon.Trash, style: Action.Style.Destructive }),
  async (props) => {
    await trash(props.paths);
    if (props.onTrash) props.onTrash(props.paths);
  },
);
Action.Push = makeAction(
  (props) => ({ title: props.title, icon: props.icon ?? Icon.ArrowRight, kind: "push" }),
  async (props, navigation) => {
    navigation.push(props.target, props.onPop);
    if (props.onPush) props.onPush();
  },
);
Action.SubmitForm = function SubmitForm(props) {
  const { onSubmit, ...rest } = props;
  return h(ActionHost, { title: "Submit", icon: Icon.Checkmark, ...rest, kind: "submitForm", onSubmit: onSubmit ?? (() => {}) });
};
Action.CreateQuicklink = makeAction(() => ({ title: "Create Quicklink", icon: Icon.Link }), async () => {});
Action.CreateSnippet = makeAction(() => ({ title: "Create Snippet", icon: Icon.Text }), async () => {});
Action.ToggleQuickLook = makeAction(() => ({ title: "Quick Look", icon: Icon.Eye }), async () => {});
Action.PickDate = makeAction(() => ({ title: "Pick Date", icon: Icon.Calendar }), async () => {});

// ---------------------------------------------------------------------------------------------
// Navigation (the host owns the stack and provides it through context)

const NavigationContext = React.createContext(null);

function useNavigationInternal() {
  return React.useContext(NavigationContext) ?? { push() {}, pop() {} };
}

function useNavigation() {
  const navigation = useNavigationInternal();
  return { push: navigation.push, pop: navigation.pop };
}

// ---------------------------------------------------------------------------------------------
// Feedback

class Toast {
  constructor(options) {
    this.id = Toast.nextId++;
    this._options = { style: Toast.Style.Success, ...options };
  }
  get style() { return this._options.style; }
  set style(value) { this._options.style = value; this._send(); }
  get title() { return this._options.title; }
  set title(value) { this._options.title = value; this._send(); }
  get message() { return this._options.message; }
  set message(value) { this._options.message = value; this._send(); }
  get primaryAction() { return this._options.primaryAction; }
  set primaryAction(value) { this._options.primaryAction = value; this._send(); }
  get secondaryAction() { return this._options.secondaryAction; }
  set secondaryAction(value) { this._options.secondaryAction = value; this._send(); }
  async show() { this._send(); }
  async hide() { bridge.notify("toast.hide", { id: this.id }); }
  _send() {
    const { style, title, message, primaryAction } = this._options;
    if (primaryAction?.onAction) actionRegistry.set(`toast.${this.id}`, () => primaryAction.onAction(this));
    bridge.notify("toast.show", {
      id: this.id, style, title: String(title ?? ""), message: message == null ? null : String(message),
      primaryAction: primaryAction ? { title: primaryAction.title, callback: `toast.${this.id}` } : null,
    });
  }
}
Toast.nextId = 1;
Toast.Style = Object.freeze({ Success: "SUCCESS", Failure: "FAILURE", Animated: "ANIMATED" });

/** Callbacks that live outside the view tree (toast buttons). */
const actionRegistry = new Map();

async function showToast(optionsOrStyle, title, message) {
  const options = typeof optionsOrStyle === "object" ? optionsOrStyle : { style: optionsOrStyle, title, message };
  const toast = new Toast(options);
  await toast.show();
  return toast;
}

async function showHUD(title, options) {
  bridge.notify("hud", { title: String(title) });
  if (options?.clearRootSearch || options?.popToRootType) bridge.notify("popToRoot", {});
  await closeMainWindow();
}

const Alert = { ActionStyle: Object.freeze({ Default: "default", Cancel: "cancel", Destructive: "destructive" }) };

async function confirmAlert(options) {
  const result = await bridge.request("confirmAlert", {
    title: options.title, message: options.message ?? null,
    primary: options.primaryAction?.title ?? "OK", destructive: options.primaryAction?.style === Alert.ActionStyle.Destructive,
    dismiss: options.dismissAction?.title ?? "Cancel",
  });
  if (result) await options.primaryAction?.onAction?.();
  else await options.dismissAction?.onAction?.();
  return Boolean(result);
}

const PopToRootType = Object.freeze({ Default: "default", Immediate: "immediate", Suspended: "suspended" });

async function closeMainWindow(options) {
  bridge.notify("closeMainWindow", { popToRoot: options?.popToRootType ?? "default" });
}

async function popToRoot() {
  bridge.notify("popToRoot", {});
}

async function clearSearchBar() {
  bridge.notify("clearSearchBar", {});
}

// ---------------------------------------------------------------------------------------------
// System

function run(file, args, input) {
  return new Promise((resolve, reject) => {
    const child = execFile(file, args, { maxBuffer: 32 * 1024 * 1024 }, (error, stdout) => (error ? reject(error) : resolve(stdout)));
    if (input != null) {
      child.stdin.end(input);
    }
  });
}

const Clipboard = {
  async copy(content, options) {
    if (content && typeof content === "object" && content.file) {
      await run("/usr/bin/osascript", ["-e", `set the clipboard to (POSIX file "${String(content.file).replace(/"/g, '\\"')}")`]);
    } else {
      const text = typeof content === "object" && content !== null ? content.text ?? content.html ?? "" : String(content ?? "");
      await run("/usr/bin/pbcopy", [], text);
    }
    bridge.notify("clipboard.copied", { concealed: Boolean(options?.concealed) });
  },
  async paste(content) {
    if (content != null) await Clipboard.copy(content);
    await bridge.request("clipboard.paste", {});
  },
  async readText() {
    const text = await run("/usr/bin/pbpaste", []);
    return text === "" ? undefined : text;
  },
  async read() {
    return { text: await Clipboard.readText() };
  },
  async clear() {
    await run("/usr/bin/pbcopy", [], "");
  },
};

async function open(target, application) {
  const app = typeof application === "object" && application ? application.path ?? application.name : application;
  await run("/usr/bin/open", app ? ["-a", app, String(target)] : [String(target)]);
}

async function showInFinder(target) {
  await run("/usr/bin/open", ["-R", String(target)]);
}

async function trash(paths) {
  const list = Array.isArray(paths) ? paths : [paths];
  for (const item of list) {
    await run("/usr/bin/osascript", ["-e", `tell application "Finder" to delete (POSIX file "${String(item).replace(/"/g, '\\"')}")`]);
  }
}

async function getApplications(target) {
  return bridge.request("applications", { target: target ?? null });
}

async function getFrontmostApplication() {
  return bridge.request("frontmostApplication", {});
}

async function getDefaultApplication(target) {
  const apps = await getApplications(target);
  return apps[0];
}

async function getSelectedText() {
  const text = await bridge.request("selectedText", {});
  if (!text) throw new Error("No text selected");
  return text;
}

async function getSelectedFinderItems() {
  const output = await run("/usr/bin/osascript", [
    "-e", 'tell application "Finder" to set theSelection to selection as alias list',
    "-e", 'set out to ""', "-e", "repeat with f in theSelection", "-e", 'set out to out & POSIX path of f & linefeed', "-e", "end repeat", "-e", "return out",
  ]).catch(() => "");
  return output.split("\n").filter(Boolean).map((p) => ({ path: p }));
}

async function launchCommand(options) {
  return bridge.request("launchCommand", {
    name: options.name, type: options.type ?? LaunchType.UserInitiated, extensionName: options.extensionName ?? null,
    arguments: options.arguments ?? {}, context: options.context ?? null,
  });
}

async function updateCommandMetadata(metadata) {
  bridge.notify("updateCommandMetadata", { subtitle: metadata?.subtitle ?? null });
}

async function openExtensionPreferences() {
  bridge.notify("openPreferences", { scope: "extension" });
}

async function openCommandPreferences() {
  bridge.notify("openPreferences", { scope: "command" });
}

function captureException(error) {
  console.error("[extension exception]", error);
}

// ---------------------------------------------------------------------------------------------
// Storage: JSON files in the command's support folder.

function supportFile(name) {
  fs.mkdirSync(environment.supportPath || ".", { recursive: true });
  return path.join(environment.supportPath || ".", name);
}

function readJSON(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return {};
  }
}

function writeJSON(file, value) {
  const temp = `${file}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(value));
  fs.renameSync(temp, file);
}

const LocalStorage = {
  async getItem(key) {
    return readJSON(supportFile("local-storage.json"))[key];
  },
  async setItem(key, value) {
    const file = supportFile("local-storage.json");
    const data = readJSON(file);
    data[key] = value;
    writeJSON(file, data);
  },
  async removeItem(key) {
    const file = supportFile("local-storage.json");
    const data = readJSON(file);
    delete data[key];
    writeJSON(file, data);
  },
  async allItems() {
    return readJSON(supportFile("local-storage.json"));
  },
  async clear() {
    writeJSON(supportFile("local-storage.json"), {});
  },
};

class Cache {
  constructor(options = {}) {
    this.namespace = options.namespace ?? "default";
    this.subscribers = new Set();
  }
  get file() {
    return supportFile(`cache-${this.namespace.replace(/[^a-z0-9_-]/gi, "_")}.json`);
  }
  get(key) {
    return readJSON(this.file)[key];
  }
  has(key) {
    return key in readJSON(this.file);
  }
  set(key, value) {
    const data = readJSON(this.file);
    data[key] = value;
    writeJSON(this.file, data);
    for (const subscriber of this.subscribers) subscriber(key, value);
  }
  remove(key) {
    const data = readJSON(this.file);
    const existed = key in data;
    delete data[key];
    writeJSON(this.file, data);
    for (const subscriber of this.subscribers) subscriber(key, undefined);
    return existed;
  }
  clear() {
    writeJSON(this.file, {});
    for (const subscriber of this.subscribers) subscriber(undefined, undefined);
  }
  get isEmpty() {
    return Object.keys(readJSON(this.file)).length === 0;
  }
  subscribe(subscriber) {
    this.subscribers.add(subscriber);
    return () => this.subscribers.delete(subscriber);
  }
}

// ---------------------------------------------------------------------------------------------
// AI: answered by the AI the person set up in Lizard (on-device first; their own cloud accounts
// when allowed). `model` picks their matching account (Claude → Anthropic or OpenRouter…).
// "data" listeners receive the answer in chunks as it streams; the promise resolves to all of it.

const AI = {
  Model: new Proxy({}, { get: (_, name) => String(name) }),
  Creativity: Object.freeze({ None: "none", Low: "low", Medium: "medium", High: "high", Maximum: "maximum" }),
  ask(prompt, options) {
    const listeners = [];
    const params = { prompt: String(prompt), creativity: options?.creativity ?? null, model: options?.model ?? null };
    const promise = bridge.request("ai.ask", params, (chunk) => {
      for (const listener of listeners) listener(String(chunk ?? ""));
    });
    promise.on = (event, listener) => {
      if (event === "data") listeners.push(listener);
      return promise;
    };
    return promise;
  },
};

// ---------------------------------------------------------------------------------------------
// OAuth: browser sign-in isn't wired for extensions yet; fail clearly.

const OAuth = {
  RedirectMethod: Object.freeze({ Web: "web", App: "app", AppURI: "appURI" }),
  PKCEClient: class PKCEClient {
    constructor(options) {
      this.options = options;
    }
    async authorizationRequest() {
      throw new Error("OAuth sign-in for extensions isn't supported in Lizard yet.");
    }
    async authorize() {
      throw new Error("OAuth sign-in for extensions isn't supported in Lizard yet.");
    }
    async getTokens() {
      return undefined;
    }
    async setTokens() {}
    async removeTokens() {}
  },
};

function randomId() {
  return Math.random().toString(36).slice(2);
}

module.exports = {
  // components
  List, Grid, Detail, Form, ActionPanel, Action, MenuBarExtra,
  // data
  Icon, Color, Image, Keyboard, LaunchType, Toast, Alert, PopToRootType, environment,
  // services
  getPreferenceValues, showToast, showHUD, confirmAlert, closeMainWindow, popToRoot, clearSearchBar, Clipboard, open,
  showInFinder, trash, getApplications, getFrontmostApplication, getDefaultApplication, getSelectedText, getSelectedFinderItems,
  launchCommand, updateCommandMetadata, openExtensionPreferences, openCommandPreferences, captureException, LocalStorage, Cache,
  AI, OAuth, useNavigation, randomId,
  // internal (used by the host)
  __internal: { state, NavigationContext, actionRegistry, run, execFileSync },
};
