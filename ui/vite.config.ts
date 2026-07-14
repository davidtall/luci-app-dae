import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  base: './',
  plugins: [vue()],
  build: {
    target: 'es2018',
    outDir: '../luci-app-dae/root/www/luci-static/resources/dae/dashboard',
    emptyOutDir: true,
    sourcemap: false,
    rollupOptions: {
      output: {
        entryFileNames: 'assets/dashboard-[hash].js',
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: (assetInfo) =>
          assetInfo.names.some((name) => name.endsWith('.css'))
            ? 'assets/dashboard-[hash][extname]'
            : 'assets/[name]-[hash][extname]',
      },
    },
  },
})
