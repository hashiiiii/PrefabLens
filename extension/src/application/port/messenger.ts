import type { PrefetchRequest, SemanticDiffRequest, SemanticDiffResponse } from "../../domain/diff/types";

// Content-script view of the background service worker. Outbound requests go
// through this port; inbound pushes stay presentation-level listeners.
export type MessengerPort = {
  semanticDiff(req: SemanticDiffRequest): Promise<SemanticDiffResponse>;
  prefetch(req: PrefetchRequest): Promise<void>;
};
