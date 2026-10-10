import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// Served from GitHub Pages at /lizard/.
export default defineConfig({
  base: "./",
  plugins: [react(), tailwindcss()],
});
