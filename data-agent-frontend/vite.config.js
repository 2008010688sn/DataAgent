/*
 * Copyright 2024-2026 the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import { resolve } from 'path';

const LOCAL_DATA_AGENT_TOKEN = process.env.VITE_DATA_AGENT_TOKEN?.trim();
const LOCAL_DATA_AGENT_AUTH_VALUE = LOCAL_DATA_AGENT_TOKEN
  ? LOCAL_DATA_AGENT_TOKEN.toLowerCase().startsWith('bearer ')
    ? LOCAL_DATA_AGENT_TOKEN
    : `Bearer ${LOCAL_DATA_AGENT_TOKEN}`
  : null;

const withLocalAuthProxy = target => ({
  target,
  changeOrigin: true,
  ...(LOCAL_DATA_AGENT_AUTH_VALUE
    ? {
        headers: {
          'V4-Authorization': LOCAL_DATA_AGENT_AUTH_VALUE,
        },
      }
    : {}),
});

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': resolve(__dirname, 'src'),
    },
  },
  server: {
    port: 3000,
    proxy: {
      '/api': withLocalAuthProxy('http://localhost:8065'),
      '/nl2sql': withLocalAuthProxy('http://localhost:8065'),
      '/uploads': withLocalAuthProxy('http://localhost:8065'),
    },
    historyApiFallback: true,
  },
  build: {
    outDir: 'dist',
    assetsDir: 'assets',
  },
});
