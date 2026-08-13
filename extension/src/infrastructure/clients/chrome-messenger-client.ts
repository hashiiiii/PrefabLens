import type {
  MessengerGateway,
  PrefetchRequest,
  SemanticDiffRequest,
  SemanticDiffResponse,
} from "../../application/gateway/messenger";

// The chrome.runtime relay to the background service worker. sendMessage
// rejects on channel loss (SW restart, teardown). This is the one place that
// maps channel loss to a failure response, so callers never see a rejection.
export function createChromeMessengerGateway(): MessengerGateway {
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
