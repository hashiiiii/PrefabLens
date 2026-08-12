import type { DiffV2 } from "../../domain/diff/types";
import type { Result } from "../../domain/result";
import type { ChangedFile, GithubFailure, RefPair } from "../gateway/github";

const CONTEXT_TTL_MS = 60_000;
const BLOB_CACHE_MAX = 32;

type PromiseCache<V> = {
  get(key: string, compute: () => Promise<V>): Promise<V>;
};

type PromiseCacheOptions<V> = {
  // Entries older than this recompute on the next get (the stale promise is overwritten in place).
  ttlMs?: number;
  // Beyond this many entries the oldest-inserted key is evicted.
  max?: number;
  // Decides whether a settled value stays cached. Entries whose value it rejects are dropped. The default keeps everything.
  retain?: (value: V) => boolean;
};

// Keyed async memoization: concurrent gets share the stored Promise. Rejections always drop, so a retry stays possible.
function createPromiseCache<V>(options: PromiseCacheOptions<V>, now: () => number): PromiseCache<V> {
  const { ttlMs, max, retain } = options;
  const entries = new Map<string, { at: number; promise: Promise<V> }>();
  return {
    get(key, compute) {
      const hit = entries.get(key);
      if (hit && (ttlMs === undefined || now() - hit.at < ttlMs)) {
        // LRU: a hit re-inserts the entry, so bursts (prefetch) evict the least recently used entry, not the oldest
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
      entries.set(key, { at: now(), promise });
      if (max !== undefined && entries.size > max) {
        const oldest = entries.keys().next().value;
        if (oldest !== undefined) entries.delete(oldest);
      }
      return promise;
    },
  };
}

// baseShas: path → blob sha at base. null means the tree is unavailable, and the contents API applies instead.
export type DiffContext = {
  refs: RefPair;
  files: ChangedFile[];
  guidIndex: Map<string, string>;
  baseShas: Map<string, string> | null;
};

export type DiffOutcome =
  | { ok: true; json: DiffV2 }
  | {
      ok: false;
      error: GithubFailure["kind"] | "diff-failed" | "not-unity-yaml";
    }
  | { ok: false; error: "too-large"; bytes: number };

export type DiffSession = {
  contexts: PromiseCache<Result<DiffContext, GithubFailure>>;
  blobs: PromiseCache<Result<Uint8Array | null, GithubFailure>>;
  diffs: PromiseCache<DiffOutcome>;
  misses: Set<string>;
  searches: PromiseCache<Result<string | null, GithubFailure>>;
  indexes: PromiseCache<Result<Record<string, string> | null, GithubFailure>>;
  indexFallback: Set<string>;
};

export function createDiffSession(now: () => number = Date.now): DiffSession {
  return {
    contexts: createPromiseCache<Result<DiffContext, GithubFailure>>(
      {
        ttlMs: CONTEXT_TTL_MS,
        retain: (r) => r.ok,
      },
      now,
    ),
    blobs: createPromiseCache<Result<Uint8Array | null, GithubFailure>>(
      {
        max: BLOB_CACHE_MAX,
        retain: (r) => r.ok,
      },
      now,
    ),
    diffs: createPromiseCache<DiffOutcome>(
      {
        retain: (o) => o.ok,
      },
      now,
    ),
    misses: new Set(),
    searches: createPromiseCache<Result<string | null, GithubFailure>>({ retain: () => false }, now),
    indexes: createPromiseCache<Result<Record<string, string> | null, GithubFailure>>(
      {
        retain: (r) => r.ok,
      },
      now,
    ),
    indexFallback: new Set(),
  };
}
