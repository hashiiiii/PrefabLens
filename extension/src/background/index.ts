import { createHandler } from './handler';
import { createQueue } from './queue';
import { createSessionDiffStore } from './diffStore';
import { GithubClient } from '../github/client';
import { createDiffer, type Differ } from '../wasm/differ';
import type { BackgroundRequest, GuidResolvedPush } from '../types';

let differ: Promise<Differ> | undefined;

// REST/GraphQL 全体で同時 6 本(spec B2)。GraphQL も fetchFn 経由なので同じ枠を共有する。
// ユーザー操作由来は front で行列を追い越す
const queue = createQueue(6);
const queuedFetch = (front: boolean): typeof fetch => (input, init) => queue(() => fetch(input, init), { front });

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
  diffStore: createSessionDiffStore(chrome.storage.session),
  repoIndexStore: {
    async loadGuids(repo) {
      const key = `metaGuids:${repo}`;
      const stored = await chrome.storage.local.get([key]);
      return (stored[key] as Record<string, string> | undefined) ?? {};
    },
    async saveGuids(repo, entries) {
      const key = `metaGuids:${repo}`;
      const stored = await chrome.storage.local.get([key]);
      await chrome.storage.local
        .set({ [key]: { ...(stored[key] as Record<string, string> | undefined), ...entries } })
        .catch(() => {}); // quota 超過はメモリのみで続行
    },
    async loadIndex(repo) {
      const key = `guidIndex:${repo}`;
      const stored = await chrome.storage.local.get([key]);
      return stored[key] as { treeSha: string; guids: Record<string, string> } | undefined;
    },
    async saveIndex(repo, index) {
      await chrome.storage.local.set({ [`guidIndex:${repo}`]: index }).catch(() => {});
    },
  },
});

chrome.runtime.onMessage.addListener((msg: BackgroundRequest, sender, sendResponse) => {
  if (msg?.type === 'semanticDiff') {
    const tabId = sender.tab?.id;
    const push =
      tabId === undefined ? undefined : (m: GuidResolvedPush) => void chrome.tabs.sendMessage(tabId, m).catch(() => {});
    void handler.semanticDiff(msg, push).then(sendResponse);
    return true; // 非同期応答
  }
  if (msg?.type === 'prefetch') void handler.prefetch(msg);
  return undefined; // prefetch は応答しない(fire-and-forget)
});
