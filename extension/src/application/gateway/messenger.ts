import type { DiffTarget, DiffV2 } from "../../domain/diff/types";

export type SemanticDiffRequest = {
  type: "semanticDiff";
  owner: string;
  repo: string;
  target: DiffTarget;
  path: string;
  force?: boolean;
};

export type PrefetchRequest = {
  type: "prefetch";
  owner: string;
  repo: string;
  prNumber: number;
};

export type BackgroundRequest = SemanticDiffRequest | PrefetchRequest;

export type BackgroundError =
  | "access-token-missing"
  | "auth-failed"
  | "rate-limited"
  | "fetch-failed"
  | "diff-failed"
  | "not-unity-yaml";

export type AuthError = Extract<BackgroundError, "access-token-missing" | "auth-failed">;

export function isAuthError(error: BackgroundError): error is AuthError {
  return error === "access-token-missing" || error === "auth-failed";
}

export type SemanticDiffResponse =
  | { ok: true; json: DiffV2; pending?: boolean }
  | { ok: false; error: BackgroundError }
  | { ok: false; error: "too-large"; bytes: number };

export type ResolutionStatus = "complete" | "rateLimited" | "failed";

export type GuidResolvedPush = {
  type: "guidResolved";
  owner: string;
  repo: string;
  target: DiffTarget;
  path: string;
  resolved: Record<string, string>;
  json?: DiffV2;
  done: boolean;
  status?: ResolutionStatus;
};

export type SemanticDiffEvent =
  | { type: "response"; response: SemanticDiffResponse }
  | { type: "resolution"; message: GuidResolvedPush };

export type MessengerGateway = {
  semanticDiff(req: SemanticDiffRequest): Promise<SemanticDiffResponse>;
  prefetch(req: PrefetchRequest): Promise<void>;
};
