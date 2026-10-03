import { defineConfig } from "vite";

// Served by the Mac app from Contents/Resources/web at http://<mac>:7788/.
// base "./" keeps the bundle relocatable; hashed assets land in dist/assets/ (long cache on the Mac side).
export default defineConfig({
  base: "./",
  build: {
    outDir: "dist",
    assetsDir: "assets",
    target: "es2022",
    sourcemap: false,
  },
  server: { port: 5173, host: "127.0.0.1" },
});
