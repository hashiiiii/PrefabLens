import type { DifferPort } from "../app/application/port/differ";
import { createChromeTokenStore } from "../app/infrastructure/providers/chrome-token-store";
import { createQueue } from "../app/infrastructure/providers/fetch-queue";
import { GithubClient } from "../app/infrastructure/providers/github-client";
import { createDiffer } from "../app/infrastructure/providers/wasm-differ";
import { createMergeStore } from "../app/infrastructure/repositories/merge-store";
import { createSessionDiffStore } from "../app/infrastructure/repositories/session-diff-store";
import type { BackgroundRequest, GuidResolvedPush } from "../app/domain/diff/types";
import { createHandler } from "./handler";

let differ: Promise<DifferPort> | undefined;

// Six concurrent across REST/GraphQL (GraphQL shares fetchFn). User-action jumps via front.
const queue = createQueue(6);
const queuedFetch =
  (front: boolean): typeof fetch =>
  (input, init) =>
    queue(() => fetch(input, init), { front });

const tokenStore = createChromeTokenStore(chrome.storage.local);

// Whole-repo .meta guid records for repoIndexStore.loadGuids/saveGuids
const metaGuids = createMergeStore(chrome.storage.local, "metaGuids");

const handler = createHandler({
  getSettings: async () => ({ accessToken: await tokenStore.readAccessToken() }),
  makeClient: (base, token, lane) => new GithubClient(base, token, queuedFetch(lane === "user")),
  getDiffer() {
    // Lazy singleton; SW restart → re-fetch
    differ ??= fetch(chrome.runtime.getURL("prefablens.wasm"))
      .then((r) => r.arrayBuffer())
      .then(createDiffer);
    return differ;
  },
  // Same merge-on-save slot under different prefixes
  guidCache: createMergeStore(chrome.storage.local, "guids"),
  diffStore: createSessionDiffStore(chrome.storage.session),
  repoIndexStore: {
    loadGuids: (repo) => metaGuids.load(repo),
    saveGuids: (repo, entries) => metaGuids.save(repo, entries).catch(() => {}), // quota overflow → memory only
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
    // semanticDiff always originates in a tab content script; non-tab sender no-ops
    const push = (m: GuidResolvedPush) => {
      if (tabId === undefined) return;
      // Final push releases the indicator: retry a dropped tab message before giving up.
      // Intermediate pushes stay fire-and-forget — losing one only delays names until final.
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
  return undefined; // prefetch is fire-and-forget
});
