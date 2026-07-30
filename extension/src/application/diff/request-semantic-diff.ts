import type { SemanticDiffRequest, SemanticDiffResponse } from "../../domain/diff/types";
import type { MessengerPort } from "../port/messenger";

export type RequestSemanticDiffDeps = { messenger: MessengerPort };
export type RequestSemanticDiff = (req: SemanticDiffRequest) => Promise<SemanticDiffResponse>;

// Channel loss (SW restart, teardown) maps to fetch-failed; callers never see a rejection
export function createRequestSemanticDiff(deps: RequestSemanticDiffDeps): RequestSemanticDiff {
  return (req) =>
    deps.messenger.semanticDiff(req).catch(() => ({ ok: false as const, error: "fetch-failed" as const }));
}
