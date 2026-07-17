import { GithubClient } from "../github/client";
import type { BackgroundRequest, GuidResolvedPush } from "../types";
import { createDiffer, type Differ } from "../wasm/differ";
import { createSessionDiffStore } from "./diffStore";
import { createHandler } from "./handler";
import { createQueue } from "./queue";

let differ: Promise<Differ> | undefined;

// Six concurrent across all REST/GraphQL. GraphQL also goes through fetchFn, so it shares the same budget.
// User-action-originated requests jump the queue via front
const queue = createQueue(6);
const queuedFetch =
  (front: boolean): typeof fetch =>
  (input, init) =>
    queue(() => fetch(input, init), { front });

const handler = createHandler({
  async getSettings() {
    const stored = await chrome.storage.local.get(["pat"]);
    return { pat: stored.pat as string | undefined };
  },
  makeClient: (base, token, lane) => new GithubClient(base, token, queuedFetch(lane === "user")),
  getDiffer() {
    // Lazy singleton. If the SW restarts, just re-fetch.
    differ ??= fetch(chrome.runtime.getURL("prefablens.wasm"))
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
        .catch(() => {}); // on quota overflow, continue in memory only
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
  if (msg?.type === "semanticDiff") {
    const tabId = sender.tab?.id;
    // semanticDiff requests always originate in a tab content script; guard defensively so a non-tab sender no-ops.
    const push = (m: GuidResolvedPush) => {
      if (tabId === undefined) return;
      // The final push releases the content-side indicator: retry a dropped tab message
      // (SPA navigation races, transient port loss) before giving up. Intermediate pushes
      // stay fire-and-forget — losing one only delays names until the final push.
      const attempt = (left: number): void => {
        void chrome.tabs.sendMessage(tabId, m).catch(() => {
          if (m.done && left > 0) setTimeout(() => attempt(left - 1), 1000);
        });
      };
      attempt(2);
    };
    void handler.semanticDiff(msg, push).then(sendResponse);
    return true; // async response
  }
  if (msg?.type === "prefetch") void handler.prefetch(msg);
  return undefined; // prefetch doesn't respond (fire-and-forget)
});
