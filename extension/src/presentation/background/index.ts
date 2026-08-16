import { createDiffSession } from "../../application/diff/create-diff-session";
import { getSemanticDiff } from "../../application/diff/get-semantic-diff";
import { prefetchPr } from "../../application/diff/prefetch-pr";
import type { BackgroundRequest, GuidResolvedPush } from "../../application/gateway/messenger";
import {
  createAuthRepository,
  createDifferGateway,
  createDiffRepository,
  createGithubGateway,
  createGuidRepository,
  createRepoIndexRepository,
} from "../../container";

const authRepository = createAuthRepository();
const guidRepository = createGuidRepository();
const diffRepository = createDiffRepository();
const repoIndexRepository = createRepoIndexRepository();
const getDiffer = createDifferGateway();
const makeGithubGateway = createGithubGateway(6);
const session = createDiffSession();

async function sendGuidResolution(tabId: number | undefined, message: GuidResolvedPush): Promise<void> {
  if (tabId === undefined) return;
  const attempts = message.done ? 3 : 1;
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      await chrome.tabs.sendMessage(tabId, message);
      return;
    } catch {
      if (attempt + 1 === attempts) return;
      // A final message releases the indicator, so retry it after the content script reloads.
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }
}

chrome.runtime.onMessage.addListener((msg: BackgroundRequest, sender, sendResponse) => {
  switch (msg?.type) {
    case "semanticDiff": {
      void (async () => {
        for await (const event of getSemanticDiff(
          authRepository,
          makeGithubGateway,
          getDiffer,
          guidRepository,
          diffRepository,
          repoIndexRepository,
          session,
          msg,
        )) {
          if (event.type === "response") sendResponse(event.response);
          else await sendGuidResolution(sender.tab?.id, event.message);
        }
      })();
      return true; // async response
    }
    case "prefetch":
      void prefetchPr(authRepository, makeGithubGateway, getDiffer, diffRepository, repoIndexRepository, session, msg);
      return undefined; // prefetch is fire-and-forget
  }
});
