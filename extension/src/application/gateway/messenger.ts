import type { PrefetchRequest, SemanticDiffRequest, SemanticDiffResponse } from "../../domain/diff/types";

// Content-script view of the background service worker. Outbound requests go
// through this gateway. Inbound pushes stay presentation-level listeners.
// Implementations never reject: channel loss becomes a failure response.
export type MessengerGateway = {
  semanticDiff(req: SemanticDiffRequest): Promise<SemanticDiffResponse>;
  prefetch(req: PrefetchRequest): Promise<void>;
};
