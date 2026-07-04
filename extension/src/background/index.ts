import { createHandler } from './handler';
import { GithubClient } from '../github/client';
import { createDiffer, type Differ } from '../wasm/differ';
import type { SemanticDiffRequest } from '../types';

let differ: Promise<Differ> | undefined;

const handle = createHandler({
  async getSettings() {
    const stored = await chrome.storage.local.get(['pat', 'baseUrl']);
    return { pat: stored['pat'] as string | undefined, baseUrl: stored['baseUrl'] as string | undefined };
  },
  makeClient: (base, token) => new GithubClient(base, token),
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
});

chrome.runtime.onMessage.addListener((msg: SemanticDiffRequest, _sender, sendResponse) => {
  if (msg?.type !== 'semanticDiff') return;
  void handle(msg).then(sendResponse);
  return true; // 非同期応答
});
