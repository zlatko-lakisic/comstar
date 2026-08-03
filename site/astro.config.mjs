import { defineConfig } from 'astro/config';

// Project Pages: https://zlatko-lakisic.github.io/comstar/
export default defineConfig({
  site: 'https://zlatko-lakisic.github.io',
  base: '/comstar',
  trailingSlash: 'always',
  build: {
    format: 'directory',
  },
});
