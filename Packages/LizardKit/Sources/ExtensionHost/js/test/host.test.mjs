// End-to-end: build the fixture extension, run commands through the host, inspect trees.
import { test, before } from "node:test";
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, "..");
const fixture = path.join(here, "fixtures/sample");
const out = mkdtempSync(path.join(tmpdir(), "lizard-shim-"));

before(() => {
  execFileSync("node", ["scripts/build.mjs"], { cwd: root });
  const summary = JSON.parse(execFileSync("node", [path.join(root, "dist/build-extension.js"), fixture, out]).toString());
  assert.deepEqual(summary.failed, []);
});

/** Runs a command; `onMessage(message, send)` returns true when the test is done. */
function runCommand(name, mode, onMessage) {
  return new Promise((resolve, reject) => {
    const child = spawn("node", [path.join(root, "dist/host.js")], { stdio: ["pipe", "pipe", "pipe"] });
    const send = (message) => child.stdin.write(JSON.stringify(message) + "\n");
    let buffer = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error("timeout\n" + stderr));
    }, 8000);
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const message = JSON.parse(buffer.slice(0, newline));
        buffer = buffer.slice(newline + 1);
        if (message.type === "ready") {
          send({
            type: "launch", bundle: path.join(out, `${name}.js`), command: { name, mode },
            extension: { name: "sample", path: fixture, assetsPath: path.join(fixture, "assets"), supportPath: path.join(out, "support") },
            preferences: { greeting: "hey" },
          });
          continue;
        }
        if (message.type === "error") {
          clearTimeout(timer);
          child.kill();
          reject(new Error(message.message + "\n" + message.stack));
          return;
        }
        if (onMessage(message, send)) {
          clearTimeout(timer);
          child.kill();
          resolve();
        }
      }
    });
  });
}

function find(nodes, type) {
  for (const node of nodes) {
    if (node.type === type) return node;
    const inner = find(node.children ?? [], type);
    if (inner) return inner;
  }
  return null;
}

test("list renders, actions run and re-render", async () => {
  let renders = 0;
  await runCommand("list", "view", (message, send) => {
    if (message.type !== "render") return false;
    renders++;
    const item = find(message.tree, "List.Item");
    assert.ok(item);
    if (renders === 1) {
      assert.equal(item.props.title, "hey 0");
      assert.equal(item.props.icon, "icon:Star");
      const action = find(item.children, "Action");
      assert.equal(action.props.title, "Increment");
      send({ type: "event", callback: action.props.onAction.$callback, args: [] });
      return false;
    }
    assert.equal(item.props.title, "hey 1");
    return true;
  });
});

test("form submit passes values", async () => {
  await runCommand("form", "view", (message, send) => {
    if (message.type === "render") {
      const submit = find(message.tree, "Action");
      assert.equal(submit.props.kind, "submitForm");
      assert.ok(find(message.tree, "Form.TextField"));
      send({ type: "event", callback: submit.props.onSubmit.$callback, args: [{ name: "Ada" }] });
      return false;
    }
    if (message.type === "notify" && message.method === "toast.show") {
      assert.equal(message.params.title, "hello Ada");
      return true;
    }
    return false;
  });
});

test("menu bar tree", async () => {
  await runCommand("menu", "menu-bar", (message) => {
    if (message.type !== "render") return false;
    const extra = find(message.tree, "MenuBarExtra");
    assert.equal(extra.props.title, "3");
    assert.ok(find(extra.children, "MenuBarExtra.Item"));
    return true;
  });
});

test("no-view command finishes", async () => {
  let hud = false;
  await runCommand("quick", "no-view", (message) => {
    if (message.type === "notify" && message.method === "hud") hud = message.params.title === "done quick";
    return message.type === "done";
  });
  assert.ok(hud);
});
