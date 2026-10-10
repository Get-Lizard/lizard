// Bundles the host (with React, the renderer and the API shim) and the extension builder into dist/.
import { build } from "esbuild";
import { cpSync, mkdirSync } from "node:fs";

mkdirSync("dist", { recursive: true });
await build({
  entryPoints: { host: "src/host.js", "build-extension": "src/build-extension.js" },
  bundle: true,
  platform: "node",
  format: "cjs",
  target: "node20",
  outdir: "dist",
  external: ["esbuild"],
  logLevel: "warning",
});
// esbuild itself is needed at runtime by build-extension (it ships a native binary).
cpSync("node_modules/esbuild", "dist/node_modules/esbuild", { recursive: true });
cpSync("node_modules/@esbuild", "dist/node_modules/@esbuild", { recursive: true });
console.log("shim built");
