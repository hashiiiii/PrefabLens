import type { Result } from "../domain/result";
import type { ChangedFile, GithubFailure, RefPair } from "./port/github";

const CONTEXT_TTL_MS = 60_000;
const BLOB_CACHE_MAX = 32;

type PromiseCache<V> = {
  get(key: string, compute: () => Promise<V>): Promise<V>;
};

type PromiseCacheOptions<V> = {
  /** Entries older than this recompute on the next get (the stale promise is overwritten in place). */
  ttlMs?: number;
  /** Beyond this many entries the oldest-inserted key is evicted. */
  max?: number;
  /** Decides whether a settled value stays cached; entries whose value it rejects are dropped. Default keeps everything. */
  retain?: (value: V) => boolean;
};

// Keyed async memoization: storing the Promise folds concurrent gets; rejections always drop for retry.
function createPromiseCache<V>(options: PromiseCacheOptions<V> = {}): PromiseCache<V> {
  const { ttlMs, max, retain } = options;
  const entries = new Map<string, { at: number; promise: Promise<V> }>();
  return {
    get(key, compute) {
      const hit = entries.get(key);
      if (hit && (ttlMs === undefined || Date.now() - hit.at < ttlMs)) {
        // LRU: re-insert on hit so bursts (prefetch) evict least-recently-used, not oldest
        entries.delete(key);
        entries.set(key, hit);
        return hit.promise;
      }
      const promise = compute();
      promise.then(
        (value) => {
          if (retain && !retain(value)) entries.delete(key);
        },
        () => entries.delete(key), // never cache failures
      );
      entries.set(key, { at: Date.now(), promise });
      if (max !== undefined && entries.size > max) {
        const oldest = entries.keys().next().value;
        if (oldest !== undefined) entries.delete(oldest);
      }
      return promise;
    },
  };
}

// baseShas: path → blob sha at base. null = tree unavailable → contents-api fallback
export type DiffContext = {
  refs: RefPair;
  files: ChangedFile[];
  guidIndex: Map<string, string>;
  baseShas: Map<string, string> | null;
};

export type DiffOutcome =
  | { ok: true; json: import("../domain/diff/types").DiffV2 }
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
