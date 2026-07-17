import { GithubClient } from "../github/client";
import { GITHUB_ORIGIN, type Instances, permissionPatterns, scriptId, scriptSyncPlan } from "../github/hosts";
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
  async getSettings(origin) {
    // github.com keeps its legacy `pat` key (device flow writes there); other instances live under `instances`.
    if (origin === GITHUB_ORIGIN) {
      const stored = await chrome.storage.local.get(["pat"]);
      return { pat: stored.pat as string | undefined };
    }
    const stored = await chrome.storage.local.get(["instances"]);
    return { pat: (stored.instances as Instances | undefined)?.[origin]?.pat };
  },
  makeClient: (api, token, lane) => new GithubClient(api, token, queuedFetch(lane === "user")),
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
  // The sender is authoritative for the instance origin: a message can be crafted, sender.origin cannot.
  const senderOrigin = sender.origin ?? (sender.url ? new URL(sender.url).origin : undefined);
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
    void handler.semanticDiff(senderOrigin ? { ...msg, origin: senderOrigin } : msg, push).then(sendResponse);
    return true; // async response
  }
  if (msg?.type === "prefetch") void handler.prefetch(senderOrigin ? { ...msg, origin: senderOrigin } : msg);
  if (msg?.type === "openOptions") void chrome.runtime.openOptionsPage();
  return undefined; // prefetch/openOptions don't respond (fire-and-forget)
});

/** Re-registers instance content scripts. Dynamic registrations are cleared on extension
 *  update and permissions can be revoked from chrome://extensions, so every SW start
 *  reconciles the registry against permission-granted instances. */
async function syncInstanceScripts(): Promise<void> {
  const stored = await chrome.storage.local.get(["instances"]);
  const instances = (stored.instances as Instances | undefined) ?? {};
  const granted: string[] = [];
  for (const origin of Object.keys(instances)) {
    const ok = await chrome.permissions.contains({ origins: permissionPatterns(origin) }).catch(() => false);
    if (ok) granted.push(origin);
  }
  const registered = await chrome.scripting.getRegisteredContentScripts();
  const plan = scriptSyncPlan(
    registered.map((s) => s.id),
    granted,
  );
  if (plan.remove.length) await chrome.scripting.unregisterContentScripts({ ids: plan.remove }).catch(() => {});
  if (plan.add.length) {
    await chrome.scripting.registerContentScripts(
      plan.add.map((origin) => ({
        id: scriptId(origin),
        matches: [`${origin}/*`],
        js: ["content.js"],
        runAt: "document_idle" as const,
        persistAcrossSessions: true,
      })),
    );
  }
}
void syncInstanceScripts().catch((err: unknown) => console.debug("prefablens: instance script sync failed", err));
