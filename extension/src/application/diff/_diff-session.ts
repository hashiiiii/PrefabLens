import type { Result } from "../../domain/result";
import type { ChangedFile, GithubFailure, RefPair } from "../port/github";
import { createPromiseCache, type PromiseCache } from "./_promise-cache";

const CONTEXT_TTL_MS = 60_000;
const BLOB_CACHE_MAX = 32;

// baseShas: path → blob sha at base. null = tree unavailable → contents-api fallback
export type DiffContext = {
  refs: RefPair;
  files: ChangedFile[];
  guidIndex: Map<string, string>;
  baseShas: Map<string, string> | null;
};

export type DiffOutcome =
  | { ok: true; json: import("../../domain/diff/types").DiffV2 }
  | { ok: false; error: "too-large"; bytes: number }
  | { ok: false; error: "not-unity-yaml" | "diff-failed" | "auth-failed" | "rate-limited" | "fetch-failed" };

export type DiffSession = {
  contexts: PromiseCache<Result<DiffContext, GithubFailure>>;
  blobs: PromiseCache<Result<Uint8Array | null, GithubFailure>>;
  diffs: PromiseCache<DiffOutcome>;
  // resolution
  misses: Set<string>;
  searches: PromiseCache<Result<string | null, GithubFailure>>;
  indexes: PromiseCache<Result<Record<string, string> | null, GithubFailure>>;
  indexFallback: Set<string>;
};

export function createDiffSession(): DiffSession {
  return {
    contexts: createPromiseCache<Result<DiffContext, GithubFailure>>({
      ttlMs: CONTEXT_TTL_MS,
      retain: (r) => r.ok,
    }),
    blobs: createPromiseCache<Result<Uint8Array | null, GithubFailure>>({
      max: BLOB_CACHE_MAX,
      retain: (r) => r.ok,
    }),
    diffs: createPromiseCache<DiffOutcome>({
      retain: (o) => o.ok || o.error !== "too-large",
    }),
    misses: new Set(),
    searches: createPromiseCache<Result<string | null, GithubFailure>>({ retain: () => false }),
    indexes: createPromiseCache<Result<Record<string, string> | null, GithubFailure>>({
      retain: (r) => r.ok,
    }),
    indexFallback: new Set(),
  };
}
