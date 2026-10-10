// Newline-delimited JSON between this process (stdout/stdin) and Lizard. stdout carries only
// protocol messages; console output is redirected to stderr so extensions can't corrupt it.
"use strict";

const pending = new Map();
let nextRequestId = 1;
const handlers = new Map();

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

/** Calls a native service and waits for its answer. */
function request(method, params = {}) {
  const id = nextRequestId++;
  send({ type: "request", id, method, params });
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
  });
}

/** Fire-and-forget notification to the native side. */
function notify(method, params = {}) {
  send({ type: "notify", method, params });
}

function on(type, handler) {
  handlers.set(type, handler);
}

function start() {
  let buffer = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        console.error("[lizard] bad message", line.slice(0, 200));
        continue;
      }
      if (message.type === "response") {
        const waiter = pending.get(message.id);
        if (!waiter) continue;
        pending.delete(message.id);
        if (message.error) waiter.reject(new Error(message.error));
        else waiter.resolve(message.result);
        continue;
      }
      const handler = handlers.get(message.type);
      if (handler) {
        Promise.resolve()
          .then(() => handler(message))
          .catch((error) => reportError(error));
      }
    }
  });
  process.stdin.on("end", () => process.exit(0));
}

function reportError(error) {
  send({ type: "error", message: String(error?.message ?? error), stack: String(error?.stack ?? "") });
}

module.exports = { send, request, notify, on, start, reportError };
