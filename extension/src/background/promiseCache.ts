import { must } from "../util/must";

export type PromiseCache<V> = {
  /** Returns the cached promise for the key, computing (and caching) it on a miss. */
  get(key: string, compute: () => Promise<V>): Promise<V>;
};

export type PromiseCacheOptions<V> = {
  /** Entries older than this recompute on the next get (the stale promise is overwritten in place). */
  ttlMs?: number;
  /** Beyond this many entries the oldest-inserted key is evicted. */
  max?: number;
  /** Decides whether a settled value stays cached; entries whose value it rejects are dropped. Default keeps everything. */
  retain?: (value: V) => boolean;
};

/** Keyed memoization of async computations for the background handler's caches.
 *  Storing the Promise itself folds concurrent requests for the same key into one
 *  computation; rejections are always dropped so the next get can retry. */
export function createPromiseCache<V>(options: PromiseCacheOptions<V> = {}): PromiseCache<V> {
  const { ttlMs, max, retain } = options;
  const entries = new Map<string, { at: number; promise: Promise<V> }>();
  return {
    get(key, compute) {
      const hit = entries.get(key);
      if (hit && (ttlMs === undefined || Date.now() - hit.at < ttlMs)) return hit.promise;
      const promise = compute();
      promise.then(
        (value) => {
          if (retain && !retain(value)) entries.delete(key);
        },
        () => entries.delete(key), // never cache failures
      );
      entries.set(key, { at: Date.now(), promise });
      if (max !== undefined && entries.size > max) entries.delete(must(entries.keys().next().value));
      return promise;
    },
  };
}
