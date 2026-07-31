import type { SemanticDiffRequest, SemanticDiffResponse } from "../../domain/diff/types";
import type { MessengerPort } from "../port/messenger";

// Channel loss (SW restart, teardown) maps to fetch-failed; callers never see a rejection
export function requestSemanticDiff(messenger: MessengerPort, req: SemanticDiffRequest): Promise<SemanticDiffResponse> {
  return messenger.semanticDiff(req).catch(() => ({ ok: false as const, error: "fetch-failed" as const }));
}
