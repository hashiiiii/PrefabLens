import { createHandler } from './handler';
import { createQueue } from './queue';
import { GithubClient } from '../github/client';
import { createDiffer, type Differ } from '../wasm/differ';
import type { BackgroundRequest, DiffV2 } from '../types';

let differ: Promise<Differ> | undefined;

// REST 全体で同時 6 本(spec B2)。ユーザー操作由来は front で行列を追い越す
const queue = createQueue(6);
const queuedFetch = (front: boolean): typeof fetch => (input, init) => queue(() => fetch(input, init), { front });

const SESSION_MAX_BYTES = 512 * 1024; // storage.session は 10MB: 大物はメモリのみ(SW が死んだら再計算)

const handler = createHandler({
  async getSettings() {
    const stored = await chrome.storage.local.get(['pat', 'baseUrl']);
    return { pat: stored['pat'] as string | undefined, baseUrl: stored['baseUrl'] as string | undefined };
  },
  makeClient: (base, token, lane) => new GithubClient(base, token, queuedFetch(lane === 'user')),
  getDiffer() {
    // 遅延シングルトン。SW が再起動したらフェッチし直すだけ。
    differ ??= fetch(chrome.runtime.getURL('prefablens.wasm'))
      .then((r) => r.arrayBuffer())
      .then(createDiffer);
    return differ;
  },
  guidCache: {
    async load(repo) {
      const key = `guids:${repo}`;
      const stored = await chrome.storage.local.get([key]);
      return (stored[key] as Record<string, string> | undefined) ?? {};
    },
    async save(repo, entries) {
      const key = `guids:${repo}`;
      const stored = await chrome.storage.local.get([key]);
      await chrome.storage.local.set({ [key]: { ...(stored[key] as Record<string, string> | undefined), ...entries } });
    },
  },
  diffStore: {
    async load(key) {
      const stored = await chrome.storage.session.get([`diff:${key}`]);
      return stored[`diff:${key}`] as DiffV2 | undefined;
    },
    async save(key, json) {
      if (JSON.stringify(json).length > SESSION_MAX_BYTES) return;
      await chrome.storage.session.set({ [`diff:${key}`]: json }).catch(() => {
        // quota 超過等は無視: メモリキャッシュだけで続行する
      });
    },
  },
});

chrome.runtime.onMessage.addListener((msg: BackgroundRequest, _sender, sendResponse) => {
  if (msg?.type === 'semanticDiff') {
    void handler.semanticDiff(msg).then(sendResponse);
    return true; // 非同期応答
  }
  if (msg?.type === 'prefetch') void handler.prefetch(msg);
  return undefined; // prefetch は応答しない(fire-and-forget)
});
