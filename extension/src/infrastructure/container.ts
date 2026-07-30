import { createHandler, type Handler } from "../application/diff/handler";
import type { DifferPort } from "../application/port/differ";
import { createChromeTokenStore } from "./providers/chrome-token-store";
import { createQueue } from "./providers/fetch-queue";
import { GithubClient } from "./providers/github-client";
import { createDiffer } from "./providers/wasm-differ";
import { createMergeStore } from "./repositories/merge-store";
import { createSessionDiffStore } from "./repositories/session-diff-store";

export type BackgroundApp = {
  handler: Handler;
};

// Wires providers/repositories for the service worker. Message listening stays in presentation.
export function createBackgroundApp(): BackgroundApp {
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

  return { handler };
}
