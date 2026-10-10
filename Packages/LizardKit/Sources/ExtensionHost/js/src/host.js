// Entry point: `node host.js`. Lizard sends {"type":"launch",…}; the host loads the command
// bundle, renders it (view / menu-bar) or runs it (no-view), and streams view trees back.
"use strict";

// stdout is the protocol channel: route console output to stderr before anything else runs.
for (const level of ["log", "info", "debug", "warn"]) console[level] = (...args) => process.stderr.write(args.map(String).join(" ") + "\n");

const Module = require("node:module");
const React = require("react");
const jsxRuntime = require("react/jsx-runtime");
const bridge = require("./bridge");
const api = require("./api");
const utils = require("./utils");
const { createRenderer, serialize } = require("./renderer");

// Extensions are bundled with react / @raycast/* left external; resolve them to our copies so
// there is exactly one React and one API instance.
const provided = {
  react: React,
  "react/jsx-runtime": jsxRuntime,
  "react/jsx-dev-runtime": jsxRuntime,
  "@raycast/api": api,
  "@raycast/utils": utils,
};
const originalLoad = Module._load;
Module._load = function load(request, parent, isMain) {
  if (Object.prototype.hasOwnProperty.call(provided, request)) return provided[request];
  return originalLoad.call(this, request, parent, isMain);
};

const { state, NavigationContext, actionRegistry } = api.__internal;

let callbacks = new Map();
let renderTimer = null;
let latestChildren = [];
let navigationDepth = 0;

function scheduleRender() {
  if (renderTimer) return;
  renderTimer = setTimeout(() => {
    renderTimer = null;
    const next = new Map();
    const tree = serialize(latestChildren, next);
    callbacks = next;
    bridge.send({ type: "render", tree, depth: navigationDepth });
  }, 12);
}

/** Root component: owns the navigation stack, provides push/pop to useNavigation. */
function Root({ initial }) {
  const [stack, setStack] = React.useState([{ element: initial }]);
  const navigation = React.useMemo(() => ({
    push(element, onPop) {
      setStack((current) => [...current, { element, onPop }]);
    },
    pop() {
      setStack((current) => {
        if (current.length <= 1) return current;
        current[current.length - 1].onPop?.();
        return current.slice(0, -1);
      });
    },
  }), []);
  rootNavigation = navigation;
  navigationDepth = stack.length - 1;
  const top = stack[stack.length - 1];
  return React.createElement(NavigationContext.Provider, { value: navigation }, top.element);
}

let rootNavigation = null;

class ErrorBoundary extends React.Component {
  constructor(props) {
    super(props);
    this.state = { error: null };
  }
  static getDerivedStateFromError(error) {
    return { error };
  }
  componentDidCatch(error) {
    bridge.reportError(error);
  }
  render() {
    if (this.state.error) {
      const message = String(this.state.error?.stack ?? this.state.error);
      return React.createElement(api.Detail, { markdown: "## Something went wrong\n\n```\n" + message.slice(0, 4000) + "\n```" });
    }
    return this.props.children;
  }
}

async function launch(message) {
  const { bundle, command, extension, preferences, launchType, arguments: args, launchContext } = message;
  Object.assign(api.environment, {
    commandName: command.name,
    commandMode: command.mode,
    extensionName: extension.name,
    assetsPath: extension.assetsPath,
    supportPath: extension.supportPath,
    launchType: launchType ?? api.LaunchType.UserInitiated,
    ownerOrAuthorName: extension.author ?? "",
    appearance: message.appearance ?? "dark",
    theme: { appearance: message.appearance ?? "dark" },
  });
  state.preferences = preferences ?? {};
  state.arguments = args ?? {};
  state.launchContext = launchContext ?? undefined;
  process.chdir(extension.path);

  const exported = require(bundle);
  const entry = exported?.default ?? exported;
  const props = { arguments: state.arguments, launchContext: state.launchContext, launchType: api.environment.launchType, fallbackText: message.fallbackText };

  if (command.mode === "no-view") {
    if (typeof entry !== "function") throw new Error("A no-view command must export a default function.");
    await entry(props);
    // Give queued notifications (toasts, HUDs) a moment to flush.
    setTimeout(() => bridge.send({ type: "done" }), 30);
    return;
  }

  const renderer = createRenderer((children) => {
    latestChildren = children;
    scheduleRender();
  });
  const container = renderer.createContainer({ children: [] }, 0, null, false, null, "", (error) => bridge.reportError(error), null);
  const element = React.createElement(ErrorBoundary, null, React.createElement(Root, { initial: React.createElement(entry, props) }));
  renderer.updateContainer(element, container, null, null);
}

bridge.on("launch", (message) =>
  launch(message).catch((error) => {
    bridge.reportError(error);
    if (message.command?.mode === "no-view") setTimeout(() => bridge.send({ type: "done" }), 30);
  }),
);

bridge.on("event", async (message) => {
  const callback = callbacks.get(message.callback) ?? actionRegistry.get(message.callback);
  if (!callback) return;
  try {
    await callback(...(message.args ?? []));
  } catch (error) {
    await api.showToast({ style: api.Toast.Style.Failure, title: "Error", message: String(error?.message ?? error) });
  }
});

bridge.on("pop", () => rootNavigation?.pop());

process.on("uncaughtException", (error) => bridge.reportError(error));
process.on("unhandledRejection", (error) => bridge.reportError(error));

bridge.start();
bridge.send({ type: "ready" });
