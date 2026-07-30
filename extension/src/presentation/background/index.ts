import type { BackgroundRequest, GuidResolvedPush } from "../../domain/diff/types";
import { createBackgroundApp } from "../../infrastructure/container";

const { handler } = createBackgroundApp();

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
