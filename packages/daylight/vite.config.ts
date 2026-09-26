import { defineConfig } from "vite";

export default defineConfig({
  build: { outDir: "dist", emptyOutDir: true, target: "es2020", sourcemap: false },
  server: {
    port: 5173,
    proxy: {
      "/api": "http://127.0.0.1:7712",
      "/ws": { target: "ws://127.0.0.1:7712", ws: true },
    },
  },
});
