// A small React renderer whose "host components" are plain objects. After every commit the
// tree is serialized to JSON for Lizard: functions become callback ids that the native side
// sends back as events; everything else is copied as data.
"use strict";

const Reconciler = require("react-reconciler");
const { DefaultEventPriority } = require("react-reconciler/constants");

let nextNodeId = 1;

function createNode(type, props) {
  return { id: nextNodeId++, type, props: stripChildren(props), children: [], text: null };
}

function stripChildren(props) {
  const { children, ...rest } = props || {};
  return rest;
}

/** Creates a renderer bound to `onCommit(rootChildren)`. */
function createRenderer(onCommit) {
  const hostConfig = {
    supportsMutation: true,
    supportsPersistence: false,
    supportsHydration: false,
    isPrimaryRenderer: true,
    noTimeout: -1,
    scheduleTimeout: setTimeout,
    cancelTimeout: clearTimeout,
    getCurrentEventPriority: () => DefaultEventPriority,
    getInstanceFromNode: () => null,
    beforeActiveInstanceBlur() {},
    afterActiveInstanceBlur() {},
    prepareScopeUpdate() {},
    getInstanceFromScope: () => null,
    detachDeletedInstance() {},

    getRootHostContext: () => ({}),
    getChildHostContext: (parent) => parent,
    getPublicInstance: (instance) => instance,
    prepareForCommit: () => null,
    resetAfterCommit(container) {
      onCommit(container.children);
    },
    preparePortalMount() {},

    createInstance: (type, props) => createNode(type, props),
    createTextInstance: (text) => ({ id: nextNodeId++, type: "#text", props: {}, children: [], text }),
    shouldSetTextContent: () => false,
    finalizeInitialChildren: () => false,

    appendInitialChild: (parent, child) => parent.children.push(child),
    appendChild: (parent, child) => parent.children.push(child),
    appendChildToContainer: (container, child) => container.children.push(child),
    insertBefore(parent, child, before) {
      remove(parent.children, child);
      parent.children.splice(parent.children.indexOf(before), 0, child);
    },
    insertInContainerBefore(container, child, before) {
      remove(container.children, child);
      container.children.splice(container.children.indexOf(before), 0, child);
    },
    removeChild: (parent, child) => remove(parent.children, child),
    removeChildFromContainer: (container, child) => remove(container.children, child),
    clearContainer(container) {
      container.children = [];
    },

    prepareUpdate: () => true,
    commitUpdate(instance, _payload, _type, _oldProps, newProps) {
      instance.props = stripChildren(newProps);
    },
    commitTextUpdate(instance, _old, text) {
      instance.text = text;
    },
    hideInstance(instance) {
      instance.hidden = true;
    },
    unhideInstance(instance) {
      instance.hidden = false;
    },
    hideTextInstance(instance) {
      instance.hidden = true;
    },
    unhideTextInstance(instance) {
      instance.hidden = false;
    },
    resetTextContent() {},
    commitMount() {},
  };
  return Reconciler(hostConfig);
}

function remove(list, item) {
  const index = list.indexOf(item);
  if (index >= 0) list.splice(index, 1);
}

/**
 * Serializes nodes to JSON-safe data. Functions are registered in `callbacks` under a stable
 * id (`<nodeId>.<prop>`) so the native side can invoke them later.
 */
function serialize(nodes, callbacks) {
  const out = [];
  for (const node of nodes) {
    if (node.hidden) continue;
    if (node.type === "#text") {
      if (node.text != null && String(node.text).trim() !== "") out.push({ id: node.id, type: "#text", text: String(node.text) });
      continue;
    }
    out.push({
      id: node.id,
      type: node.type,
      props: serializeValue(node.props, callbacks, String(node.id)),
      children: serialize(node.children, callbacks),
    });
  }
  return out;
}

function serializeValue(value, callbacks, path) {
  if (value == null) return null;
  if (typeof value === "function") {
    callbacks.set(path, value);
    return { $callback: path };
  }
  if (value instanceof Date) return { $date: value.toISOString() };
  if (Array.isArray(value)) return value.map((item, index) => serializeValue(item, callbacks, `${path}.${index}`));
  if (typeof value === "object") {
    // React elements in props are moved to "slot" children by the API layer; drop leftovers.
    if (value.$$typeof) return null;
    const result = {};
    for (const [key, inner] of Object.entries(value)) {
      if (key === "key" || key === "ref") continue;
      const serialized = serializeValue(inner, callbacks, `${path}.${key}`);
      if (serialized !== undefined) result[key] = serialized;
    }
    return result;
  }
  if (typeof value === "number" && !Number.isFinite(value)) return null;
  if (typeof value === "symbol" || typeof value === "bigint") return String(value);
  return value;
}

module.exports = { createRenderer, serialize };
