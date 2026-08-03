import { createDiffSession } from "../../application/diff/create-diff-session";
import { createPrPrefetch } from "../../application/diff/create-pr-prefetch";
import { getSemanticDiff } from "../../application/diff/get-semantic-diff";
import {
  createDifferLoader,
  createDiffStore,
  createFetchQueue,
  createGithubClient,
  createGithubFetch,
  createGuidCache,
  createRepoIndexStore,
  createTokenStore,
} from "../../container";
import type { BackgroundRequest, GuidResolvedPush } from "../../domain/diff/types";

const tokenStore = createTokenStore();
const guidCache = createGuidCache();
const diffStore = createDiffStore();
const repoIndexStore = createRepoIndexStore();
const getDiffer = createDifferLoader();
const queue = createFetchQueue(6);
const makeClient = (base: string, token: string, lane: "user" | "prefetch") =>
  createGithubClient(base, token, createGithubFetch(queue, lane));
const session = createDiffSession();

function makeGuidPush(tabId: number | undefined): (m: GuidResolvedPush) => void {
  return (m) => {
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
}

chrome.runtime.onMessage.addListener((msg: BackgroundRequest, sender, sendResponse) => {
  switch (msg?.type) {
    case "semanticDiff": {
      void getSemanticDiff(
        tokenStore,
        makeClient,
        getDiffer,
        guidCache,
        diffStore,
        repoIndexStore,
        session,
        msg,
        makeGuidPush(sender.tab?.id),
      ).then(sendResponse);
      return true; // async response
    }
    case "prefetch":
      void createPrPrefetch(tokenStore, makeClient, getDiffer, diffStore, repoIndexStore, session, msg);
      return undefined; // prefetch is fire-and-forget
  }
});
