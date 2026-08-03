import type { MessengerGateway } from "../../application/gateway/messenger";
import type { PrefetchRequest, SemanticDiffRequest, SemanticDiffResponse } from "../../domain/diff/types";

// chrome.runtime relay to the background service worker
export function createChromeMessenger(): MessengerGateway {
  return {
    semanticDiff: (req: SemanticDiffRequest) => chrome.runtime.sendMessage(req) as Promise<SemanticDiffResponse>,
    prefetch: (req: PrefetchRequest) => (chrome.runtime.sendMessage(req) as Promise<unknown>).then(() => undefined),
  };
}
