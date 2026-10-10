// `node build-extension.js <extensionDir> <outDir>`: bundles every command in the extension's
// package.json into <outDir>/<command>.js with react and @raycast/* left external (the host
// provides them). Prints a JSON summary on stdout.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const esbuild = require("esbuild");

async function main() {
  const [extensionDir, outDir] = process.argv.slice(2);
  if (!extensionDir || !outDir) throw new Error("usage: build-extension <extensionDir> <outDir>");
  const manifest = JSON.parse(fs.readFileSync(path.join(extensionDir, "package.json"), "utf8"));
  fs.mkdirSync(outDir, { recursive: true });
  const built = [];
  const failed = [];
  for (const command of manifest.commands ?? []) {
    const entry = ["tsx", "ts", "jsx", "js"].map((ext) => path.join(extensionDir, "src", `${command.name}.${ext}`)).find((file) => fs.existsSync(file));
    if (!entry) {
      failed.push({ command: command.name, error: "entry file not found in src/" });
      continue;
    }
    try {
      await esbuild.build({
        entryPoints: [entry],
        outfile: path.join(outDir, `${command.name}.js`),
        bundle: true,
        platform: "node",
        format: "cjs",
        target: "node20",
        jsx: "automatic",
        external: ["react", "react/*", "react-dom", "@raycast/api", "@raycast/utils"],
        loader: { ".png": "file", ".svg": "text", ".md": "text", ".txt": "text", ".node": "file" },
        nodePaths: [path.join(extensionDir, "node_modules")],
        absWorkingDir: extensionDir,
        logLevel: "silent",
        define: { "process.env.NODE_ENV": '"production"' },
      });
      built.push(command.name);
    } catch (error) {
      failed.push({ command: command.name, error: String(error?.message ?? error).slice(0, 2000) });
    }
  }
  process.stdout.write(JSON.stringify({ built, failed }) + "\n");
  if (built.length === 0 && failed.length > 0) process.exit(1);
}

main().catch((error) => {
  process.stderr.write(String(error?.stack ?? error) + "\n");
  process.exit(1);
});
