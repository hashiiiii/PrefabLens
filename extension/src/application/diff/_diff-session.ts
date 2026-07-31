import type { ChangedFile, RefPair } from "../port/github";
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
  | { ok: false; error: "not-unity-yaml" };

export type DiffSession = {
  contexts: PromiseCache<DiffContext>;
  blobs: PromiseCache<Uint8Array | null>;
  diffs: PromiseCache<DiffOutcome>;
  // resolution
  misses: Set<string>;
  searches: PromiseCache<string | null>;
  indexes: PromiseCache<Record<string, string> | null>;
  indexFallback: Set<string>;
};

export function createDiffSession(): DiffSession {
  return {
    contexts: createPromiseCache<DiffContext>({ ttlMs: CONTEXT_TTL_MS }),
    blobs: createPromiseCache<Uint8Array | null>({ max: BLOB_CACHE_MAX }),
    diffs: createPromiseCache<DiffOutcome>({
      retain: (o) => o.ok || o.error !== "too-large",
    }),
    misses: new Set(),
    searches: createPromiseCache<string | null>({ retain: () => false }),
    indexes: createPromiseCache<Record<string, string> | null>(),
    indexFallback: new Set(),
  };
}
