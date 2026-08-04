import type { MessengerGateway } from "../../application/gateway/messenger";
import type { PrefetchRequest, SemanticDiffRequest, SemanticDiffResponse } from "../../domain/diff/types";

// The chrome.runtime relay to the background service worker. sendMessage
// rejects on channel loss (SW restart, teardown). This is the one place that
// maps channel loss to a failure response, so callers never see a rejection.
export function createChromeMessenger(): MessengerGateway {
  return {
    semanticDiff: (req: SemanticDiffRequest) =>
      (chrome.runtime.sendMessage(req) as Promise<SemanticDiffResponse>).catch(() => ({
        ok: false as const,
        error: "fetch-failed" as const,
      })),
    prefetch: (req: PrefetchRequest) =>
      (chrome.runtime.sendMessage(req) as Promise<unknown>).then(
        () => undefined,
        () => undefined,
      ),
  };
}
