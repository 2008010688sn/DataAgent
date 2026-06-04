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

import axios from 'axios';

const LOCAL_TOKEN = (import.meta.env.VITE_DATA_AGENT_TOKEN || '').trim();
const LOCAL_AUTH_ENABLED =
  import.meta.env.DEV &&
  import.meta.env.VITE_DATA_AGENT_LOCAL_AUTH_ENABLED !== 'false' &&
  Boolean(LOCAL_TOKEN);

const normalizeBearerToken = (token: string): string => {
  const value = token.trim();
  return value.toLowerCase().startsWith('bearer ') ? value : `Bearer ${value}`;
};

export const DATA_AGENT_AUTH_HEADER = 'V4-Authorization';

export const DATA_AGENT_AUTH_VALUE = LOCAL_AUTH_ENABLED
  ? normalizeBearerToken(LOCAL_TOKEN)
  : null;

if (DATA_AGENT_AUTH_VALUE) {
  axios.defaults.headers.common[DATA_AGENT_AUTH_HEADER] = DATA_AGENT_AUTH_VALUE;
}

export const dataAgentAuthHeaders = (): Record<string, string> => ({
  ...(DATA_AGENT_AUTH_VALUE ? { [DATA_AGENT_AUTH_HEADER]: DATA_AGENT_AUTH_VALUE } : {}),
});

const shouldAttachLocalAuth = (url: string): boolean => {
  return url.startsWith('/api') || url.startsWith('/nl2sql') || url.startsWith('/uploads');
};

const attachLocalAuthHeaders = (headers?: HeadersInit): Headers => {
  const nextHeaders = new Headers(headers);
  if (DATA_AGENT_AUTH_VALUE) {
    nextHeaders.set(DATA_AGENT_AUTH_HEADER, DATA_AGENT_AUTH_VALUE);
  }
  return nextHeaders;
};

const installFetchLocalAuth = (): void => {
  if (!DATA_AGENT_AUTH_VALUE || typeof window === 'undefined' || window.fetch == null) {
    return;
  }
  const originalFetch = window.fetch.bind(window);
  window.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input instanceof Request ? input.url : input.toString();
    if (!shouldAttachLocalAuth(url)) {
      return originalFetch(input, init);
    }
    if (input instanceof Request) {
      return originalFetch(new Request(input, { headers: attachLocalAuthHeaders(input.headers) }), init);
    }
    return originalFetch(input, { ...init, headers: attachLocalAuthHeaders(init?.headers) });
  };
};

installFetchLocalAuth();
