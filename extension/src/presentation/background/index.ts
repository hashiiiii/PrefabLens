import { computeSemanticDiff } from "../../application/diff/compute-semantic-diff";
import { prefetchPr } from "../../application/diff/prefetch-pr";
import type { BackgroundRequest, GuidResolvedPush } from "../../domain/diff/types";
import { createBackgroundDeps } from "../../infrastructure/container";

const { deps, session } = createBackgroundDeps();

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
      void computeSemanticDiff(deps, session, msg, makeGuidPush(sender.tab?.id)).then(sendResponse);
      return true; // async response
    }
    case "prefetch":
      void prefetchPr(deps, session, msg);
      return undefined; // prefetch is fire-and-forget
  }
});
