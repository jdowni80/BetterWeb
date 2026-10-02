import { defineConfig } from "vite";

export default defineConfig({
  server: {
    port: 8743,
    proxy: {
      "/api": "http://127.0.0.1:8742",
    },
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
});
