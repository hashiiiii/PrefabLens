import { must } from "../app/presentation/util/must";

export type PromiseCache<V> = {
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

// Keyed async memoization: storing the Promise folds concurrent gets; rejections always drop for retry.
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
